use axum::extract::ws::WebSocket;

use crate::server::git;
use crate::server::protocol::{ClientMessage, GitLogEntryInfo, GitShowFileInfo, ServerMessage};
use crate::server::ws::{send_message, SharedAppState};

use super::get_workspace_root;

pub async fn try_handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.19: Git log
        ClientMessage::GitLog {
            project,
            workspace,
            limit,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    match get_workspace_root(p, workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git log in blocking task
                            let limit_copy = *limit;
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_log(&root, limit_copy)
                            })
                            .await;

                            match result {
                                Ok(Ok(log_result)) => {
                                    let entries: Vec<GitLogEntryInfo> = log_result
                                        .entries
                                        .into_iter()
                                        .map(|e| GitLogEntryInfo {
                                            sha: e.sha,
                                            message: e.message,
                                            author: e.author,
                                            date: e.date,
                                            refs: e.refs,
                                        })
                                        .collect();

                                    send_message(
                                        socket,
                                        &ServerMessage::GitLogResult {
                                            project: project.clone(),
                                            workspace: workspace.clone(),
                                            entries,
                                        },
                                    )
                                    .await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "git_error".to_string(),
                                            message: format!("Git log failed: {}", e),
                                        },
                                    )
                                    .await?;
                                }
                                Err(e) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "internal_error".to_string(),
                                            message: format!("Git log task failed: {}", e),
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

        // v1.20: Git show (single commit details)
        ClientMessage::GitShow {
            project,
            workspace,
            sha,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    match get_workspace_root(p, workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git show in blocking task
                            let sha_clone = sha.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_show(&root, &sha_clone)
                            })
                            .await;

                            match result {
                                Ok(Ok(show_result)) => {
                                    let files: Vec<GitShowFileInfo> = show_result
                                        .files
                                        .into_iter()
                                        .map(|f| GitShowFileInfo {
                                            status: f.status,
                                            path: f.path,
                                            old_path: f.old_path,
                                        })
                                        .collect();

                                    send_message(
                                        socket,
                                        &ServerMessage::GitShowResult {
                                            project: project.clone(),
                                            workspace: workspace.clone(),
                                            sha: show_result.sha,
                                            full_sha: show_result.full_sha,
                                            message: show_result.message,
                                            author: show_result.author,
                                            author_email: show_result.author_email,
                                            date: show_result.date,
                                            files,
                                        },
                                    )
                                    .await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "git_error".to_string(),
                                            message: format!("Git show failed: {}", e),
                                        },
                                    )
                                    .await?;
                                }
                                Err(e) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "internal_error".to_string(),
                                            message: format!("Git show task failed: {}", e),
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
