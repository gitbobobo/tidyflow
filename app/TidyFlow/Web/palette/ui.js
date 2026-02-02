/**
 * TidyFlow Palette - UI, shortcuts, init, export
 */
(function () {
  "use strict";

  const P = window.TidyFlowPalette;

  let paletteEl = null;
  let paletteInputEl = null;
  let paletteListEl = null;
  let paletteMode = "command";
  let paletteItems = [];
  let selectedIndex = 0;
  let isOpen = false;

  const shortcuts = new Map();

  function getFileIcon(filename) {
    const ext = filename.split(".").pop().toLowerCase();
    const icons = {
      js: "📜", ts: "📘", jsx: "⚛️", tsx: "⚛️",
      html: "🌐", css: "🎨", json: "📋",
      md: "📝", txt: "📄",
      rs: "🦀", go: "🐹", py: "🐍",
      swift: "🍎", java: "☕",
      png: "🖼️", jpg: "🖼️", gif: "🖼️", svg: "🖼️",
    };
    return icons[ext] || "📄";
  }

  function formatShortcut(shortcut) {
    if (!shortcut) return "";
    return shortcut
      .replace("Cmd", "⌘")
      .replace("Ctrl", "⌃")
      .replace("Alt", "⌥")
      .replace("Shift", "⇧")
      .replace(/\+/g, "");
  }

  function createPaletteUI() {
    if (paletteEl) return;

    paletteEl = document.createElement("div");
    paletteEl.id = "command-palette";
    paletteEl.className = "palette-overlay";
    paletteEl.innerHTML = `
      <div class="palette-container">
        <div class="palette-input-wrapper">
          <span class="palette-prefix"></span>
          <input type="text" class="palette-input" placeholder="Type to search...">
        </div>
        <div class="palette-list"></div>
        <div class="palette-footer">
          <span class="palette-hint">↑↓ Navigate</span>
          <span class="palette-hint">↵ Select</span>
          <span class="palette-hint">Esc Close</span>
        </div>
      </div>
    `;

    document.body.appendChild(paletteEl);

    paletteInputEl = paletteEl.querySelector(".palette-input");
    paletteListEl = paletteEl.querySelector(".palette-list");

    paletteEl.addEventListener("click", (e) => {
      if (e.target === paletteEl) closePalette();
    });

    paletteInputEl.addEventListener("input", () => filterItems(paletteInputEl.value));
    paletteInputEl.addEventListener("keydown", handlePaletteKeydown);
  }

  function openPalette(mode) {
    createPaletteUI();

    paletteMode = mode;
    isOpen = true;
    selectedIndex = 0;

    const prefixEl = paletteEl.querySelector(".palette-prefix");

    if (mode === "command") {
      prefixEl.textContent = ">";
      paletteInputEl.placeholder = "Type a command...";
      loadCommands();
    } else {
      prefixEl.textContent = "";
      paletteInputEl.placeholder = "Type a file name...";
      loadFiles();
    }

    paletteEl.classList.add("open");
    paletteInputEl.value = "";
    paletteInputEl.focus();
  }

  function closePalette() {
    if (!paletteEl) return;
    paletteEl.classList.remove("open");
    isOpen = false;
    paletteItems = [];
  }

  function loadCommands() {
    const hasWorkspace = window.tidyflow &&
      window.tidyflow.getCurrentProject() &&
      window.tidyflow.getCurrentWorkspace();

    const scope = hasWorkspace ? "workspace" : "global";
    const availableCommands = P.getCommands(scope === "workspace" ? "all" : "global");

    paletteItems = availableCommands.map((cmd) => ({
      type: "command",
      id: cmd.id,
      label: cmd.label,
      description: cmd.description,
      shortcut: cmd.shortcut,
      disabled: cmd.scope === "workspace" && !hasWorkspace,
      handler: cmd.handler,
    }));

    renderItems(paletteItems);
  }

  function loadFiles() {
    const hasWorkspace = window.tidyflow &&
      window.tidyflow.getCurrentProject() &&
      window.tidyflow.getCurrentWorkspace();

    if (!hasWorkspace) {
      paletteItems = [];
      paletteListEl.innerHTML = '<div class="palette-empty">Select a workspace first</div>';
      return;
    }

    const project = window.tidyflow.getCurrentProject();
    const workspace = window.tidyflow.getCurrentWorkspace();
    const cachedIndex = window.tidyflow.getFileIndex(project, workspace);

    if (cachedIndex && cachedIndex.items && cachedIndex.items.length > 0) {
      P.fileIndex = cachedIndex.items;
      paletteItems = P.fileIndex.map((path) => ({
        type: "file",
        path: path,
        label: path.split("/").pop(),
        description: path,
      }));
      renderItems(paletteItems);

      if (cachedIndex.truncated) {
        const warning = document.createElement("div");
        warning.className = "palette-warning";
        warning.textContent = "File list truncated (too many files)";
        paletteListEl.insertBefore(warning, paletteListEl.firstChild);
      }
      return;
    }

    paletteListEl.innerHTML = '<div class="palette-loading">Loading file index...</div>';

    P.updateFileIndex((files) => {
      if (!isOpen || paletteMode !== "file") return;

      if (files.length === 0) {
        paletteListEl.innerHTML = '<div class="palette-empty">No files found</div>';
        return;
      }

      paletteItems = files.map((path) => ({
        type: "file",
        path: path,
        label: path.split("/").pop(),
        description: path,
      }));
      renderItems(paletteItems);
    });
  }

  function filterItems(query) {
    if (!query) {
      if (paletteMode === "command") loadCommands();
      else loadFiles();
      return;
    }

    let filtered;
    if (paletteMode === "command") {
      filtered = paletteItems
        .map((item) => {
          const result = P.fuzzyMatch(query, item.label);
          return { ...item, ...result };
        })
        .filter((item) => item.match)
        .sort((a, b) => b.score - a.score);
    } else {
      filtered = paletteItems
        .map((item) => {
          const result = P.fuzzyMatch(query, item.path || item.label);
          return { ...item, ...result };
        })
        .filter((item) => item.match)
        .sort((a, b) => b.score - a.score);
    }

    paletteItems = filtered;
    selectedIndex = 0;
    renderItems(filtered, query);
  }

  function renderItems(items, query = "") {
    if (items.length === 0) {
      paletteListEl.innerHTML = '<div class="palette-empty">No results found</div>';
      return;
    }

    paletteListEl.innerHTML = items.slice(0, 50).map((item, idx) => {
      const isSelected = idx === selectedIndex;
      const isDisabled = item.disabled;

      let labelHtml = item.label;
      let descHtml = item.description || "";

      if (query && item.indices) {
        if (paletteMode === "file") {
          descHtml = P.highlightMatches(item.description || item.path, item.indices);
        } else {
          labelHtml = P.highlightMatches(item.label, item.indices);
        }
      }

      const shortcutHtml = item.shortcut
        ? `<span class="palette-shortcut">${formatShortcut(item.shortcut)}</span>`
        : "";

      const icon = item.type === "file" ? getFileIcon(item.label) : "⌘";

      return `
        <div class="palette-item ${isSelected ? "selected" : ""} ${isDisabled ? "disabled" : ""}"
             data-index="${idx}">
          <span class="palette-icon">${icon}</span>
          <div class="palette-item-content">
            <span class="palette-label">${labelHtml}</span>
            ${descHtml ? `<span class="palette-desc">${descHtml}</span>` : ""}
          </div>
          ${shortcutHtml}
        </div>
      `;
    }).join("");

    paletteListEl.querySelectorAll(".palette-item").forEach((el) => {
      el.addEventListener("click", () => {
        const idx = parseInt(el.dataset.index);
        selectItem(idx);
      });
    });
  }

  function selectItem(idx) {
    const items = paletteListEl.querySelectorAll(".palette-item");
    const item = items[idx];
    if (!item || item.classList.contains("disabled")) return;

    const data = paletteItems[idx];

    if (!data) return;

    closePalette();

    if (data.type === "command" && data.handler) {
      data.handler();
    } else if (data.type === "file" && data.path) {
      if (window.tidyflow && window.tidyflow.getCurrentProject()) {
        window.tidyflow.sendFileRead(
          window.tidyflow.getCurrentProject(),
          window.tidyflow.getCurrentWorkspace(),
          data.path,
        );
      }
    }
  }

  function handlePaletteKeydown(e) {
    const items = paletteListEl.querySelectorAll(".palette-item:not(.disabled)");
    const itemCount = items.length;

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        selectedIndex = (selectedIndex + 1) % Math.max(1, itemCount);
        updateSelection();
        break;

      case "ArrowUp":
        e.preventDefault();
        selectedIndex = (selectedIndex - 1 + itemCount) % Math.max(1, itemCount);
        updateSelection();
        break;

      case "Enter":
        e.preventDefault();
        selectItem(selectedIndex);
        break;

      case "Escape":
        e.preventDefault();
        closePalette();
        break;
    }
  }

  function updateSelection() {
    const items = paletteListEl.querySelectorAll(".palette-item");
    items.forEach((el, idx) => {
      el.classList.toggle("selected", idx === selectedIndex);
    });

    const selected = items[selectedIndex];
    if (selected) selected.scrollIntoView({ block: "nearest" });
  }

  function registerShortcut(key, handler, options = {}) {
    shortcuts.set(key, { handler, ...options });
  }

  function normalizeKey(e) {
    const parts = [];
    if (e.metaKey) parts.push("Cmd");
    if (e.ctrlKey) parts.push("Ctrl");
    if (e.altKey) parts.push("Alt");
    if (e.shiftKey) parts.push("Shift");

    let key = e.key;
    if (key === " ") key = "Space";
    if (key.length === 1) key = key.toUpperCase();

    parts.push(key);
    return parts.join("+");
  }

  function handleGlobalKeydown(e) {
    if (isOpen && (e.key === "ArrowUp" || e.key === "ArrowDown" || e.key === "Enter" || e.key === "Escape")) {
      return;
    }

    const key = normalizeKey(e);

    // 当焦点在终端中时，只保留必要的全局快捷键，其他键传递给终端
    // 这对于 TUI 应用（vim、tmux、opencode 等）非常重要
    const terminalContainer = document.activeElement?.closest(".terminal-container");
    // #region agent log
    fetch('http://127.0.0.1:7246/ingest/32320cbc-e53a-472d-b913-91a971c9bee7',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'ui.js:handleGlobalKeydown',message:'Global keydown',data:{key,inTerminal:!!terminalContainer,activeEl:document.activeElement?.tagName,activeClass:document.activeElement?.className},timestamp:Date.now(),sessionId:'debug-session',hypothesisId:'B'})}).catch(()=>{});
    // #endregion
    if (terminalContainer) {
      // 仅保留命令面板快捷键，其他键让终端处理
      const allowedInTerminal = ["Cmd+Shift+P", "Cmd+P"];
      if (!allowedInTerminal.includes(key)) {
        return;
      }
    }

    const shortcut = shortcuts.get(key);

    if (shortcut) {
      if (shortcut.scope === "workspace") {
        const hasWorkspace = window.tidyflow &&
          window.tidyflow.getCurrentProject() &&
          window.tidyflow.getCurrentWorkspace();
        if (!hasWorkspace) return;
      }

      e.preventDefault();
      shortcut.handler();
    }
  }

  function switchToNextTab() {
    if (!window.tidyflow) return;
    const tabs = window.tidyflow.getWorkspaceTabs();
    if (tabs.length === 0) return;

    const activeId = window.tidyflow.getActiveTabId();
    const currentIdx = tabs.findIndex((t) => t.id === activeId);
    const nextIdx = (currentIdx + 1) % tabs.length;
    window.tidyflow.switchToTab(tabs[nextIdx].id);
  }

  function switchToPrevTab() {
    if (!window.tidyflow) return;
    const tabs = window.tidyflow.getWorkspaceTabs();
    if (tabs.length === 0) return;

    const activeId = window.tidyflow.getActiveTabId();
    const currentIdx = tabs.findIndex((t) => t.id === activeId);
    const prevIdx = (currentIdx - 1 + tabs.length) % tabs.length;
    window.tidyflow.switchToTab(tabs[prevIdx].id);
  }

  function init() {
    registerShortcut("Cmd+Shift+P", () => openPalette("command"));
    registerShortcut("Cmd+P", () => openPalette("file"));

    registerShortcut("Cmd+1", () => {
      if (window.tidyflow) window.tidyflow.switchToolView("explorer");
    });
    registerShortcut("Cmd+2", () => {
      if (window.tidyflow) window.tidyflow.switchToolView("search");
    });
    registerShortcut("Cmd+3", () => {
      if (window.tidyflow) window.tidyflow.switchToolView("git");
    });

    registerShortcut("Cmd+T", () => {
      if (window.tidyflow) {
        const proj = window.tidyflow.getCurrentProject();
        const ws = window.tidyflow.getCurrentWorkspace();
        if (proj && ws) window.tidyflow.createTerminal(proj, ws);
      }
    }, { scope: "workspace" });

    registerShortcut("Cmd+W", () => {
      if (window.tidyflow) {
        const tabId = window.tidyflow.getActiveTabId();
        if (tabId) window.tidyflow.closeTab(tabId);
      }
    }, { scope: "workspace" });

    registerShortcut("Ctrl+Tab", () => switchToNextTab(), { scope: "workspace" });
    registerShortcut("Ctrl+Shift+Tab", () => switchToPrevTab(), { scope: "workspace" });
    registerShortcut("Cmd+Alt+ArrowRight", () => switchToNextTab(), { scope: "workspace" });
    registerShortcut("Cmd+Alt+ArrowLeft", () => switchToPrevTab(), { scope: "workspace" });

    P.registerCommand("palette.openCommandPalette", {
      label: "Show All Commands",
      shortcut: "Cmd+Shift+P",
      scope: "global",
      handler: () => openPalette("command"),
    });

    P.registerCommand("palette.quickOpen", {
      label: "Quick Open File",
      shortcut: "Cmd+P",
      scope: "workspace",
      handler: () => openPalette("file"),
    });

    P.registerCommand("view.explorer", {
      label: "Show Explorer",
      shortcut: "Cmd+1",
      scope: "global",
      category: "View",
      handler: () => window.tidyflow?.switchToolView("explorer"),
    });

    P.registerCommand("view.search", {
      label: "Show Search",
      shortcut: "Cmd+2",
      scope: "global",
      category: "View",
      handler: () => window.tidyflow?.switchToolView("search"),
    });

    P.registerCommand("view.git", {
      label: "Show Git",
      shortcut: "Cmd+3",
      scope: "global",
      category: "View",
      handler: () => window.tidyflow?.switchToolView("git"),
    });

    P.registerCommand("terminal.new", {
      label: "New Terminal",
      shortcut: "Cmd+T",
      scope: "workspace",
      category: "Terminal",
      handler: () => {
        if (window.tidyflow) {
          const proj = window.tidyflow.getCurrentProject();
          const ws = window.tidyflow.getCurrentWorkspace();
          if (proj && ws) window.tidyflow.createTerminal(proj, ws);
        }
      },
    });

    P.registerCommand("tab.close", {
      label: "Close Tab",
      shortcut: "Cmd+W",
      scope: "workspace",
      category: "Tab",
      handler: () => {
        if (window.tidyflow) {
          const tabId = window.tidyflow.getActiveTabId();
          if (tabId) window.tidyflow.closeTab(tabId);
        }
      },
    });

    P.registerCommand("tab.next", {
      label: "Next Tab",
      shortcut: "Ctrl+Tab",
      scope: "workspace",
      category: "Tab",
      handler: () => switchToNextTab(),
    });

    P.registerCommand("tab.prev", {
      label: "Previous Tab",
      shortcut: "Ctrl+Shift+Tab",
      scope: "workspace",
      category: "Tab",
      handler: () => switchToPrevTab(),
    });

    P.registerCommand("file.save", {
      label: "Save File",
      shortcut: "Cmd+S",
      scope: "workspace",
      category: "File",
      handler: () => {
        document.dispatchEvent(new KeyboardEvent("keydown", {
          key: "s",
          metaKey: true,
          bubbles: true,
        }));
      },
    });

    P.registerCommand("projects.refresh", {
      label: "Refresh Projects",
      scope: "global",
      category: "Projects",
      handler: () => window.tidyflow?.listProjects(),
    });

    P.registerCommand("explorer.refresh", {
      label: "Refresh Explorer",
      scope: "workspace",
      category: "Explorer",
      handler: () => window.tidyflow?.refreshExplorer(),
    });

    P.registerCommand("fileIndex.refresh", {
      label: "Refresh File Index",
      scope: "workspace",
      category: "File",
      description: "Rebuild the file index for Quick Open (Cmd+P)",
      handler: () => P.refreshFileIndex(),
    });

    P.registerCommand("core.reconnect", {
      label: "Reconnect to Core",
      scope: "global",
      category: "Connection",
      handler: () => window.tidyflow?.reconnect(),
    });

    document.addEventListener("keydown", handleGlobalKeydown);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  window.tidyflowPalette = {
    open: openPalette,
    close: closePalette,
    isOpen: () => isOpen,
    registerCommand: P.registerCommand,
    registerShortcut: registerShortcut,
    updateFileIndex: P.updateFileIndex,
    refreshFileIndex: P.refreshFileIndex,
    getFileIndex: P.getFileIndex,
    isFileIndexLoading: P.isFileIndexLoading,
    onFileIndexReady: P.onFileIndexReady,
  };
})();
