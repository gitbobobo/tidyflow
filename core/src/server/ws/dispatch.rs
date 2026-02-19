use axum::extract::ws::WebSocket;

use tokio::sync::Mutex;
use tracing::{error, info, trace, warn};

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, RequestEnvelope, ServerMessage};
use crate::server::watcher::WorkspaceWatcher;
use crate::server::ws::send_message;

pub(super) fn probe_client_message_type(data: &[u8]) -> String {
    rmp_serde::from_slice::<ClientMessageTypeProbe>(data)
        .ok()
        .and_then(|probe| probe.message_type)
        .unwrap_or_else(|| "unknown".to_string())
}

#[derive(serde::Deserialize)]
struct ClientMessageTypeProbe {
    #[serde(rename = "type")]
    message_type: Option<String>,
}

/// Handle a client message — 统一调度层
///
/// 支持两种消息格式：
/// 1. 带 `id` 的 RequestEnvelope（客户端希望关联响应时附带 request_id）
/// 2. 裸 ClientMessage（向后兼容）
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

    // 尝试先按 RequestEnvelope 解析（带可选 id 字段）
    // RequestEnvelope 使用 #[serde(flatten)] 所以裸 ClientMessage 也能匹配（id 为 None）
    let envelope: RequestEnvelope = rmp_serde::from_slice(data).map_err(|e| {
        error!("Failed to parse client message: {}", e);
        format!("Parse error: {}", e)
    })?;

    let _request_id = envelope.id; // 预留：未来可在响应中回显
    let client_msg = envelope.body;
    trace!(
        "Parsed client message: {:?}",
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

    // 按领域分发，handler 返回 Option<ServerMessage>，由此处统一发送
    // 终端消息需要特殊处理（可能返回多条消息），沿用旧模式
    if crate::server::handlers::terminal::handle_terminal_message(&client_msg, socket, ctx).await? {
        return Ok(());
    }

    // 文件消息
    if crate::server::handlers::file::handle_file_message(&client_msg, socket, &ctx.app_state)
        .await?
    {
        return Ok(());
    }

    // Git 消息
    if crate::server::handlers::git::handle_git_message(&client_msg, socket, &ctx.app_state, ctx)
        .await?
    {
        return Ok(());
    }

    // 项目/工作空间消息
    if crate::server::handlers::project::handle_project_message(&client_msg, socket, ctx).await? {
        return Ok(());
    }

    // LSP 诊断消息
    if crate::server::handlers::lsp::handle_lsp_message(&client_msg, socket, ctx).await? {
        return Ok(());
    }

    // 设置消息
    if crate::server::handlers::settings::handle_settings_message(
        &client_msg,
        socket,
        &ctx.app_state,
        &ctx.save_tx,
    )
    .await?
    {
        return Ok(());
    }

    // 日志消息
    if crate::server::handlers::log::handle_log_message(&client_msg)? {
        return Ok(());
    }

    // AI 消息
    if crate::server::handlers::ai::handle_ai_message(
        &client_msg,
        socket,
        &ctx.app_state,
        &ctx.ai_state,
        &ctx.cmd_output_tx,
        &ctx.task_broadcast_tx,
        &ctx.conn_meta.conn_id,
    )
    .await?
    {
        return Ok(());
    }

    // 内置消息处理
    match client_msg {
        ClientMessage::Ping => {
            send_message(socket, &ServerMessage::Pong).await?;
        }

        // v1.22: File watcher
        ClientMessage::WatchSubscribe { project, workspace } => {
            trace!(
                "WatchSubscribe: project={}, workspace={}",
                project,
                workspace
            );

            match crate::server::context::resolve_workspace(&ctx.app_state, &project, &workspace)
                .await
            {
                Ok(ws_ctx) => {
                    let mut w = watcher.lock().await;
                    match w.subscribe(project.clone(), workspace.clone(), ws_ctx.root_path) {
                        Ok(_) => {
                            send_message(
                                socket,
                                &ServerMessage::WatchSubscribed { project, workspace },
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
        }

        ClientMessage::WatchUnsubscribe => {
            info!("WatchUnsubscribe");
            let mut w = watcher.lock().await;
            w.unsubscribe();
            send_message(socket, &ServerMessage::WatchUnsubscribed).await?;
        }

        // 所有其他消息类型已在上方 handler 链中处理，此处兜底
        _ => {
            warn!(
                "Unhandled message type: {:?}",
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
    }

    Ok(())
}
