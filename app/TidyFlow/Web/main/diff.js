/**
 * TidyFlow Main - Diff Tab (Unified/Split view)
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function createDiffTab(filePath, code) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return null;

    const tabSet = TF.getOrCreateTabSet(wsKey);
    const tabId = "diff-" + filePath.replace(/[^a-zA-Z0-9]/g, "-");

    if (tabSet.tabs.has(tabId)) {
      TF.switchToTab(tabId);
      const existingTab = tabSet.tabs.get(tabId);
      TF.sendGitDiff(
        TF.currentProject,
        TF.currentWorkspace,
        filePath,
        existingTab.diffMode || "working",
      );
      return tabSet.tabs.get(tabId);
    }

    const pane = document.createElement("div");
    pane.className = "tab-pane diff-pane";
    pane.id = "pane-" + tabId;

    const toolbar = document.createElement("div");
    toolbar.className = "diff-toolbar";

    const pathEl = document.createElement("span");
    pathEl.className = "diff-path";
    pathEl.textContent = filePath;
    toolbar.appendChild(pathEl);

    const codeEl = document.createElement("span");
    codeEl.className = "diff-code";
    codeEl.textContent = `[${code}]`;
    toolbar.appendChild(codeEl);

    const openFileBtn = document.createElement("button");
    openFileBtn.className = "diff-open-btn";
    openFileBtn.textContent = "📄 Open file";
    openFileBtn.title = "Open file in editor";
    if (code === "D") {
      openFileBtn.disabled = true;
      openFileBtn.title = "File has been deleted";
    }
    openFileBtn.addEventListener("click", () => {
      const tab = tabSet.tabs.get(tabId);
      if (tab && tab.code !== "D") TF.openFileInEditor(tab.filePath);
    });
    toolbar.appendChild(openFileBtn);

    const refreshBtn = document.createElement("button");
    refreshBtn.className = "diff-refresh-btn";
    refreshBtn.textContent = "↻ Refresh";
    refreshBtn.addEventListener("click", () => {
      const tab = tabSet.tabs.get(tabId);
      if (tab) {
        tab.contentEl.innerHTML =
          '<div class="diff-loading">Loading diff...</div>';
        TF.sendGitDiff(
          tab.project,
          tab.workspace,
          tab.filePath,
          tab.diffMode || "working",
        );
      }
    });
    toolbar.appendChild(refreshBtn);

    const modeToggle = document.createElement("div");
    modeToggle.className = "diff-mode-toggle";

    const workingBtn = document.createElement("button");
    workingBtn.className = "diff-mode-btn active";
    workingBtn.textContent = "Working";
    workingBtn.dataset.mode = "working";
    workingBtn.title = "Show unstaged changes (git diff)";

    const stagedBtn = document.createElement("button");
    stagedBtn.className = "diff-mode-btn";
    stagedBtn.textContent = "Staged";
    stagedBtn.dataset.mode = "staged";
    stagedBtn.title = "Show staged changes (git diff --cached)";

    modeToggle.appendChild(workingBtn);
    modeToggle.appendChild(stagedBtn);

    modeToggle.addEventListener("click", (e) => {
      const btn = e.target.closest(".diff-mode-btn");
      if (!btn) return;
      const newMode = btn.dataset.mode;
      const tab = tabSet.tabs.get(tabId);
      if (tab && tab.diffMode !== newMode) {
        modeToggle
          .querySelectorAll(".diff-mode-btn")
          .forEach((b) => b.classList.remove("active"));
        btn.classList.add("active");
        tab.diffMode = newMode;
        tab.contentEl.innerHTML =
          '<div class="diff-loading">Loading diff...</div>';
        TF.sendGitDiff(tab.project, tab.workspace, tab.filePath, newMode);
      }
    });
    toolbar.appendChild(modeToggle);

    const viewToggle = document.createElement("div");
    viewToggle.className = "diff-view-toggle";

    const unifiedBtn = document.createElement("button");
    unifiedBtn.className = "diff-view-btn active";
    unifiedBtn.textContent = "Unified";
    unifiedBtn.dataset.mode = "unified";

    const splitBtn = document.createElement("button");
    splitBtn.className = "diff-view-btn";
    splitBtn.textContent = "Split";
    splitBtn.dataset.mode = "split";

    viewToggle.appendChild(unifiedBtn);
    viewToggle.appendChild(splitBtn);

    viewToggle.addEventListener("click", (e) => {
      const btn = e.target.closest(".diff-view-btn");
      if (!btn) return;
      const mode = btn.dataset.mode;
      const tab = tabSet.tabs.get(tabId);
      if (tab && tab.diffData && tab.viewMode !== mode) {
        viewToggle
          .querySelectorAll(".diff-view-btn")
          .forEach((b) => b.classList.remove("active"));
        btn.classList.add("active");
        tab.viewMode = mode;
        renderDiffView(tab);
      }
    });
    toolbar.appendChild(viewToggle);

    pane.appendChild(toolbar);

    const contentEl = document.createElement("div");
    contentEl.className = "diff-content";
    contentEl.innerHTML = '<div class="diff-loading">Loading diff...</div>';
    pane.appendChild(contentEl);

    const statusBar = document.createElement("div");
    statusBar.className = "diff-status";
    pane.appendChild(statusBar);

    TF.tabContent.appendChild(pane);

    const tabEl = document.createElement("div");
    tabEl.className = "tab";
    tabEl.dataset.tabId = tabId;

    const icon = document.createElement("span");
    icon.className = "tab-icon diff";
    icon.textContent = "±";
    tabEl.appendChild(icon);

    const title = document.createElement("span");
    title.className = "tab-title";
    title.textContent = filePath.split("/").pop() + " (diff)";
    title.title = filePath;
    tabEl.appendChild(title);

    const closeBtn = document.createElement("span");
    closeBtn.className = "tab-close";
    closeBtn.textContent = "×";
    closeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      TF.closeTab(tabId);
    });
    tabEl.appendChild(closeBtn);

    tabEl.addEventListener("click", () => TF.switchToTab(tabId));

    const tabActions = document.getElementById("tab-actions");
    TF.tabBar.insertBefore(tabEl, tabActions);

    const tabInfo = {
      id: tabId,
      type: "diff",
      title: filePath.split("/").pop() + " (diff)",
      filePath,
      code,
      pane,
      tabEl,
      contentEl,
      statusBar,
      project: TF.currentProject,
      workspace: TF.currentWorkspace,
      viewMode: "unified",
      diffMode: "working",
      diffData: null,
      rawText: null,
      isBinary: false,
      truncated: false,
    };

    tabSet.tabs.set(tabId, tabInfo);
    tabSet.tabOrder.push(tabId);

    return tabInfo;
  }

  function openDiffTab(filePath, code) {
    if (!TF.currentProject || !TF.currentWorkspace) return;
    const tabInfo = createDiffTab(filePath, code);
    if (tabInfo) {
      TF.switchToTab(tabInfo.id);
      TF.sendGitDiff(
        TF.currentProject,
        TF.currentWorkspace,
        filePath,
        tabInfo.diffMode,
      );
    }
  }

  function renderDiffContent(path, code, text, isBinary, truncated) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;

    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet) return;

    const tabId = "diff-" + path.replace(/[^a-zA-Z0-9]/g, "-");
    const tab = tabSet.tabs.get(tabId);
    if (!tab || !tab.contentEl) return;

    const openBtn = tab.pane.querySelector(".diff-open-btn");
    if (openBtn) {
      if (code === "D") {
        openBtn.disabled = true;
        openBtn.title = "File has been deleted";
      } else {
        openBtn.disabled = false;
        openBtn.title = "Open file in editor";
      }
    }

    tab.rawText = text;
    tab.isBinary = isBinary;
    tab.truncated = truncated;
    tab.code = code;

    if (isBinary) {
      tab.contentEl.innerHTML =
        '<div class="diff-binary">Binary file diff not supported</div>';
      disableSplitMode(tab);
      return;
    }

    if (!text || text.trim() === "") {
      tab.contentEl.innerHTML = '<div class="diff-empty">No changes</div>';
      disableSplitMode(tab);
      return;
    }

    tab.diffData = parseDiffToStructure(text, path);

    const totalLines = tab.diffData.hunks.reduce(
      (sum, h) => sum + h.lines.length,
      0,
    );
    if (totalLines > 5000) {
      tab.viewMode = "unified";
      disableSplitMode(
        tab,
        "Diff too large for split view (" + totalLines + " lines)",
      );
    } else {
      enableSplitMode(tab);
    }

    renderDiffView(tab);
  }

  function parseDiffToStructure(text, path) {
    const lines = text.split("\n");
    const result = { headers: [], hunks: [], path: path };
    let currentHunk = null;
    let currentOldLine = 0;
    let currentNewLine = 0;

    lines.forEach((line) => {
      const hunkMatch = line.match(
        /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/,
      );
      if (hunkMatch) {
        if (currentHunk) result.hunks.push(currentHunk);
        currentOldLine = parseInt(hunkMatch[1], 10);
        currentNewLine = parseInt(hunkMatch[2], 10);
        currentHunk = {
          oldStart: currentOldLine,
          newStart: currentNewLine,
          header: line,
          context: hunkMatch[3] || "",
          lines: [],
        };
        return;
      }

      if (
        line.startsWith("diff --git") ||
        line.startsWith("index ") ||
        line.startsWith("---") ||
        line.startsWith("+++") ||
        line.startsWith("new file") ||
        line.startsWith("deleted file") ||
        line.startsWith("Binary files")
      ) {
        result.headers.push(line);
        return;
      }

      if (currentHunk) {
        const firstChar = line.charAt(0);

        if (firstChar === "+") {
          currentHunk.lines.push({
            type: "add",
            oldLine: null,
            newLine: currentNewLine,
            text: line,
          });
          currentNewLine++;
        } else if (firstChar === "-") {
          currentHunk.lines.push({
            type: "del",
            oldLine: currentOldLine,
            newLine: null,
            text: line,
          });
          currentOldLine++;
        } else if (firstChar === " ") {
          currentHunk.lines.push({
            type: "context",
            oldLine: currentOldLine,
            newLine: currentNewLine,
            text: line,
          });
          currentOldLine++;
          currentNewLine++;
        } else if (line === "\\ No newline at end of file") {
          currentHunk.lines.push({
            type: "meta",
            oldLine: null,
            newLine: null,
            text: line,
          });
        } else if (line !== "") {
          currentHunk.lines.push({
            type: "context",
            oldLine: currentOldLine,
            newLine: currentNewLine,
            text: line,
          });
        }
      }
    });

    if (currentHunk) result.hunks.push(currentHunk);
    return result;
  }

  function disableSplitMode(tab, reason) {
    const splitBtn = tab.pane.querySelector(
      '.diff-view-btn[data-mode="split"]',
    );
    if (splitBtn) {
      splitBtn.disabled = true;
      splitBtn.title = reason || "Split view not available";
    }
    const unifiedBtn = tab.pane.querySelector(
      '.diff-view-btn[data-mode="unified"]',
    );
    if (unifiedBtn) unifiedBtn.classList.add("active");
    if (splitBtn) splitBtn.classList.remove("active");
    tab.viewMode = "unified";
  }

  function enableSplitMode(tab) {
    const splitBtn = tab.pane.querySelector(
      '.diff-view-btn[data-mode="split"]',
    );
    if (splitBtn) {
      splitBtn.disabled = false;
      splitBtn.title = "Split view (side-by-side)";
    }
  }

  function renderDiffView(tab) {
    if (!tab.diffData) return;
    const scrollTop = tab.contentEl.scrollTop;

    if (tab.viewMode === "split") renderSplitDiff(tab);
    else renderUnifiedDiff(tab);

    tab.contentEl.scrollTop = scrollTop;
    updateDiffStatusBar(tab);
  }

  function renderUnifiedDiffCodeMirror(tab) {
    const { EditorView, Decoration, StateField } = window.CodeMirror;
    const data = tab.diffData;
    const lines = [];
    const lineMetadata = [];

    // Flatten hunks into lines
    data.headers.forEach((header) => {
      lines.push(header);
      lineMetadata.push({ type: "header" });
    });

    data.hunks.forEach((hunk) => {
      lines.push(hunk.header);
      lineMetadata.push({ type: "hunk-header" });

      hunk.lines.forEach((line) => {
        let text = line.text;
        let type = line.type; // add, del, context, meta

        // Strip diff markers for code highlighting, but keep content
        if (type === "add" || type === "del" || type === "context") {
          if (text.length > 0) text = text.substring(1);
        }

        lines.push(text);
        lineMetadata.push({
          type: type,
          newLine: line.newLine,
          path: data.path,
        });
      });
    });

    const docContent = lines.join("\n");

    // Custom theme for diff colors
    const diffTheme = EditorView.theme({
      ".cm-diff-add": { backgroundColor: "rgba(16, 185, 129, 0.15)" }, // Green background
      ".cm-diff-del": { backgroundColor: "rgba(239, 68, 68, 0.15)" }, // Red background
      ".cm-diff-header": { backgroundColor: "#1f2937", color: "#9ca3af" }, // Dark header
      ".cm-diff-hunk": {
        backgroundColor: "#1f2937",
        color: "#60a5fa",
        fontStyle: "italic",
      }, // Blueish hunk header
      ".cm-content": {
        fontFamily: 'Menlo, Monaco, "Courier New", monospace',
        fontSize: "13px",
      },
      ".cm-gutters": {
        backgroundColor: "#1e1e1e",
        borderRight: "1px solid #333",
        color: "#666",
      },
      ".cm-activeLine": { backgroundColor: "transparent" },
      ".cm-activeLineGutter": { backgroundColor: "transparent" },
    });

    // Line decorations
    const diffDecorations = StateField.define({
      create() {
        const ranges = [];
        let pos = 0;
        lines.forEach((lineText, i) => {
          const meta = lineMetadata[i];
          let className = "";
          if (meta.type === "add") className = "cm-diff-add";
          else if (meta.type === "del") className = "cm-diff-del";
          else if (meta.type === "header") className = "cm-diff-header";
          else if (meta.type === "hunk-header") className = "cm-diff-hunk";

          if (className) {
            ranges.push(
              Decoration.line({ attributes: { class: className } }).range(pos),
            );
          }
          pos += lineText.length + 1; // +1 for newline
        });
        return Decoration.set(ranges);
      },
      update(deco) {
        return deco;
      },
      provide: (f) => EditorView.decorations.from(f),
    });

    // Click handler for navigation
    const clickHandler = EditorView.domEventHandlers({
      click: (event, view) => {
        const pos = view.posAtDOM(event.target);
        if (pos === null) return;
        const line = view.state.doc.lineAt(pos);
        const index = line.number - 1;
        const meta = lineMetadata[index];

        if (meta && meta.newLine && tab.code !== "D") {
          TF.openFileAtLine(meta.path, meta.newLine);
        }
      },
    });

    const extensions = [
      window.CodeMirror.basicSetup,
      window.CodeMirror.oneDark,
      EditorView.editable.of(false),
      EditorView.lineWrapping,
      diffTheme,
      diffDecorations,
      clickHandler,
    ];

    // Attempt to load language mode
    const langExt = window.CodeMirror.getLanguageExtension(tab.filePath);
    if (langExt) {
      extensions.push(langExt);
    }

    tab.contentEl.innerHTML = "";
    tab.contentEl.style.padding = "0";
    const container = document.createElement("div");
    container.className = "diff-codemirror-wrapper";
    container.style.height = "100%";
    tab.contentEl.appendChild(container);

    new EditorView({
      doc: docContent,
      extensions: extensions,
      parent: container,
    });
  }

  function renderUnifiedDiff(tab) {
    if (window.CodeMirror) {
      renderUnifiedDiffCodeMirror(tab);
      return;
    }
    const data = tab.diffData;
    const pre = document.createElement("pre");
    pre.className = "diff-text";

    data.headers.forEach((line) => {
      const lineEl = document.createElement("div");
      lineEl.className = "diff-line diff-header";
      lineEl.textContent = line;
      pre.appendChild(lineEl);
    });

    data.hunks.forEach((hunk) => {
      const hunkEl = document.createElement("div");
      hunkEl.className = "diff-line diff-hunk";
      hunkEl.textContent = hunk.header;
      pre.appendChild(hunkEl);

      hunk.lines.forEach((lineInfo) => {
        const lineEl = document.createElement("div");
        lineEl.className = "diff-line";

        if (lineInfo.type === "add") {
          lineEl.classList.add("diff-add");
          lineEl.dataset.lineNew = lineInfo.newLine;
          lineEl.dataset.path = data.path;
          lineEl.dataset.clickable = "true";
        } else if (lineInfo.type === "del") {
          lineEl.classList.add("diff-remove");
          const nearestNew = findNearestNewLine(hunk, lineInfo);
          lineEl.dataset.lineNew = nearestNew;
          lineEl.dataset.path = data.path;
          lineEl.dataset.clickable = "true";
        } else if (lineInfo.type === "context") {
          lineEl.dataset.lineNew = lineInfo.newLine;
          lineEl.dataset.path = data.path;
          lineEl.dataset.clickable = "true";
        } else if (lineInfo.type === "meta") {
          lineEl.classList.add("diff-meta");
        }

        lineEl.textContent = lineInfo.text;
        pre.appendChild(lineEl);
      });
    });

    pre.addEventListener("click", (e) => {
      const lineEl = e.target.closest(".diff-line");
      if (!lineEl || lineEl.dataset.clickable !== "true") return;
      const targetLine = parseInt(lineEl.dataset.lineNew, 10);
      const targetPath = lineEl.dataset.path;
      if (targetPath && !isNaN(targetLine) && tab.code !== "D") {
        TF.openFileAtLine(targetPath, targetLine);
      }
    });

    tab.contentEl.innerHTML = "";
    tab.contentEl.appendChild(pre);
  }

  function renderSplitDiff(tab) {
    const data = tab.diffData;
    const container = document.createElement("div");
    container.className = "diff-split-container";

    if (data.headers.length > 0) {
      const headersEl = document.createElement("div");
      headersEl.className = "diff-split-headers";
      data.headers.forEach((line) => {
        const lineEl = document.createElement("div");
        lineEl.className = "diff-line diff-header";
        lineEl.textContent = line;
        headersEl.appendChild(lineEl);
      });
      container.appendChild(headersEl);
    }

    data.hunks.forEach((hunk) => {
      const hunkHeaderEl = document.createElement("div");
      hunkHeaderEl.className = "diff-split-hunk-header diff-hunk";
      hunkHeaderEl.textContent = hunk.header;
      container.appendChild(hunkHeaderEl);

      const splitEl = document.createElement("div");
      splitEl.className = "diff-split";

      const oldPane = document.createElement("div");
      oldPane.className = "diff-split-pane diff-old";

      const newPane = document.createElement("div");
      newPane.className = "diff-split-pane diff-new";

      const rows = buildSplitRows(hunk.lines);

      rows.forEach((row) => {
        const oldRow = document.createElement("div");
        oldRow.className = "diff-split-row";

        if (row.old) {
          const lineNumEl = document.createElement("span");
          lineNumEl.className = "diff-line-num";
          lineNumEl.textContent = row.old.oldLine || "";
          oldRow.appendChild(lineNumEl);

          const textEl = document.createElement("span");
          textEl.className = "diff-line-text";
          if (row.old.type === "del") textEl.classList.add("diff-remove");
          else if (row.old.type === "context")
            textEl.classList.add("diff-context");
          textEl.textContent = row.old.text.substring(1);
          oldRow.appendChild(textEl);

          oldRow.dataset.clickable = "true";
          oldRow.dataset.path = data.path;
          oldRow.dataset.lineNew = row.new
            ? row.new.newLine
            : row.old.newLine || hunk.newStart;
        } else {
          oldRow.classList.add("diff-split-empty");
          const ln = document.createElement("span");
          ln.className = "diff-line-num";
          oldRow.appendChild(ln);
          const lt = document.createElement("span");
          lt.className = "diff-line-text";
          oldRow.appendChild(lt);
        }
        oldPane.appendChild(oldRow);

        const newRow = document.createElement("div");
        newRow.className = "diff-split-row";

        if (row.new) {
          const lineNumEl = document.createElement("span");
          lineNumEl.className = "diff-line-num";
          lineNumEl.textContent = row.new.newLine || "";
          newRow.appendChild(lineNumEl);

          const textEl = document.createElement("span");
          textEl.className = "diff-line-text";
          if (row.new.type === "add") textEl.classList.add("diff-add");
          else if (row.new.type === "context")
            textEl.classList.add("diff-context");
          textEl.textContent = row.new.text.substring(1);
          newRow.appendChild(textEl);

          newRow.dataset.clickable = "true";
          newRow.dataset.path = data.path;
          newRow.dataset.lineNew = row.new.newLine;
        } else {
          newRow.classList.add("diff-split-empty");
          const ln2 = document.createElement("span");
          ln2.className = "diff-line-num";
          newRow.appendChild(ln2);
          const lt2 = document.createElement("span");
          lt2.className = "diff-line-text";
          newRow.appendChild(lt2);
        }
        newPane.appendChild(newRow);
      });

      splitEl.appendChild(oldPane);
      splitEl.appendChild(newPane);
      container.appendChild(splitEl);
    });

    container.addEventListener("click", (e) => {
      const row = e.target.closest(".diff-split-row");
      if (!row || row.dataset.clickable !== "true") return;
      const targetLine = parseInt(row.dataset.lineNew, 10);
      const targetPath = row.dataset.path;
      if (targetPath && !isNaN(targetLine) && tab.code !== "D") {
        TF.openFileAtLine(targetPath, targetLine);
      }
    });

    tab.contentEl.innerHTML = "";
    tab.contentEl.appendChild(container);
  }

  function buildSplitRows(lines) {
    const rows = [];
    let i = 0;

    while (i < lines.length) {
      const line = lines[i];

      if (line.type === "context") {
        rows.push({ old: line, new: line });
        i++;
      } else if (line.type === "del") {
        const delLines = [];
        const addLines = [];
        while (i < lines.length && lines[i].type === "del") {
          delLines.push(lines[i]);
          i++;
        }
        while (i < lines.length && lines[i].type === "add") {
          addLines.push(lines[i]);
          i++;
        }
        const maxLen = Math.max(delLines.length, addLines.length);
        for (let j = 0; j < maxLen; j++) {
          rows.push({ old: delLines[j] || null, new: addLines[j] || null });
        }
      } else if (line.type === "add") {
        rows.push({ old: null, new: line });
        i++;
      } else if (line.type === "meta") {
        rows.push({ old: line, new: line });
        i++;
      } else {
        i++;
      }
    }
    return rows;
  }

  function findNearestNewLine(hunk, targetLine) {
    const idx = hunk.lines.indexOf(targetLine);
    if (idx === -1) return hunk.newStart;
    for (let i = idx + 1; i < hunk.lines.length; i++) {
      if (hunk.lines[i].newLine !== null) return hunk.lines[i].newLine;
    }
    for (let i = idx - 1; i >= 0; i--) {
      if (hunk.lines[i].newLine !== null) return hunk.lines[i].newLine;
    }
    return hunk.newStart;
  }

  function updateDiffStatusBar(tab) {
    if (!tab.statusBar) return;
    let status = "Click any line to jump to that location in the file";
    if (tab.viewMode === "split")
      status =
        "Split view: Click left (old) or right (new) to jump | " + status;
    if (tab.truncated)
      status = "⚠️ Diff too large, truncated to 1MB | " + status;
    if (tab.code === "D") status = "File deleted - navigation disabled";
    tab.statusBar.textContent = status;
  }

  function sendGitDiff(project, workspace, path, mode = "working") {
    TF.sendControlMessage({ type: "git_diff", project, workspace, path, mode });
  }

  TF.createDiffTab = createDiffTab;
  TF.openDiffTab = openDiffTab;
  TF.renderDiffContent = renderDiffContent;
  TF.sendGitDiff = sendGitDiff;
})();
