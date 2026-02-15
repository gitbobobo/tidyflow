use axum::extract::ws::WebSocket;
use std::path::PathBuf;
use std::time::Duration;
use tracing::{info, warn, error};

use crate::server::context::{
    resolve_project, resolve_workspace, resolve_workspace_branch, HandlerContext,
    RunningAITaskEntry, SharedAppState, TaskBroadcastEvent,
};
use crate::server::git;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

/// AI 代理执行超时（5 分钟）
const AI_AGENT_TIMEOUT: Duration = Duration::from_secs(600);

pub async fn try_handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ctx: &HandlerContext,
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

        // v1.33: AI Git merge
        ClientMessage::GitAIMerge {
            project,
            workspace,
            ai_agent,
            default_branch,
        } => {
            try_handle_git_ai_merge(
                project.clone(),
                workspace.clone(),
                ai_agent.clone(),
                default_branch.clone(),
                socket,
                app_state,
                ctx,
            )
            .await
        }

        _ => Ok(false),
    }
}

/// 处理 AI 智能合并（后台执行，不阻塞 WebSocket 主循环）
async fn try_handle_git_ai_merge(
    project: String,
    workspace: String,
    ai_agent: Option<String>,
    default_branch: String,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    let (proj_ctx, source_branch) =
        match resolve_workspace_branch(app_state, &project, &workspace).await {
            Ok(r) => r,
            Err(e) => {
                send_message(socket, &e.to_server_error()).await?;
                return Ok(true);
            }
        };

    if source_branch == "HEAD" || source_branch.is_empty() {
        let msg = ServerMessage::GitAIMergeResult {
            project: project.clone(),
            workspace: workspace.clone(),
            success: false,
            message: "Workspace is in detached HEAD state. Create/switch to a branch first."
                .to_string(),
            conflicts: vec![],
        };
        send_message(socket, &msg).await?;
        let _ = ctx.task_broadcast_tx.send(TaskBroadcastEvent {
            origin_conn_id: ctx.conn_meta.conn_id.clone(),
            message: msg,
        });
        return Ok(true);
    }

    let root = proj_ctx.root_path;
    let project_name = proj_ctx.project_name;
    let ai_agent_type = ai_agent.unwrap_or_else(|| "cursor".to_string());

    // 通过 cmd_output_tx 异步回传结果，不阻塞 WS 主循环
    let cmd_output_tx = ctx.cmd_output_tx.clone();
    let task_broadcast_tx = ctx.task_broadcast_tx.clone();
    let origin_conn_id = ctx.conn_meta.conn_id.clone();

    info!(
        "AI merge started: project={}, workspace={}, agent={}, {} -> {}",
        project, workspace, ai_agent_type, source_branch, default_branch
    );

    let running_ai_tasks = ctx.running_ai_tasks.clone();
    let task_id = uuid::Uuid::new_v4().to_string();
    let child_pid: std::sync::Arc<std::sync::Mutex<Option<u32>>> =
        std::sync::Arc::new(std::sync::Mutex::new(None));
    let child_pid_clone = child_pid.clone();
    let task_id_clone = task_id.clone();
    let running_ai_tasks_cleanup = running_ai_tasks.clone();
    let project_for_registry = project.clone();
    let workspace_for_registry = workspace.clone();

    let join_handle = tokio::spawn(async move {
        let pid_for_blocking = child_pid_clone.clone();
        let result = tokio::time::timeout(
            AI_AGENT_TIMEOUT,
            tokio::task::spawn_blocking(move || {
                handle_ai_merge_internal(
                    &root,
                    &project_name,
                    &source_branch,
                    &default_branch,
                    &ai_agent_type,
                    Some(&pid_for_blocking),
                )
            }),
        )
        .await;

        let msg = match result {
            Ok(Ok(Ok(merge_result))) => {
                info!(
                    "AI merge succeeded: project={}, workspace={}",
                    project, workspace
                );
                ServerMessage::GitAIMergeResult {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    success: merge_result.success,
                    message: merge_result.message,
                    conflicts: merge_result.conflicts,
                }
            }
            Ok(Ok(Err(e))) => {
                warn!("AI merge failed: project={}, workspace={}, error={}", project, workspace, e);
                ServerMessage::GitAIMergeResult {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    success: false,
                    message: e,
                    conflicts: vec![],
                }
            }
            Ok(Err(e)) => {
                error!("AI merge task panicked: {}", e);
                ServerMessage::GitAIMergeResult {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    success: false,
                    message: format!("AI merge task failed: {}", e),
                    conflicts: vec![],
                }
            }
            Err(_) => {
                error!(
                    "AI merge timed out after {}s: project={}, workspace={}",
                    AI_AGENT_TIMEOUT.as_secs(), project, workspace
                );
                ServerMessage::GitAIMergeResult {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    success: false,
                    message: format!(
                        "AI agent timed out after {} seconds",
                        AI_AGENT_TIMEOUT.as_secs()
                    ),
                    conflicts: vec![],
                }
            }
        };

        // 发送给发起者
        if let Err(e) = cmd_output_tx.send(msg.clone()).await {
            error!("Failed to send AI merge result to WS: {}", e);
        }
        // 广播给其他连接
        let _ = task_broadcast_tx.send(TaskBroadcastEvent {
            origin_conn_id,
            message: msg,
        });
        // 从注册表移除
        running_ai_tasks_cleanup.lock().await.remove(&task_id_clone);
    });

    // 注册到 AI 任务注册表
    running_ai_tasks.lock().await.insert(
        task_id.clone(),
        RunningAITaskEntry {
            task_id,
            project: project_for_registry,
            workspace: workspace_for_registry,
            operation_type: "ai_merge".to_string(),
            child_pid,
            join_handle,
        },
    );

    Ok(true)
}

