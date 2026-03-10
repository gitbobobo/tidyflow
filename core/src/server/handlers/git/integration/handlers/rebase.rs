use crate::server::ws::OutboundTx as WebSocket;

use crate::server::context::{
    resolve_project, resolve_workspace, resolve_workspace_branch, SharedAppState,
};
use crate::server::git;
use crate::server::protocol::ServerMessage;
use crate::server::ws::send_message;

pub(crate) async fn handle_git_rebase(
    project: &str,
    workspace: &str,
    onto_branch: &str,
    socket: &WebSocket,
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
    let onto_clone = onto_branch.to_string();
    let result = tokio::task::spawn_blocking(move || git::git_rebase(&root, &onto_clone)).await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
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
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    ok: false,
                    state: "error".to_string(),
                    message: Some(format!("{}", e)),
                    conflicts: vec![],
                    conflict_files: vec![],
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Git rebase task failed: {}", e),
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

pub(crate) async fn handle_git_rebase_continue(
    project: &str,
    workspace: &str,
    socket: &WebSocket,
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
    let result = tokio::task::spawn_blocking(move || git::git_rebase_continue(&root)).await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
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
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    ok: false,
                    state: "error".to_string(),
                    message: Some(format!("{}", e)),
                    conflicts: vec![],
                    conflict_files: vec![],
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Git rebase continue task failed: {}", e),
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

pub(crate) async fn handle_git_rebase_abort(
    project: &str,
    workspace: &str,
    socket: &WebSocket,
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
    let result = tokio::task::spawn_blocking(move || git::git_rebase_abort(&root)).await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
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
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    ok: false,
                    state: "error".to_string(),
                    message: Some(format!("{}", e)),
                    conflicts: vec![],
                    conflict_files: vec![],
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Git rebase abort task failed: {}", e),
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

pub(crate) async fn handle_git_rebase_onto_default(
    project: &str,
    workspace: &str,
    default_branch: &str,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    let (proj_ctx, source_branch) =
        match resolve_workspace_branch(app_state, project, workspace).await {
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
            &ServerMessage::GitRebaseOntoDefaultResult {
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
        git::rebase_onto_default(&root, &project_name, &source_branch, &default_branch_clone)
    })
    .await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseOntoDefaultResult {
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
                &ServerMessage::GitRebaseOntoDefaultResult {
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
                    message: format!("Rebase onto default task failed: {}", e),
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

pub(crate) async fn handle_git_rebase_onto_default_continue(
    project: &str,
    socket: &WebSocket,
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
    let result =
        tokio::task::spawn_blocking(move || git::rebase_onto_default_continue(&project_name)).await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseOntoDefaultResult {
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
                &ServerMessage::GitRebaseOntoDefaultResult {
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
                    message: format!("Rebase continue task failed: {}", e),
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

pub(crate) async fn handle_git_rebase_onto_default_abort(
    project: &str,
    socket: &WebSocket,
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
    let result =
        tokio::task::spawn_blocking(move || git::rebase_onto_default_abort(&project_name)).await;
    match result {
        Ok(Ok(r)) => {
            send_message(
                socket,
                &ServerMessage::GitRebaseOntoDefaultResult {
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
                &ServerMessage::GitRebaseOntoDefaultResult {
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
                    message: format!("Rebase abort task failed: {}", e),
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
