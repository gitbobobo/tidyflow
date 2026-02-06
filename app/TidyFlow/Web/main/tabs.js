/**
 * TidyFlow Main - Tab Management (Terminal + Editor)
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  // 渲染器类型建议（参考 VS Code 策略）
  // undefined = 尚未检测，'dom' = 建议使用 DOM 渲染器
  let suggestedRendererType = undefined;

  /**
   * 检测 xterm.js 生成的终端查询响应，避免发送到服务器被 shell 回显
   * 
   * 当 TUI 应用（如 opencode、vim）查询终端属性时，xterm.js 会生成响应并通过 onData 发出。
   * 这些响应如果发送到服务器，会被 shell 当作普通输入回显，导致屏幕出现 "rgb:..." 等乱码。
   * 
   * 常见的查询响应模式：
   * - OSC 4/10/11/12 颜色查询响应: ESC ] N ; rgb:RRRR/GGGG/BBBB BEL/ST
   * - Primary DA 响应: ESC [ ? ... c
   * - Secondary DA 响应: ESC [ > ... c
   * - DECRQSS 响应: ESC P ... ESC \
   * - XTVERSION 响应: ESC P > | ... ESC \
   */
  function isTerminalQueryResponse(data) {
    if (!data || data.length === 0) return false;
    
    const firstChar = data.charCodeAt(0);
    
    // OSC 响应 (ESC ] ...) - 颜色查询等
    // ESC = 0x1b = 27, ] = 0x5d = 93
    if (firstChar === 0x1b && data.length > 1) {
      const secondChar = data.charCodeAt(1);
      // OSC: ESC ]
      if (secondChar === 0x5d) {
        // 检测颜色响应模式: 包含 rgb: 或 以数字开头
        if (/rgb:/i.test(data) || /^\x1b\]\d+;/.test(data)) {
          return true;
        }
      }
      // CSI 响应: ESC [
      if (secondChar === 0x5b) {
        // Primary DA: ESC [ ? ... c
        // Secondary DA: ESC [ > ... c
        if (/^\x1b\[\?[\d;]*c/.test(data) || /^\x1b\[>[\d;]*c/.test(data)) {
          return true;
        }
      }
      // DCS 响应: ESC P ... (用于 DECRQSS, XTVERSION 等)
      if (secondChar === 0x50) {
        return true;
      }
    }
    
    // 有些响应可能不以 ESC 开头（被截断或合并的数据）
    // 检测常见的颜色响应片段
    if (/^\d+;rgb:[\da-f]{4}\/[\da-f]{4}\/[\da-f]{4}/i.test(data)) {
      return true;
    }
    
    // 检测 $y 响应 (DECRQSS)
    if (/\$y/.test(data) && /^\d/.test(data)) {
      return true;
    }
    
    return false;
  }

  function createTerminalTab(termId, cwd, project, workspace) {
    TF.tabCounter++;
    const wsKey = TF.getWorkspaceKey(project, workspace);
    const tabSet = TF.getOrCreateTabSet(wsKey);

    const term = new Terminal({
      cursorBlink: true,
      cursorStyle: "block",
      fontSize: 14,
      fontFamily: '"MesloLGS NF", "Meslo LG M DZ", "FiraCode Nerd Font", "JetBrains Mono", "Sarasa Mono SC", "Source Han Mono", "Noto Sans Mono CJK SC", Menlo, Monaco, "Courier New", monospace',
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
      // Kitty Keyboard Protocol (CSI u) 支持
      // 启用后，终端会响应键盘协议查询，允许程序启用增强键盘报告
      // 这使得 Shift+Enter 等修饰键组合可以被正确识别
      // 参考: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
      kittyKeyboard: true,
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

    // WebLinks addon - 支持 Command+Click 在浏览器中打开链接
    try {
      const webLinksAddon = new WebLinksAddon.WebLinksAddon(
        (event, uri) => {
          // 仅在按住 Command 键时打开链接
          if (event.metaKey) {
            // 通过 Native Bridge 打开 URL
            if (window.tidyflowNative && window.tidyflowNative.post) {
              window.tidyflowNative.post("open_url", { url: uri });
            } else {
              // 回退：尝试直接打开
              window.open(uri, "_blank");
            }
          }
        }
      );
      term.loadAddon(webLinksAddon);
    } catch (e) {
      console.warn("WebLinks addon failed:", e.message);
    }

    // WebGL addon - GPU 加速渲染（参考 VS Code 策略）
    // 策略：WebGL 失败时直接回退到 DOM 渲染器，不再尝试恢复
    let webglAddon = null;

    /**
     * 判断是否应该加载 WebGL 渲染器
     * 参考 VS Code: gpuAcceleration === 'auto' && suggestedRendererType === undefined
     */
    function shouldLoadWebgl() {
      return suggestedRendererType === undefined;
    }

    /**
     * 释放 WebGL 渲染器
     */
    function disposeWebglAddon() {
      if (!webglAddon) return;
      try {
        webglAddon.dispose();
      } catch (e) {
        // ignore
      }
      webglAddon = null;
    }

    /**
     * 尝试加载 WebGL 渲染器
     * 失败时设置 suggestedRendererType = 'dom'，后续终端将直接使用 DOM 渲染器
     */
    function enableWebglAddon() {
      if (!shouldLoadWebgl()) {
        console.log("[WebGL] Skipped, using DOM renderer (suggested)");
        return false;
      }

      disposeWebglAddon();

      try {
        webglAddon = new WebglAddon.WebglAddon();
        webglAddon.onContextLoss(() => {
          // 参考 VS Code: context loss 时直接回退到 DOM，不尝试恢复
          console.warn("[WebGL] Context lost, falling back to DOM renderer");
          disposeWebglAddon();
          // 不设置 suggestedRendererType，允许其他终端继续尝试 WebGL
        });
        term.loadAddon(webglAddon);
        console.log("[WebGL] Addon loaded successfully");
        return true;
      } catch (e) {
        // 参考 VS Code: 加载失败时设置建议类型为 DOM
        console.warn("[WebGL] Addon failed, falling back to DOM renderer:", e.message);
        suggestedRendererType = 'dom';
        webglAddon = null;
        return false;
      }
    }

    // Unicode11 addon - 正确处理 CJK 等宽字符
    try {
      if (typeof Unicode11Addon !== 'undefined' && Unicode11Addon.Unicode11Addon) {
        const unicode11Addon = new Unicode11Addon.Unicode11Addon();
        term.loadAddon(unicode11Addon);
        // 激活 Unicode 11 版本
        term.unicode.activeVersion = '11';
      }
    } catch (e) {
      console.warn("Unicode11 addon failed:", e.message);
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
    // 以及中文标点（如 shift+9 输入 `（`）在 composition 期间被阻止的问题
    let isComposing = false;
    let compositionJustEnded = false;
    let compositionEndData = "";      // compositionend 事件的数据
    let compositionDataSent = false;  // onData 是否已发送 composition 数据
    const textarea = container.querySelector("textarea");
    if (textarea) {
      // FIX: 处理中文输入法下 keyCode=229 但没有 composition 事件的情况
      // 当 input 事件触发且 inputType 为 insertText，且非 composition 状态时，
      // xterm.js 可能因为 keyCode=229 而不触发 onData，需要手动发送
      let pendingInputTimer = null;
      let lastOnDataTime = 0;  // onData 最后触发的时间戳
      let lastOnDataChar = ""; // onData 最后处理的字符
      
      textarea.addEventListener("input", (e) => {
        // 只处理 insertText 类型，且非 composition 状态
        if (e.inputType === "insertText" && e.data && !isComposing && !e.isComposing) {
          const inputData = e.data;
          const inputTime = Date.now();
          
          // 检查 onData 是否最近已经处理过相同的字符（50ms 内）
          // 如果是，说明 xterm.js 已经处理了，不需要 fallback
          if (inputData === lastOnDataChar && (inputTime - lastOnDataTime) < 50) {
            return;
          }
          
          // 清除之前的定时器
          if (pendingInputTimer) {
            clearTimeout(pendingInputTimer);
          }
          
          // 设置短暂超时，检查 onData 是否触发
          pendingInputTimer = setTimeout(() => {
            // 再次检查 onData 是否在这段时间内处理过
            const checkTime = Date.now();
            if (inputData === lastOnDataChar && (checkTime - lastOnDataTime) < 50) {
              return;
            }
            
            // onData 没有触发,手动发送
            if (TF.transport && TF.transport.isConnected) {
              const encoder = new TextEncoder();
              const bytes = encoder.encode(inputData);
              TF.transport.send({
                type: "input",
                term_id: termId,
                data: bytes,
              });
            }
            pendingInputTimer = null;
          }, 20); // 20ms 足够让 onData 触发
        }
      });
      
      // 在 onData 处理中记录时间和字符
      term._inputFallbackMarker = (data) => {
        lastOnDataTime = Date.now();
        lastOnDataChar = data;
      };
      textarea.addEventListener("compositionstart", () => {
        isComposing = true;
        compositionJustEnded = false;
        compositionEndData = "";
        compositionDataSent = false;
      });
      textarea.addEventListener("compositionend", (e) => {
        isComposing = false;
        compositionJustEnded = true;
        compositionEndData = e.data || "";
        compositionDataSent = false;
        
        // 设置短暂超时：如果 onData 没有触发（中文标点的情况），手动发送数据
        setTimeout(() => {
          if (!compositionDataSent && compositionEndData.length > 0) {
            if (TF.transport && TF.transport.isConnected) {
              const encoder = new TextEncoder();
              const bytes = encoder.encode(compositionEndData);
              TF.transport.send({
                type: "input",
                term_id: termId,
                data: bytes,
              });
            }
          }
          compositionJustEnded = false;
          compositionEndData = "";
        }, 50);
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

    // OSC 52 剪贴板支持 - 用于 TUI 应用（如 opencode、vim 等）
    // 使用 ClipboardAddon 处理 OSC 52 序列，通过自定义 ClipboardProvider 发送到 Native Bridge
    if (typeof ClipboardAddon !== 'undefined' && ClipboardAddon.ClipboardAddon) {
      // 自定义 ClipboardProvider，通过 Native Bridge 写入系统剪贴板
      const nativeClipboardProvider = {
        readText: function(selection) {
          // 读取剪贴板暂不支持
          return Promise.resolve('');
        },
        writeText: function(selection, text) {
          if (text && text.length > 0) {
            TF.postToNative("clipboard_copy", { text: text });
          }
          return Promise.resolve();
        }
      };
      try {
        const clipboardAddon = new ClipboardAddon.ClipboardAddon(undefined, nativeClipboardProvider);
        term.loadAddon(clipboardAddon);
      } catch (e) {
        console.warn("[Clipboard] Failed to load ClipboardAddon:", e);
      }
    }

    term.onData((data) => {
      // 标记 onData 已触发，用于 input 事件的 fallback 逻辑
      if (term._inputFallbackMarker) {
        term._inputFallbackMarker(data);
      }
      // composition 期间不发送（避免重复）
      if (isComposing) {
        return;
      }
      
      // composition 刚结束后，标记 onData 已触发，避免 compositionend 超时重复发送
      if (compositionJustEnded) {
        compositionDataSent = true;
      }
      
      // composition 刚结束时，处理拼音残留（如 "o p" -> "op", "mu si ver" -> "musiver"）
      if (compositionJustEnded && /^[a-z]+(\s+[a-z]+)+$/i.test(data)) {
        data = data.replace(/\s+/g, '');
      }

      // 过滤 xterm.js 生成的终端查询响应，避免被 shell 回显
      // 这些响应通常是 xterm.js 回应 shell/应用程序的查询序列
      if (isTerminalQueryResponse(data)) {
        // console.log("[Terminal] Filtered query response:", data.length, "bytes");
        return;
      }

      if (TF.transport && TF.transport.isConnected) {
        const encoder = new TextEncoder();
        const bytes = encoder.encode(data);
        TF.transport.send({
          type: "input",
          term_id: termId,
          data: bytes,
        });
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
      // 使用 getter 获取当前的 webglAddon 状态
      get webglAddon() { return webglAddon; },
      // 检查是否使用 GPU 加速
      get isGpuAccelerated() { return !!webglAddon; },
      // 释放 WebGL 渲染器
      disposeWebgl: disposeWebglAddon,
      // 仅在需要时启用 WebGL（由激活逻辑控制）
      enableWebgl: enableWebglAddon,
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

    // 返回 Diff 按钮（仅当从 diff 跳转过来时显示）
    const backToDiffBtn = document.createElement("button");
    backToDiffBtn.className = "editor-back-diff-btn";
    backToDiffBtn.textContent = "← Back to Diff";
    backToDiffBtn.title = "Return to diff view";
    backToDiffBtn.style.display = "none";
    backToDiffBtn.addEventListener("click", () => {
      if (TF.goBackToDiff && TF.goBackToDiff()) {
        backToDiffBtn.style.display = "none";
      }
    });
    toolbar.appendChild(backToDiffBtn);

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
      const { EditorView, basicSetup, getLanguageExtension, oneDark } = window.CodeMirror;

      // 构建扩展列表
      const extensions = [
        basicSetup,
        oneDark,
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            const tab = tabSet.tabs.get(tabId);
            if (tab && !tab.isDirty && !tab._isReloading) {
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
      ];

      // 根据文件类型添加语言扩展
      const langExt = getLanguageExtension(filePath);
      if (langExt) {
        extensions.push(langExt);
      }

      editorView = new EditorView({
        doc: content || "",
        extensions,
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
      backToDiffBtn,
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

    // 通知 Native 层 dirty 状态变化
    if (tab.filePath) {
      TF.postToNative("dirty_state_changed", { path: tab.filePath, isDirty });
    }
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
    TF.sendFileWrite(tab.project, tab.workspace, tab.filePath, bytes);
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
        // 如果从 diff 跳转过来，显示返回按钮
        if (TF.lastDiffTabId && tab.backToDiffBtn) {
          tab.backToDiffBtn.style.display = "inline-block";
        }
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

    // 仅在激活的终端启用 WebGL，其他终端释放 WebGL
    updateWebglForActiveTab(tabId);

    // 如果是终端 tab，更新 activeSessionId
    if (tab.type === "terminal" && tab.termId) {
      TF.activeSessionId = tab.termId;
    }

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

          // 发送 resize 信号，触发 TUI 应用重绘
          // 这是让切换回来后界面正确显示的关键
          TF.sendResize(tab.termId, cols, rows);
        } else if (tab.type === "editor" && tab.editorView) {
          tab.editorView.focus();
        }
      });
    });

    TF.notifySwift("tab_switched", { tab_id: tabId, type: tab.type });
  }

  /**
   * 保证只有当前激活的终端使用 WebGL
   * 其他终端释放 WebGL 以减少上下文占用
   */
  function updateWebglForActiveTab(activeTabId) {
    TF.workspaceTabs.forEach((tabSet) => {
      tabSet.tabs.forEach((tab) => {
        if (tab.type !== "terminal") return;
        if (tab.id === activeTabId) {
          if (tab.enableWebgl) tab.enableWebgl();
        } else {
          if (tab.disposeWebgl) tab.disposeWebgl();
        }
      });
    });
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
        TF.transport.send({ type: "term_close", term_id: tab.termId });
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

  /**
   * 刷新当前活跃的终端，清除纹理图集并触发重绘
   * 用于解决应用切换后的花屏问题
   * 参考 VS Code 策略：不强制重建 WebGL，仅清除纹理和刷新显示
   */
  function refreshActiveTerminal() {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;

    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet || !tabSet.activeTabId) return;

    const tab = tabSet.tabs.get(tabSet.activeTabId);
    if (!tab || tab.type !== "terminal" || !tab.term) return;

    // 使用双重 requestAnimationFrame 确保浏览器完成布局更新
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        // 清除纹理图集以修复渲染问题
        if (tab.term.clearTextureAtlas) {
          tab.term.clearTextureAtlas();
        }

        tab.fitAddon.fit();
        const cols = tab.term.cols;
        const rows = tab.term.rows;
        tab.term.refresh(0, rows - 1);
        tab.term.focus();

        // 发送 resize 信号，触发 TUI 应用重绘
        TF.sendResize(tab.termId, cols, rows);
      });
    });
  }

  /**
   * 刷新所有终端的显示状态
   * 用于处理全局的渲染问题
   */
  function refreshAllTerminals() {
    console.log("[Terminal] Refreshing all terminals...");
    TF.workspaceTabs.forEach((tabSet) => {
      tabSet.tabs.forEach((tab) => {
        if (tab.type === "terminal" && tab.term) {
          // 清除纹理图集
          if (tab.term.clearTextureAtlas) {
            tab.term.clearTextureAtlas();
          }
          // 刷新显示
          tab.term.refresh(0, tab.term.rows - 1);
        }
      });
    });
  }

  // === 文件外部变更自动刷新 ===

  /// 静默重载（非 dirty 文件）
  function reloadEditorContent(tab, tabId, filePath, project, workspace) {
    const wsKey = TF.getWorkspaceKey(project, workspace);
    TF.pendingReloads.set(filePath, { tabId, wsKey });
    TF.sendFileRead(project, workspace, filePath);
  }

  /// 冲突提示（dirty 文件）
  function handleFileConflict(tab, tabId, filePath, project, workspace) {
    const fileName = filePath.split("/").pop();
    if (tab.statusBar) {
      tab.statusBar.textContent = `⚠ "${fileName}" 已在磁盘上更改。点击重新加载`;
      tab.statusBar.className = "editor-status file-conflict";
      tab.statusBar.onclick = () => {
        tab.statusBar.onclick = null;
        tab.statusBar.className = "editor-status";
        tab.statusBar.textContent = "正在重新加载...";
        TF.reloadEditorContent(tab, tabId, filePath, project, workspace);
      };
    }
  }

  /// 文件删除提示
  function handleFileDeleted(tab) {
    if (tab.statusBar) {
      tab.statusBar.textContent = "⚠ 此文件已从磁盘删除";
      tab.statusBar.className = "editor-status file-deleted";
    }
  }

  /// 替换 CodeMirror 内容（核心函数）
  function replaceEditorContent(tab, tabId, newContent) {
    if (!tab || !tab.editorView) return;

    const view = tab.editorView;
    const currentContent = view.state.doc.toString();
    if (currentContent === newContent) {
      if (tab.statusBar) {
        tab.statusBar.textContent = "";
        tab.statusBar.className = "editor-status";
      }
      return;
    }

    // 标记正在重载，防止 updateListener 触发 dirty 状态
    tab._isReloading = true;

    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: newContent },
    });

    tab._isReloading = false;

    // 重置 dirty 状态
    TF.updateTabDirtyState(tabId, false);

    if (tab.statusBar) {
      tab.statusBar.textContent = "已从磁盘重新加载";
      tab.statusBar.className = "editor-status";
      setTimeout(() => {
        tab.statusBar.textContent = "";
      }, 3000);
    }
  }

  // 监听页面可见性变化，解决应用切换后的花屏问题
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      // 延迟执行，等待 WKWebView 完全恢复
      setTimeout(() => {
        refreshActiveTerminal();
      }, 300);
    }
  });

  // 监听窗口焦点变化，作为 visibilitychange 的补充
  window.addEventListener("focus", () => {
    setTimeout(() => {
      refreshActiveTerminal();
    }, 200);
  });

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
  TF.refreshActiveTerminal = refreshActiveTerminal;
  TF.refreshAllTerminals = refreshAllTerminals;
  TF.reloadEditorContent = reloadEditorContent;
  TF.handleFileConflict = handleFileConflict;
  TF.handleFileDeleted = handleFileDeleted;
  TF.replaceEditorContent = replaceEditorContent;
})();
