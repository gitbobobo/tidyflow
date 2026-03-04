use axum::extract::ws::WebSocket;
use tracing::{info, warn};

use crate::application::project::{list_projects_message, list_workspaces_message};
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
            let success = matches!(msg, ServerMessage::ProjectImported { .. });
            if success {
                info!("Project imported successfully: {}", name);
            }
            send_message(socket, &msg).await?;
            if success {
                let _ = ctx.save_tx.send(()).await;
                broadcast_projects_snapshot(ctx).await;
                broadcast_workspaces_snapshot(ctx, name).await;
            }
            Ok(true)
        }
        ClientMessage::CreateWorkspace {
            project,
            from_branch,
        } => {
            let msg =
                create_workspace_message(&ctx.app_state, project, from_branch.as_deref()).await;
            let success = matches!(msg, ServerMessage::WorkspaceCreated { .. });
            send_message(socket, &msg).await?;
            if success {
                let _ = ctx.save_tx.send(()).await;
                broadcast_projects_snapshot(ctx).await;
                broadcast_workspaces_snapshot(ctx, project).await;
            }
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
            if matches!(msg, ServerMessage::ProjectRemoved { ok: true, .. }) {
                let _ = ctx.save_tx.send(()).await;
                broadcast_projects_snapshot(ctx).await;
            }
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
            if matches!(msg, ServerMessage::WorkspaceRemoved { ok: true, .. }) {
                let _ = ctx.save_tx.send(()).await;
                broadcast_projects_snapshot(ctx).await;
                broadcast_workspaces_snapshot(ctx, project).await;
            }
            Ok(true)
        }
        ClientMessage::SaveProjectCommands { project, commands } => {
            info!("SaveProjectCommands request: project={}", project);
            let msg = save_project_commands_message(&ctx.app_state, project, commands).await;
            let success = project_commands_saved_ok(&msg);
            if success {
                let _ = ctx.save_tx.send(()).await;
            }
            send_message(socket, &msg).await?;
            if success {
                broadcast_projects_snapshot(ctx).await;
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}

async fn broadcast_projects_snapshot(ctx: &HandlerContext) {
    let snapshot = list_projects_message(&ctx.app_state).await;
    let _ = crate::server::context::send_task_broadcast_message(
        &ctx.task_broadcast_tx,
        &ctx.conn_meta.conn_id,
        snapshot,
    );
}

async fn broadcast_workspaces_snapshot(ctx: &HandlerContext, project: &str) {
    let snapshot = match list_workspaces_message(ctx, project).await {
        Ok(snapshot) => snapshot,
        Err(error) => {
            warn!(
                "Broadcast workspaces snapshot failed: project={}, error={:?}",
                project, error
            );
            return;
        }
    };
    let _ = crate::server::context::send_task_broadcast_message(
        &ctx.task_broadcast_tx,
        &ctx.conn_meta.conn_id,
        snapshot,
    );
}
