use crate::server::ws::OutboundTx as WebSocket;

use crate::application::file as file_app;
use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub(crate) async fn query_file_read(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
    path: &str,
) -> Result<crate::server::protocol::ServerMessage, crate::server::protocol::ServerMessage> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_server_error())?;
    Ok(file_app::file_read_message(
        &ws_ctx.root_path,
        project,
        workspace,
        path,
    ))
}

pub async fn handle_read_write_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::FileRead {
            project,
            workspace,
            path,
        } => match query_file_read(app_state, project, workspace, path).await {
            Ok(msg) => {
                send_message(socket, &msg).await?;
                Ok(true)
            }
            Err(err) => {
                send_message(socket, &err).await?;
                Ok(true)
            }
        },
        ClientMessage::FileWrite {
            project,
            workspace,
            path,
            content,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let msg =
                file_app::file_write_message(&ws_ctx.root_path, project, workspace, path, content);
            send_message(socket, &msg).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
