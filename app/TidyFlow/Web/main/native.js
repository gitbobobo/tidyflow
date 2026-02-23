/**
 * TidyFlow Main - Native Bridge & Mode Switching
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function postToNative(type, payload) {
    if (window.tidyflowNative && window.tidyflowNative.post) {
      window.tidyflowNative.post(type, payload || {});
    } else {
      console.warn("[NativeBridge] Native bridge not available");
    }
  }

  function notifyNativeSaved(path) {
    postToNative("saved", { path });
  }

  function notifyNativeSaveError(path, message) {
    postToNative("save_error", { path, message });
  }

  function handleNativeEvent(type, payload) {
    console.log("[NativeBridge] Handling event:", type, payload);

    switch (type) {
      case "enter_mode": {
        const { mode, project, workspace } = payload;
        const oldWsKey = TF.getCurrentWorkspaceKey();
        const newProject = project || TF.currentProject;
        const newWorkspace = workspace || TF.currentWorkspace;
        const newWsKey = TF.getWorkspaceKey(newProject, newWorkspace);

        // 如果 workspace 发生变化，切换 tab UI
        if (oldWsKey !== newWsKey && newProject && newWorkspace) {
          // 隐藏旧 workspace 的 tabs
          if (oldWsKey && TF.workspaceTabs.has(oldWsKey)) {
            const oldTabSet = TF.workspaceTabs.get(oldWsKey);
            oldTabSet.tabs.forEach((tab) => {
              tab.pane.classList.remove("active");
              tab.tabEl.style.display = "none";
            });
          }

          // 更新当前 workspace
          TF.currentProject = newProject;
          TF.currentWorkspace = newWorkspace;

          // 显示新 workspace 的 tabs（如果已存在）
          if (TF.workspaceTabs.has(newWsKey)) {
            const newTabSet = TF.workspaceTabs.get(newWsKey);
            newTabSet.tabs.forEach((tab) => {
              tab.tabEl.style.display = "";
            });
            // 激活之前的活动 tab
            if (newTabSet.activeTabId && newTabSet.tabs.has(newTabSet.activeTabId)) {
              TF.activeTabId = newTabSet.activeTabId;
              TF.switchToTab(TF.activeTabId);
            }
          }
        } else {
          // 只更新状态，不切换 UI
          if (project) TF.currentProject = project;
          if (workspace) TF.currentWorkspace = workspace;
        }

        console.log("[NativeBridge] enter_mode:", mode, "project:", TF.currentProject, "workspace:", TF.currentWorkspace);
        if (mode !== "terminal") {
          console.warn("[NativeBridge] Unsupported mode ignored:", mode);
          break;
        }
        TF.setNativeMode("terminal");
        break;
      }

      case "terminal_spawn": {
        const { project, workspace, tab_id } = payload;
        console.log("[NativeBridge] terminal_spawn:", tab_id, project, workspace);

        TF.pendingTerminalSpawn = { tabId: tab_id, project, workspace };

        if (!TF.transport || !TF.transport.isConnected) {
          console.log("[NativeBridge] WebSocket not connected, connecting first...");
          TF.currentProject = project;
          TF.currentWorkspace = workspace;
          TF.connect();
          setTimeout(() => {
            if (TF.transport && TF.transport.isConnected) {
              console.log("[NativeBridge] Sending select_workspace:", project, workspace);
              TF.sendControlMessage({ type: "select_workspace", project, workspace });
            } else {
              postToNative("terminal_error", { tab_id: tab_id, message: "Not connected to core" });
            }
          }, 1000);
          return;
        }

        // 如果 workspace 已经是当前 workspace，直接创建新终端
        // 否则先选择 workspace
        if (TF.currentProject === project && TF.currentWorkspace === workspace) {
          console.log("[NativeBridge] Workspace already selected, sending term_create:", project, workspace);
          TF.sendControlMessage({ type: "term_create", project, workspace });
        } else {
          console.log("[NativeBridge] Switching workspace, sending select_workspace:", project, workspace);
          TF.currentProject = project;
          TF.currentWorkspace = workspace;
          TF.sendControlMessage({ type: "select_workspace", project, workspace });
        }
        break;
      }

      case "terminal_attach": {
        const { tab_id, session_id } = payload;
        console.log("[NativeBridge] terminal_attach:", tab_id, session_id);

        // JS 层已有该 session（WS 未断场景），走本地附着
        if (TF.terminalSessions.has(session_id)) {
          TF.activeSessionId = session_id;
          TF.nativeTerminalReady = true;

          for (const [, tabSet] of TF.workspaceTabs) {
            if (tabSet.tabs.has(session_id)) {
              const tab = tabSet.tabs.get(session_id);
              if (tab.term) {
                tab.term.focus();
                if (tab.fitAddon) {
                  tab.fitAddon.fit();
                  TF.sendResize(session_id, tab.term.cols, tab.term.rows);
                }
              }
              TF.switchToTab(session_id);
              break;
            }
          }

          const session = TF.terminalSessions.get(session_id);
          postToNative("terminal_ready", {
            tab_id: tab_id,
            session_id: session_id,
            project: session ? session.project : "",
            workspace: session ? session.workspace : "",
          });
          break;
        }

        // JS 层没有该 session（WS 重连场景），向服务端请求附着
        if (!TF.transport || !TF.transport.isConnected) {
          postToNative("terminal_error", { tab_id: tab_id, message: "Not connected to core" });
          return;
        }

        console.log("[NativeBridge] Session not in JS, requesting server attach:", session_id);
        TF.pendingTerminalAttach = { tabId: tab_id, termId: session_id };
        TF.sendControlMessage({ type: "term_attach", term_id: session_id });
        break;
      }

      case "terminal_kill": {
        const { tab_id, session_id } = payload;
        console.log("[NativeBridge] terminal_kill:", tab_id, session_id);

        TF.terminalSessions.delete(session_id);
        if (TF.activeSessionId === session_id) TF.activeSessionId = null;

        if (TF.transport && TF.transport.isConnected) {
          TF.transport.send({ type: "term_close", term_id: session_id });
        }

        postToNative("terminal_closed", { tab_id: tab_id, session_id: session_id, code: 0 });
        break;
      }

      case "terminal_input": {
        const { session_id, input } = payload;
        console.log("[NativeBridge] terminal_input:", session_id, input);

        if (TF.transport && TF.transport.isConnected) {
          const encoder = new TextEncoder();
          const bytes = encoder.encode(input + "\n");
          TF.transport.send({
            type: "input",
            term_id: session_id,
            data: bytes,
          });
        }
        break;
      }

      case "terminal_ensure": {
        const { project, workspace } = payload;
        TF.ensureTerminalForNative(project, workspace);
        break;
      }

      default:
        console.warn("[NativeBridge] Unknown event type:", type);
    }
  }

  function setNativeMode(mode) {
    if (TF.nativeMode === mode) return;

    TF.nativeMode = mode;
    console.log("[NativeMode] Switching to:", mode);
    TF.hideNonTerminalTabs();
    TF.showTerminalMode();
  }

  function hideNonTerminalTabs() {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey || !TF.workspaceTabs.has(wsKey)) return;

    const tabSet = TF.workspaceTabs.get(wsKey);
    tabSet.tabs.forEach((tab) => {
      if (tab.type !== "terminal") {
        tab.pane.classList.remove("active");
        tab.tabEl.style.display = "none";
      }
    });
  }

  function showTerminalMode() {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey || !TF.workspaceTabs.has(wsKey)) return;

    const tabSet = TF.workspaceTabs.get(wsKey);
    let terminalTab = null;
    for (const [, tab] of tabSet.tabs) {
      if (tab.type === "terminal") {
        terminalTab = tab;
        break;
      }
    }

    if (terminalTab) {
      tabSet.tabs.forEach((tab, tabId) => {
        if (tabId !== terminalTab.id) {
          tab.pane.classList.remove("active");
          tab.tabEl.classList.remove("active");
        }
      });

      terminalTab.tabEl.style.display = "";
      terminalTab.tabEl.classList.add("active");
      terminalTab.pane.classList.add("active");
      TF.activeTabId = terminalTab.id;
      tabSet.activeTabId = terminalTab.id;

      setTimeout(() => {
        if (terminalTab.fitAddon) terminalTab.fitAddon.fit();
        if (terminalTab.term) {
          terminalTab.term.focus();
          TF.sendResize(terminalTab.termId, terminalTab.term.cols, terminalTab.term.rows);
        }
      }, 50);
    }

    if (TF.placeholder) TF.placeholder.style.display = "none";
  }

  function ensureTerminalForNative(project, workspace) {
    console.log("[NativeMode] Ensuring terminal for:", project, workspace);

    if (!TF.transport || !TF.transport.isConnected) {
      console.log("[NativeMode] WebSocket not connected, connecting...");
      TF.connect();
      setTimeout(() => TF.ensureTerminalForNative(project, workspace), 500);
      return;
    }

    const wsKey = TF.getWorkspaceKey(project, workspace);

    if (TF.workspaceTabs.has(wsKey)) {
      const tabSet = TF.workspaceTabs.get(wsKey);
      for (const [, tab] of tabSet.tabs) {
        if (tab.type === "terminal") {
          TF.activeSessionId = tab.termId;
          TF.nativeTerminalReady = true;
          postToNative("terminal_ready", {
            tab_id: tab.termId,
            session_id: tab.termId,
            project: project,
            workspace: workspace,
          });
          console.log("[NativeMode] Existing terminal found:", tab.termId);
          return;
        }
      }
    }

    if (TF.currentProject !== project || TF.currentWorkspace !== workspace) {
      console.log("[NativeMode] Selecting workspace:", project, workspace);
      TF.selectWorkspace(project, workspace);
    } else {
      console.log("[NativeMode] Creating new terminal");
      TF.createTerminal(project, workspace);
    }
  }

  TF.postToNative = postToNative;
  TF.notifyNativeSaved = notifyNativeSaved;
  TF.notifyNativeSaveError = notifyNativeSaveError;
  TF.handleNativeEvent = handleNativeEvent;
  TF.setNativeMode = setNativeMode;
  TF.hideNonTerminalTabs = hideNonTerminalTabs;
  TF.showTerminalMode = showTerminalMode;
  TF.ensureTerminalForNative = ensureTerminalForNative;
})();
