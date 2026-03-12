use crate::server::context::{
    resolve_project, resolve_workspace, resolve_workspace_branch, SharedAppState,
};
use crate::server::git;
use crate::server::protocol::{
    ConflictFileEntryInfo, GitBranchInfo, GitLogEntryInfo, GitShowFileInfo, GitStatusEntry,
    ServerMessage,
};

pub(crate) async fn query_git_status(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
) -> Result<ServerMessage, String> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_string())?;
    let root = ws_ctx.root_path;
    let default_branch = ws_ctx.default_branch;

    // git_status 现在一次性产出 status items、current_branch 和 divergence（复用同一 repo 对象）
    let status_result =
        tokio::task::spawn_blocking(move || git::git_status(&root, &default_branch))
            .await
            .map_err(|e| format!("Git status task failed: {}", e))?
            .map_err(|e| format!("Git status failed: {}", e))?;

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

    Ok(ServerMessage::GitStatusResult {
        project: project.to_string(),
        workspace: workspace.to_string(),
        repo_root: status_result.repo_root,
        items,
        has_staged_changes: status_result.has_staged_changes,
        staged_count: status_result.staged_count,
        current_branch: status_result.current_branch,
        default_branch: status_result.default_branch,
        ahead_by: status_result.ahead_by,
        behind_by: status_result.behind_by,
        compared_branch: status_result.compared_branch,
    })
}

pub(crate) async fn query_git_diff(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
    path: &str,
    base: Option<String>,
    mode: &str,
) -> Result<ServerMessage, String> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_string())?;
    let root = ws_ctx.root_path;
    let path_clone = path.to_string();
    let base_clone = base.clone();
    let mode_clone = mode.to_string();
    let diff_result = tokio::task::spawn_blocking(move || {
        git::git_diff(&root, &path_clone, base_clone.as_deref(), &mode_clone)
    })
    .await
    .map_err(|e| format!("Git diff task failed: {}", e))?
    .map_err(|e| format!("Git diff failed: {}", e))?;

    Ok(ServerMessage::GitDiffResult {
        project: project.to_string(),
        workspace: workspace.to_string(),
        path: path.to_string(),
        code: diff_result.code,
        format: diff_result.format,
        text: diff_result.text,
        is_binary: diff_result.is_binary,
        truncated: diff_result.truncated,
        mode: diff_result.mode,
        base,
    })
}

pub(crate) async fn query_git_branches(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
) -> Result<ServerMessage, String> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_string())?;
    let root = ws_ctx.root_path;
    let branches_result = tokio::task::spawn_blocking(move || git::git_branches(&root))
        .await
        .map_err(|e| format!("Git branches task failed: {}", e))?
        .map_err(|e| format!("Git branches failed: {}", e))?;

    Ok(ServerMessage::GitBranchesResult {
        project: project.to_string(),
        workspace: workspace.to_string(),
        current: branches_result.current,
        branches: branches_result
            .branches
            .into_iter()
            .map(|b| GitBranchInfo { name: b.name })
            .collect(),
    })
}

pub(crate) async fn query_git_log(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
    limit: usize,
) -> Result<ServerMessage, String> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_string())?;
    let root = ws_ctx.root_path;
    let log_result = tokio::task::spawn_blocking(move || git::git_log(&root, limit))
        .await
        .map_err(|e| format!("Git log task failed: {}", e))?
        .map_err(|e| format!("Git log failed: {}", e))?;

    Ok(ServerMessage::GitLogResult {
        project: project.to_string(),
        workspace: workspace.to_string(),
        entries: log_result
            .entries
            .into_iter()
            .map(|e| GitLogEntryInfo {
                sha: e.sha,
                message: e.message,
                author: e.author,
                date: e.date,
                refs: e.refs,
            })
            .collect(),
    })
}

pub(crate) async fn query_git_show(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
    sha: &str,
) -> Result<ServerMessage, String> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_string())?;
    let root = ws_ctx.root_path;
    let sha_clone = sha.to_string();
    let show_result = tokio::task::spawn_blocking(move || git::git_show(&root, &sha_clone))
        .await
        .map_err(|e| format!("Git show task failed: {}", e))?
        .map_err(|e| format!("Git show failed: {}", e))?;

    Ok(ServerMessage::GitShowResult {
        project: project.to_string(),
        workspace: workspace.to_string(),
        sha: show_result.sha,
        full_sha: show_result.full_sha,
        message: show_result.message,
        author: show_result.author,
        author_email: show_result.author_email,
        date: show_result.date,
        files: show_result
            .files
            .into_iter()
            .map(|f| GitShowFileInfo {
                status: f.status,
                path: f.path,
                old_path: f.old_path,
            })
            .collect(),
    })
}

