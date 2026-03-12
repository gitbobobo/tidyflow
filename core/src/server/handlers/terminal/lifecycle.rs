use crate::server::ws::OutboundTx as WebSocket;
use std::path::PathBuf;
use tracing::{debug, info};

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::terminal_registry::ATTACH_REPLAY_LIMIT_BYTES;
use crate::server::ws::{send_message, subscribe_terminal, unsubscribe_terminal};

pub async fn handle_lifecycle_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::SpawnTerminal { cwd } => {
            let cwd_path = PathBuf::from(&cwd);
            if !cwd_path.exists() {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "invalid_path".to_string(),
                        message: format!("Path '{}' does not exist", cwd),
                        project: None,
                        workspace: None,
                        session_id: None,
                        cycle_id: None,
                    },
                )
                .await?;
                return Ok(true);
            }

            let (session_id, shell_name) = {
                let mut reg = ctx.terminal_registry.lock().await;
                reg.spawn(
                    Some(cwd_path.clone()),
                    None,
                    None,
                    ctx.scrollback_tx.clone(),
                    None,
                    None,
                    None,
                    None,
                )
                .map_err(|e| format!("Spawn error: {}", e))?
            };

            subscribe_terminal(
                &session_id,
                &ctx.terminal_registry,
                &ctx.subscribed_terms,
                &ctx.agg_tx,
            )
            .await;

            if ctx.conn_meta.is_remote {
                let mut rsub = ctx.remote_sub_registry.lock().await;
                rsub.subscribe(
                    &session_id,
                    ctx.conn_meta.remote_subscriber_id(),
                    ctx.conn_meta.device_name.as_deref().unwrap_or("Unknown"),
                );
            }

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
            let term_id = {
                let reg = ctx.terminal_registry.lock().await;
                reg.resolve_term_id(None)
            };

            if let Some(id) = term_id {
                unsubscribe_terminal(&id, &ctx.subscribed_terms).await;
                {
                    let mut rsub = ctx.remote_sub_registry.lock().await;
                    rsub.unsubscribe_term(&id);
                }
                let mut reg = ctx.terminal_registry.lock().await;
                reg.close(&id);
                drop(reg);

                // 终端被强制关闭，清除恢复元数据
                let _ = ctx
                    .state_store
                    .update_terminal_recovery_state(&id, "recovered", None)
                    .await;

                info!(term_id = %id, "Terminal killed by client request");
                send_message(socket, &ServerMessage::TerminalKilled { session_id: id }).await?;
            }
            Ok(true)
        }
        ClientMessage::TermCreate {
            project,
            workspace,
            cols,
            rows,
            name,
            icon,
        } => {
            info!(
                project = %project,
                workspace = %workspace,
                "TermCreate request received"
            );

            match crate::server::context::resolve_workspace(&ctx.app_state, project, workspace)
                .await
            {
                Ok(ws_ctx) => {
                    let (term_id, shell_name) = {
                        let mut reg = ctx.terminal_registry.lock().await;
                        reg.spawn(
                            Some(ws_ctx.root_path.clone()),
                            Some(project.clone()),
                            Some(workspace.clone()),
                            ctx.scrollback_tx.clone(),
                            *cols,
                            *rows,
                            name.clone(),
                            icon.clone(),
                        )
                        .map_err(|e| format!("Spawn error: {}", e))?
                    };

                    subscribe_terminal(
                        &term_id,
                        &ctx.terminal_registry,
                        &ctx.subscribed_terms,
                        &ctx.agg_tx,
                    )
                    .await;

                    // 首个订阅者连接后，迁移到 Active
                    {
                        let mut reg = ctx.terminal_registry.lock().await;
                        reg.transition_to_active(&term_id);
                    }

                    if ctx.conn_meta.is_remote {
                        let subscriber_id = ctx.conn_meta.remote_subscriber_id();
                        info!(
                            term_id = %term_id,
                            subscriber_id = %subscriber_id,
                            device_name = ?ctx.conn_meta.device_name,
                            "Registering remote subscription for new terminal"
                        );
                        let mut rsub = ctx.remote_sub_registry.lock().await;
                        rsub.subscribe(
                            &term_id,
                            subscriber_id,
                            ctx.conn_meta.device_name.as_deref().unwrap_or("Unknown"),
                        );
                    } else {
                        debug!(
                            term_id = %term_id,
                            conn_id = %ctx.conn_meta.conn_id,
                            "Local connection created terminal, skipping remote subscription"
                        );
                    }

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
                            cwd: ws_ctx.root_path.to_string_lossy().to_string(),
                            shell: shell_name,
                            name: name.clone(),
                            icon: icon.clone(),
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                }
            }
            Ok(true)
        }
        ClientMessage::TermClose { term_id } => {
            unsubscribe_terminal(term_id, &ctx.subscribed_terms).await;
            {
                let mut rsub = ctx.remote_sub_registry.lock().await;
                rsub.unsubscribe_term(term_id);
            }
            let closed = {
                let mut reg = ctx.terminal_registry.lock().await;
                reg.close(term_id)
            };

            // 终端主动关闭后，清除恢复元数据（避免僵尸恢复记录）
            if closed {
                let _ = ctx
                    .state_store
                    .update_terminal_recovery_state(term_id, "recovered", None)
                    .await;
            }

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
                        project: None,
                        workspace: None,
                        session_id: None,
                        cycle_id: None,
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
        ClientMessage::TermAttach { term_id } => {
            info!(term_id = %term_id, "TermAttach request received");

            // 标记为 Resuming（客户端正在重新附着）
            {
                let mut reg = ctx.terminal_registry.lock().await;
                reg.transition_to_resuming(term_id);
            }

            let reg = ctx.terminal_registry.lock().await;
            if let Some((project, workspace, cwd, shell, name, icon)) = reg.get_info(term_id) {
                // 仅回放受限的最近输出，避免大体积 scrollback 整块复制
                let scrollback = reg
                    .get_scrollback_limited(term_id, ATTACH_REPLAY_LIMIT_BYTES)
                    .unwrap_or_default();
                drop(reg);

                subscribe_terminal(
                    term_id,
                    &ctx.terminal_registry,
                    &ctx.subscribed_terms,
                    &ctx.agg_tx,
                )
                .await;

                // 订阅完成后迁移到 Active
                {
                    let mut reg = ctx.terminal_registry.lock().await;
                    reg.transition_to_active(term_id);
                }

                if ctx.conn_meta.is_remote {
                    let mut rsub = ctx.remote_sub_registry.lock().await;
                    rsub.subscribe(
                        term_id,
                        ctx.conn_meta.remote_subscriber_id(),
                        ctx.conn_meta.device_name.as_deref().unwrap_or("Unknown"),
                    );
                }

                send_message(
                    socket,
                    &ServerMessage::TermAttached {
                        term_id: term_id.clone(),
                        project,
                        workspace,
                        cwd,
                        shell,
                        scrollback,
                        name,
                        icon,
                    },
                )
                .await?;
            } else {
                drop(reg);
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!("Terminal '{}' not found (may have exited)", term_id),
                        project: None,
                        workspace: None,
                        session_id: None,
                        cycle_id: None,
                    },
                )
                .await?;
            }
            Ok(true)
        }
        ClientMessage::TermDetach { term_id } => {
            info!(term_id = %term_id, "TermDetach request received");
            unsubscribe_terminal(term_id, &ctx.subscribed_terms).await;

            // 如果无订阅者剩余，迁移到 Idle
            {
                let mut reg = ctx.terminal_registry.lock().await;
                if let Some(0) = reg.subscriber_count(term_id) {
                    reg.transition_to_idle(term_id);
                }
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}
