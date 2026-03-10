use crate::server::ws::OutboundTx as WebSocket;

use crate::application::project::{list_projects_message, list_workspaces_message};
use crate::application::task::list_tasks_snapshot_message;
use crate::server::context::HandlerContext;
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub async fn handle_query_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::ListProjects => {
            let msg = list_projects_message(&ctx.app_state).await;
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::ListWorkspaces { project } => {
            match list_workspaces_message(ctx, project).await {
                Ok(msg) => send_message(socket, &msg).await?,
                Err(err_msg) => send_message(socket, &err_msg).await?,
            }
            Ok(true)
        }
        ClientMessage::ListTasks => {
            let msg = list_tasks_snapshot_message(&ctx.task_history).await;
            send_message(socket, &msg).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