/// AI 合并结果
struct AIMergeOutput {
    success: bool,
    message: String,
    conflicts: Vec<String>,
}

/// 内部函数：执行 AI 智能合并逻辑
fn handle_ai_merge_internal(
    repo_root: &std::path::Path,
    project_name: &str,
    source_branch: &str,
    default_branch: &str,
    ai_agent: &str,
    pid_holder: Option<&std::sync::Arc<std::sync::Mutex<Option<u32>>>>,
) -> Result<AIMergeOutput, String> {
    // 确保 integration worktree 存在
    let integration_path =
        git::ensure_integration_worktree(repo_root, project_name, default_branch)
            .map_err(|e| format!("Failed to ensure integration worktree: {}", e))?;
    let integration_root = std::path::PathBuf::from(&integration_path);

    // 构建合并 prompt
    let prompt = build_ai_merge_prompt(source_branch, default_branch);

    // 调用 AI agent
    let agent_args = super::branch_commit::build_ai_agent_command(ai_agent, &prompt)?;
    let ai_output = super::branch_commit::execute_ai_agent(&integration_root, &agent_args, pid_holder)?;

    // 解析结果
    parse_ai_merge_result(&ai_output)
}

/// 构建 AI 合并提示词
fn build_ai_merge_prompt(source_branch: &str, default_branch: &str) -> String {
    format!(
        r#"你是一个 Git 合并助手。请在当前目录执行合并操作。这是纯本地操作，禁止任何网络请求。

**任务**：将分支 `{source_branch}` 合并到 `{default_branch}`

请确保当前在 `{default_branch}` 分支上，然后执行合并。如果有冲突，尝试解决并提交。
以严格 JSON 格式输出结果（只输出 JSON，不要输出其他内容）：
```json
{{
  "success": true,
  "message": "操作结果描述",
  "conflicts": ["冲突文件路径列表，无冲突则为空数组"]
}}
```"#
    )
}

/// 解析 AI 合并结果
fn parse_ai_merge_result(output: &str) -> Result<AIMergeOutput, String> {
    let json_str = super::branch_commit::extract_json_from_output(output)?;
    let value: serde_json::Value = serde_json::from_str(&json_str)
        .map_err(|e| format!("Failed to parse AI merge output as JSON: {}", e))?;

    // 兼容 envelope 格式
    let inner = super::branch_commit::extract_inner_json(&value);

    let success = inner
        .get("success")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let message = inner
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("Unknown result")
        .to_string();
    let conflicts = inner
        .get("conflicts")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    Ok(AIMergeOutput {
        success,
        message,
        conflicts,
    })
}
