//! Workspace management using git worktree

use crate::workspace::config::ProjectConfig;
use crate::workspace::setup::SetupExecutor;
use crate::workspace::state::{
    AppState, SetupResultSummary, StateError, Workspace, WorkspaceStatus,
};
use chrono::Utc;
use petname::{Generator, Petnames};
use std::path::{Path, PathBuf};
use std::process::Command;
use thiserror::Error;
use tracing::{error, info, warn};

#[derive(Error, Debug)]
pub enum WorkspaceError {
    #[error("Project not found: {0}")]
    ProjectNotFound(String),
    #[error("Workspace already exists: {0}")]
    AlreadyExists(String),
    #[error("Workspace not found: {0}")]
    NotFound(String),
    #[error("Git operation failed: {0}")]
    GitError(String),
    #[error("Not a git repository: {0}")]
    NotGitRepo(String),
    #[error("State error: {0}")]
    StateError(#[from] StateError),
    #[error("IO error: {0}")]
    IoError(String),
    #[error("Setup failed: {0}")]
    SetupFailed(String),
}

pub struct WorkspaceManager;

impl WorkspaceManager {
    /// Create a new workspace using git worktree.
    /// 名称由 Core 用 petname 生成唯一名。
    pub fn create(
        state: &mut AppState,
        project_name: &str,
        from_branch: Option<&str>,
        run_setup: bool,
    ) -> Result<Workspace, WorkspaceError> {
        // Get project
        let project = state
            .get_project(project_name)
            .ok_or_else(|| WorkspaceError::ProjectNotFound(project_name.to_string()))?;

        // 检查项目根目录是否为 Git 仓库
        if !project.root_path.join(".git").exists() {
            return Err(WorkspaceError::NotGitRepo(format!(
                "项目 '{}' 的根目录不是 Git 仓库，无法创建工作空间。请先在项目目录中运行 git init 初始化仓库。",
                project_name
            )));
        }

        // 检查项目是否有 remote URL，没有则不允许创建工作空间
        if project.remote_url.is_none() {
            return Err(WorkspaceError::GitError(
                "项目没有配置 Git 远程仓库，无法创建工作空间。请先运行 git remote add origin <url> 添加远程仓库。".to_string()
            ));
        }

        let project_root = project.root_path.clone();
        let default_branch = project.default_branch.clone();

        // Determine source branch
        let source_branch = from_branch.unwrap_or(&default_branch);

        // Check if source branch exists locally
        let branch_check = Command::new("git")
            .args([
                "rev-parse",
                "--verify",
                &format!("refs/heads/{}", source_branch),
            ])
            .current_dir(&project_root)
            .output();

        let source_branch_exists = matches!(branch_check, Ok(ref out) if out.status.success());

        if !source_branch_exists {
            return Err(WorkspaceError::GitError(format!(
                "源分支 '{}' 不存在，无法创建工作空间。请确保仓库中存在该分支。",
                source_branch
            )));
        }

        // Generate random branch name with retry on conflict (branch or workspace name)
        let mut workspace_branch = format!("tidy/{}", Self::generate_random_branch_name());
        let mut attempts = 0;
        const MAX_ATTEMPTS: u32 = 5;

        let workspace_display_name = loop {
            let display = workspace_branch
                .strip_prefix("tidy/")
                .unwrap_or(&workspace_branch)
                .to_string();

            let branch_exists = Command::new("git")
                .args([
                    "show-ref",
                    "--quiet",
                    "--verify",
                    &format!("refs/heads/{}", workspace_branch),
                ])
                .current_dir(&project_root)
                .output();
            let branch_exists = matches!(branch_exists, Ok(ref out) if out.status.success());

            let name_exists = state
                .get_project(project_name)
                .map(|p| p.get_workspace(&display).is_some())
                .unwrap_or(false);

            if !branch_exists && !name_exists {
                break display;
            }
            workspace_branch = format!("tidy/{}", Self::generate_random_branch_name());
            attempts += 1;
            if attempts >= MAX_ATTEMPTS {
                return Err(WorkspaceError::GitError(format!(
                    "Failed to generate unique workspace name after {} attempts",
                    MAX_ATTEMPTS
                )));
            }
        };

        let worktrees_dir = project.worktrees_dir();
        std::fs::create_dir_all(&worktrees_dir)
            .map_err(|e| WorkspaceError::IoError(e.to_string()))?;

        let worktree_path = worktrees_dir.join(&workspace_display_name);

        // Create the worktree with a new branch
        let output = Command::new("git")
            .args([
                "worktree",
                "add",
                "-b",
                &workspace_branch,
                worktree_path.to_str().unwrap(),
                source_branch,
            ])
            .current_dir(&project_root)
            .output()
            .map_err(|e| WorkspaceError::GitError(e.to_string()))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            // If branch already exists, try without -b
            if stderr.contains("already exists") {
                let output = Command::new("git")
                    .args([
                        "worktree",
                        "add",
                        worktree_path.to_str().unwrap(),
                        &workspace_branch,
                    ])
                    .current_dir(&project_root)
                    .output()
                    .map_err(|e| WorkspaceError::GitError(e.to_string()))?;

                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(WorkspaceError::GitError(stderr.to_string()));
                }
            } else {
                return Err(WorkspaceError::GitError(stderr.to_string()));
            }
        }

