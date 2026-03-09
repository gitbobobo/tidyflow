use axum::extract::ws::WebSocket;
use std::path::PathBuf;

use crate::server::context::{resolve_project, SharedAppState};
use crate::server::git;
use crate::server::protocol::ServerMessage;
use crate::server::ws::send_message;

pub(crate) async fn handle_git_ensure_integration_worktree(
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
    let root = proj_ctx.root_path;
    let project_name = proj_ctx.project_name;
    let default_branch = proj_ctx.default_branch;
    let result = tokio::task::spawn_blocking(move || {
        git::ensure_integration_worktree(&root, &project_name, &default_branch)
    })
    .await;
    match result {
        Ok(Ok(path)) => {
            send_message(
                socket,
                &ServerMessage::GitMergeToDefaultResult {
                    project: project.to_string(),
                    ok: true,
                    state: "idle".to_string(),
                    message: Some("Integration worktree ready".to_string()),
                    conflicts: vec![],
                    conflict_files: vec![],
                    head_sha: None,
                    integration_path: Some(path),
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitMergeToDefaultResult {
                    project: project.to_string(),
                    ok: false,
                    state: "failed".to_string(),
                    message: Some(format!("{}", e)),
                    conflicts: vec![],
                    conflict_files: vec![],
                    head_sha: None,
                    integration_path: None,
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Ensure integration worktree task failed: {}", e),
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

pub(crate) async fn handle_git_merge_to_default(
    project: &str,
    workspace: &str,
    default_branch: &str,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    let (proj_ctx, source_branch) =
        match crate::server::context::resolve_workspace_branch(app_state, project, workspace).await
        {
            Ok(r) => r,
            Err(e) => {
                send_message(socket, &e.to_server_error()).await?;
                return Ok(true);
            }
        };
    let root = proj_ctx.root_path;
    let project_name = proj_ctx.project_name;

    if source_branch == "HEAD" || source_branch.is_empty() {
        send_message(
            socket,
            &ServerMessage::GitMergeToDefaultResult {
                project: project.to_string(),
                ok: false,
                state: "failed".to_string(),
                message: Some(
                    "Workspace is in detached HEAD state. Create/switch to a branch first."
                        .to_string(),
                ),
                conflicts: vec![],
                conflict_files: vec![],
                head_sha: None,
                integration_path: None,
            },
        )
        .await?;
        return Ok(true);
    }

    let default_branch_clone = default_branch.to_string();
    let result = tokio::task::spawn_blocking(move || {
        git::merge_to_default(&root, &project_name, &source_branch, &default_branch_clone)
    })
    .await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitMergeToDefaultResult {
                    project: project.to_string(),
                    ok: r.ok,
                    state: r.state,
                    message: r.message,
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
                    head_sha: r.head_sha,
                    integration_path: r.integration_path,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitMergeToDefaultResult {
                    project: project.to_string(),
                    ok: false,
                    state: "failed".to_string(),
                    message: Some(format!("{}", e)),
                    conflicts: vec![],
                    conflict_files: vec![],
                    head_sha: None,
                    integration_path: None,
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Merge to default task failed: {}", e),
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

pub(crate) async fn handle_git_merge_continue(
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
    let result = tokio::task::spawn_blocking(move || git::merge_continue(&project_name)).await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitMergeToDefaultResult {
                    project: project.to_string(),
                    ok: r.ok,
                    state: r.state,
                    message: r.message,
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
                    head_sha: r.head_sha,
                    integration_path: r.integration_path,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitMergeToDefaultResult {
                    project: project.to_string(),
                    ok: false,
                    state: "failed".to_string(),
                    message: Some(format!("{}", e)),
                    conflicts: vec![],
                    conflict_files: vec![],
                    head_sha: None,
                    integration_path: None,
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Merge continue task failed: {}", e),
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

pub(crate) async fn handle_git_merge_abort(
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
    let result = tokio::task::spawn_blocking(move || git::merge_abort(&project_name)).await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitMergeToDefaultResult {
                    project: project.to_string(),
                    ok: r.ok,
                    state: r.state,
                    message: r.message,
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
                    head_sha: r.head_sha,
                    integration_path: r.integration_path,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitMergeToDefaultResult {
                    project: project.to_string(),
                    ok: false,
                    state: "failed".to_string(),
                    message: Some(format!("{}", e)),
                    conflicts: vec![],
                    conflict_files: vec![],
                    head_sha: None,
                    integration_path: None,
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Merge abort task failed: {}", e),
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

pub(crate) async fn handle_git_reset_integration_worktree(
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
    let repo_root = proj_ctx.root_path;
    let default_branch = proj_ctx.default_branch;
    let result = tokio::task::spawn_blocking(move || {
        git::reset_integration_worktree(&PathBuf::from(&repo_root), &project_name, &default_branch)
    })
    .await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitResetIntegrationWorktreeResult {
                    project: project.to_string(),
                    ok: r.ok,
                    message: r.message,
                    path: r.path,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitResetIntegrationWorktreeResult {
                    project: project.to_string(),
                    ok: false,
                    message: Some(format!("{}", e)),
                    path: None,
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Reset integration worktree task failed: {}", e),
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

// ============================================================================
// 冲突向导 handlers
// ============================================================================

/// 读取单个冲突文件的四路对比内容
pub(crate) async fn handle_git_conflict_detail(
    project: &str,
    workspace: &str,
    path: &str,
    context: &str,
    socket: &mut axum::extract::ws::WebSocket,
    app_state: &crate::server::context::SharedAppState,
) -> Result<bool, String> {
    use crate::server::context::resolve_workspace;
    use crate::server::git;

    // 根据 context 选择工作目录
    let root = if context == "integration" {
        // 集成工作树路径
        let proj_ctx = match crate::server::context::resolve_project(app_state, project).await {
            Ok(ctx) => ctx,
            Err(e) => {
                crate::server::ws::send_message(socket, &e.to_server_error()).await?;
                return Ok(true);
            }
        };
        let project_name = proj_ctx.project_name.clone();
        git::get_integration_worktree_root(&project_name)
    } else {
        let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
            Ok(ctx) => ctx,
            Err(e) => {
                crate::server::ws::send_message(socket, &e.to_server_error()).await?;
                return Ok(true);
            }
        };
        ws_ctx.root_path
    };

    let path_owned = path.to_string();
    let context_owned = context.to_string();
    let result = tokio::task::spawn_blocking(move || {
        git::git_conflict_detail(&root, &path_owned, &context_owned)
    })
    .await;

    match result {
        Ok(Ok(detail)) => {
            crate::server::ws::send_message(
                socket,
                &crate::server::protocol::ServerMessage::GitConflictDetailResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    context: detail.context,
                    path: detail.path,
                    base_content: detail.base_content,
                    ours_content: detail.ours_content,
                    theirs_content: detail.theirs_content,
                    current_content: detail.current_content,
                    conflict_markers_count: detail.conflict_markers_count,
                    is_binary: detail.is_binary,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            crate::server::ws::send_message(
                socket,
                &crate::server::protocol::ServerMessage::Error {
                    code: "git_error".to_string(),
                    message: format!("Conflict detail failed: {}", e),
                    project: None,
                    workspace: None,
                    session_id: None,
                    cycle_id: None,
                },
            )
            .await?;
        }
        Err(e) => {
            crate::server::ws::send_message(
                socket,
                &crate::server::protocol::ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Conflict detail task failed: {}", e),
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

/// 执行冲突解决动作（accept_ours/accept_theirs/accept_both/mark_resolved）
pub(crate) async fn handle_git_conflict_action(
    project: &str,
    workspace: &str,
    path: &str,
    context: &str,
    action: &str,
    socket: &mut axum::extract::ws::WebSocket,
    app_state: &crate::server::context::SharedAppState,
) -> Result<bool, String> {
    use crate::server::context::resolve_workspace;
    use crate::server::git;

    let root = if context == "integration" {
        let proj_ctx = match crate::server::context::resolve_project(app_state, project).await {
            Ok(ctx) => ctx,
            Err(e) => {
                crate::server::ws::send_message(socket, &e.to_server_error()).await?;
                return Ok(true);
            }
        };
        let project_name = proj_ctx.project_name.clone();
        git::get_integration_worktree_root(&project_name)
    } else {
        let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
            Ok(ctx) => ctx,
            Err(e) => {
                crate::server::ws::send_message(socket, &e.to_server_error()).await?;
                return Ok(true);
            }
        };
        ws_ctx.root_path
    };

    let path_owned = path.to_string();
    let context_owned = context.to_string();
    let action_owned = action.to_string();
    let result = tokio::task::spawn_blocking(move || match action_owned.as_str() {
        "accept_ours" => git::git_conflict_accept_ours(&root, &path_owned, &context_owned),
        "accept_theirs" => git::git_conflict_accept_theirs(&root, &path_owned, &context_owned),
        "accept_both" => git::git_conflict_accept_both(&root, &path_owned, &context_owned),
        "mark_resolved" => git::git_conflict_mark_resolved(&root, &path_owned, &context_owned),
        other => Err(crate::server::git::GitError::CommandFailed(format!(
            "Unknown conflict action: {}",
            other
        ))),
    })
    .await;

    match result {
        Ok(Ok(r)) => {
            let context_str = r.snapshot.context.clone();
            let snapshot = crate::server::protocol::ConflictSnapshotInfo {
                context: r.snapshot.context,
                files: r
                    .snapshot
                    .files
                    .iter()
                    .map(|f| crate::server::protocol::ConflictFileEntryInfo {
                        path: f.path.clone(),
                        conflict_type: f.conflict_type.clone(),
                        staged: f.staged,
                    })
                    .collect(),
                all_resolved: r.snapshot.all_resolved,
            };
            crate::server::ws::send_message(
                socket,
                &crate::server::protocol::ServerMessage::GitConflictActionResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    context: context_str,
                    path: path.to_string(),
                    action: r.action,
                    ok: r.ok,
                    message: r.message,
                    snapshot,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            crate::server::ws::send_message(
                socket,
                &crate::server::protocol::ServerMessage::Error {
                    code: "git_error".to_string(),
                    message: format!("Conflict action failed: {}", e),
                    project: None,
                    workspace: None,
                    session_id: None,
                    cycle_id: None,
                },
            )
            .await?;
        }
        Err(e) => {
            crate::server::ws::send_message(
                socket,
                &crate::server::protocol::ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Conflict action task failed: {}", e),
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
