use axum::extract::ws::WebSocket;

use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::git;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub async fn try_handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.6: Git stage
        ClientMessage::GitStage {
            project,
            workspace,
            path,
            scope,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let path_clone = path.clone();
            let scope_clone = scope.clone();
            let result = tokio::task::spawn_blocking(move || {
                git::git_stage(&root, path_clone.as_deref(), &scope_clone)
            })
            .await;

            match result {
                Ok(Ok(op_result)) => {
                    send_message(
                        socket,
                        &ServerMessage::GitOpResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            op: op_result.op,
                            ok: op_result.ok,
                            message: op_result.message,
                            path: op_result.path,
                            scope: op_result.scope,
                        },
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &ServerMessage::GitOpResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            op: "stage".to_string(),
                            ok: false,
                            message: Some(format!("{}", e)),
                            path: path.clone(),
                            scope: scope.clone(),
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Git stage task failed: {}", e),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.6: Git unstage
        ClientMessage::GitUnstage {
            project,
            workspace,
            path,
            scope,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let path_clone = path.clone();
            let scope_clone = scope.clone();
            let result = tokio::task::spawn_blocking(move || {
                git::git_unstage(&root, path_clone.as_deref(), &scope_clone)
            })
            .await;

            match result {
                Ok(Ok(op_result)) => {
                    send_message(
                        socket,
                        &ServerMessage::GitOpResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            op: op_result.op,
                            ok: op_result.ok,
                            message: op_result.message,
                            path: op_result.path,
                            scope: op_result.scope,
                        },
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &ServerMessage::GitOpResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            op: "unstage".to_string(),
                            ok: false,
                            message: Some(format!("{}", e)),
                            path: path.clone(),
                            scope: scope.clone(),
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Git unstage task failed: {}", e),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.7: Git discard
        ClientMessage::GitDiscard {
            project,
            workspace,
            path,
            scope,
            include_untracked,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let path_clone = path.clone();
            let scope_clone = scope.clone();
            let include_untracked_clone = *include_untracked;
            let result = tokio::task::spawn_blocking(move || {
                git::git_discard(&root, path_clone.as_deref(), &scope_clone, include_untracked_clone)
            })
            .await;

            match result {
                Ok(Ok(op_result)) => {
                    send_message(
                        socket,
                        &ServerMessage::GitOpResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            op: op_result.op,
                            ok: op_result.ok,
                            message: op_result.message,
                            path: op_result.path,
                            scope: op_result.scope,
                        },
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &ServerMessage::GitOpResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            op: "discard".to_string(),
                            ok: false,
                            message: Some(format!("{}", e)),
                            path: path.clone(),
                            scope: scope.clone(),
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Git discard task failed: {}", e),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        _ => Ok(false),
    }
}
