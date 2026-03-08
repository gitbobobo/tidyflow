use axum::extract::ws::WebSocket;
use std::path::PathBuf;
use tracing::{debug, info};

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::{send_message, subscribe_terminal, unsubscribe_terminal};

pub async fn handle_lifecycle_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
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

            let reg = ctx.terminal_registry.lock().await;
            if let Some((project, workspace, cwd, shell, name, icon)) = reg.get_info(term_id) {
                let scrollback = reg.get_scrollback(term_id).unwrap_or_default();
                drop(reg);

                subscribe_terminal(
                    term_id,
                    &ctx.terminal_registry,
                    &ctx.subscribed_terms,
                    &ctx.agg_tx,
                )
                .await;

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
            Ok(true)
        }
        _ => Ok(false),
    }
}
