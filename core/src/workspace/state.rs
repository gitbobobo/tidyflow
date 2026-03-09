//! State persistence for projects and workspaces
//!
//! ## 工作区生命周期语义
//!
//! ### `default` 虚拟工作区
//! 每个项目都有一个名为 `default` 的**虚拟工作区**，指向项目根目录，
//! 状态始终为 `Ready`。该工作区不持久化到 `Project.workspaces` HashMap，
//! 由 `list_workspaces` 和 `system_snapshot` 在查询时动态注入。
//! 客户端不得假设 `default` 工作区需要由客户端本地生成，
//! 所有工作区列表均由 Core 权威输出。
//!
//! ### 命名工作区生命周期状态（`WorkspaceStatus`）
//! ```text
//! Creating → Initializing → Ready
//!                         ↘ SetupFailed
//! (任意状态) → Destroying
//! ```
//! - `Creating`：git worktree 已创建，尚未执行 setup
//! - `Initializing`：setup 脚本执行中
//! - `Ready`：完全就绪，可以使用
//! - `SetupFailed`：setup 失败，需要手动修复
//! - `Destroying`：已标记删除，不应再接受新的操作

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use thiserror::Error;

/// 虚拟默认工作区名称。
/// 每个项目都有一个不持久化的 `default` 工作区，指向项目根目录，状态始终为 `Ready`。
/// Core 在 `list_workspaces` 与 `system_snapshot` 输出时动态注入，客户端不得本地重建该工作区。
pub const DEFAULT_WORKSPACE_NAME: &str = "default";

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
    /// Evolution 全局默认配置
    #[serde(default)]
    pub evolution_default_profiles: Vec<EvolutionStageProfile>,
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

    /// 更新指定工作区的 last_accessed 时间戳。
    /// 在工作区被选中（切换）时调用，供资源管理器按 LRU 顺序释放非活跃工作区缓存。
    /// 若项目或工作区不存在则静默忽略（`default` 虚拟工作区无需持久化，跳过）。
    pub fn touch_workspace_last_accessed(&mut self, project: &str, workspace: &str) {
        if workspace == DEFAULT_WORKSPACE_NAME {
            return;
        }
        if let Some(proj) = self.get_project_mut(project) {
            if let Some(ws) = proj.get_workspace_mut(workspace) {
                ws.last_accessed = chrono::Utc::now();
            }
        }
    }

    /// 返回所有命名工作区（不含 default 虚拟工作区），按 last_accessed 升序排列（最旧的在前）。
    /// 用于资源管理器决定哪些工作区可以优先回收缓存。
    pub fn workspaces_sorted_by_last_accessed(&self) -> Vec<(&str, &str, &Workspace)> {
        let mut entries: Vec<(&str, &str, &Workspace)> = self
            .projects
            .values()
            .flat_map(|p| {
                p.workspaces
                    .values()
                    .map(move |w| (p.name.as_str(), w.name.as_str(), w))
            })
            .collect();
        entries.sort_by_key(|(_, _, w)| w.last_accessed);
        entries
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
    use chrono::Utc;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::time::Duration;

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

    fn create_test_project(name: &str) -> Project {
        Project {
            name: name.to_string(),
            root_path: PathBuf::from("/tmp/test"),
            remote_url: Some("https://github.com/test/test.git".to_string()),
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: HashMap::new(),
            commands: vec![],
        }
    }

    fn create_test_workspace(name: &str) -> Workspace {
        Workspace {
            name: name.to_string(),
            worktree_path: PathBuf::from("/tmp/test/ws"),
            branch: "feature/test".to_string(),
            status: WorkspaceStatus::Ready,
            created_at: Utc::now(),
            last_accessed: Utc::now(),
            setup_result: None,
        }
    }

    #[test]
    fn app_state_default_shape_is_stable() {
        let state = AppState::default();
        assert_eq!(state.version, 1);
        assert!(state.projects.is_empty());
        assert!(state.client_settings.custom_commands.is_empty());
        assert!(state.paired_tokens.is_empty());
    }

    #[test]
    fn app_state_add_and_remove_project() {
        let mut state = AppState::default();
        let project = create_test_project("test-project");

        state.add_project(project);
        assert_eq!(state.projects.len(), 1);
        assert!(state.get_project("test-project").is_some());

        let removed = state.remove_project("test-project");
        assert!(removed.is_some());
        assert!(state.projects.is_empty());
    }

    #[test]
    fn app_state_remove_nonexistent_returns_none() {
        let mut state = AppState::default();
        let removed = state.remove_project("nonexistent");
        assert!(removed.is_none());
    }

    #[test]
    fn app_state_lists_and_mutates_projects() {
        let mut state = AppState::default();
        state.add_project(create_test_project("project-a"));
        state.add_project(create_test_project("project-b"));

        let list = state.list_projects();
        assert_eq!(list.len(), 2);

        let project = state.get_project_mut("project-a").unwrap();
        project.default_branch = "develop".to_string();

        assert_eq!(
            state.get_project("project-a").unwrap().default_branch,
            "develop"
        );
    }

    #[test]
    fn project_workspace_lifecycle_helpers_work() {
        let mut project = create_test_project("test-project");
        let workspace = create_test_workspace("feature-1");

        project.add_workspace(workspace);
        assert_eq!(project.workspaces.len(), 1);
        assert!(project.get_workspace("feature-1").is_some());
        assert_eq!(project.list_workspaces().len(), 1);

        let removed = project.remove_workspace("feature-1");
        assert!(removed.is_some());
        assert!(project.workspaces.is_empty());
    }

    #[test]
    fn project_worktrees_dir_points_to_tidyflow_storage() {
        let project = create_test_project("test-project");
        let dir = project.worktrees_dir();

        assert!(dir.to_string_lossy().contains(".tidyflow"));
        assert!(dir.to_string_lossy().contains("workspaces"));
    }

    #[test]
    fn workspace_status_roundtrip_covers_all_variants() {
        let variants = vec![
            WorkspaceStatus::Creating,
            WorkspaceStatus::Initializing,
            WorkspaceStatus::Ready,
            WorkspaceStatus::SetupFailed,
            WorkspaceStatus::Destroying,
        ];

        for status in variants {
            let json = serde_json::to_string(&status).unwrap();
            let parsed: WorkspaceStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(parsed, status);
        }
    }

    #[test]
    fn client_settings_and_related_models_roundtrip() {
        let mut settings = ClientSettings::default();
        settings.custom_commands.push(CustomCommand {
            id: "cmd-1".to_string(),
            name: "Test Command".to_string(),
            icon: "terminal".to_string(),
            command: "echo test".to_string(),
        });
        settings
            .workspace_shortcuts
            .insert("1".to_string(), "project/workspace".to_string());
        settings.evolution_agent_profiles.insert(
            "project/workspace".to_string(),
            vec![EvolutionStageProfile {
                stage: "direction".to_string(),
                ai_tool: "codex".to_string(),
                mode: Some("auto".to_string()),
                model: None,
                config_options: HashMap::new(),
            }],
        );

        assert_eq!(settings.custom_commands.len(), 1);
        assert_eq!(
            settings.workspace_shortcuts.get("1"),
            Some(&"project/workspace".to_string())
        );
        assert_eq!(settings.evolution_agent_profiles.len(), 1);
    }

    #[test]
    fn supporting_models_keep_expected_fields() {
        let todo = WorkspaceTodoItem {
            id: "todo-1".to_string(),
            title: "Implement feature".to_string(),
            note: Some("Important".to_string()),
            status: "in_progress".to_string(),
            order: 1,
            created_at_ms: 1000,
            updated_at_ms: 2000,
        };
        assert_eq!(todo.status, "in_progress");
        assert_eq!(todo.order, 1);

        let cmd = ProjectCommand {
            id: "cmd-1".to_string(),
            name: "Build".to_string(),
            icon: "hammer".to_string(),
            command: "npm run build".to_string(),
            blocking: true,
            interactive: false,
        };
        assert!(cmd.blocking);
        assert!(!cmd.interactive);

        let entry = PersistedTokenEntry {
            token_id: "token-123".to_string(),
            ws_token: "secret-token".to_string(),
            device_name: "iPhone".to_string(),
            issued_at_unix: 1000,
            expires_at_unix: 2000,
        };
        assert_eq!(entry.token_id, "token-123");
        assert!(entry.expires_at_unix > entry.issued_at_unix);

        let summary = SetupResultSummary {
            success: true,
            steps_total: 5,
            steps_completed: 5,
            last_error: None,
            completed_at: Utc::now(),
        };
        assert!(summary.success);
        assert_eq!(summary.steps_total, summary.steps_completed);
    }

    #[test]
    fn state_models_json_roundtrip() {
        let state = AppState::default();
        let state_json = serde_json::to_string(&state).unwrap();
        let parsed_state: AppState = serde_json::from_str(&state_json).unwrap();
        assert_eq!(parsed_state.version, state.version);
        assert_eq!(parsed_state.projects.len(), state.projects.len());

        let project = create_test_project("demo");
        let project_json = serde_json::to_string(&project).unwrap();
        let parsed_project: Project = serde_json::from_str(&project_json).unwrap();
        assert_eq!(parsed_project.name, project.name);
        assert_eq!(parsed_project.default_branch, project.default_branch);

        let workspace = create_test_workspace("feature-1");
        let workspace_json = serde_json::to_string(&workspace).unwrap();
        let parsed_workspace: Workspace = serde_json::from_str(&workspace_json).unwrap();
        assert_eq!(parsed_workspace.name, workspace.name);
        assert_eq!(parsed_workspace.status, workspace.status);
    }

    fn make_project_with_workspaces(
        name: &str,
        workspace_names: &[(&str, WorkspaceStatus)],
    ) -> Project {
        let mut workspaces = HashMap::new();
        for (ws_name, status) in workspace_names {
            workspaces.insert(
                ws_name.to_string(),
                Workspace {
                    name: ws_name.to_string(),
                    worktree_path: format!("/tmp/{name}/ws/{ws_name}").into(),
                    branch: format!("tidy/{ws_name}"),
                    status: status.clone(),
                    created_at: Utc::now(),
                    last_accessed: Utc::now(),
                    setup_result: None,
                },
            );
        }
        Project {
            name: name.to_string(),
            root_path: format!("/tmp/{name}").into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces,
            commands: vec![],
        }
    }

    #[test]
    fn default_workspace_semantics_are_stable() {
        assert_eq!(DEFAULT_WORKSPACE_NAME, "default");

        let project =
            make_project_with_workspaces("demo", &[("feature-x", WorkspaceStatus::Ready)]);
        assert!(project.get_workspace(DEFAULT_WORKSPACE_NAME).is_none());
        assert!(project.get_workspace("feature-x").is_some());
    }

    #[test]
    fn workspace_status_serializes_to_snake_case() {
        let cases: &[(WorkspaceStatus, &str)] = &[
            (WorkspaceStatus::Ready, "ready"),
            (WorkspaceStatus::Creating, "creating"),
            (WorkspaceStatus::Initializing, "initializing"),
            (WorkspaceStatus::SetupFailed, "setup_failed"),
            (WorkspaceStatus::Destroying, "destroying"),
        ];

        for (status, expected) in cases {
            let json = serde_json::to_string(status).unwrap();
            assert_eq!(json, format!("\"{expected}\""));
        }
    }

    #[test]
    fn default_workspace_is_sorted_before_named_workspaces() {
        let named_workspaces = vec!["alpha".to_string(), "zebra".to_string()];
        let mut all_workspaces = vec![DEFAULT_WORKSPACE_NAME.to_string()];
        let mut sorted_named = named_workspaces.clone();
        sorted_named.sort();
        all_workspaces.extend(sorted_named);

        assert_eq!(
            all_workspaces.first().map(|s| s.as_str()),
            Some(DEFAULT_WORKSPACE_NAME)
        );
        assert_eq!(all_workspaces, vec!["default", "alpha", "zebra"]);
    }

    fn make_project(name: &str, workspaces: &[&str]) -> Project {
        let ws_map: HashMap<String, Workspace> = workspaces
            .iter()
            .map(|&ws_name| {
                let ws = Workspace {
                    name: ws_name.to_string(),
                    worktree_path: format!("/tmp/{name}/ws/{ws_name}").into(),
                    branch: format!("tidy/{ws_name}"),
                    status: WorkspaceStatus::Ready,
                    created_at: Utc::now(),
                    last_accessed: Utc::now(),
                    setup_result: None,
                };
                (ws_name.to_string(), ws)
            })
            .collect();
        Project {
            name: name.to_string(),
            root_path: format!("/tmp/{name}").into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: ws_map,
            commands: vec![],
        }
    }

    #[test]
    fn same_workspace_name_in_different_projects_has_different_paths() {
        let proj_a = make_project("project-a", &["feature"]);
        let proj_b = make_project("project-b", &["feature"]);

        let ws_a = proj_a.get_workspace("feature").unwrap();
        let ws_b = proj_b.get_workspace("feature").unwrap();

        assert_ne!(ws_a.worktree_path, ws_b.worktree_path);
    }

    #[test]
    fn touch_workspace_last_accessed_updates_only_target() {
        let mut state = AppState::default();
        state.add_project(make_project("proj-a", &["ws1", "ws2"]));
        state.add_project(make_project("proj-b", &["ws1"]));

        let before_a_ws2 = state
            .get_project("proj-a")
            .unwrap()
            .get_workspace("ws2")
            .unwrap()
            .last_accessed;
        let before_b_ws1 = state
            .get_project("proj-b")
            .unwrap()
            .get_workspace("ws1")
            .unwrap()
            .last_accessed;

        std::thread::sleep(Duration::from_millis(5));
        state.touch_workspace_last_accessed("proj-a", "ws1");

        let after_a_ws1 = state
            .get_project("proj-a")
            .unwrap()
            .get_workspace("ws1")
            .unwrap()
            .last_accessed;
        let after_a_ws2 = state
            .get_project("proj-a")
            .unwrap()
            .get_workspace("ws2")
            .unwrap()
            .last_accessed;
        let after_b_ws1 = state
            .get_project("proj-b")
            .unwrap()
            .get_workspace("ws1")
            .unwrap()
            .last_accessed;

        assert!(after_a_ws1 >= before_a_ws2);
        assert_eq!(before_a_ws2, after_a_ws2);
        assert_eq!(before_b_ws1, after_b_ws1);
    }

    #[test]
    fn touch_default_or_missing_workspace_is_no_op() {
        let mut state = AppState::default();
        state.add_project(make_project("proj", &["ws1"]));

        state.touch_workspace_last_accessed("proj", DEFAULT_WORKSPACE_NAME);
        state.touch_workspace_last_accessed("no-such-project", "ws1");
        state.touch_workspace_last_accessed("proj", "no-such-workspace");

        assert!(state
            .get_project("proj")
            .unwrap()
            .get_workspace("ws1")
            .is_some());
    }

    #[test]
    fn workspaces_sorted_by_last_accessed_returns_all_named_workspaces() {
        let mut state = AppState::default();
        state.add_project(make_project("proj-a", &["ws1", "ws2"]));
        state.add_project(make_project("proj-b", &["ws3"]));

        let sorted = state.workspaces_sorted_by_last_accessed();
        assert_eq!(sorted.len(), 3);

        let times: Vec<_> = sorted.iter().map(|(_, _, w)| w.last_accessed).collect();
        for window in times.windows(2) {
            assert!(window[0] <= window[1]);
        }
    }

    #[test]
    fn workspaces_sorted_by_last_accessed_handles_empty_projects() {
        let mut state = AppState::default();
        state.add_project(make_project("proj-empty", &[]));
        let sorted = state.workspaces_sorted_by_last_accessed();
        assert!(sorted.is_empty());
    }
}
