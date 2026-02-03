/**
 * TidyFlow Main - Tab Management (Terminal + Editor)
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function createTerminalTab(termId, cwd, project, workspace) {
    TF.tabCounter++;
    const wsKey = TF.getWorkspaceKey(project, workspace);
    const tabSet = TF.getOrCreateTabSet(wsKey);

    const term = new Terminal({
      cursorBlink: true,
      cursorStyle: "block",
      fontSize: 14,
      fontFamily: '"MesloLGS NF", "Meslo LG M DZ", "FiraCode Nerd Font", "JetBrains Mono", Menlo, Monaco, "Courier New", monospace',
      drawBoldTextInBrightColors: false,
      allowTransparency: true,
      theme: {
        background: "#1e1e1e",
        foreground: "#cccccc",
        cursor: "#cccccc",
        cursorAccent: "#1e1e1e",
        selectionBackground: "#264f78",
        black: "#000000", red: "#cd3131", green: "#0dbc79", yellow: "#e5e510",
        blue: "#2472c8", magenta: "#bc3fbc", cyan: "#11a8cd", white: "#e5e5e5",
        brightBlack: "#666666", brightRed: "#f14c4c", brightGreen: "#23d18b",
        brightYellow: "#f5f543", brightBlue: "#3b8eea", brightMagenta: "#d670d6",
        brightCyan: "#29b8db", brightWhite: "#e5e5e5",
      },
      allowProposedApi: true,
      // TUI 应用支持（vim、tmux、opencode 等）
      macOptionIsMeta: true,              // Option 键作为 Meta 键
      macOptionClickForcesSelection: true, // Option+Click 强制选择模式
      scrollback: 10000,                  // 滚动缓冲区行数
      rightClickSelectsWord: true,        // 右键选择单词
      overviewRulerWidth: 0,              // 禁用右侧概览标尺
    });

    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);

    // 自定义 fit 函数，不预留滚动条宽度，尽量填满容器
    const originalProposeDimensions = fitAddon.proposeDimensions.bind(fitAddon);
    fitAddon.proposeDimensions = function() {
      const dims = originalProposeDimensions();
      if (!dims) return dims;
      const core = term._core;
      if (core && core.viewport) {
        const scrollBarWidth = core.viewport.scrollBarWidth || 0;
        const cellWidth = core._renderService.dimensions.css.cell.width;
        if (cellWidth > 0) {
          // 加回滚动条宽度对应的列数，使用 ceil 确保填满
          dims.cols += Math.ceil(scrollBarWidth / cellWidth);
        }
      }
      return dims;
    };

    try {
      const webLinksAddon = new WebLinksAddon.WebLinksAddon();
      term.loadAddon(webLinksAddon);
    } catch (e) {
      console.warn("WebLinks addon failed:", e.message);
    }

    // WebGL addon - 启用 GPU 加速渲染
    let webglAddon = null;
    try {
      webglAddon = new WebglAddon.WebglAddon();
      webglAddon.onContextLoss(() => {
        webglAddon.dispose();
        webglAddon = null;
      });
      term.loadAddon(webglAddon);
    } catch (e) {
      console.warn("WebGL addon failed:", e.message);
      webglAddon = null;
    }

    const pane = document.createElement("div");
    pane.className = "tab-pane terminal-pane";
    pane.id = "pane-" + termId;

    const container = document.createElement("div");
    container.className = "terminal-container";
    pane.appendChild(container);
    TF.tabContent.appendChild(pane);

    term.open(container);

    // IME composition 状态追踪
    // 解决中文输入法切换到英文时产生空格的问题（如 "o p" -> "op"）
    let isComposing = false;
    let compositionJustEnded = false;
    const textarea = container.querySelector("textarea");
    if (textarea) {
      textarea.addEventListener("compositionstart", () => {
        isComposing = true;
        compositionJustEnded = false;
      });
      textarea.addEventListener("compositionend", () => {
        isComposing = false;
        compositionJustEnded = true;
        setTimeout(() => { compositionJustEnded = false; }, 100);
      });
    }

    const tabEl = document.createElement("div");
    tabEl.className = "tab";
    tabEl.dataset.tabId = termId;

    const icon = document.createElement("span");
    icon.className = "tab-icon terminal";
    icon.textContent = "⌘";
    tabEl.appendChild(icon);

    const title = document.createElement("span");
    title.className = "tab-title";
    title.textContent = workspace || "Terminal";
    tabEl.appendChild(title);

    const closeBtn = document.createElement("span");
    closeBtn.className = "tab-close";
    closeBtn.textContent = "×";
    closeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      TF.closeTab(termId);
    });
    tabEl.appendChild(closeBtn);

    tabEl.addEventListener("click", () => TF.switchToTab(termId));

    const tabActions = document.getElementById("tab-actions");
    TF.tabBar.insertBefore(tabEl, tabActions);

    term.onData((data) => {
      // composition 期间不发送（避免重复）
      if (isComposing) return;
      
      // composition 刚结束时，处理拼音残留（如 "o p" -> "op"）
      if (compositionJustEnded && /^[a-z](\s+[a-z])+$/i.test(data)) {
        data = data.replace(/\s+/g, '');
      }

      if (TF.transport && TF.transport.isConnected) {
        const encoder = new TextEncoder();
        const bytes = encoder.encode(data);
        TF.transport.send(JSON.stringify({
          type: "input",
          term_id: termId,
          data_b64: TF.encodeBase64(bytes),
        }));
      }
    });

    // 防抖处理：避免动画期间频繁触发 resize
    let resizeTimer = null;
    const resizeObserver = new ResizeObserver(() => {
      if (fitAddon && TF.activeTabId === termId) {
        // 清除之前的定时器
        if (resizeTimer) {
          clearTimeout(resizeTimer);
        }
        // 延迟执行，等待布局稳定
        resizeTimer = setTimeout(() => {
          resizeTimer = null;
          fitAddon.fit();
          TF.sendResize(termId, term.cols, term.rows);
        }, 100);
      }
    });
    resizeObserver.observe(container);

    const tabInfo = {
      id: termId,
      type: "terminal",
      title: workspace || "Terminal",
      termId: termId,
      term,
      fitAddon,
      webglAddon,
      pane,
      tabEl,
      cwd: cwd || "",
      project,
      workspace,
      resizeObserver,
      // 存储 resizeTimer 的引用，用于清理
      getResizeTimer: () => resizeTimer,
      clearResizeTimer: () => {
        if (resizeTimer) {
          clearTimeout(resizeTimer);
          resizeTimer = null;
        }
      },
    };

    tabSet.tabs.set(termId, tabInfo);
    tabSet.tabOrder.push(termId);

    return tabInfo;
  }

  function createEditorTab(filePath, content) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return null;

    const tabSet = TF.getOrCreateTabSet(wsKey);
    const tabId = "editor-" + filePath.replace(/[^a-zA-Z0-9]/g, "-");

    if (tabSet.tabs.has(tabId)) {
      TF.switchToTab(tabId);
      return tabSet.tabs.get(tabId);
    }

    const pane = document.createElement("div");
    pane.className = "tab-pane editor-pane";
    pane.id = "pane-" + tabId;

    const toolbar = document.createElement("div");
    toolbar.className = "editor-toolbar";

    const pathEl = document.createElement("span");
    pathEl.className = "editor-path";
    pathEl.textContent = filePath;
    toolbar.appendChild(pathEl);

    const saveBtn = document.createElement("button");
    saveBtn.className = "editor-save-btn";
    saveBtn.textContent = "Save";
    saveBtn.disabled = true;
    saveBtn.addEventListener("click", () => TF.saveEditorTab(tabId));
    toolbar.appendChild(saveBtn);

    pane.appendChild(toolbar);

    const editorContainer = document.createElement("div");
    editorContainer.className = "editor-container";
    pane.appendChild(editorContainer);

    const statusBar = document.createElement("div");
    statusBar.className = "editor-status";
    pane.appendChild(statusBar);

    TF.tabContent.appendChild(pane);

    let editorView = null;
    if (window.CodeMirror) {
      const { EditorView, basicSetup } = window.CodeMirror;
      editorView = new EditorView({
        doc: content || "",
        extensions: [
          basicSetup,
          EditorView.updateListener.of((update) => {
            if (update.docChanged) {
              const tab = tabSet.tabs.get(tabId);
              if (tab && !tab.isDirty) {
                tab.isDirty = true;
                TF.updateTabDirtyState(tabId, true);
              }
            }
          }),
          EditorView.theme(
            {
              "&": { height: "100%", fontSize: "14px" },
              ".cm-scroller": { fontFamily: 'Menlo, Monaco, "Courier New", monospace' },
              ".cm-content": { caretColor: "#d4d4d4" },
              "&.cm-focused .cm-cursor": { borderLeftColor: "#d4d4d4" },
            },
            { dark: true },
          ),
        ],
        parent: editorContainer,
      });
    }

    const tabEl = document.createElement("div");
    tabEl.className = "tab";
    tabEl.dataset.tabId = tabId;

    const icon = document.createElement("span");
    icon.className = "tab-icon editor";
    icon.textContent = TF.getFileIcon(filePath);
    tabEl.appendChild(icon);

    const title = document.createElement("span");
    title.className = "tab-title";
    title.textContent = filePath.split("/").pop();
    title.title = filePath;
    tabEl.appendChild(title);

    const dirtyIndicator = document.createElement("span");
    dirtyIndicator.className = "tab-dirty";
    dirtyIndicator.style.display = "none";
    dirtyIndicator.textContent = "*";
    tabEl.appendChild(dirtyIndicator);

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
      type: "editor",
      title: filePath.split("/").pop(),
      filePath,
      editorView,
      pane,
      tabEl,
      saveBtn,
      statusBar,
      dirtyIndicator,
      isDirty: false,
      project: TF.currentProject,
      workspace: TF.currentWorkspace,
    };

    tabSet.tabs.set(tabId, tabInfo);
    tabSet.tabOrder.push(tabId);

    return tabInfo;
  }

  function updateTabDirtyState(tabId, isDirty) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;
    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet) return;
    const tab = tabSet.tabs.get(tabId);
    if (!tab) return;

    tab.isDirty = isDirty;
    if (tab.dirtyIndicator) tab.dirtyIndicator.style.display = isDirty ? "inline" : "none";
    if (tab.saveBtn) tab.saveBtn.disabled = !isDirty;
  }

  function saveEditorTab(tabId) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;
    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet) return;
    const tab = tabSet.tabs.get(tabId);
    if (!tab || tab.type !== "editor" || !tab.editorView) return;

    const content = tab.editorView.state.doc.toString();
    const encoder = new TextEncoder();
    const bytes = encoder.encode(content);
    TF.sendFileWrite(tab.project, tab.workspace, tab.filePath, TF.encodeBase64(bytes));
  }

  function saveCurrentEditor() {
    if (!TF.activeTabId) return;
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;
    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet) return;
    const tab = tabSet.tabs.get(TF.activeTabId);
    if (tab && tab.type === "editor") TF.saveEditorTab(TF.activeTabId);
  }

  function openFileInEditor(filePath) {
    if (!TF.currentProject || !TF.currentWorkspace) return;

    const wsKey = TF.getCurrentWorkspaceKey();
    const tabId = "editor-" + filePath.replace(/[^a-zA-Z0-9]/g, "-");
    const tabSet = wsKey ? TF.workspaceTabs.get(wsKey) : null;
    const tabExists = !!(tabSet && tabSet.tabs.has(tabId));

    // 若该 path 的 tab 已存在，仅切换显示，不重复发 file_read
    if (tabExists) {
      TF.switchToTab(tabId);
      return;
    }

    // 如果 WebSocket 未连接，先连接再发送文件读取请求
    if (!TF.transport || !TF.transport.isConnected) {
      console.log("[openFileInEditor] WebSocket not connected, connecting first...");
      TF.pendingFileOpen = { filePath, project: TF.currentProject, workspace: TF.currentWorkspace };
      TF.connect();
      return;
    }

    TF.sendFileRead(TF.currentProject, TF.currentWorkspace, filePath);
  }

  function openFileAtLine(filePath, lineNumber) {
    if (!TF.currentProject || !TF.currentWorkspace) return;

    if (TF.nativeMode === "diff") {
      TF.openFileAtLineViaNative(filePath, lineNumber);
      return;
    }

    const wsKey = TF.getCurrentWorkspaceKey();
    const tabId = "editor-" + filePath.replace(/[^a-zA-Z0-9]/g, "-");

    if (wsKey && TF.workspaceTabs.has(wsKey)) {
      const tabSet = TF.workspaceTabs.get(wsKey);
      if (tabSet.tabs.has(tabId)) {
        const tab = tabSet.tabs.get(tabId);
        TF.switchToTab(tabId);
        TF.scrollToLineAndHighlight(tab, lineNumber);
        return;
      }
    }

    TF.pendingLineNavigation = { filePath, lineNumber };

    // 如果 WebSocket 未连接，先连接再发送文件读取请求
    if (!TF.transport || !TF.transport.isConnected) {
      console.log("[openFileAtLine] WebSocket not connected, connecting first...");
      TF.pendingFileOpen = { filePath, project: TF.currentProject, workspace: TF.currentWorkspace };
      TF.connect();
      return;
    }

    TF.sendFileRead(TF.currentProject, TF.currentWorkspace, filePath);
  }

  function scrollToLineAndHighlight(tab, lineNumber, highlightMs = 2000) {
    if (!tab || !tab.editorView || !window.CodeMirror) return;

    const { EditorView } = window.CodeMirror;
    const view = tab.editorView;
    const doc = view.state.doc;

    const totalLines = doc.lines;
    const targetLine = Math.max(1, Math.min(lineNumber, totalLines));

    const lineInfo = doc.line(targetLine);
    const lineStart = lineInfo.from;

    view.dispatch({
      selection: { anchor: lineStart },
      scrollIntoView: true,
    });

    TF.highlightLine(view, targetLine, highlightMs);

    if (tab.statusBar) tab.statusBar.textContent = `Line ${targetLine}`;
  }

  function highlightLine(view, lineNumber, highlightMs = 2000) {
    if (!window.CodeMirror) return;

    const { EditorView, Decoration, StateEffect, StateField } = window.CodeMirror;
    const doc = view.state.doc;
    const lineInfo = doc.line(lineNumber);

    const highlightMark = Decoration.line({ class: "cm-highlight-line" });
    const decorations = Decoration.set([highlightMark.range(lineInfo.from)]);

    if (!view._highlightEffect) {
      view._highlightEffect = StateEffect.define();
      view._highlightField = StateField.define({
        create: () => Decoration.none,
        update: (value, tr) => {
          for (const e of tr.effects) {
            if (e.is(view._highlightEffect)) return e.value;
          }
          return value;
        },
        provide: (f) => EditorView.decorations.from(f),
      });

      view.dispatch({ effects: StateEffect.appendConfig.of(view._highlightField) });
    }

    view.dispatch({ effects: view._highlightEffect.of(decorations) });

    setTimeout(() => {
      view.dispatch({ effects: view._highlightEffect.of(Decoration.none) });
    }, highlightMs);
  }

  function switchToTab(tabId) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;

    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet || !tabSet.tabs.has(tabId)) return;

    if (TF.activeTabId && tabSet.tabs.has(TF.activeTabId)) {
      const current = tabSet.tabs.get(TF.activeTabId);
      current.pane.classList.remove("active");
      current.tabEl.classList.remove("active");
    }

    const tab = tabSet.tabs.get(tabId);
    tab.pane.classList.add("active");
    tab.tabEl.classList.add("active");
    TF.activeTabId = tabId;
    tabSet.activeTabId = tabId;

    if (TF.placeholder) TF.placeholder.style.display = "none";

    // 使用 requestAnimationFrame 确保浏览器完成布局更新后再刷新终端
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        if (tab.type === "terminal" && tab.term) {
          // 清除 WebGL 纹理图集以修复 visibility:hidden 后的渲染问题
          if (tab.term.clearTextureAtlas) {
            tab.term.clearTextureAtlas();
          }

          tab.fitAddon.fit();
          const cols = tab.term.cols;
          const rows = tab.term.rows;
          tab.term.refresh(0, rows - 1);
          tab.term.focus();
          TF.sendResize(tab.termId, cols, rows);
        } else if (tab.type === "editor" && tab.editorView) {
          tab.editorView.focus();
        }
      });
    });

    TF.notifySwift("tab_switched", { tab_id: tabId, type: tab.type });
  }

  function closeTab(tabId) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;

    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet || !tabSet.tabs.has(tabId)) return;

    const tab = tabSet.tabs.get(tabId);

    if (tab.type === "editor" && tab.isDirty) {
      if (!confirm("Unsaved changes will be lost. Close anyway?")) return;
    }

    if (tab.type === "terminal") {
      if (TF.transport && TF.transport.isConnected) {
        TF.transport.send(JSON.stringify({ type: "term_close", term_id: tab.termId }));
      }
    }

    TF.removeTabFromUI(tabId);
  }

  function removeTabFromUI(tabId) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;

    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet || !tabSet.tabs.has(tabId)) return;

    const tab = tabSet.tabs.get(tabId);

    if (tab.type === "terminal") {
      if (tab.clearResizeTimer) tab.clearResizeTimer();
      if (tab.resizeObserver) tab.resizeObserver.disconnect();
      if (tab.term) tab.term.dispose();
    } else if (tab.type === "editor") {
      if (tab.editorView) tab.editorView.destroy();
    }

    if (tab.pane) tab.pane.remove();
    if (tab.tabEl) tab.tabEl.remove();

    tabSet.tabs.delete(tabId);
    tabSet.tabOrder = tabSet.tabOrder.filter((id) => id !== tabId);

    if (TF.activeTabId === tabId) {
      TF.activeTabId = null;
      tabSet.activeTabId = null;
      if (tabSet.tabOrder.length > 0) {
        TF.switchToTab(tabSet.tabOrder[tabSet.tabOrder.length - 1]);
      } else {
        if (TF.placeholder) TF.placeholder.style.display = "flex";
      }
    }
  }

  TF.createTerminalTab = createTerminalTab;
  TF.createEditorTab = createEditorTab;
  TF.updateTabDirtyState = updateTabDirtyState;
  TF.saveEditorTab = saveEditorTab;
  TF.saveCurrentEditor = saveCurrentEditor;
  TF.openFileInEditor = openFileInEditor;
  TF.openFileAtLine = openFileAtLine;
  TF.scrollToLineAndHighlight = scrollToLineAndHighlight;
  TF.highlightLine = highlightLine;
  TF.switchToTab = switchToTab;
  TF.closeTab = closeTab;
  TF.removeTabFromUI = removeTabFromUI;
})();
