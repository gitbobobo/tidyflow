use axum::extract::ws::WebSocket;

use crate::server::context::{
    resolve_project, resolve_workspace, resolve_workspace_branch, SharedAppState,
};
use crate::server::git;
use crate::server::protocol::ServerMessage;
use crate::server::ws::send_message;

pub(crate) async fn handle_git_op_status(
    project: &str,
    workspace: &str,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
        Ok(ctx) => ctx,
        Err(e) => {
            send_message(socket, &e.to_server_error()).await?;
            return Ok(true);
        }
    };
    let root = ws_ctx.root_path;
    let result = tokio::task::spawn_blocking(move || git::git_op_status(&root)).await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitOpStatusResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    state: r.state.as_str().to_string(),
                    conflicts: r.conflicts,
                    conflict_files: r
                        .conflict_files
                        .iter()
                        .map(|f| crate::server::protocol::ConflictFileEntryInfo {
                            path: f.path.clone(),
                            conflict_type: f.conflict_type.clone(),
                            staged: f.staged,
                        })
                        .collect(),
                    head: r.head,
                    onto: r.onto,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "git_error".to_string(),
                    message: format!("Git op status failed: {}", e),
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
                    message: format!("Git op status task failed: {}", e),
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

pub(crate) async fn handle_git_integration_status(
    project: &str,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    let proj_ctx = match resolve_project(app_state, project).await {
        Ok(ctx) => ctx,
        Err(e) => {
            send_message(socket, &e.to_server_error()).await?;
            return Ok(true);
        }
    };
    let project_name = proj_ctx.project_name;
    let default_branch = proj_ctx.default_branch;
    let result = tokio::task::spawn_blocking(move || {
        git::integration_status(&project_name, &default_branch)
    })
    .await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitIntegrationStatusResult {
                    project: project.to_string(),
                    state: r.state.as_str().to_string(),
                    conflicts: r.conflicts,
                    conflict_files: r
                        .conflict_files
                        .iter()
                        .map(|f| crate::server::protocol::ConflictFileEntryInfo {
                            path: f.path.clone(),
                            conflict_type: f.conflict_type.clone(),
                            staged: f.staged,
                        })
                        .collect(),
                    head: r.head,
                    default_branch: r.default_branch,
                    path: r.path,
                    is_clean: r.is_clean,
                    branch_ahead_by: r.branch_ahead_by,
                    branch_behind_by: r.branch_behind_by,
                    compared_branch: r.compared_branch,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "git_error".to_string(),
                    message: format!("Integration status failed: {}", e),
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
                    message: format!("Integration status task failed: {}", e),
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

pub(crate) async fn handle_git_check_branch_up_to_date(
    project: &str,
    workspace: &str,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    let (proj_ctx, current_branch) =
        match resolve_workspace_branch(app_state, project, workspace).await {
            Ok(r) => r,
            Err(e) => {
                send_message(socket, &e.to_server_error()).await?;
                return Ok(true);
            }
        };

    let root = if workspace == "default" {
        proj_ctx.root_path.clone()
    } else {
        let state = app_state.read().await;
        state
            .get_project(project)
            .and_then(|p| p.get_workspace(workspace))
            .map(|w| w.worktree_path.clone())
            .unwrap_or(proj_ctx.root_path.clone())
    };
    let project_name = proj_ctx.project_name;

    if current_branch == "HEAD" || current_branch.is_empty() {
        send_message(
            socket,
            &ServerMessage::GitIntegrationStatusResult {
                project: project.to_string(),
                state: "idle".to_string(),
                conflicts: vec![],
                conflict_files: vec![],
                head: None,
                default_branch: "main".to_string(),
                path: root.to_string_lossy().to_string(),
                is_clean: true,
                branch_ahead_by: None,
                branch_behind_by: None,
                compared_branch: None,
            },
        )
        .await?;
        return Ok(true);
    }

    let default_branch = proj_ctx.default_branch.clone();
    let default_branch_clone = default_branch.clone();
    let current_branch_clone = current_branch.clone();

    let result = tokio::task::spawn_blocking(move || {
        git::check_branch_divergence(&root, &current_branch_clone, &default_branch_clone)
    })
    .await;

    match result {
        Ok(Ok(divergence_result)) => {
            let integration_result = tokio::task::spawn_blocking({
                let project_name = project_name.clone();
                let default_branch = default_branch.clone();
                move || git::integration_status(&project_name, &default_branch)
            })
            .await;

            match integration_result {
                Ok(Ok(r)) => {
                    send_message(
                        socket,
                        &ServerMessage::GitIntegrationStatusResult {
                            project: project.to_string(),
                            state: r.state.as_str().to_string(),
                            conflicts: r.conflicts,
                            conflict_files: r
                                .conflict_files
                                .iter()
                                .map(|f| crate::server::protocol::ConflictFileEntryInfo {
                                    path: f.path.clone(),
                                    conflict_type: f.conflict_type.clone(),
                                    staged: f.staged,
                                })
                                .collect(),
                            head: r.head,
                            default_branch: r.default_branch,
                            path: r.path,
                            is_clean: r.is_clean,
                            branch_ahead_by: Some(divergence_result.ahead_by),
                            branch_behind_by: Some(divergence_result.behind_by),
                            compared_branch: Some(current_branch),
                        },
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "git_error".to_string(),
                            message: format!("Integration status failed: {}", e),
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
                            message: format!("Integration status task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
            }
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "git_error".to_string(),
                    message: format!("Check branch divergence failed: {}", e),
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
                    message: format!("Check branch divergence task failed: {}", e),
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