pub(crate) async fn query_git_op_status(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
) -> Result<ServerMessage, String> {
    let ws_ctx = resolve_workspace(app_state, project, workspace)
        .await
        .map_err(|e| e.to_string())?;
    let root = ws_ctx.root_path;
    let result = tokio::task::spawn_blocking(move || git::git_op_status(&root))
        .await
        .map_err(|e| format!("Git op status task failed: {}", e))?
        .map_err(|e| format!("Git op status failed: {}", e))?;

    Ok(ServerMessage::GitOpStatusResult {
        project: project.to_string(),
        workspace: workspace.to_string(),
        state: result.state.as_str().to_string(),
        conflicts: result.conflicts,
        conflict_files: result
            .conflict_files
            .iter()
            .map(|f| ConflictFileEntryInfo {
                path: f.path.clone(),
                conflict_type: f.conflict_type.clone(),
                staged: f.staged,
            })
            .collect(),
        head: result.head,
        onto: result.onto,
    })
}

pub(crate) async fn query_git_integration_status(
    app_state: &SharedAppState,
    project: &str,
) -> Result<ServerMessage, String> {
    let proj_ctx = resolve_project(app_state, project)
        .await
        .map_err(|e| e.to_string())?;
    let project_name = proj_ctx.project_name;
    let default_branch = proj_ctx.default_branch;
    let result = tokio::task::spawn_blocking(move || {
        git::integration_status(&project_name, &default_branch)
    })
    .await
    .map_err(|e| format!("Integration status task failed: {}", e))?
    .map_err(|e| format!("Integration status failed: {}", e))?;

    Ok(ServerMessage::GitIntegrationStatusResult {
        project: project.to_string(),
        state: result.state.as_str().to_string(),
        conflicts: result.conflicts,
        conflict_files: result
            .conflict_files
            .iter()
            .map(|f| ConflictFileEntryInfo {
                path: f.path.clone(),
                conflict_type: f.conflict_type.clone(),
                staged: f.staged,
            })
            .collect(),
        head: result.head,
        default_branch: result.default_branch,
        path: result.path,
        is_clean: result.is_clean,
        branch_ahead_by: result.branch_ahead_by,
        branch_behind_by: result.branch_behind_by,
        compared_branch: result.compared_branch,
    })
}

pub(crate) async fn query_git_check_branch_up_to_date(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
) -> Result<ServerMessage, String> {
    let (proj_ctx, current_branch) = resolve_workspace_branch(app_state, project, workspace)
        .await
        .map_err(|e| e.to_string())?;

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
        return Ok(ServerMessage::GitIntegrationStatusResult {
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
        });
    }

    let default_branch = proj_ctx.default_branch.clone();
    let default_branch_clone = default_branch.clone();
    let current_branch_clone = current_branch.clone();

    let divergence_result = tokio::task::spawn_blocking(move || {
        git::check_branch_divergence(&root, &current_branch_clone, &default_branch_clone)
    })
    .await
    .map_err(|e| format!("Branch divergence task failed: {}", e))?
    .map_err(|e| format!("Branch divergence failed: {}", e))?;

    let integration_result = tokio::task::spawn_blocking({
        let project_name = project_name.clone();
        let default_branch = default_branch.clone();
        move || git::integration_status(&project_name, &default_branch)
    })
    .await
    .map_err(|e| format!("Integration status task failed: {}", e))?
    .map_err(|e| format!("Integration status failed: {}", e))?;

    Ok(ServerMessage::GitIntegrationStatusResult {
        project: project.to_string(),
        state: integration_result.state.as_str().to_string(),
        conflicts: integration_result.conflicts,
        conflict_files: integration_result
            .conflict_files
            .iter()
            .map(|f| ConflictFileEntryInfo {
                path: f.path.clone(),
                conflict_type: f.conflict_type.clone(),
                staged: f.staged,
            })
            .collect(),
        head: integration_result.head,
        default_branch: integration_result.default_branch,
        path: integration_result.path,
        is_clean: integration_result.is_clean,
        branch_ahead_by: Some(divergence_result.ahead_by),
        branch_behind_by: Some(divergence_result.behind_by),
        compared_branch: Some(current_branch),
    })
}

pub(crate) async fn query_git_conflict_detail(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
    path: &str,
    context: &str,
) -> Result<ServerMessage, String> {
    let root = if context == "integration" {
        let proj_ctx = resolve_project(app_state, project)
            .await
            .map_err(|e| e.to_string())?;
        git::get_integration_worktree_root(&proj_ctx.project_name)
    } else {
        resolve_workspace(app_state, project, workspace)
            .await
            .map_err(|e| e.to_string())?
            .root_path
    };

    let path_owned = path.to_string();
    let context_owned = context.to_string();
    let detail = tokio::task::spawn_blocking(move || {
        git::git_conflict_detail(&root, &path_owned, &context_owned)
    })
    .await
    .map_err(|e| format!("Conflict detail task failed: {}", e))?
    .map_err(|e| format!("Conflict detail failed: {}", e))?;

    Ok(ServerMessage::GitConflictDetailResult {
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
    })
}
