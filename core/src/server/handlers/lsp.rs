use axum::extract::ws::WebSocket;

use crate::server::context::{resolve_workspace, HandlerContext};
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

/// 处理 LSP 诊断相关消息
pub async fn handle_lsp_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::LspStartWorkspace { project, workspace } => {
            match resolve_workspace(&ctx.app_state, project, workspace).await {
                Ok(ws_ctx) => {
                    if let Err(e) = ctx
                        .lsp_supervisor
                        .start_workspace(project, workspace, ws_ctx.root_path)
                        .await
                    {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "lsp_start_failed".to_string(),
                                message: e,
                            },
                        )
                        .await?;
                    }
                }
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                }
            }
            Ok(true)
        }
        ClientMessage::LspStopWorkspace { project, workspace } => {
            if let Err(e) = ctx.lsp_supervisor.stop_workspace(project, workspace).await {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "lsp_stop_failed".to_string(),
                        message: e,
                    },
                )
                .await?;
            }
            Ok(true)
        }
        ClientMessage::LspGetDiagnostics { project, workspace } => {
            let messages = ctx
                .lsp_supervisor
                .get_snapshot_messages(project, workspace)
                .await;
            for msg in messages {
                send_message(socket, &msg).await?;
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}
