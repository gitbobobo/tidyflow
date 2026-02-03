//! State persistence for projects and workspaces

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum StateError {
    #[error("Failed to read state: {0}")]
    ReadError(String),
    #[error("Failed to write state: {0}")]
    WriteError(String),
    #[error("Failed to parse state: {0}")]
    ParseError(String),
    #[error("Project not found: {0}")]
    ProjectNotFound(String),
    #[error("Workspace not found: {0}")]
    WorkspaceNotFound(String),
}

/// 自定义终端命令
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomCommand {
    pub id: String,
    pub name: String,
    pub icon: String,  // SF Symbol 名称或自定义图标路径
    pub command: String,
}

/// 客户端设置
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ClientSettings {
    #[serde(default)]
    pub custom_commands: Vec<CustomCommand>,
    /// 工作空间快捷键映射：key 为 "0"-"9"，value 为 "projectName/workspaceName"
    #[serde(default)]
    pub workspace_shortcuts: HashMap<String, String>,
}

/// Application state - persisted to JSON
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppState {
    pub version: u32,
    pub projects: HashMap<String, Project>,
    #[serde(default)]
    pub last_updated: Option<DateTime<Utc>>,
    #[serde(default)]
    pub client_settings: ClientSettings,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            version: 1,
            projects: HashMap::new(),
            last_updated: Some(Utc::now()),
            client_settings: ClientSettings::default(),
        }
    }
}

/// Project metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub name: String,
    pub root_path: PathBuf,
    pub remote_url: Option<String>,
    pub default_branch: String,
    pub created_at: DateTime<Utc>,
    pub workspaces: HashMap<String, Workspace>,
}

/// Workspace metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workspace {
    pub name: String,
    pub worktree_path: PathBuf,
    pub branch: String,
    pub status: WorkspaceStatus,
    pub created_at: DateTime<Utc>,
    pub last_accessed: DateTime<Utc>,
    pub setup_result: Option<SetupResultSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceStatus {
    Creating,
    Initializing,
    Ready,
    SetupFailed,
    Destroying,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetupResultSummary {
    pub success: bool,
    pub steps_total: usize,
    pub steps_completed: usize,
    pub last_error: Option<String>,
    pub completed_at: DateTime<Utc>,
}

impl AppState {
    /// Get the state file path
    pub fn state_path() -> PathBuf {
        let home = dirs::home_dir().expect("Cannot find home directory");
        home.join(".tidyflow").join("tidyflow.json")
    }

    /// Load state from disk
    pub fn load() -> Result<Self, StateError> {
        let path = Self::state_path();
        if !path.exists() {
            return Ok(Self::default());
        }

        let content =
            fs::read_to_string(&path).map_err(|e| StateError::ReadError(e.to_string()))?;

        serde_json::from_str(&content).map_err(|e| StateError::ParseError(e.to_string()))
    }

    /// Save state to disk
    pub fn save(&mut self) -> Result<(), StateError> {
        let path = Self::state_path();

        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| StateError::WriteError(e.to_string()))?;
        }

        self.last_updated = Some(Utc::now());

        let content = serde_json::to_string_pretty(self)
            .map_err(|e| StateError::WriteError(e.to_string()))?;

        fs::write(&path, content).map_err(|e| StateError::WriteError(e.to_string()))
    }

    /// Add a project
    pub fn add_project(&mut self, project: Project) {
        self.projects.insert(project.name.clone(), project);
    }

    /// Get a project by name
    pub fn get_project(&self, name: &str) -> Option<&Project> {
        self.projects.get(name)
    }

    /// Get a mutable project by name
    pub fn get_project_mut(&mut self, name: &str) -> Option<&mut Project> {
        self.projects.get_mut(name)
    }

    /// Remove a project
    pub fn remove_project(&mut self, name: &str) -> Option<Project> {
        self.projects.remove(name)
    }

    /// List all project names
    pub fn list_projects(&self) -> Vec<&str> {
        self.projects.keys().map(|s| s.as_str()).collect()
    }
}

impl Project {
    /// Add a workspace to this project
    pub fn add_workspace(&mut self, workspace: Workspace) {
        self.workspaces.insert(workspace.name.clone(), workspace);
    }

    /// Get a workspace by name
    pub fn get_workspace(&self, name: &str) -> Option<&Workspace> {
        self.workspaces.get(name)
    }

    /// Get a mutable workspace by name
    pub fn get_workspace_mut(&mut self, name: &str) -> Option<&mut Workspace> {
        self.workspaces.get_mut(name)
    }

    /// Remove a workspace
    pub fn remove_workspace(&mut self, name: &str) -> Option<Workspace> {
        self.workspaces.remove(name)
    }

    /// List all workspace names
    pub fn list_workspaces(&self) -> Vec<&str> {
        self.workspaces.keys().map(|s| s.as_str()).collect()
    }

    /// Get the worktrees directory for this project
    pub fn worktrees_dir(&self) -> PathBuf {
        dirs::home_dir()
            .expect("Cannot find home directory")
            .join(".tidyflow")
            .join("workspaces")
    }
}
