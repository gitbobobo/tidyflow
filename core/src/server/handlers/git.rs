use axum::extract::ws::WebSocket;
use std::path::PathBuf;

use crate::server::ws::{SharedAppState, send_message};
use crate::server::protocol::{ClientMessage, ServerMessage, GitStatusEntry, GitBranchInfo, GitLogEntryInfo, GitShowFileInfo};
use crate::server::git;
use crate::workspace::state::Project;

/// 获取工作空间的根路径,支持 "default" 虚拟工作空间
/// 如果 workspace 是 "default"，返回项目根目录
fn get_workspace_root(project: &Project, workspace: &str) -> Option<PathBuf> {
    if workspace == "default" {
        Some(project.root_path.clone())
    } else {
        project.get_workspace(workspace).map(|w| w.worktree_path.clone())
    }
}

/// 处理 Git 相关的客户端消息
pub async fn handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.5: Git status
        ClientMessage::GitStatus { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git status in blocking task
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_status(&root)
                            }).await;

                            match result {
                                Ok(Ok(status_result)) => {
                                    let items: Vec<GitStatusEntry> = status_result.items
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

                                    send_message(socket, &ServerMessage::GitStatusResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        repo_root: status_result.repo_root,
                                        items,
                                        has_staged_changes: status_result.has_staged_changes,
                                        staged_count: status_result.staged_count,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git status failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git status task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.5: Git diff
        ClientMessage::GitDiff { project, workspace, path, base, mode } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git diff in blocking task
                            let path_clone = path.clone();
                            let base_clone = base.clone();
                            let mode_clone = mode.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_diff(&root, &path_clone, base_clone.as_deref(), &mode_clone)
                            }).await;

                            match result {
                                Ok(Ok(diff_result)) => {
                                    send_message(socket, &ServerMessage::GitDiffResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        path: path.clone(),
                                        code: diff_result.code,
                                        format: diff_result.format,
                                        text: diff_result.text,
                                        is_binary: diff_result.is_binary,
                                        truncated: diff_result.truncated,
                                        mode: diff_result.mode,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git diff failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git diff task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.6: Git stage
        ClientMessage::GitStage { project, workspace, path, scope } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let path_clone = path.clone();
                            let scope_clone = scope.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_stage(&root, path_clone.as_deref(), &scope_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: "stage".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: path.clone(),
                                        scope: scope.clone(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git stage task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.6: Git unstage
        ClientMessage::GitUnstage { project, workspace, path, scope } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let path_clone = path.clone();
                            let scope_clone = scope.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_unstage(&root, path_clone.as_deref(), &scope_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: "unstage".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: path.clone(),
                                        scope: scope.clone(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git unstage task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.7: Git discard
        ClientMessage::GitDiscard { project, workspace, path, scope } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let path_clone = path.clone();
                            let scope_clone = scope.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_discard(&root, path_clone.as_deref(), &scope_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: "discard".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: path.clone(),
                                        scope: scope.clone(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git discard task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.8: Git branches
        ClientMessage::GitBranches { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git::git_branches(&root)
                            }).await;

                            match result {
                                Ok(Ok(branches_result)) => {
                                    let branches: Vec<GitBranchInfo> = branches_result.branches
                                        .into_iter()
                                        .map(|b| GitBranchInfo { name: b.name })
                                        .collect();

                                    send_message(socket, &ServerMessage::GitBranchesResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        current: branches_result.current,
                                        branches,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git branches failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git branches task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.8: Git switch branch
        ClientMessage::GitSwitchBranch { project, workspace, branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let branch_clone = branch.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_switch_branch(&root, &branch_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: "switch_branch".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: Some(branch.clone()),
                                        scope: "branch".to_string(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git switch branch task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.9: Git create branch
        ClientMessage::GitCreateBranch { project, workspace, branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let branch_clone = branch.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_create_branch(&root, &branch_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: "create_branch".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: Some(branch.clone()),
                                        scope: "branch".to_string(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git create branch task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.10: Git commit
        ClientMessage::GitCommit { project, workspace, message } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let message_clone = message.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_commit(&root, &message_clone)
                            }).await;

                            match result {
                                Ok(Ok(commit_result)) => {
                                    send_message(socket, &ServerMessage::GitCommitResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: commit_result.ok,
                                        message: commit_result.message,
                                        sha: commit_result.sha,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitCommitResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        sha: None,
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git commit task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git fetch (UX-3a)
        ClientMessage::GitFetch { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git::git_fetch(&root)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: "fetch".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: None,
                                        scope: "all".to_string(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git fetch task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git rebase (UX-3a)
        ClientMessage::GitRebase { project, workspace, onto_branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let onto_clone = onto_branch.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_rebase(&root, &onto_clone)
                            }).await;

                            match result {
                                Ok(Ok(rebase_result)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: rebase_result.ok,
                                        state: rebase_result.state,
                                        message: rebase_result.message,
                                        conflicts: rebase_result.conflicts,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: false,
                                        state: "error".to_string(),
                                        message: Some(format!("{}", e)),
                                        conflicts: vec![],
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git rebase task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git rebase continue (UX-3a)
        ClientMessage::GitRebaseContinue { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git::git_rebase_continue(&root)
                            }).await;

                            match result {
                                Ok(Ok(rebase_result)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: rebase_result.ok,
                                        state: rebase_result.state,
                                        message: rebase_result.message,
                                        conflicts: rebase_result.conflicts,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: false,
                                        state: "error".to_string(),
                                        message: Some(format!("{}", e)),
                                        conflicts: vec![],
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git rebase continue task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git rebase abort (UX-3a)
        ClientMessage::GitRebaseAbort { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git::git_rebase_abort(&root)
                            }).await;

                            match result {
                                Ok(Ok(rebase_result)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: rebase_result.ok,
                                        state: rebase_result.state,
                                        message: rebase_result.message,
                                        conflicts: rebase_result.conflicts,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: false,
                                        state: "error".to_string(),
                                        message: Some(format!("{}", e)),
                                        conflicts: vec![],
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git rebase abort task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.11: Git operation status (UX-3a)
        ClientMessage::GitOpStatus { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git::git_op_status(&root)
                            }).await;

                            match result {
                                Ok(Ok(status_result)) => {
                                    send_message(socket, &ServerMessage::GitOpStatusResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        state: status_result.state.as_str().to_string(),
                                        conflicts: status_result.conflicts,
                                        head: status_result.head,
                                        onto: status_result.onto,
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
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git ensure integration worktree (UX-3b)
        ClientMessage::GitEnsureIntegrationWorktree { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let root = p.root_path.clone();
                    let project_name = p.name.clone();
                    drop(state);

                    // Default to "main" branch for now
                    let default_branch = "main".to_string();
                    let result = tokio::task::spawn_blocking(move || {
                        git::ensure_integration_worktree(&root, &project_name, &default_branch)
                    }).await;

                    match result {
                        Ok(Ok(path)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project: project.clone(),
                                ok: true,
                                state: "idle".to_string(),
                                message: Some("Integration worktree ready".to_string()),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: Some(path),
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project: project.clone(),
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Ensure integration worktree task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git merge to default (UX-3b)
        ClientMessage::GitMergeToDefault { project, workspace, default_branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 获取源分支：如果是默认工作空间，使用项目默认分支
                    let source_branch = if workspace == "default" {
                        p.default_branch.clone()
                    } else {
                        match p.get_workspace(&workspace) {
                            Some(w) => w.branch.clone(),
                            None => {
                                drop(state);
                                send_message(socket, &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                }).await?;
                                return Ok(true);
                            }
                        }
                    };
                    let root = p.root_path.clone();
                    let project_name = p.name.clone();
                    drop(state);

                    // Check if workspace is on a branch (not detached HEAD)
                    if source_branch == "HEAD" || source_branch.is_empty() {
                        send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                            project: project.clone(),
                            ok: false,
                            state: "failed".to_string(),
                            message: Some("Workspace is in detached HEAD state. Create/switch to a branch first.".to_string()),
                            conflicts: vec![],
                            head_sha: None,
                            integration_path: None,
                        }).await?;
                        return Ok(true);
                    }

                    let default_branch_clone = default_branch.clone();
                    let result = tokio::task::spawn_blocking(move || {
                        git::merge_to_default(&root, &project_name, &source_branch, &default_branch_clone)
                    }).await;

                    match result {
                        Ok(Ok(merge_result)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project: project.clone(),
                                ok: merge_result.ok,
                                state: merge_result.state,
                                message: merge_result.message,
                                conflicts: merge_result.conflicts,
                                head_sha: merge_result.head_sha,
                                integration_path: merge_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project: project.clone(),
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Merge to default task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git merge continue (UX-3b)
        ClientMessage::GitMergeContinue { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    let result = tokio::task::spawn_blocking(move || {
                        git::merge_continue(&project_name)
                    }).await;

                    match result {
                        Ok(Ok(merge_result)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project: project.clone(),
                                ok: merge_result.ok,
                                state: merge_result.state,
                                message: merge_result.message,
                                conflicts: merge_result.conflicts,
                                head_sha: merge_result.head_sha,
                                integration_path: merge_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project: project.clone(),
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Merge continue task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git merge abort (UX-3b)
        ClientMessage::GitMergeAbort { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    let result = tokio::task::spawn_blocking(move || {
                        git::merge_abort(&project_name)
                    }).await;

                    match result {
                        Ok(Ok(merge_result)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project: project.clone(),
                                ok: merge_result.ok,
                                state: merge_result.state,
                                message: merge_result.message,
                                conflicts: merge_result.conflicts,
                                head_sha: merge_result.head_sha,
                                integration_path: merge_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project: project.clone(),
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Merge abort task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.12: Git integration status (UX-3b)
        ClientMessage::GitIntegrationStatus { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    // Default to "main" branch for now
                    let default_branch = "main".to_string();
                    let result = tokio::task::spawn_blocking(move || {
                        git::integration_status(&project_name, &default_branch)
                    }).await;

                    match result {
                        Ok(Ok(status_result)) => {
                            send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                                project: project.clone(),
                                state: status_result.state.as_str().to_string(),
                                conflicts: status_result.conflicts,
                                head: status_result.head,
                                default_branch: status_result.default_branch,
                                path: status_result.path,
                                is_clean: status_result.is_clean,
                                branch_ahead_by: status_result.branch_ahead_by,
                                branch_behind_by: status_result.branch_behind_by,
                                compared_branch: status_result.compared_branch,
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
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.13: Git rebase onto default (UX-4)
        ClientMessage::GitRebaseOntoDefault { project, workspace, default_branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 获取源分支：如果是默认工作空间，使用项目默认分支
                    let source_branch = if workspace == "default" {
                        p.default_branch.clone()
                    } else {
                        match p.get_workspace(&workspace) {
                            Some(w) => w.branch.clone(),
                            None => {
                                drop(state);
                                send_message(socket, &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                }).await?;
                                return Ok(true);
                            }
                        }
                    };
                    let root = p.root_path.clone();
                    let project_name = p.name.clone();
                    drop(state);

                    // Check if workspace is on a branch (not detached HEAD)
                    if source_branch == "HEAD" || source_branch.is_empty() {
                        send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                            project: project.clone(),
                            ok: false,
                            state: "failed".to_string(),
                            message: Some("Workspace is in detached HEAD state. Create/switch to a branch first.".to_string()),
                            conflicts: vec![],
                            head_sha: None,
                            integration_path: None,
                        }).await?;
                        return Ok(true);
                    }

                    let default_branch_clone = default_branch.clone();
                    let result = tokio::task::spawn_blocking(move || {
                        git::rebase_onto_default(&root, &project_name, &source_branch, &default_branch_clone)
                    }).await;

                    match result {
                        Ok(Ok(rebase_result)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project: project.clone(),
                                ok: rebase_result.ok,
                                state: rebase_result.state,
                                message: rebase_result.message,
                                conflicts: rebase_result.conflicts,
                                head_sha: rebase_result.head_sha,
                                integration_path: rebase_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project: project.clone(),
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Rebase onto default task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.13: Git rebase onto default continue (UX-4)
        ClientMessage::GitRebaseOntoDefaultContinue { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    let result = tokio::task::spawn_blocking(move || {
                        git::rebase_onto_default_continue(&project_name)
                    }).await;

                    match result {
                        Ok(Ok(rebase_result)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project: project.clone(),
                                ok: rebase_result.ok,
                                state: rebase_result.state,
                                message: rebase_result.message,
                                conflicts: rebase_result.conflicts,
                                head_sha: rebase_result.head_sha,
                                integration_path: rebase_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project: project.clone(),
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Rebase continue task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.13: Git rebase onto default abort (UX-4)
        ClientMessage::GitRebaseOntoDefaultAbort { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    let result = tokio::task::spawn_blocking(move || {
                        git::rebase_onto_default_abort(&project_name)
                    }).await;

                    match result {
                        Ok(Ok(rebase_result)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project: project.clone(),
                                ok: rebase_result.ok,
                                state: rebase_result.state,
                                message: rebase_result.message,
                                conflicts: rebase_result.conflicts,
                                head_sha: rebase_result.head_sha,
                                integration_path: rebase_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project: project.clone(),
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Rebase abort task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.14: Git reset integration worktree (UX-5)
        ClientMessage::GitResetIntegrationWorktree { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    let repo_root = p.root_path.clone();
                    drop(state);

                    // Use "main" as default branch for reset
                    let default_branch = "main".to_string();
                    let result = tokio::task::spawn_blocking(move || {
                        git::reset_integration_worktree(
                            &PathBuf::from(&repo_root),
                            &project_name,
                            &default_branch,
                        )
                    }).await;

                    match result {
                        Ok(Ok(reset_result)) => {
                            send_message(socket, &ServerMessage::GitResetIntegrationWorktreeResult {
                                project: project.clone(),
                                ok: reset_result.ok,
                                message: reset_result.message,
                                path: reset_result.path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitResetIntegrationWorktreeResult {
                                project: project.clone(),
                                ok: false,
                                message: Some(format!("{}", e)),
                                path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Reset integration worktree task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.15: Git check branch up to date (UX-6)
        ClientMessage::GitCheckBranchUpToDate { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 获取工作空间信息：如果是默认工作空间，使用项目根目录和默认分支
                    let (root, current_branch) = if workspace == "default" {
                        (p.root_path.clone(), p.default_branch.clone())
                    } else {
                        match p.get_workspace(&workspace) {
                            Some(w) => (w.worktree_path.clone(), w.branch.clone()),
                            None => {
                                drop(state);
                                send_message(socket, &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                }).await?;
                                return Ok(true);
                            }
                        }
                    };
                    let project_name = p.name.clone();
                    drop(state);

                    // Check if workspace is on a branch (not detached HEAD)
                    if current_branch == "HEAD" || current_branch.is_empty() {
                        send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                            project: project.clone(),
                            state: "idle".to_string(),
                            conflicts: vec![],
                            head: None,
                            default_branch: "main".to_string(),
                            path: root.to_string_lossy().to_string(),
                            is_clean: true,
                            branch_ahead_by: None,
                            branch_behind_by: None,
                            compared_branch: None,
                        }).await?;
                        return Ok(true);
                    }

                    // Default to "main" branch for comparison
                    let default_branch = "main".to_string();
                    let default_branch_clone = default_branch.clone();
                    let current_branch_clone = current_branch.clone();

                    let result = tokio::task::spawn_blocking(move || {
                        git::check_branch_divergence(&root, &current_branch_clone, &default_branch_clone)
                    }).await;

                    match result {
                        Ok(Ok(divergence_result)) => {
                            // Get integration status for the full response
                            let integration_result = tokio::task::spawn_blocking({
                                let project_name = project_name.clone();
                                let default_branch = default_branch.clone();
                                move || {
                                    git::integration_status(&project_name, &default_branch)
                                }
                            }).await;

                            match integration_result {
                                Ok(Ok(status_result)) => {
                                    send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                                        project: project.clone(),
                                        state: status_result.state.as_str().to_string(),
                                        conflicts: status_result.conflicts,
                                        head: status_result.head,
                                        default_branch: status_result.default_branch,
                                        path: status_result.path,
                                        is_clean: status_result.is_clean,
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
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.19: Git log
        ClientMessage::GitLog { project, workspace, limit } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git log in blocking task
                            let limit_copy = *limit;
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_log(&root, limit_copy)
                            }).await;

                            match result {
                                Ok(Ok(log_result)) => {
                                    let entries: Vec<GitLogEntryInfo> = log_result.entries
                                        .into_iter()
                                        .map(|e| GitLogEntryInfo {
                                            sha: e.sha,
                                            message: e.message,
                                            author: e.author,
                                            date: e.date,
                                            refs: e.refs,
                                        })
                                        .collect();

                                    send_message(socket, &ServerMessage::GitLogResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        entries,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git log failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git log task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // v1.20: Git show (single commit details)
        ClientMessage::GitShow { project, workspace, sha } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git show in blocking task
                            let sha_clone = sha.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git::git_show(&root, &sha_clone)
                            }).await;

                            match result {
                                Ok(Ok(show_result)) => {
                                    let files: Vec<GitShowFileInfo> = show_result.files
                                        .into_iter()
                                        .map(|f| GitShowFileInfo {
                                            status: f.status,
                                            path: f.path,
                                            old_path: f.old_path,
                                        })
                                        .collect();

                                    send_message(socket, &ServerMessage::GitShowResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        sha: show_result.sha,
                                        full_sha: show_result.full_sha,
                                        message: show_result.message,
                                        author: show_result.author,
                                        author_email: show_result.author_email,
                                        date: show_result.date,
                                        files,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git show failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git show task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
            Ok(true)
        }

        // Not a git message
        _ => Ok(false),
    }
}
