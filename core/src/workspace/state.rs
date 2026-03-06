//! State persistence for projects and workspaces

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
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

/// 项目级命令（后台任务）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectCommand {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub command: String,
    #[serde(default)]
    pub blocking: bool,
    /// 交互式命令：在新终端 Tab 中执行（前台任务），而非后台任务
    #[serde(default)]
    pub interactive: bool,
}

/// 自定义终端命令
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomCommand {
    pub id: String,
    pub name: String,
    pub icon: String, // SF Symbol 名称或自定义图标路径
    pub command: String,
}

/// Evolution 阶段代理模型选择
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionModelSelection {
    pub provider_id: String,
    pub model_id: String,
}

/// Evolution 单阶段代理配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionStageProfile {
    pub stage: String,
    #[serde(default = "default_evolution_ai_tool")]
    pub ai_tool: String,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub model: Option<EvolutionModelSelection>,
    #[serde(default)]
    pub config_options: HashMap<String, serde_json::Value>,
}

/// 快捷键绑定配置
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct KeybindingConfig {
    pub command_id: String,
    pub key_combination: String,
    pub context: String,
}

/// 工作空间待办项
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceTodoItem {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub note: Option<String>,
    /// pending | in_progress | completed
    pub status: String,
    pub order: i64,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

/// 工作流模板命令
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemplateCommand {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub command: String,
    #[serde(default)]
    pub blocking: bool,
    #[serde(default)]
    pub interactive: bool,
}

/// 工作流模板
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowTemplate {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    /// 技术栈标签，如 "rust", "node", "go", "python"
    #[serde(default)]
    pub tags: Vec<String>,
    pub commands: Vec<TemplateCommand>,
    /// 环境变量 key=value
    #[serde(default)]
    pub env_vars: Vec<(String, String)>,
    /// 是否为内置模板（内置模板不可删除）
    #[serde(default)]
    pub builtin: bool,
}

/// 客户端设置
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ClientSettings {
    #[serde(default)]
    pub custom_commands: Vec<CustomCommand>,
    /// 工作空间快捷键映射：key 为 "0"-"9"，value 为 "projectName/workspaceName"
    #[serde(default)]
    pub workspace_shortcuts: HashMap<String, String>,
    /// 用于合并操作的 AI Agent
    #[serde(default)]
    pub merge_ai_agent: Option<String>,
    /// 固定端口，0 表示动态分配
    #[serde(default)]
    pub fixed_port: u16,
    /// 是否开启远程访问（开启后 Core 绑定 0.0.0.0）
    #[serde(default)]
    pub remote_access_enabled: bool,
    /// Evolution 代理配置（key: "project/workspace"）
    #[serde(default)]
    pub evolution_agent_profiles: HashMap<String, Vec<EvolutionStageProfile>>,
    /// 工作空间待办（key: "project:workspace"）
    #[serde(default)]
    pub workspace_todos: HashMap<String, Vec<WorkspaceTodoItem>>,
    /// 快捷键绑定配置
    #[serde(default)]
    pub keybindings: Vec<KeybindingConfig>,
    /// 工作流模板
    #[serde(default)]
    pub templates: Vec<WorkflowTemplate>,
}

fn default_evolution_ai_tool() -> String {
    "codex".to_string()
}

impl ClientSettings {
    /// 预留迁移入口（当前无需迁移逻辑）
    pub fn migrate(&mut self) {}
}

/// 移动端配对 token 持久化条目
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersistedTokenEntry {
    pub token_id: String,
    pub ws_token: String,
    pub device_name: String,
    pub issued_at_unix: u64,
    pub expires_at_unix: u64,
}

/// Application state - 持久化由 StateStore（SQLite）负责
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppState {
    pub version: u32,
    pub projects: HashMap<String, Project>,
    #[serde(default)]
    pub last_updated: Option<DateTime<Utc>>,
    #[serde(default)]
    pub client_settings: ClientSettings,
    #[serde(default)]
    pub paired_tokens: Vec<PersistedTokenEntry>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            version: 1,
            projects: HashMap::new(),
            last_updated: Some(Utc::now()),
            client_settings: ClientSettings::default(),
            paired_tokens: Vec::new(),
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
    /// 项目级命令配置
    #[serde(default)]
    pub commands: Vec<ProjectCommand>,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_settings_should_ignore_removed_implement_profiles_field() {
        let parsed: ClientSettings = serde_json::from_value(serde_json::json!({
            "custom_commands": [],
            "workspace_shortcuts": {},
            "evolution_implement_agent_profiles": {
                "general": { "ai_tool": "codex" },
                "visual": { "ai_tool": "opencode" },
                "advanced": { "ai_tool": "copilot" }
            }
        }))
        .expect("deserialize client settings should succeed");

        assert!(parsed.custom_commands.is_empty());
        assert!(parsed.workspace_shortcuts.is_empty());
    }
}
