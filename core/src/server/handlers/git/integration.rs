use axum::extract::ws::WebSocket;
use std::path::PathBuf;

use crate::server::context::{
    resolve_project, resolve_workspace, resolve_workspace_branch, SharedAppState,
};
use crate::server::git;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub async fn try_handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.11: Git fetch (UX-3a)
        ClientMessage::GitFetch { project, workspace } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let root = ws_ctx.root_path;
            let result = tokio::task::spawn_blocking(move || git::git_fetch(&root)).await;
            match result {
                Ok(Ok(op_result)) => {
                    send_message(socket, &ServerMessage::GitOpResult {
                        project: project.clone(), workspace: workspace.clone(),
                        op: op_result.op, ok: op_result.ok, message: op_result.message,
                        path: op_result.path, scope: op_result.scope,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitOpResult {
                        project: project.clone(), workspace: workspace.clone(),
                        op: "fetch".to_string(), ok: false, message: Some(format!("{}", e)),
                        path: None, scope: "all".to_string(),
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Git fetch task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git rebase (UX-3a)
        ClientMessage::GitRebase { project, workspace, onto_branch } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let root = ws_ctx.root_path;
            let onto_clone = onto_branch.clone();
            let result = tokio::task::spawn_blocking(move || git::git_rebase(&root, &onto_clone)).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitRebaseResult {
                        project: project.clone(), workspace: workspace.clone(),
                        ok: r.ok, state: r.state, message: r.message, conflicts: r.conflicts,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitRebaseResult {
                        project: project.clone(), workspace: workspace.clone(),
                        ok: false, state: "error".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Git rebase task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git rebase continue (UX-3a)
        ClientMessage::GitRebaseContinue { project, workspace } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let root = ws_ctx.root_path;
            let result = tokio::task::spawn_blocking(move || git::git_rebase_continue(&root)).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitRebaseResult {
                        project: project.clone(), workspace: workspace.clone(),
                        ok: r.ok, state: r.state, message: r.message, conflicts: r.conflicts,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitRebaseResult {
                        project: project.clone(), workspace: workspace.clone(),
                        ok: false, state: "error".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Git rebase continue task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git rebase abort (UX-3a)
        ClientMessage::GitRebaseAbort { project, workspace } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let root = ws_ctx.root_path;
            let result = tokio::task::spawn_blocking(move || git::git_rebase_abort(&root)).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitRebaseResult {
                        project: project.clone(), workspace: workspace.clone(),
                        ok: r.ok, state: r.state, message: r.message, conflicts: r.conflicts,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitRebaseResult {
                        project: project.clone(), workspace: workspace.clone(),
                        ok: false, state: "error".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Git rebase abort task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git operation status (UX-3a)
        ClientMessage::GitOpStatus { project, workspace } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let root = ws_ctx.root_path;
            let result = tokio::task::spawn_blocking(move || git::git_op_status(&root)).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitOpStatusResult {
                        project: project.clone(), workspace: workspace.clone(),
                        state: r.state.as_str().to_string(),
                        conflicts: r.conflicts, head: r.head, onto: r.onto,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "git_error".to_string(),
                        message: format!("Git op status failed: {}", e),
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Git op status task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git ensure integration worktree (UX-3b)
        ClientMessage::GitEnsureIntegrationWorktree { project } => {
            let proj_ctx = match resolve_project(app_state, project).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let root = proj_ctx.root_path;
            let project_name = proj_ctx.project_name;
            let default_branch = proj_ctx.default_branch;
            let result = tokio::task::spawn_blocking(move || {
                git::ensure_integration_worktree(&root, &project_name, &default_branch)
            }).await;
            match result {
                Ok(Ok(path)) => {
                    send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                        project: project.clone(), ok: true, state: "idle".to_string(),
                        message: Some("Integration worktree ready".to_string()),
                        conflicts: vec![], head_sha: None, integration_path: Some(path),
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                        project: project.clone(), ok: false, state: "failed".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                        head_sha: None, integration_path: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Ensure integration worktree task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git merge to default (UX-3b)
        ClientMessage::GitMergeToDefault { project, workspace, default_branch } => {
            let (proj_ctx, source_branch) = match resolve_workspace_branch(app_state, project, workspace).await {
                Ok(r) => r,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let root = proj_ctx.root_path;
            let project_name = proj_ctx.project_name;

            if source_branch == "HEAD" || source_branch.is_empty() {
                send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                    project: project.clone(), ok: false, state: "failed".to_string(),
                    message: Some("Workspace is in detached HEAD state. Create/switch to a branch first.".to_string()),
                    conflicts: vec![], head_sha: None, integration_path: None,
                }).await?;
                return Ok(true);
            }

            let default_branch_clone = default_branch.clone();
            let result = tokio::task::spawn_blocking(move || {
                git::merge_to_default(&root, &project_name, &source_branch, &default_branch_clone)
            }).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                        project: project.clone(), ok: r.ok, state: r.state,
                        message: r.message, conflicts: r.conflicts,
                        head_sha: r.head_sha, integration_path: r.integration_path,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                        project: project.clone(), ok: false, state: "failed".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                        head_sha: None, integration_path: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Merge to default task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git merge continue (UX-3b)
        ClientMessage::GitMergeContinue { project } => {
            let proj_ctx = match resolve_project(app_state, project).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let project_name = proj_ctx.project_name;
            let result = tokio::task::spawn_blocking(move || git::merge_continue(&project_name)).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                        project: project.clone(), ok: r.ok, state: r.state,
                        message: r.message, conflicts: r.conflicts,
                        head_sha: r.head_sha, integration_path: r.integration_path,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                        project: project.clone(), ok: false, state: "failed".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                        head_sha: None, integration_path: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Merge continue task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git merge abort (UX-3b)
        ClientMessage::GitMergeAbort { project } => {
            let proj_ctx = match resolve_project(app_state, project).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let project_name = proj_ctx.project_name;
            let result = tokio::task::spawn_blocking(move || git::merge_abort(&project_name)).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                        project: project.clone(), ok: r.ok, state: r.state,
                        message: r.message, conflicts: r.conflicts,
                        head_sha: r.head_sha, integration_path: r.integration_path,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                        project: project.clone(), ok: false, state: "failed".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                        head_sha: None, integration_path: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Merge abort task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git integration status (UX-3b)
        ClientMessage::GitIntegrationStatus { project } => {
            let proj_ctx = match resolve_project(app_state, project).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let project_name = proj_ctx.project_name;
            let default_branch = proj_ctx.default_branch;
            let result = tokio::task::spawn_blocking(move || {
                git::integration_status(&project_name, &default_branch)
            }).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                        project: project.clone(),
                        state: r.state.as_str().to_string(),
                        conflicts: r.conflicts, head: r.head,
                        default_branch: r.default_branch, path: r.path,
                        is_clean: r.is_clean,
                        branch_ahead_by: r.branch_ahead_by,
                        branch_behind_by: r.branch_behind_by,
                        compared_branch: r.compared_branch,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "git_error".to_string(),
                        message: format!("Integration status failed: {}", e),
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Integration status task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.13: Git rebase onto default (UX-4)
        ClientMessage::GitRebaseOntoDefault { project, workspace, default_branch } => {
            let (proj_ctx, source_branch) = match resolve_workspace_branch(app_state, project, workspace).await {
                Ok(r) => r,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let root = proj_ctx.root_path;
            let project_name = proj_ctx.project_name;

            if source_branch == "HEAD" || source_branch.is_empty() {
                send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                    project: project.clone(), ok: false, state: "failed".to_string(),
                    message: Some("Workspace is in detached HEAD state. Create/switch to a branch first.".to_string()),
                    conflicts: vec![], head_sha: None, integration_path: None,
                }).await?;
                return Ok(true);
            }

            let default_branch_clone = default_branch.clone();
            let result = tokio::task::spawn_blocking(move || {
                git::rebase_onto_default(&root, &project_name, &source_branch, &default_branch_clone)
            }).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                        project: project.clone(), ok: r.ok, state: r.state,
                        message: r.message, conflicts: r.conflicts,
                        head_sha: r.head_sha, integration_path: r.integration_path,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                        project: project.clone(), ok: false, state: "failed".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                        head_sha: None, integration_path: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Rebase onto default task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.13: Git rebase onto default continue (UX-4)
        ClientMessage::GitRebaseOntoDefaultContinue { project } => {
            let proj_ctx = match resolve_project(app_state, project).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let project_name = proj_ctx.project_name;
            let result = tokio::task::spawn_blocking(move || {
                git::rebase_onto_default_continue(&project_name)
            }).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                        project: project.clone(), ok: r.ok, state: r.state,
                        message: r.message, conflicts: r.conflicts,
                        head_sha: r.head_sha, integration_path: r.integration_path,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                        project: project.clone(), ok: false, state: "failed".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                        head_sha: None, integration_path: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Rebase continue task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.13: Git rebase onto default abort (UX-4)
        ClientMessage::GitRebaseOntoDefaultAbort { project } => {
            let proj_ctx = match resolve_project(app_state, project).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let project_name = proj_ctx.project_name;
            let result = tokio::task::spawn_blocking(move || {
                git::rebase_onto_default_abort(&project_name)
            }).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                        project: project.clone(), ok: r.ok, state: r.state,
                        message: r.message, conflicts: r.conflicts,
                        head_sha: r.head_sha, integration_path: r.integration_path,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                        project: project.clone(), ok: false, state: "failed".to_string(),
                        message: Some(format!("{}", e)), conflicts: vec![],
                        head_sha: None, integration_path: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Rebase abort task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.14: Git reset integration worktree (UX-5)
        ClientMessage::GitResetIntegrationWorktree { project } => {
            let proj_ctx = match resolve_project(app_state, project).await {
                Ok(ctx) => ctx,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };
            let project_name = proj_ctx.project_name;
            let repo_root = proj_ctx.root_path;
            let default_branch = proj_ctx.default_branch;
            let result = tokio::task::spawn_blocking(move || {
                git::reset_integration_worktree(&PathBuf::from(&repo_root), &project_name, &default_branch)
            }).await;
            match result {
                Ok(Ok(r)) => {
                    send_message(socket, &ServerMessage::GitResetIntegrationWorktreeResult {
                        project: project.clone(), ok: r.ok, message: r.message, path: r.path,
                    }).await?;
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::GitResetIntegrationWorktreeResult {
                        project: project.clone(), ok: false,
                        message: Some(format!("{}", e)), path: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Reset integration worktree task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.15: Git check branch up to date (UX-6)
        ClientMessage::GitCheckBranchUpToDate { project, workspace } => {
            let (proj_ctx, current_branch) = match resolve_workspace_branch(app_state, project, workspace).await {
                Ok(r) => r,
                Err(e) => { send_message(socket, &e.to_server_error()).await?; return Ok(true); }
            };

            // 获取工作空间根路径
            let root = if workspace == "default" {
                proj_ctx.root_path.clone()
            } else {
                let state = app_state.read().await;
                state.get_project(project)
                    .and_then(|p| p.get_workspace(workspace))
                    .map(|w| w.worktree_path.clone())
                    .unwrap_or(proj_ctx.root_path.clone())
            };
            let project_name = proj_ctx.project_name;

            // 未挂载分支则直接返回空结果
            if current_branch == "HEAD" || current_branch.is_empty() {
                send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                    project: project.clone(), state: "idle".to_string(),
                    conflicts: vec![], head: None, default_branch: "main".to_string(),
                    path: root.to_string_lossy().to_string(), is_clean: true,
                    branch_ahead_by: None, branch_behind_by: None, compared_branch: None,
                }).await?;
                return Ok(true);
            }

            let default_branch = proj_ctx.default_branch.clone();
            let default_branch_clone = default_branch.clone();
            let current_branch_clone = current_branch.clone();

            let result = tokio::task::spawn_blocking(move || {
                git::check_branch_divergence(&root, &current_branch_clone, &default_branch_clone)
            }).await;

            match result {
                Ok(Ok(divergence_result)) => {
                    let integration_result = tokio::task::spawn_blocking({
                        let project_name = project_name.clone();
                        let default_branch = default_branch.clone();
                        move || git::integration_status(&project_name, &default_branch)
                    }).await;

                    match integration_result {
                        Ok(Ok(r)) => {
                            send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                                project: project.clone(),
                                state: r.state.as_str().to_string(),
                                conflicts: r.conflicts, head: r.head,
                                default_branch: r.default_branch, path: r.path,
                                is_clean: r.is_clean,
                                branch_ahead_by: Some(divergence_result.ahead_by),
                                branch_behind_by: Some(divergence_result.behind_by),
                                compared_branch: Some(current_branch),
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "git_error".to_string(),
                                message: format!("Integration status failed: {}", e),
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Integration status task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                Ok(Err(e)) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "git_error".to_string(),
                        message: format!("Check branch divergence failed: {}", e),
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::Error {
                        code: "internal_error".to_string(),
                        message: format!("Check branch divergence task failed: {}", e),
                    }).await?;
                }
            }
            Ok(true)
        }

        _ => Ok(false),
    }
}
