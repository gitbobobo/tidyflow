use crate::server::ws::OutboundTx as WebSocket;

use crate::application::file as file_app;
use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub async fn handle_query_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::FileList {
            project,
            workspace,
            path,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let msg = file_app::file_list_message(&ws_ctx.root_path, project, workspace, path);
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::FileIndex {
            project,
            workspace,
            query,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let msg = file_app::file_index_message(
                &ws_ctx.root_path,
                project,
                workspace,
                query.as_deref(),
            )
            .await;
            send_message(socket, &msg).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
