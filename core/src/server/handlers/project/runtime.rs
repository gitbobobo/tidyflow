use axum::extract::ws::WebSocket;
use tracing::info;

use crate::application::project_command::{cancel_project_command, run_project_command};
use crate::application::project_workspace::select_workspace_and_spawn_terminal;
use crate::server::context::{HandlerContext, TaskBroadcastEvent};
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub async fn handle_runtime_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::SelectWorkspace { project, workspace } => {
            match select_workspace_and_spawn_terminal(ctx, project, workspace).await {
                Ok(result) => {
                    info!(
                        project = %project,
                        workspace = %workspace,
                        root = %result.root_path.display(),
                        "Terminal spawned in workspace"
                    );
                    send_message(socket, &result.message).await?;
                }
                Err(msg) => send_message(socket, &msg).await?,
            }
            Ok(true)
        }
        ClientMessage::RunProjectCommand {
            project,
            workspace,
            command_id,
        } => {
            info!(
                "RunProjectCommand request: project={}, workspace={}, command_id={}",
                project, workspace, command_id
            );
            let reply = run_project_command(ctx, project, workspace, command_id).await;
            send_message(socket, &reply.response).await?;
            if let Some(message) = reply.broadcast {
                let _ = ctx.task_broadcast_tx.send(TaskBroadcastEvent {
                    origin_conn_id: ctx.conn_meta.conn_id.clone(),
                    message,
                });
            }
            Ok(true)
        }
        ClientMessage::CancelProjectCommand {
            project,
            workspace,
            command_id,
            task_id,
        } => {
            info!(
                "CancelProjectCommand request: project={}, workspace={}, command_id={}, task_id={}",
                project,
                workspace,
                command_id,
                task_id.as_deref().unwrap_or("<none>")
            );

            let reply =
                cancel_project_command(ctx, project, workspace, command_id, task_id.as_deref())
                    .await;
            send_message(socket, &reply.response).await?;
            if let Some(message) = reply.broadcast {
                let _ = ctx.task_broadcast_tx.send(TaskBroadcastEvent {
                    origin_conn_id: ctx.conn_meta.conn_id.clone(),
                    message,
                });
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}
