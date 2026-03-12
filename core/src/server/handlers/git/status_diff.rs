use crate::server::ws::OutboundTx as WebSocket;

use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::git;
use crate::server::protocol::{ClientMessage, GitStatusEntry, ServerMessage};
use crate::server::ws::send_message;

pub async fn handle_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
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

            // git_status 现在一次性产出 status items、current_branch 和 divergence
            let result =
                tokio::task::spawn_blocking(move || git::git_status(&root, &default_branch)).await;

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
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
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
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
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
