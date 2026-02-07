use axum::extract::ws::WebSocket;

use crate::server::git;
use crate::server::protocol::{ClientMessage, GitStatusEntry, ServerMessage};
use crate::server::ws::{send_message, SharedAppState};

use super::get_workspace_root;

pub async fn try_handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.5: Git status
        ClientMessage::GitStatus { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    match get_workspace_root(p, workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git status in blocking task
                            let result =
                                tokio::task::spawn_blocking(move || git::git_status(&root)).await;

                            match result {
                                Ok(Ok(status_result)) => {
                                    let items: Vec<GitStatusEntry> = status_result
                                        .items
                                        .into_iter()
                                        .map(|e| GitStatusEntry {
                                            path: e.path,
                                            code: e.code,
                                            orig_path: e.orig_path,
                                            staged: e.staged,
                                            additions: e.additions,
                                            deletions: e.deletions,
                                        })
                                        .collect();

                                    send_message(
                                        socket,
                                        &ServerMessage::GitStatusResult {
                                            project: project.clone(),
                                            workspace: workspace.clone(),
                                            repo_root: status_result.repo_root,
                                            items,
                                            has_staged_changes: status_result.has_staged_changes,
                                            staged_count: status_result.staged_count,
                                        },
                                    )
                                    .await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "git_error".to_string(),
                                            message: format!("Git status failed: {}", e),
                                        },
                                    )
                                    .await?;
                                }
                                Err(e) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "internal_error".to_string(),
                                            message: format!("Git status task failed: {}", e),
                                        },
                                    )
                                    .await?;
                                }
                            }
                        }
                        None => {
                            send_message(
                                socket,
                                &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                },
                            )
                            .await?;
                        }
                    }
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.5: Git diff
        ClientMessage::GitDiff {
            project,
            workspace,
            path,
            base,
            mode,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    match get_workspace_root(p, workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git diff in blocking task
                            let path_clone = path.clone();
                            let base_clone = base.clone();
                            let mode_clone = mode.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_diff(
                                    &root,
                                    &path_clone,
                                    base_clone.as_deref(),
                                    &mode_clone,
                                )
                            })
                            .await;

                            match result {
                                Ok(Ok(diff_result)) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::GitDiffResult {
                                            project: project.clone(),
                                            workspace: workspace.clone(),
                                            path: path.clone(),
                                            code: diff_result.code,
                                            format: diff_result.format,
                                            text: diff_result.text,
                                            is_binary: diff_result.is_binary,
                                            truncated: diff_result.truncated,
                                            mode: diff_result.mode,
                                        },
                                    )
                                    .await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "git_error".to_string(),
                                            message: format!("Git diff failed: {}", e),
                                        },
                                    )
                                    .await?;
                                }
                                Err(e) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "internal_error".to_string(),
                                            message: format!("Git diff task failed: {}", e),
                                        },
                                    )
                                    .await?;
                                }
                            }
                        }
                        None => {
                            send_message(
                                socket,
                                &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                },
                            )
                            .await?;
                        }
                    }
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
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
