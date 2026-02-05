//! Project management - import from local path or git clone

use crate::workspace::config::ProjectConfig;
use crate::workspace::state::{AppState, Project, StateError};
use chrono::Utc;
use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use thiserror::Error;
use tracing::{info, warn};

#[derive(Error, Debug)]
pub enum ProjectError {
    #[error("Project already exists: {0}")]
    AlreadyExists(String),
    #[error("Path does not exist: {0}")]
    PathNotFound(String),
    #[error("Not a git repository: {0}")]
    NotGitRepo(String),
    #[error("Git operation failed: {0}")]
    GitError(String),
    #[error("State error: {0}")]
    StateError(#[from] StateError),
    #[error("IO error: {0}")]
    IoError(String),
}

pub struct ProjectManager;

impl ProjectManager {
    /// Import a project from a local path
    pub fn import_local(
        state: &mut AppState,
        name: &str,
        path: &Path,
    ) -> Result<Project, ProjectError> {
        // Check if project already exists
        if state.get_project(name).is_some() {
            return Err(ProjectError::AlreadyExists(name.to_string()));
        }

        // Validate path exists
        let abs_path = path
            .canonicalize()
            .map_err(|_| ProjectError::PathNotFound(path.display().to_string()))?;

        // Load project config
        let config = ProjectConfig::load(&abs_path).unwrap_or_default();

        // Get default branch from git
        let default_branch = Self::get_default_branch(&abs_path)
            .unwrap_or_else(|| config.project.default_branch.clone());

        // Get remote URL if available
        let remote_url = Self::get_remote_url(&abs_path);

        let project = Project {
            name: name.to_string(),
            root_path: abs_path,
            remote_url,
            default_branch,
            created_at: Utc::now(),
            workspaces: HashMap::new(),
        };

        state.add_project(project.clone());
        state.save()?;

        info!(project = name, "Project imported successfully");
        Ok(project)
    }

    /// Import a project by cloning from a git URL
    pub fn import_git(
        state: &mut AppState,
        name: &str,
        url: &str,
        branch: Option<&str>,
        target_dir: Option<&Path>,
    ) -> Result<Project, ProjectError> {
        // Check if project already exists
        if state.get_project(name).is_some() {
            return Err(ProjectError::AlreadyExists(name.to_string()));
        }

        // Determine target directory
        let base_dir = target_dir.map(|p| p.to_path_buf()).unwrap_or_else(|| {
            dirs::home_dir()
                .expect("Cannot find home directory")
                .join("Projects")
        });

        let clone_path = base_dir.join(name);

        // Create parent directory if needed
        std::fs::create_dir_all(&base_dir).map_err(|e| ProjectError::IoError(e.to_string()))?;

        // Clone the repository
        let mut cmd = Command::new("git");
        cmd.arg("clone");
        if let Some(b) = branch {
            cmd.arg("--branch").arg(b);
        }
        cmd.arg(url).arg(&clone_path);

        let output = cmd
            .output()
            .map_err(|e| ProjectError::GitError(e.to_string()))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(ProjectError::GitError(stderr.to_string()));
        }

        info!(project = name, url = url, "Repository cloned successfully");

        // Now import as local
        Self::import_local(state, name, &clone_path)
    }

    /// Get the default branch from git
    fn get_default_branch(repo_path: &Path) -> Option<String> {
        // Try to get from remote HEAD
        let output = Command::new("git")
            .args(["symbolic-ref", "refs/remotes/origin/HEAD", "--short"])
            .current_dir(repo_path)
            .output()
            .ok()?;

        if output.status.success() {
            let branch = String::from_utf8_lossy(&output.stdout)
                .trim()
                .strip_prefix("origin/")
                .unwrap_or("main")
                .to_string();
            return Some(branch);
        }

        // Fallback: try to get current branch
        let output = Command::new("git")
            .args(["branch", "--show-current"])
            .current_dir(repo_path)
            .output()
            .ok()?;

        if output.status.success() {
            let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !branch.is_empty() {
                return Some(branch);
            }
        }

        None
    }

    /// Get the remote URL from git
    fn get_remote_url(repo_path: &Path) -> Option<String> {
        let output = Command::new("git")
            .args(["remote", "get-url", "origin"])
            .current_dir(repo_path)
            .output()
            .ok()?;

        if output.status.success() {
            let url = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !url.is_empty() {
                return Some(url);
            }
        }

        None
    }

    pub fn remove(state: &mut AppState, name: &str) -> Result<(), ProjectError> {
        let project = state.get_project(name).ok_or_else(|| {
            ProjectError::StateError(StateError::ProjectNotFound(name.to_string()))
        })?;

        let project_workspaces_dir = dirs::home_dir()
            .expect("Cannot find home directory")
            .join(".tidyflow")
            .join("workspaces")
            .join(name);

        for (workspace_name, workspace) in &project.workspaces {
            let workspace_path = project_workspaces_dir.join(workspace_name);
            if workspace_path.exists() {
                if let Err(e) = std::fs::remove_dir_all(&workspace_path) {
                    warn!(project = name, workspace = workspace_name, path = %workspace_path.display(), error = %e, "Failed to remove workspace directory");
                } else {
                    info!(project = name, workspace = workspace_name, path = %workspace_path.display(), "Workspace directory removed");
                }
            }

            let git_worktree_path = &workspace.worktree_path;
            if git_worktree_path.exists() && git_worktree_path != &workspace_path {
                if let Err(e) = std::fs::remove_dir_all(git_worktree_path) {
                    warn!(project = name, workspace = workspace_name, path = %git_worktree_path.display(), error = %e, "Failed to remove git worktree directory");
                } else {
                    info!(project = name, workspace = workspace_name, path = %git_worktree_path.display(), "Git worktree directory removed");
                }
            }
        }

        if project_workspaces_dir.exists() {
            if let Err(e) = std::fs::remove_dir(&project_workspaces_dir) {
                warn!(project = name, path = %project_workspaces_dir.display(), error = %e, "Failed to remove project workspaces directory");
            } else {
                info!(project = name, path = %project_workspaces_dir.display(), "Project workspaces directory removed");
            }
        }

        if state.remove_project(name).is_none() {
            return Err(ProjectError::StateError(StateError::ProjectNotFound(
                name.to_string(),
            )));
        }

        state.save()?;

        info!(project = name, "Project removed from TidyFlow");
        Ok(())
    }
}