        info!(
            project = project_name,
            workspace = workspace_display_name,
            branch = workspace_branch,
            "Worktree created"
        );

        let mut workspace = Workspace {
            name: workspace_display_name.clone(),
            worktree_path: worktree_path.clone(),
            branch: workspace_branch,
            status: WorkspaceStatus::Creating,
            created_at: Utc::now(),
            last_accessed: Utc::now(),
            setup_result: None,
        };

        // Update state
        {
            let project = state.get_project_mut(project_name).unwrap();
            project.add_workspace(workspace.clone());
        }
        state.save()?;

        // Run setup if requested
        if run_setup {
            workspace = Self::run_setup_internal(
                state,
                project_name,
                &workspace_display_name,
                &worktree_path,
            )?;
        } else {
            // Mark as ready if no setup
            let project = state.get_project_mut(project_name).unwrap();
            if let Some(ws) = project.get_workspace_mut(&workspace_display_name) {
                ws.status = WorkspaceStatus::Ready;
                workspace.status = WorkspaceStatus::Ready;
            }
            state.save()?;
        }

        Ok(workspace)
    }

    /// Run setup for an existing workspace
    pub fn run_setup(
        state: &mut AppState,
        project_name: &str,
        workspace_name: &str,
    ) -> Result<Workspace, WorkspaceError> {
        let project = state
            .get_project(project_name)
            .ok_or_else(|| WorkspaceError::ProjectNotFound(project_name.to_string()))?;

        let workspace = project
            .get_workspace(workspace_name)
            .ok_or_else(|| WorkspaceError::NotFound(workspace_name.to_string()))?;

        let worktree_path = workspace.worktree_path.clone();

        Self::run_setup_internal(state, project_name, workspace_name, &worktree_path)
    }

    fn run_setup_internal(
        state: &mut AppState,
        project_name: &str,
        workspace_name: &str,
        worktree_path: &Path,
    ) -> Result<Workspace, WorkspaceError> {
        // Update status to Initializing
        {
            let project = state.get_project_mut(project_name).unwrap();
            if let Some(ws) = project.get_workspace_mut(workspace_name) {
                ws.status = WorkspaceStatus::Initializing;
            }
        }
        state.save()?;

        // Load config and run setup
        let config = ProjectConfig::load(worktree_path).unwrap_or_default();
        let result = SetupExecutor::execute(&config, worktree_path);

        // Update workspace with result
        let project = state.get_project_mut(project_name).unwrap();
        let workspace = project.get_workspace_mut(workspace_name).unwrap();

        let summary = SetupResultSummary {
            success: result.success,
            steps_total: result.steps.len(),
            steps_completed: result.steps.iter().filter(|s| s.success).count(),
            last_error: result.steps.iter().rev().find(|s| !s.success).map(|s| {
                s.stderr
                    .clone()
                    .unwrap_or_else(|| "Unknown error".to_string())
            }),
            completed_at: Utc::now(),
        };

        workspace.setup_result = Some(summary);
        workspace.status = if result.success {
            WorkspaceStatus::Ready
        } else {
            WorkspaceStatus::SetupFailed
        };
        workspace.last_accessed = Utc::now();

        let ws_clone = workspace.clone();
        state.save()?;

        if result.success {
            info!(
                project = project_name,
                workspace = workspace_name,
                "Setup completed successfully"
            );
        } else {
            warn!(
                project = project_name,
                workspace = workspace_name,
                "Setup failed"
            );
        }

        Ok(ws_clone)
    }

    fn generate_random_branch_name() -> String {
        Petnames::default()
            .generate_one(2, "-")
            .expect("Failed to generate branch name")
    }

    /// Remove a workspace
    pub fn remove(
        state: &mut AppState,
        project_name: &str,
        workspace_name: &str,
    ) -> Result<(), WorkspaceError> {
        let project = state
            .get_project(project_name)
            .ok_or_else(|| WorkspaceError::ProjectNotFound(project_name.to_string()))?;

        let workspace = project
            .get_workspace(workspace_name)
            .ok_or_else(|| WorkspaceError::NotFound(workspace_name.to_string()))?;

        let worktree_path = workspace.worktree_path.clone();
        let project_root = project.root_path.clone();

        // Remove git worktree
        let output = Command::new("git")
            .args([
                "worktree",
                "remove",
                "--force",
                worktree_path.to_str().unwrap(),
            ])
            .current_dir(&project_root)
            .output()
            .map_err(|e| WorkspaceError::GitError(e.to_string()))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            error!(error = %stderr, "Failed to remove worktree");
            // Continue anyway to clean up state
        }

        // Remove from state
        let project = state.get_project_mut(project_name).unwrap();
        project.remove_workspace(workspace_name);
        state.save()?;

        info!(
            project = project_name,
            workspace = workspace_name,
            "Workspace removed"
        );

        Ok(())
    }

    /// Get workspace root path
    pub fn get_root_path(
        state: &AppState,
        project_name: &str,
        workspace_name: &str,
    ) -> Result<PathBuf, WorkspaceError> {
        let project = state
            .get_project(project_name)
            .ok_or_else(|| WorkspaceError::ProjectNotFound(project_name.to_string()))?;

        let workspace = project
            .get_workspace(workspace_name)
            .ok_or_else(|| WorkspaceError::NotFound(workspace_name.to_string()))?;

        Ok(workspace.worktree_path.clone())
    }
}
