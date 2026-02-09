use axum::extract::ws::WebSocket;
use tracing::warn;

use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::git;
use crate::server::protocol::{ClientMessage, GitStatusEntry, ServerMessage};
use crate::server::ws::send_message;

pub async fn try_handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.5: Git status
        ClientMessage::GitStatus { project, workspace } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let default_branch = ws_ctx.default_branch;

            // Run git status + branch divergence in blocking task
            let result = tokio::task::spawn_blocking(move || {
                let mut status = git::git_status(&root)?;
                let current_branch = match git::git_current_branch(&root) {
                    Ok(branch) => branch,
                    Err(e) => {
                        warn!("Failed to get current branch: {}", e);
                        None
                    }
                };

                let divergence = if let Some(branch) = current_branch.as_deref() {
                    match git::check_branch_divergence_local(
                        &root,
                        branch,
                        &default_branch,
                    ) {
                        Ok(result) => Some(result),
                        Err(e) => {
                            warn!(
                                "Failed to compute local branch divergence for '{}' vs '{}': {}",
                                branch, default_branch, e
                            );
                            None
                        }
                    }
                } else {
                    None
                };

                status.current_branch = current_branch;
                status.default_branch = Some(default_branch);
                status.ahead_by = divergence.as_ref().map(|d| d.ahead_by);
                status.behind_by = divergence.as_ref().map(|d| d.behind_by);
                status.compared_branch = divergence.map(|d| d.compared_branch);
                Ok::<_, git::GitError>(status)
            })
            .await;

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
                            current_branch: status_result.current_branch,
                            default_branch: status_result.default_branch,
                            ahead_by: status_result.ahead_by,
                            behind_by: status_result.behind_by,
                            compared_branch: status_result.compared_branch,
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
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let path_clone = path.clone();
            let base_clone = base.clone();
            let mode_clone = mode.clone();
            let result = tokio::task::spawn_blocking(move || {
                git::git_diff(&root, &path_clone, base_clone.as_deref(), &mode_clone)
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
                            base: base.clone(),
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
            Ok(true)
        }

        _ => Ok(false),
    }
}
