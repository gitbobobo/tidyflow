use crate::server::ws::OutboundTx as WebSocket;

use crate::application::file as file_app;
use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub(crate) async fn query_file_list(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
    path: &str,
) -> Result<crate::server::protocol::ServerMessage, crate::server::protocol::ServerMessage> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_server_error())?;
    Ok(file_app::file_list_message(
        &ws_ctx.root_path,
        project,
        workspace,
        path,
    ))
}

pub(crate) async fn query_file_index(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
    query: Option<&str>,
) -> Result<crate::server::protocol::ServerMessage, crate::server::protocol::ServerMessage> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_server_error())?;
    Ok(file_app::file_index_message(&ws_ctx.root_path, project, workspace, query).await)
}

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
        } => match query_file_list(app_state, project, workspace, path).await {
            Ok(msg) => {
                send_message(socket, &msg).await?;
                Ok(true)
            }
            Err(err) => {
                send_message(socket, &err).await?;
                Ok(true)
            }
        },
        ClientMessage::FileIndex {
            project,
            workspace,
            query,
        } => match query_file_index(app_state, project, workspace, query.as_deref()).await {
            Ok(msg) => {
                send_message(socket, &msg).await?;
                Ok(true)
            }
            Err(err) => {
                send_message(socket, &err).await?;
                Ok(true)
            }
        },
        _ => Ok(false),
    }
}
