//! Git stash WS 写操作处理器

use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::git;
use crate::server::protocol::{ClientMessage, ConflictFileEntryInfo, ServerMessage};
use crate::server::ws::send_message;
use crate::server::ws::OutboundTx as WebSocket;

/// 将 stash 领域操作结果映射为 ServerMessage
fn map_stash_op_result(
    project: &str,
    workspace: &str,
    result: git::StashOpResult,
) -> ServerMessage {
    ServerMessage::GitStashOpResult {
        project: project.to_string(),
        workspace: workspace.to_string(),
        op: result.op,
        stash_id: result.stash_id,
        ok: result.ok,
        state: result.state.as_str().to_string(),
        message: result.message,
        affected_paths: result.affected_paths,
        conflict_files: result
            .conflict_files
            .iter()
            .map(|f| ConflictFileEntryInfo {
                path: f.path.clone(),
                conflict_type: f.conflict_type.clone(),
                staged: f.staged,
            })
            .collect(),
    }
}

/// 构造 stash 操作失败的 ServerMessage
fn stash_op_error(project: &str, workspace: &str, op: &str, err: String) -> ServerMessage {
    ServerMessage::GitStashOpResult {
        project: project.to_string(),
        workspace: workspace.to_string(),
        op: op.to_string(),
        stash_id: String::new(),
        ok: false,
        state: "failed".to_string(),
        message: Some(err),
        affected_paths: vec![],
        conflict_files: vec![],
    }
}

pub async fn handle_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::GitStashSave {
            project,
            workspace,
            message,
            include_untracked,
            keep_index,
            paths,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let msg_clone = message.clone();
            let include_untracked = *include_untracked;
            let keep_index = *keep_index;
            let paths_clone = paths.clone();

            let result = tokio::task::spawn_blocking(move || {
                git::git_stash_save(
                    &root,
                    msg_clone.as_deref(),
                    include_untracked,
                    keep_index,
                    &paths_clone,
                )
            })
            .await;

            match result {
                Ok(Ok(op_result)) => {
                    send_message(
                        socket,
                        &map_stash_op_result(project, workspace, op_result),
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &stash_op_error(project, workspace, "save", format!("{}", e)),
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Git stash save task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::GitStashApply {
            project,
            workspace,
            stash_id,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let stash_id_clone = stash_id.clone();

            let result = tokio::task::spawn_blocking(move || {
                git::git_stash_apply(&root, &stash_id_clone)
            })
            .await;

            match result {
                Ok(Ok(op_result)) => {
                    send_message(
                        socket,
                        &map_stash_op_result(project, workspace, op_result),
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &stash_op_error(project, workspace, "apply", format!("{}", e)),
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Git stash apply task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::GitStashPop {
            project,
            workspace,
            stash_id,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let stash_id_clone = stash_id.clone();

            let result = tokio::task::spawn_blocking(move || {
                git::git_stash_pop(&root, &stash_id_clone)
            })
            .await;

            match result {
                Ok(Ok(op_result)) => {
                    send_message(
                        socket,
                        &map_stash_op_result(project, workspace, op_result),
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &stash_op_error(project, workspace, "pop", format!("{}", e)),
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Git stash pop task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::GitStashDrop {
            project,
            workspace,
            stash_id,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let stash_id_clone = stash_id.clone();

            let result = tokio::task::spawn_blocking(move || {
                git::git_stash_drop(&root, &stash_id_clone)
            })
            .await;

            match result {
                Ok(Ok(op_result)) => {
                    send_message(
                        socket,
                        &map_stash_op_result(project, workspace, op_result),
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &stash_op_error(project, workspace, "drop", format!("{}", e)),
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Git stash drop task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::GitStashRestorePaths {
            project,
            workspace,
            stash_id,
            paths,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let stash_id_clone = stash_id.clone();
            let paths_clone = paths.clone();

            let result = tokio::task::spawn_blocking(move || {
                git::git_stash_restore_paths(&root, &stash_id_clone, &paths_clone)
            })
            .await;

            match result {
                Ok(Ok(op_result)) => {
                    send_message(
                        socket,
                        &map_stash_op_result(project, workspace, op_result),
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &stash_op_error(
                            project,
                            workspace,
                            "restore_paths",
                            format!("{}", e),
                        ),
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Git stash restore task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
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
