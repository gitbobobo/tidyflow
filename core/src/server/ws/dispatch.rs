use axum::extract::ws::WebSocket;
use serde_json::{Map, Value};

use tokio::sync::Mutex;
use tracing::{error, info, trace, warn};

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientEnvelopeV3, ClientMessage, ServerMessage};
use crate::server::watcher::WorkspaceWatcher;
use crate::server::ws::send_message;

pub(super) fn probe_client_message_type(data: &[u8]) -> String {
    rmp_serde::from_slice::<ClientEnvelopeV3>(data)
        .map(|env| env.action)
        .unwrap_or_else(|_| "unknown".to_string())
}

#[derive(Copy, Clone)]
enum DomainRoute {
    System,
    Terminal,
    File,
    Git,
    Project,
    Lsp,
    Settings,
    Log,
    Ai,
    Evolution,
}

fn parse_domain_route(domain: &str) -> Option<DomainRoute> {
    match domain {
        "system" => Some(DomainRoute::System),
        "terminal" => Some(DomainRoute::Terminal),
        "file" => Some(DomainRoute::File),
        "git" => Some(DomainRoute::Git),
        "project" => Some(DomainRoute::Project),
        "lsp" => Some(DomainRoute::Lsp),
        "settings" => Some(DomainRoute::Settings),
        "log" => Some(DomainRoute::Log),
        "ai" => Some(DomainRoute::Ai),
        "evolution" => Some(DomainRoute::Evolution),
        _ => None,
    }
}

fn action_matches_domain(domain: &str, action: &str) -> bool {
    crate::server::protocol::action_table::matches_action_domain(domain, action)
}

