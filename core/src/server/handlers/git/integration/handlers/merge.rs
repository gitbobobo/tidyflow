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
