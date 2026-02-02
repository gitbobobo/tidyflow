/**
 * TidyFlow Main - WebSocket Message Handling
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function handleMessage(data) {
    try {
      const msg = JSON.parse(data);

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
            const bytes = TF.decodeBase64(msg.data_b64);
            TF.pendingOutputBuffer.push({ termId, bytes });
            break;
          }

          if (termId) {
            const bytes = TF.decodeBase64(msg.data_b64);

            if (TF.terminalSessions.has(termId)) {
              const session = TF.terminalSessions.get(termId);
              const text = new TextDecoder().decode(bytes);
              session.buffer.push(text);
              while (session.buffer.length > TF.MAX_BUFFER_LINES) {
                session.buffer.shift();
              }
            }

            if (termId === TF.activeSessionId) {
              for (const [wsKey, tabSet] of TF.workspaceTabs) {
                if (tabSet.tabs.has(termId)) {
                  const tab = tabSet.tabs.get(termId);
                  if (tab.term) tab.term.write(bytes);
                  break;
                }
              }
            }
          }
          break;
        }

        case "exit": {
          const termId = msg.term_id;
          if (termId) {
            for (const [, tabSet] of TF.workspaceTabs) {
              if (tabSet.tabs.has(termId)) {
                const tab = tabSet.tabs.get(termId);
                if (tab.term) {
                  tab.term.writeln("");
                  tab.term.writeln("\x1b[33m[Shell exited with code " + msg.code + "]\x1b[0m");
                }
                break;
              }
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

        case "term_closed":
          for (const [wsKey, tabSet] of TF.workspaceTabs) {
            if (tabSet.tabs.has(msg.term_id)) {
              const [proj, ws] = wsKey.split("/");
              const savedProj = TF.currentProject;
              const savedWs = TF.currentWorkspace;
              TF.currentProject = proj;
              TF.currentWorkspace = ws;
              TF.removeTabFromUI(msg.term_id);
              TF.currentProject = savedProj;
              TF.currentWorkspace = savedWs;
              break;
            }
          }
          TF.notifySwift("term_closed", { term_id: msg.term_id });
          break;

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
          if (msg.project === TF.currentProject && msg.workspace === TF.currentWorkspace) {
            try {
              const content = new TextDecoder().decode(TF.decodeBase64(msg.content_b64));
              const tabInfo = TF.createEditorTab(msg.path, content);
              if (tabInfo) {
                TF.switchToTab(tabInfo.id);
                // 创建 tab 后再次确保编辑器模式下的 tab 可见（open_file 时 tab set 可能尚不存在，showEditorMode 曾提前返回）
                if (TF.nativeMode === "editor") {
                  TF.showEditorMode();
                }
                // 强制隐藏 placeholder（避免被 placeholder 遮挡）
                // 注意：不要设置 pane 的内联 visibility/z-index，依赖 .active 类控制可见性
                if (TF.placeholder) TF.placeholder.style.setProperty("display", "none", "important");
                // pane 可见后再触发布局，避免 CodeMirror 在零尺寸下测量
                if (tabInfo.editorView) {
                  requestAnimationFrame(() => {
                    tabInfo.editorView.focus();
                  });
                }

                if (
                  TF.pendingLineNavigation &&
                  TF.pendingLineNavigation.filePath === msg.path
                ) {
                  const lineNumber = TF.pendingLineNavigation.lineNumber;
                  TF.pendingLineNavigation = null;
                  setTimeout(() => {
                    TF.scrollToLineAndHighlight(tabInfo, lineNumber);
                  }, 50);
                }
              }
            } catch (e) {
              console.error("Failed to decode file content:", e);
            }
          }
          TF.notifySwift("file_read", {
            project: msg.project,
            workspace: msg.workspace,
            path: msg.path,
            size: msg.size,
          });
          break;

        case "file_write_result":
          if (msg.project === TF.currentProject && msg.workspace === TF.currentWorkspace && msg.success) {
            const wsKey = TF.getCurrentWorkspaceKey();
            if (wsKey && TF.workspaceTabs.has(wsKey)) {
              const tabSet = TF.workspaceTabs.get(wsKey);
              const tabId = "editor-" + msg.path.replace(/[^a-zA-Z0-9]/g, "-");
              if (tabSet.tabs.has(tabId)) {
                TF.updateTabDirtyState(tabId, false);
                const tab = tabSet.tabs.get(tabId);
                if (tab.statusBar) {
                  tab.statusBar.textContent = "Saved: " + msg.path;
                  setTimeout(() => { tab.statusBar.textContent = ""; }, 3000);
                }
              }
            }
            TF.notifyNativeSaved(msg.path);
          } else if (!msg.success) {
            TF.notifyNativeSaveError(msg.path, msg.error || "Save failed");
          }
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
          if (msg.project === TF.currentProject && msg.workspace === TF.currentWorkspace) {
            TF.renderDiffContent(msg.path, msg.code, msg.text, msg.is_binary, msg.truncated);
          }
          TF.notifySwift("git_diff", {
            project: msg.project,
            workspace: msg.workspace,
            path: msg.path,
          });
          break;

        case "error":
          console.error("Server error:", msg.code, msg.message);
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