async fn dispatch_domain_handler(
    route: DomainRoute,
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
    watcher: &std::sync::Arc<Mutex<WorkspaceWatcher>>,
) -> Result<bool, String> {
    let handled = match route {
        DomainRoute::System => match client_msg {
            ClientMessage::Ping => {
                send_message(socket, &ServerMessage::Pong).await?;
                true
            }
            _ => false,
        },
        DomainRoute::Terminal => {
            crate::server::handlers::terminal::handle_terminal_message(client_msg, socket, ctx)
                .await?
        }
        DomainRoute::File => match client_msg {
            ClientMessage::WatchSubscribe { project, workspace } => {
                trace!(
                    "WatchSubscribe: project={}, workspace={}",
                    project,
                    workspace
                );
                match crate::server::context::resolve_workspace(&ctx.app_state, project, workspace)
                    .await
                {
                    Ok(ws_ctx) => {
                        let mut w = watcher.lock().await;
                        match w.subscribe(project.clone(), workspace.clone(), ws_ctx.root_path) {
                            Ok(_) => {
                                send_message(
                                    socket,
                                    &ServerMessage::WatchSubscribed {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "watch_subscribe_failed".to_string(),
                                        message: e,
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    Err(e) => {
                        send_message(socket, &e.to_server_error()).await?;
                    }
                }
                true
            }
            ClientMessage::WatchUnsubscribe => {
                info!("WatchUnsubscribe");
                let mut w = watcher.lock().await;
                w.unsubscribe();
                send_message(socket, &ServerMessage::WatchUnsubscribed).await?;
                true
            }
            _ => {
                crate::server::handlers::file::handle_file_message(
                    client_msg,
                    socket,
                    &ctx.app_state,
                )
                .await?
            }
        },
        DomainRoute::Git => {
            crate::server::handlers::git::handle_git_message(
                client_msg,
                socket,
                &ctx.app_state,
                ctx,
            )
            .await?
        }
        DomainRoute::Project => {
            crate::server::handlers::project::handle_project_message(client_msg, socket, ctx)
                .await?
        }
        DomainRoute::Lsp => {
            crate::server::handlers::lsp::handle_lsp_message(client_msg, socket, ctx).await?
        }
        DomainRoute::Settings => {
            crate::server::handlers::settings::handle_settings_message(
                client_msg,
                socket,
                &ctx.app_state,
                &ctx.save_tx,
            )
            .await?
        }
        DomainRoute::Log => crate::server::handlers::log::handle_log_message(client_msg)?,
        DomainRoute::Ai => {
            crate::server::handlers::ai::handle_ai_message(
                client_msg,
                socket,
                &ctx.app_state,
                &ctx.ai_state,
                &ctx.cmd_output_tx,
                &ctx.task_broadcast_tx,
                &ctx.conn_meta.conn_id,
            )
            .await?
        }
        DomainRoute::Evolution => {
            crate::server::handlers::evolution::handle_evolution_message(client_msg, socket, ctx)
                .await?
        }
    };
    Ok(handled)
}

fn envelope_payload_to_client_message(
    envelope: &ClientEnvelopeV3,
) -> Result<ClientMessage, String> {
    let mut payload = match &envelope.payload {
        Value::Object(map) => map.clone(),
        Value::Null => Map::new(),
        _ => {
            return Err("Invalid payload: expected object".to_string());
        }
    };
    payload.insert("type".to_string(), Value::String(envelope.action.clone()));
    serde_json::from_value(Value::Object(payload)).map_err(|e| format!("Parse error: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn envelope_payload_to_client_message_parses_ping() {
        let env = ClientEnvelopeV3 {
            request_id: "req-1".to_string(),
            domain: "system".to_string(),
            action: "ping".to_string(),
            payload: json!({}),
        };
        let msg = envelope_payload_to_client_message(&env).expect("should parse");
        assert!(matches!(msg, ClientMessage::Ping));
    }

    #[test]
    fn envelope_payload_to_client_message_rejects_non_object_payload() {
        let env = ClientEnvelopeV3 {
            request_id: "req-2".to_string(),
            domain: "system".to_string(),
            action: "ping".to_string(),
            payload: json!(["invalid"]),
        };
        let err = envelope_payload_to_client_message(&env).expect_err("should fail");
        assert!(err.contains("expected object"));
    }
}

/// Handle a client message — 统一调度层
///
/// v3：客户端消息统一使用 `ClientEnvelopeV3`
pub(super) async fn handle_client_message(
    data: &[u8],
    socket: &mut WebSocket,
    ctx: &HandlerContext,
    watcher: &std::sync::Arc<Mutex<WorkspaceWatcher>>,
) -> Result<(), String> {
    trace!(
        "handle_client_message called with data length: {}",
        data.len()
    );
    let envelope: ClientEnvelopeV3 = rmp_serde::from_slice(data).map_err(|e| {
        error!("Failed to parse client message: {}", e);
        format!("Parse error: {}", e)
    })?;

    crate::server::ws::with_request_id(Some(envelope.request_id.clone()), async {
        let route = parse_domain_route(&envelope.domain)
            .ok_or_else(|| format!("Unknown domain: {}", envelope.domain))?;
        if !action_matches_domain(&envelope.domain, &envelope.action) {
            return Err(format!(
                "Action/domain mismatch: action={} domain={}",
                envelope.action, envelope.domain
            ));
        }
        let client_msg = envelope_payload_to_client_message(&envelope)?;
        trace!(
            "Parsed client message: domain={}, action={}, discriminant={:?}",
            envelope.domain,
            envelope.action,
            std::mem::discriminant(&client_msg)
        );
        match &client_msg {
        ClientMessage::AIChatAbort {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
        } => {
            info!(
                "Inbound AIChatAbort: conn_id={}, remote={}, project={}, workspace={}, ai_tool={}, session_id={}",
                ctx.conn_meta.conn_id,
                ctx.conn_meta.is_remote,
                project_name,
                workspace_name,
                ai_tool,
                session_id
            );
        }
        ClientMessage::AIQuestionReply {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
            answers,
        } => {
            info!(
                "Inbound AIQuestionReply: conn_id={}, remote={}, project={}, workspace={}, ai_tool={}, session_id={}, request_id={}, answers_count={}",
                ctx.conn_meta.conn_id,
                ctx.conn_meta.is_remote,
                project_name,
                workspace_name,
                ai_tool,
                session_id,
                request_id,
                answers.len()
            );
        }
        ClientMessage::AIQuestionReject {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
        } => {
            info!(
                "Inbound AIQuestionReject: conn_id={}, remote={}, project={}, workspace={}, ai_tool={}, session_id={}, request_id={}",
                ctx.conn_meta.conn_id,
                ctx.conn_meta.is_remote,
                project_name,
                workspace_name,
                ai_tool,
                session_id,
                request_id
            );
        }
        _ => {}
        }
        if !dispatch_domain_handler(route, &client_msg, socket, ctx, watcher).await? {
            warn!(
                "Unhandled message type: domain={}, action={}, discriminant={:?}",
                envelope.domain,
                envelope.action,
                std::mem::discriminant(&client_msg)
            );
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "unhandled_message".to_string(),
                    message: "Message type not recognized".to_string(),
                },
            )
            .await?;
        }
        Ok(())
    })
    .await
}
