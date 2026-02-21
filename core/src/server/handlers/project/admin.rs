use axum::extract::ws::WebSocket;
use tracing::{info, warn};

use crate::application::project_admin::{
    create_workspace_message, import_project_message, project_commands_saved_ok,
    remove_project_message, remove_workspace_message, save_project_commands_message,
};
use crate::application::project_workspace::cleanup_workspace_before_remove;
use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub async fn handle_admin_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::ImportProject { name, path } => {
            info!("ImportProject request: name={}, path={}", name, path);
            let msg = import_project_message(&ctx.app_state, name, path).await;
            if let ServerMessage::ProjectImported { .. } = &msg {
                info!("Project imported successfully: {}", name);
            }
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::CreateWorkspace {
            project,
            from_branch,
        } => {
            let msg =
                create_workspace_message(&ctx.app_state, project, from_branch.as_deref()).await;
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::RemoveProject { name } => {
            info!("RemoveProject request: name={}", name);
            let msg = remove_project_message(&ctx.app_state, name).await;
            if let ServerMessage::ProjectRemoved {
                ok: false, message, ..
            } = &msg
            {
                warn!(
                    "Failed to remove project: {}, error: {}",
                    name,
                    message.as_deref().unwrap_or("unknown")
                );
            } else {
                info!("Project removed successfully: {}", name);
            }
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::RemoveWorkspace { project, workspace } => {
            info!(
                "RemoveWorkspace request: project={}, workspace={}",
                project, workspace
            );

            let closed_terminals = cleanup_workspace_before_remove(ctx, project, workspace).await;
            for tid in &closed_terminals {
                info!(
                    "Closed terminal {} for workspace {}/{}",
                    tid, project, workspace
                );
            }

            let msg = remove_workspace_message(&ctx.app_state, project, workspace).await;
            if let ServerMessage::WorkspaceRemoved {
                ok: false, message, ..
            } = &msg
            {
                warn!(
                    "Failed to remove workspace: {} / {}, error: {}",
                    project,
                    workspace,
                    message.as_deref().unwrap_or("unknown")
                );
            } else {
                info!(
                    "Workspace removed successfully: {} / {}",
                    project, workspace
                );
            }
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::SaveProjectCommands { project, commands } => {
            info!("SaveProjectCommands request: project={}", project);
            let msg = save_project_commands_message(&ctx.app_state, project, commands).await;
            if project_commands_saved_ok(&msg) {
                let _ = ctx.save_tx.send(()).await;
            }
            send_message(socket, &msg).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
