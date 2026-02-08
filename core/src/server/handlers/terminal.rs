use axum::extract::ws::WebSocket;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::info;

use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::terminal_registry::SharedTerminalRegistry;
use crate::server::ws::{
    ack_terminal_output, send_message, subscribe_terminal, unsubscribe_terminal,
    SharedAppState, TermSubscription,
};

/// 处理终端相关的客户端消息
pub async fn handle_terminal_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    registry: &SharedTerminalRegistry,
    app_state: &SharedAppState,
    scrollback_tx: &tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    subscribed_terms: &Arc<Mutex<HashMap<String, TermSubscription>>>,
    agg_tx: &tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
) -> Result<bool, String> {
    match client_msg {
        // v0/v1.1: Terminal data plane with optional term_id
        ClientMessage::Input { data, term_id } => {
            info!(
                "[DEBUG] Input received: term_id={:?}, data_len={}",
                term_id,
                data.len()
            );

            let mut reg = registry.lock().await;
            let resolved_id = reg.resolve_term_id(term_id.as_deref());
            info!(
                "[DEBUG] Resolved term_id: {:?}, available_terms: {:?}",
                resolved_id,
                reg.term_ids()
            );

            if let Some(id) = resolved_id {
                info!("[DEBUG] Writing input to PTY: term_id={}", id);
                reg.write_input(&id, data)
                    .map_err(|e| format!("Write error: {}", e))?;
                info!("[DEBUG] Input written successfully");
            } else if term_id.is_some() {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!(
                            "Terminal '{}' not found",
                            term_id.as_ref().unwrap()
                        ),
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
            let reg = registry.lock().await;
            let resolved_id = reg.resolve_term_id(term_id.as_deref());

            if let Some(id) = resolved_id {
                reg.resize(&id, *cols, *rows)
                    .map_err(|e| format!("Resize error: {}", e))?;
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

            let (session_id, shell_name) = {
                let mut reg = registry.lock().await;
                reg.spawn(
                    Some(cwd_path.clone()),
                    None,
                    None,
                    scrollback_tx.clone(),
                )
                .map_err(|e| format!("Spawn error: {}", e))?
            };

            // 自动订阅新创建的终端
            subscribe_terminal(
                &session_id,
                registry,
                subscribed_terms,
                agg_tx,
            )
            .await;

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
            // 关闭默认终端
            let term_id = {
                let reg = registry.lock().await;
                reg.resolve_term_id(None)
            };

            if let Some(id) = term_id {
                unsubscribe_terminal(&id, subscribed_terms).await;
                let mut reg = registry.lock().await;
                reg.close(&id);
                drop(reg);

                info!(term_id = %id, "Terminal killed by client request");
                send_message(
                    socket,
                    &ServerMessage::TerminalKilled { session_id: id },
                )
                .await?;
            }
            Ok(true)
        }

        // v1.2: Multi-workspace extension
        ClientMessage::TermCreate { project, workspace } => {
            info!(
                project = %project,
                workspace = %workspace,
                "TermCreate request received"
            );
            let state = app_state.read().await;
            match state.get_project(project) {
                Some(p) => {
                    let root_path = if workspace == "default" {
                        info!(
                            project = %project,
                            "Using project root for default workspace"
                        );
                        p.root_path.clone()
                    } else {
                        match p.get_workspace(workspace) {
                            Some(w) => w.worktree_path.clone(),
                            None => {
                                drop(state);
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "workspace_not_found"
                                            .to_string(),
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
                        let mut reg = registry.lock().await;
                        reg.spawn(
                            Some(root_path.clone()),
                            Some(project.clone()),
                            Some(workspace.clone()),
                            scrollback_tx.clone(),
                        )
                        .map_err(|e| format!("Spawn error: {}", e))?
                    };

                    // 自动订阅新创建的终端
                    subscribe_terminal(
                        &term_id,
                        registry,
                        subscribed_terms,
                        agg_tx,
                    )
                    .await;

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
                            message: format!(
                                "Project '{}' not found",
                                project
                            ),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::TermList => {
            let reg = registry.lock().await;
            let items = reg.list();
            send_message(socket, &ServerMessage::TermList { items }).await?;
            Ok(true)
        }

        ClientMessage::TermClose { term_id } => {
            unsubscribe_terminal(term_id, subscribed_terms).await;
            let closed = {
                let mut reg = registry.lock().await;
                reg.close(term_id)
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
                        message: format!(
                            "Terminal '{}' not found",
                            term_id
                        ),
                    },
                )
                .await?;
            }
            Ok(true)
        }

        ClientMessage::TermFocus { term_id } => {
            tracing::debug!(
                term_id = %term_id,
                "Client focused terminal"
            );
            Ok(true)
        }

        // v1.27: Terminal persistence — 重连附着
        ClientMessage::TermAttach { term_id } => {
            info!(term_id = %term_id, "TermAttach request received");

            let reg = registry.lock().await;
            if let Some((project, workspace, cwd, shell)) =
                reg.get_info(term_id)
            {
                let scrollback =
                    reg.get_scrollback(term_id).unwrap_or_default();
                drop(reg);

                // 订阅终端输出
                subscribe_terminal(
                    term_id,
                    registry,
                    subscribed_terms,
                    agg_tx,
                )
                .await;

                send_message(
                    socket,
                    &ServerMessage::TermAttached {
                        term_id: term_id.clone(),
                        project,
                        workspace,
                        cwd,
                        shell,
                        scrollback,
                    },
                )
                .await?;
            } else {
                drop(reg);
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!(
                            "Terminal '{}' not found (may have exited)",
                            term_id
                        ),
                    },
                )
                .await?;
            }
            Ok(true)
        }

        // v1.28: Terminal output flow control ACK
        ClientMessage::TermOutputAck { term_id, bytes } => {
            ack_terminal_output(term_id, *bytes, subscribed_terms).await;
            Ok(true)
        }

        // Not a terminal message
        _ => Ok(false),
    }
}
