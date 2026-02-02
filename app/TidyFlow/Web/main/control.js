/**
 * TidyFlow Main - Control Plane (RPC, file ops, terminal)
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function sendControlMessage(msg) {
    if (TF.transport && TF.transport.isConnected) {
      TF.transport.send(JSON.stringify(msg));
    }
  }

  function listProjects() {
    sendControlMessage({ type: "list_projects" });
  }

  function listWorkspaces(project) {
    sendControlMessage({ type: "list_workspaces", project });
  }

  function selectWorkspace(project, workspace) {
    sendControlMessage({ type: "select_workspace", project, workspace });
  }

  function createTerminal(project, workspace) {
    sendControlMessage({ type: "term_create", project, workspace });
  }

  function useDefaultServerTerminal(tabId, project, workspace) {
    const sessionId = TF.defaultServerTerminalId;
    if (!sessionId) {
      console.error("[useDefaultServerTerminal] No default server terminal ID");
      TF.postToNative("terminal_error", { tab_id: tabId, message: "No default terminal available" });
      return;
    }

    try {
      const tabInfo = TF.createTerminalTab(sessionId, "~", project, workspace);
      TF.switchToTab(sessionId);

      if (tabInfo && tabInfo.term) {
        setTimeout(() => {
          tabInfo.fitAddon.fit();
          TF.sendResize(sessionId, tabInfo.term.cols, tabInfo.term.rows);

          const itemsToReplay = TF.pendingOutputBuffer.filter((item) => item.termId === sessionId);
          TF.pendingOutputBuffer = TF.pendingOutputBuffer.filter((item) => item.termId !== sessionId);

          if (itemsToReplay.length > 0) {
            let writePromise = Promise.resolve();
            for (const item of itemsToReplay) {
              writePromise = writePromise.then(() => {
                return new Promise((resolve) => {
                  tabInfo.term.write(item.bytes, resolve);
                });
              });
            }
            writePromise.then(() => {
              tabInfo.term.refresh(0, tabInfo.term.rows - 1);
              tabInfo.term.scrollToBottom();
              tabInfo.term.focus();
            });
          } else {
            tabInfo.term.focus();
            tabInfo.term.refresh(0, tabInfo.term.rows - 1);
          }
        }, 100);
      }

      TF.terminalSessions.set(sessionId, {
        buffer: [],
        tabId: tabId,
        project: project,
        workspace: workspace,
      });
      TF.activeSessionId = sessionId;
      TF.nativeTerminalReady = true;

      TF.postToNative("terminal_ready", {
        tab_id: tabId,
        session_id: sessionId,
        project: project,
        workspace: workspace,
      });

      TF.defaultServerTerminalId = null;

      TF.setNativeMode("terminal");
      TF.showTerminalMode();
    } catch (err) {
      console.error("[useDefaultServerTerminal] Error:", err);
      TF.postToNative("terminal_error", {
        tab_id: tabId,
        message: "Failed to setup terminal: " + (err?.message || String(err)),
      });
    }
  }

  function listTerminals() {
    sendControlMessage({ type: "term_list" });
  }

  function sendFileList(project, workspace, path) {
    sendControlMessage({ type: "file_list", project, workspace, path: path || "." });
  }

  function sendFileRead(project, workspace, path) {
    sendControlMessage({ type: "file_read", project, workspace, path });
  }

  function sendFileWrite(project, workspace, path, content_b64) {
    sendControlMessage({ type: "file_write", project, workspace, path, content_b64 });
  }

  function sendFileIndex(project, workspace) {
    sendControlMessage({ type: "file_index", project, workspace });
  }

  function sendResize(termId, cols, rows) {
    if (TF.transport && TF.transport.isConnected) {
      TF.transport.send(JSON.stringify({
        type: "resize",
        term_id: termId,
        cols: cols,
        rows: rows,
      }));
    }
  }

  TF.sendControlMessage = sendControlMessage;
  TF.listProjects = listProjects;
  TF.listWorkspaces = listWorkspaces;
  TF.selectWorkspace = selectWorkspace;
  TF.createTerminal = createTerminal;
  TF.useDefaultServerTerminal = useDefaultServerTerminal;
  TF.listTerminals = listTerminals;
  TF.sendFileList = sendFileList;
  TF.sendFileRead = sendFileRead;
  TF.sendFileWrite = sendFileWrite;
  TF.sendFileIndex = sendFileIndex;
  TF.sendResize = sendResize;
})();
