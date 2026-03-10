use crate::server::ws::OutboundTx as WebSocket;

use crate::application::file as file_app;
use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub async fn handle_mutate_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::FileRename {
            project,
            workspace,
            old_path,
            new_name,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::FileRenameResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            old_path: old_path.clone(),
                            new_path: String::new(),
                            success: false,
                            message: Some(e.to_string()),
                        },
                    )
                    .await?;
                    return Ok(true);
                }
            };

            let msg = file_app::file_rename_message(
                &ws_ctx.root_path,
                project,
                workspace,
                old_path,
                new_name,
            );
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::FileDelete {
            project,
            workspace,
            path,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::FileDeleteResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            path: path.clone(),
                            success: false,
                            message: Some(e.to_string()),
                        },
                    )
                    .await?;
                    return Ok(true);
                }
            };

            let msg = file_app::file_delete_message(&ws_ctx.root_path, project, workspace, path);
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::FileCopy {
            dest_project,
            dest_workspace,
            source_absolute_path,
            dest_dir,
        } => {
            let ws_ctx = match resolve_workspace(app_state, dest_project, dest_workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::FileCopyResult {
                            project: dest_project.clone(),
                            workspace: dest_workspace.clone(),
                            source_absolute_path: source_absolute_path.clone(),
                            dest_path: String::new(),
                            success: false,
                            message: Some(e.to_string()),
                        },
                    )
                    .await?;
                    return Ok(true);
                }
            };

            let msg = file_app::file_copy_message(
                &ws_ctx.root_path,
                dest_project,
                dest_workspace,
                source_absolute_path,
                dest_dir,
            );
            send_message(socket, &msg).await?;
            Ok(true)
        }
        ClientMessage::FileMove {
            project,
            workspace,
            old_path,
            new_dir,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::FileMoveResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            old_path: old_path.clone(),
                            new_path: String::new(),
                            success: false,
                            message: Some(e.to_string()),
                        },
                    )
                    .await?;
                    return Ok(true);
                }
            };

            let msg = file_app::file_move_message(
                &ws_ctx.root_path,
                project,
                workspace,
                old_path,
                new_dir,
            );
            send_message(socket, &msg).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
