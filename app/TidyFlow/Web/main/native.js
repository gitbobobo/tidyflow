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
      case "open_file": {
        const { project, workspace, path } = payload;
        if (!project || !workspace || !path) {
          console.error("[NativeBridge] open_file missing required fields");
          return;
        }
        if (TF.currentProject !== project || TF.currentWorkspace !== workspace) {
          TF.currentProject = project;
          TF.currentWorkspace = workspace;
        }
        TF.openFileInEditor(path);
        break;
      }

      case "save_file": {
        const { project, workspace, path } = payload;
        if (!path) {
          console.error("[NativeBridge] save_file missing path");
          postToNative("save_error", { path: "", message: "Missing path" });
          return;
        }
        const wsKey = TF.getWorkspaceKey(project || TF.currentProject, workspace || TF.currentWorkspace);
        const tabId = "editor-" + path.replace(/[^a-zA-Z0-9]/g, "-");

        if (TF.workspaceTabs.has(wsKey)) {
          const tabSet = TF.workspaceTabs.get(wsKey);
          if (tabSet.tabs.has(tabId)) {
            TF.saveEditorTab(tabId);
          } else {
            postToNative("save_error", { path, message: "Editor tab not found" });
          }
        } else {
          postToNative("save_error", { path, message: "Workspace not found" });
        }
        break;
      }

      case "enter_mode": {
        const { mode, project, workspace } = payload;
        if (project) TF.currentProject = project;
        if (workspace) TF.currentWorkspace = workspace;
        console.log("[NativeBridge] enter_mode:", mode, "project:", TF.currentProject, "workspace:", TF.currentWorkspace);
        if (mode === "terminal" || mode === "editor" || mode === "diff") {
          TF.setNativeMode(mode);
        } else {
          console.warn("[NativeBridge] Unknown mode:", mode);
        }
        break;
      }

      case "terminal_spawn": {
        const { project, workspace, tab_id } = payload;
        console.log("[NativeBridge] terminal_spawn:", tab_id, project, workspace);

        TF.currentProject = project;
        TF.currentWorkspace = workspace;

        TF.pendingTerminalSpawn = { tabId: tab_id, project, workspace };

        if (!TF.transport || !TF.transport.isConnected) {
          console.log("[NativeBridge] WebSocket not connected, connecting first...");
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

        console.log("[NativeBridge] Sending select_workspace:", project, workspace);
        TF.sendControlMessage({ type: "select_workspace", project, workspace });
        break;
      }

      case "terminal_attach": {
        const { tab_id, session_id } = payload;
        console.log("[NativeBridge] terminal_attach:", tab_id, session_id);

        if (!TF.terminalSessions.has(session_id)) {
          postToNative("terminal_error", { tab_id: tab_id, message: "Session not found, respawn needed" });
          return;
        }

        TF.activeSessionId = session_id;
        TF.nativeTerminalReady = true;

        for (const [, tabSet] of TF.workspaceTabs) {
          if (tabSet.tabs.has(session_id)) {
            const tab = tabSet.tabs.get(session_id);
            if (tab.term) {
              tab.term.clear();
              const session = TF.terminalSessions.get(session_id);
              if (session && session.buffer.length > 0) {
                for (const line of session.buffer) {
                  tab.term.write(line);
                }
              }
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

      case "terminal_kill": {
        const { tab_id, session_id } = payload;
        console.log("[NativeBridge] terminal_kill:", tab_id, session_id);

        TF.terminalSessions.delete(session_id);
        if (TF.activeSessionId === session_id) TF.activeSessionId = null;

        if (TF.transport && TF.transport.isConnected) {
          TF.transport.send(JSON.stringify({ type: "term_kill", term_id: session_id }));
        }

        postToNative("terminal_closed", { tab_id: tab_id, session_id: session_id, code: 0 });
        break;
      }

      case "terminal_ensure": {
        const { project, workspace } = payload;
        TF.ensureTerminalForNative(project, workspace);
        break;
      }

      case "diff_open": {
        const { project, workspace, path, mode } = payload;
        console.log("[NativeBridge] diff_open:", path, mode);

        if (!project || !workspace || !path) {
          console.error("[NativeBridge] diff_open missing required fields");
          postToNative("diff_error", { message: "Missing required fields" });
          return;
        }

        if (TF.currentProject !== project || TF.currentWorkspace !== workspace) {
          TF.currentProject = project;
          TF.currentWorkspace = workspace;
        }

        TF.openDiffTabFromNative(path, mode || "working");
        break;
      }

      case "diff_set_mode": {
        const { mode } = payload;
        console.log("[NativeBridge] diff_set_mode:", mode);

        const wsKey = TF.getCurrentWorkspaceKey();
        if (wsKey && TF.workspaceTabs.has(wsKey)) {
          const tabSet = TF.workspaceTabs.get(wsKey);
          const activeTab = tabSet.tabs.get(tabSet.activeTabId);
          if (activeTab && activeTab.type === "diff") {
            activeTab.diffMode = mode;
            TF.sendGitDiff(activeTab.project, activeTab.workspace, activeTab.filePath, mode);
          }
        }
        break;
      }

      case "editor_reveal_line": {
        const { path, line, highlightMs } = payload;
        console.log("[NativeBridge] editor_reveal_line:", path, line, highlightMs);

        if (!path || !line) {
          console.error("[NativeBridge] editor_reveal_line missing required fields");
          return;
        }

        const wsKey = TF.getCurrentWorkspaceKey();
        if (!wsKey || !TF.workspaceTabs.has(wsKey)) {
          console.warn("[NativeBridge] No workspace for editor_reveal_line");
          return;
        }

        const tabId = "editor-" + path.replace(/[^a-zA-Z0-9]/g, "-");
        const tabSet = TF.workspaceTabs.get(wsKey);

        if (tabSet.tabs.has(tabId)) {
          const tab = tabSet.tabs.get(tabId);
          TF.scrollToLineAndHighlight(tab, line, highlightMs || 2000);
        } else {
          console.warn("[NativeBridge] Editor tab not found for:", path);
        }
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

    const leftSidebar = document.getElementById("left-sidebar");
    const rightPanel = document.getElementById("right-panel");

    if (mode === "terminal") {
      if (leftSidebar) leftSidebar.style.display = "none";
      if (rightPanel) rightPanel.style.display = "none";
      TF.hideNonTerminalTabs();
      TF.showTerminalMode();
    } else if (mode === "diff") {
      if (leftSidebar) leftSidebar.style.display = "none";
      if (rightPanel) rightPanel.style.display = "none";
      TF.showDiffMode();
    } else {
      if (leftSidebar) leftSidebar.style.display = "flex";
      if (rightPanel) rightPanel.style.display = "flex";
      TF.showEditorMode();
    }
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

  function showEditorMode() {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey || !TF.workspaceTabs.has(wsKey)) return;

    const tabSet = TF.workspaceTabs.get(wsKey);

    tabSet.tabs.forEach((tab) => {
      tab.tabEl.style.display = "";
    });

    if (tabSet.activeTabId && tabSet.tabs.has(tabSet.activeTabId)) {
      TF.switchToTab(tabSet.activeTabId);
    }
  }

  function showDiffMode() {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey || !TF.workspaceTabs.has(wsKey)) return;

    const tabSet = TF.workspaceTabs.get(wsKey);

    tabSet.tabs.forEach((tab) => {
      if (tab.type !== "diff") {
        tab.pane.classList.remove("active");
        tab.tabEl.style.display = "none";
      } else {
        tab.tabEl.style.display = "";
      }
    });

    for (const [tabId, tab] of tabSet.tabs) {
      if (tab.type === "diff") {
        TF.switchToTab(tabId);
        break;
      }
    }
  }

  function openDiffTabFromNative(path, mode) {
    if (!TF.currentProject || !TF.currentWorkspace) {
      postToNative("diff_error", { message: "No workspace selected" });
      return;
    }

    const tabInfo = TF.createDiffTab(path, "M");
    if (tabInfo) {
      tabInfo.diffMode = mode;

      const modeToggle = tabInfo.pane.querySelector(".diff-mode-toggle");
      if (modeToggle) {
        modeToggle.querySelectorAll(".diff-mode-btn").forEach((btn) => {
          btn.classList.toggle("active", btn.dataset.mode === mode);
        });
      }

      TF.switchToTab(tabInfo.id);
      TF.sendGitDiff(TF.currentProject, TF.currentWorkspace, path, mode);
    }
  }

  function openFileAtLineViaNative(path, line) {
    postToNative("open_file_request", {
      workspace: TF.currentWorkspace,
      path: path,
      line: line || null,
    });
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
  TF.showEditorMode = showEditorMode;
  TF.showDiffMode = showDiffMode;
  TF.openDiffTabFromNative = openDiffTabFromNative;
  TF.openFileAtLineViaNative = openFileAtLineViaNative;
  TF.ensureTerminalForNative = ensureTerminalForNative;
})();
