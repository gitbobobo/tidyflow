/**
 * TidyFlow Main - WebSocket Message Handling
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function handleMessage(data) {
    try {
      if (
        !data ||
        typeof data.seq !== "number" ||
        data.seq <= 0 ||
        typeof data.domain !== "string" ||
        typeof data.action !== "string" ||
        typeof data.kind !== "string" ||
        typeof data.payload !== "object"
      ) {
        console.error("[Messages] Invalid v4 envelope:", data);
        return;
      }
      if (data.seq <= TF.lastServerSeq) {
        console.warn("[Messages] Drop stale envelope:", data.seq, TF.lastServerSeq);
        return;
      }
      TF.lastServerSeq = data.seq;
      const msg = { ...(data.payload || {}), type: data.action };

      switch (msg.type) {
        case "hello": {
          TF.protocolVersion = msg.version || 0;
          TF.capabilities = msg.capabilities || [];

          if (msg.session_id) {
            TF.defaultServerTerminalId = msg.session_id;
          }

          TF.listProjects();

          TF.notifySwift("hello", {
            session_id: msg.session_id,
            version: TF.protocolVersion,
            capabilities: TF.capabilities,
          });
          break;
        }

        case "output": {
          const termId = msg.term_id;

          if (
            termId &&
            !TF.terminalSessions.has(termId) &&
            termId === TF.defaultServerTerminalId
          ) {
            TF.pendingOutputBuffer.push({ termId, bytes: msg.data });
            break;
          }

          if (termId) {
            const dataLen = msg.data ? msg.data.length || msg.data.byteLength || 0 : 0;
            // 使用 termTabIndex 直接索引 O(1) 查找目标终端
            const entry = TF.termTabIndex.get(termId);
            if (entry && entry.tab && entry.tab.term) {
              const tab = entry.tab;
              // 使用回调形式：xterm.js 解析完数据后触发，用于流控 ACK
              tab.term.write(msg.data, () => {
                // 累加已消费字节数
                let state = TF.termAckedBytes.get(termId);
                if (!state) {
                  state = { pending: 0 };
                  TF.termAckedBytes.set(termId, state);
                }
                state.pending += dataLen;
                // 超过阈值时发送 ACK
                if (state.pending >= TF.ACK_THRESHOLD) {
                  const ackBytes = state.pending;
                  state.pending = 0;
                  if (TF.transport && TF.transport.isConnected) {
                    TF.transport.send({
                      type: "term_output_ack",
                      term_id: termId,
                      bytes: ackBytes,
                    });
                  }
                }
              });
            }
          }
          break;
        }

        case "exit": {
          const termId = msg.term_id;
          if (termId) {
            const entry = TF.termTabIndex.get(termId);
            if (entry && entry.tab && entry.tab.term) {
              entry.tab.term.writeln("");
              entry.tab.term.writeln("\x1b[33m[Shell exited with code " + msg.code + "]\x1b[0m");
            }
          }
          break;
        }

        case "pong":
          break;

        case "projects":
          TF.projects = msg.items || [];
          TF.renderProjectTree();
          TF.notifySwift("projects", { items: TF.projects });
          break;

        case "workspaces":
          TF.workspacesMap.set(msg.project, msg.items || []);
          TF.renderProjectTree();
          TF.notifySwift("workspaces", { project: msg.project, items: msg.items });
          break;

        case "selected_workspace": {
          TF.switchWorkspaceUI(msg.project, msg.workspace, msg.root);

          const originalTabId = TF.pendingTerminalSpawn?.tabId || msg.session_id;

          const tabInfo = TF.createTerminalTab(
            msg.session_id,
            msg.root,
            msg.project,
            msg.workspace,
          );
          TF.switchToTab(msg.session_id);

          if (tabInfo.term) {
            tabInfo.fitAddon.fit();
            TF.sendResize(msg.session_id, tabInfo.term.cols, tabInfo.term.rows);
          }

          TF.terminalSessions.set(msg.session_id, {
            buffer: [],
            tabId: originalTabId,
            project: msg.project,
            workspace: msg.workspace,
          });
          TF.activeSessionId = msg.session_id;
          TF.nativeTerminalReady = true;

          TF.pendingTerminalSpawn = null;

          TF.postToNative("terminal_ready", {
            tab_id: originalTabId,
            session_id: msg.session_id,
            project: msg.project,
            workspace: msg.workspace,
          });

          TF.notifySwift("workspace_selected", {
            project: msg.project,
            workspace: msg.workspace,
            root: msg.root,
            session_id: msg.session_id,
          });

          TF.setNativeMode("terminal");
          break;
        }

        case "term_created": {
          const sessionId = msg.term_id;
          const pendingTabId = TF.pendingTerminalSpawn ? TF.pendingTerminalSpawn.tabId : null;

          const tabInfo = TF.createTerminalTab(
            sessionId,
            msg.cwd,
            msg.project,
            msg.workspace,
          );
          TF.switchToTab(sessionId);

          if (tabInfo.term) {
            tabInfo.term.writeln("\x1b[32m[New Terminal: " + (msg.workspace || "default") + "]\x1b[0m");
            tabInfo.term.writeln("\x1b[90mCWD: " + msg.cwd + "\x1b[0m");
            tabInfo.term.writeln("\x1b[90mShell: " + msg.shell + "\x1b[0m");
            tabInfo.term.writeln("");

            tabInfo.fitAddon.fit();
            TF.sendResize(sessionId, tabInfo.term.cols, tabInfo.term.rows);
          }

          TF.terminalSessions.set(sessionId, {
            buffer: [],
            tabId: pendingTabId || sessionId,
            project: msg.project,
            workspace: msg.workspace,
          });
          TF.activeSessionId = sessionId;
          TF.nativeTerminalReady = true;

          TF.postToNative("terminal_ready", {
            tab_id: pendingTabId || sessionId,
            session_id: sessionId,
            project: msg.project,
            workspace: msg.workspace,
          });

          TF.pendingTerminalSpawn = null;

          TF.notifySwift("term_created", {
            term_id: sessionId,
            project: msg.project,
            workspace: msg.workspace,
            cwd: msg.cwd,
          });
          break;
        }

        case "term_list":
          TF.notifySwift("term_list", { items: msg.items });
          break;

        case "term_attached": {
          // WS 重连后服务端返回的附着响应，包含 scrollback 回放数据
          const termId = msg.term_id;
          const pending = TF.pendingTerminalAttach;
          const tabId = pending && pending.termId === termId ? pending.tabId : termId;
          TF.pendingTerminalAttach = null;

          console.log("[Messages] term_attached:", termId, "project:", msg.project, "workspace:", msg.workspace);

          // 创建 xterm.js 实例
          const tabInfo = TF.createTerminalTab(
            termId,
            msg.cwd,
            msg.project,
            msg.workspace,
          );
          TF.switchToTab(termId);

          if (tabInfo.term) {
            // 写入 scrollback 数据回放
            if (msg.scrollback && msg.scrollback.length > 0) {
              tabInfo.term.write(msg.scrollback);
            }

            tabInfo.fitAddon.fit();
            TF.sendResize(termId, tabInfo.term.cols, tabInfo.term.rows);
            tabInfo.term.focus();
          }

          TF.terminalSessions.set(termId, {
            buffer: [],
            tabId: tabId,
            project: msg.project,
            workspace: msg.workspace,
          });
          TF.activeSessionId = termId;
          TF.nativeTerminalReady = true;

          TF.postToNative("terminal_ready", {
            tab_id: tabId,
            session_id: termId,
            project: msg.project,
            workspace: msg.workspace,
          });

          TF.notifySwift("term_attached", {
            term_id: termId,
            project: msg.project,
            workspace: msg.workspace,
            cwd: msg.cwd,
          });
          break;
        }

        case "term_closed": {
          const entry = TF.termTabIndex.get(msg.term_id);
          if (entry) {
            const [proj, ws] = entry.wsKey.split("/");
            const savedProj = TF.currentProject;
            const savedWs = TF.currentWorkspace;
            TF.currentProject = proj;
            TF.currentWorkspace = ws;
            TF.removeTabFromUI(msg.term_id);
            TF.currentProject = savedProj;
            TF.currentWorkspace = savedWs;
          }
          TF.notifySwift("term_closed", { term_id: msg.term_id });
          break;
        }

        case "file_list_result":
          if (msg.project === TF.currentProject && msg.workspace === TF.currentWorkspace) {
            TF.renderExplorerTree(msg.path, msg.items);
          }
          TF.notifySwift("file_list", {
            project: msg.project,
            workspace: msg.workspace,
            items: msg.items,
          });
          break;

        case "file_read_result":
          // 文件编辑器已迁移至 Native，Web 端忽略此消息
          TF.notifySwift("file_read", {
            project: msg.project,
            workspace: msg.workspace,
            path: msg.path,
            size: msg.size,
          });
          break;

        case "file_write_result":
          // 文件编辑器已迁移至 Native，Web 端忽略此消息
          TF.notifySwift("file_write", {
            project: msg.project,
            workspace: msg.workspace,
            path: msg.path,
            success: msg.success,
          });
          break;

        case "file_index_result": {
          const wsKey = TF.getWorkspaceKey(msg.project, msg.workspace);
          TF.workspaceFileIndex.set(wsKey, {
            items: msg.items || [],
            truncated: msg.truncated || false,
            updatedAt: Date.now(),
          });
          if (window.tidyflowPalette && window.tidyflowPalette.onFileIndexReady) {
            window.tidyflowPalette.onFileIndexReady(wsKey);
          }
          TF.notifySwift("file_index", {
            project: msg.project,
            workspace: msg.workspace,
            count: msg.items?.length || 0,
            truncated: msg.truncated,
          });
          break;
        }

        case "git_status_result":
          if (msg.project === TF.currentProject && msg.workspace === TF.currentWorkspace) {
            TF.renderGitStatus(msg.repo_root, msg.items || []);
          }
          TF.notifySwift("git_status", {
            project: msg.project,
            workspace: msg.workspace,
            count: msg.items?.length || 0,
          });
          break;

        case "git_diff_result":
          // Diff 已迁移至 Native，Web 端忽略此消息
          TF.notifySwift("git_diff", {
            project: msg.project,
            workspace: msg.workspace,
            path: msg.path,
          });
          break;

        case "error":
          console.error("Server error:", msg.code, msg.message);
          // 如果有 pending terminal spawn 且错误是 workspace_not_found，通知 Native
          if (TF.pendingTerminalSpawn && (msg.code === 'workspace_not_found' || msg.code === 'project_not_found')) {
            TF.postToNative("terminal_error", {
              tab_id: TF.pendingTerminalSpawn.tabId,
              message: msg.message || msg.code
            });
            TF.pendingTerminalSpawn = null;
          }
          TF.notifySwift("error", { code: msg.code, message: msg.message });
          break;

        default:
          console.warn("Unknown message type:", msg.type);
      }
    } catch (e) {
      console.error("Failed to parse message:", e);
    }
  }

  TF.handleMessage = handleMessage;
})();
