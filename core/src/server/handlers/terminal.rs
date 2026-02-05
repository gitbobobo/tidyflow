use axum::extract::ws::WebSocket;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::info;

use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::{send_message, SharedAppState, TerminalManager};

/// 处理终端相关的客户端消息
pub async fn handle_terminal_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    manager: &Arc<Mutex<TerminalManager>>,
    app_state: &SharedAppState,
    tx_output: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    tx_exit: tokio::sync::mpsc::Sender<(String, i32)>,
) -> Result<bool, String> {
    match client_msg {
        // v0/v1.1: Terminal data plane with optional term_id
        ClientMessage::Input { data, term_id } => {
            info!(
                "[DEBUG] Input received: term_id={:?}, data_len={}",
                term_id,
                data.len()
            );

            let mut mgr = manager.lock().await;
            let resolved_id = mgr.resolve_term_id(term_id.as_deref());
            info!(
                "[DEBUG] Resolved term_id: {:?}, available_terms: {:?}",
                resolved_id,
                mgr.term_ids()
            );

            if let Some(id) = resolved_id {
                if let Some(handle) = mgr.get_mut(&id) {
                    info!("[DEBUG] Writing input to PTY: term_id={}", id);
                    handle
                        .session
                        .write_input(data)
                        .map_err(|e| format!("Write error: {}", e))?;
                    info!("[DEBUG] Input written successfully");
                } else {
                    info!("[DEBUG] Handle not found for term_id={}", id);
                }
            } else if term_id.is_some() {
                // Invalid term_id provided
                info!("[DEBUG] Term not found: {:?}", term_id);
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!("Terminal '{}' not found", term_id.as_ref().unwrap()),
                    },
                )
                .await?;
            } else {
                info!("[DEBUG] No term_id provided and no default terminal");
            }
            Ok(true)
        }

        ClientMessage::Resize {
            cols,
            rows,
            term_id,
        } => {
            let mgr = manager.lock().await;
            let resolved_id = mgr.resolve_term_id(term_id.as_deref());

            if let Some(id) = resolved_id {
                if let Some(handle) = mgr.get(&id) {
                    handle
                        .session
                        .resize(*cols, *rows)
                        .map_err(|e| format!("Resize error: {}", e))?;
                }
            }
            Ok(true)
        }

        ClientMessage::SpawnTerminal { cwd } => {
            let cwd_path = PathBuf::from(&cwd);
            if !cwd_path.exists() {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "invalid_path".to_string(),
                        message: format!("Path '{}' does not exist", cwd),
                    },
                )
                .await?;
                return Ok(true);
            }

            // v1.2: Spawn new terminal WITHOUT closing existing (parallel support)
            let (session_id, shell_name) = {
                let mut mgr = manager.lock().await;
                mgr.spawn(
                    Some(cwd_path.clone()),
                    None,
                    None,
                    tx_output.clone(),
                    tx_exit.clone(),
                )
                .map_err(|e| format!("Spawn error: {}", e))?
            };

            info!(
                cwd = %cwd,
                term_id = %session_id,
                "Terminal spawned with custom cwd"
            );

            send_message(
                socket,
                &ServerMessage::TerminalSpawned {
                    session_id,
                    shell: shell_name,
                    cwd: cwd.clone(),
                },
            )
            .await?;
            Ok(true)
        }

        ClientMessage::KillTerminal => {
            let session_id = {
                let mut mgr = manager.lock().await;
                if let Some(default_id) = mgr.default_term_id.clone() {
                    mgr.close(&default_id);
                    default_id
                } else {
                    return Ok(true);
                }
            };

            info!(term_id = %session_id, "Terminal killed by client request");
            send_message(socket, &ServerMessage::TerminalKilled { session_id }).await?;
            Ok(true)
        }

        // v1.2: Multi-workspace extension
        ClientMessage::TermCreate { project, workspace } => {
            info!(project = %project, workspace = %workspace, "TermCreate request received");
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    // 处理默认工作空间：如果 workspace 是 "default"，使用项目根目录
                    let root_path = if workspace == "default" {
                        info!(project = %project, "Using project root for default workspace");
                        p.root_path.clone()
                    } else {
                        match p.get_workspace(workspace) {
                            Some(w) => w.worktree_path.clone(),
                            None => {
                                drop(state);
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "workspace_not_found".to_string(),
                                        message: format!(
                                            "Workspace '{}' not found in project '{}'",
                                            workspace, project
                                        ),
                                    },
                                )
                                .await?;
                                return Ok(true);
                            }
                        }
                    };
                    drop(state);

                    let (term_id, shell_name) = {
                        let mut mgr = manager.lock().await;
                        mgr.spawn(
                            Some(root_path.clone()),
                            Some(project.clone()),
                            Some(workspace.clone()),
                            tx_output.clone(),
                            tx_exit.clone(),
                        )
                        .map_err(|e| format!("Spawn error: {}", e))?
                    };

                    info!(
                        project = %project,
                        workspace = %workspace,
                        term_id = %term_id,
                        "New terminal created in workspace"
                    );

                    send_message(
                        socket,
                        &ServerMessage::TermCreated {
                            term_id,
                            project: project.clone(),
                            workspace: workspace.clone(),
                            cwd: root_path.to_string_lossy().to_string(),
                            shell: shell_name,
                        },
                    )
                    .await?;
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::TermList => {
            let mgr = manager.lock().await;
            let items = mgr.list();
            send_message(socket, &ServerMessage::TermList { items }).await?;
            Ok(true)
        }

        ClientMessage::TermClose { term_id } => {
            let closed = {
                let mut mgr = manager.lock().await;
                mgr.close(term_id)
            };

            if closed {
                info!(term_id = %term_id, "Terminal closed by client request");
                send_message(
                    socket,
                    &ServerMessage::TermClosed {
                        term_id: term_id.clone(),
                    },
                )
                .await?;
            } else {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!("Terminal '{}' not found", term_id),
                    },
                )
                .await?;
            }
            Ok(true)
        }

        ClientMessage::TermFocus { term_id } => {
            // Optional: server can use this for optimization
            tracing::debug!(term_id = %term_id, "Client focused terminal");
            Ok(true)
        }

        // Not a terminal message
        _ => Ok(false),
    }
}
