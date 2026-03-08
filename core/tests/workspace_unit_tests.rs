//! Workspace 模块单元测试
//!
//! 测试 workspace/config, workspace/state, workspace/project 等核心功能

// ============================================================================
// config 模块测试
// ============================================================================

mod config_tests {
    use std::io::Write;
    use std::path::Path;
    use tempfile::TempDir;

    fn create_test_config(dir: &Path, content: &str) {
        let config_path = dir.join(".tidyflow.toml");
        let mut file = std::fs::File::create(&config_path).unwrap();
        file.write_all(content.as_bytes()).unwrap();
    }

    #[test]
    fn test_default_project_config() {
        use tidyflow_core::workspace::ProjectConfig;

        let config = ProjectConfig::default();
        assert_eq!(config.project.default_branch, "main");
        assert_eq!(config.setup.timeout, 600);
        assert!(config.env.inherit);
        assert!(config.project.name.is_none());
        assert!(config.setup.steps.is_empty());
    }

    #[test]
    fn test_load_missing_config_returns_default() {
        use tidyflow_core::workspace::ProjectConfig;

        let temp_dir = TempDir::new().unwrap();
        let config = ProjectConfig::load(temp_dir.path()).unwrap();

        // 加载不存在的配置应该返回默认值
        assert_eq!(config.project.default_branch, "main");
        assert!(config.project.name.is_none());
    }

    #[test]
    fn test_load_valid_config() {
        use tidyflow_core::workspace::ProjectConfig;

        let temp_dir = TempDir::new().unwrap();
        let toml_content = r#"
[project]
name = "my-project"
description = "A test project"
default_branch = "develop"

[setup]
timeout = 300
shell = "/bin/bash"

[[setup.steps]]
name = "Install dependencies"
run = "npm install"
timeout = 120

[[setup.steps]]
name = "Build"
run = "npm run build"
continue_on_error = false

[env]
inherit = true
[env.vars]
NODE_ENV = "development"
"#;
        create_test_config(temp_dir.path(), toml_content);

        let config = ProjectConfig::load(temp_dir.path()).unwrap();

        assert_eq!(config.project.name, Some("my-project".to_string()));
        assert_eq!(
            config.project.description,
            Some("A test project".to_string())
        );
        assert_eq!(config.project.default_branch, "develop");
        assert_eq!(config.setup.timeout, 300);
        assert_eq!(config.setup.shell, Some("/bin/bash".to_string()));
        assert_eq!(config.setup.steps.len(), 2);
        assert_eq!(config.setup.steps[0].name, "Install dependencies");
        assert_eq!(config.setup.steps[0].run, "npm install");
        assert_eq!(config.setup.steps[0].timeout, Some(120));
        assert!(!config.setup.steps[0].continue_on_error);
        assert!(config.env.inherit);
        assert_eq!(
            config.env.vars.get("NODE_ENV"),
            Some(&"development".to_string())
        );
    }

    #[test]
    fn test_effective_name() {
        use tidyflow_core::workspace::ProjectConfig;

        let mut config = ProjectConfig::default();
        assert_eq!(config.effective_name("fallback"), "fallback");

        config.project.name = Some("custom-name".to_string());
        assert_eq!(config.effective_name("fallback"), "custom-name");
    }

    #[test]
    fn test_check_condition_file_exists() {
        use tempfile::TempDir;
        use tidyflow_core::workspace::config::check_condition;

        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.txt");
        std::fs::write(&file_path, "test").unwrap();

        assert!(check_condition("file_exists:test.txt", temp_dir.path()));
        assert!(!check_condition(
            "file_exists:nonexistent.txt",
            temp_dir.path()
        ));
    }

    #[test]
    fn test_check_condition_dir_exists() {
        use tempfile::TempDir;
        use tidyflow_core::workspace::config::check_condition;

        let temp_dir = TempDir::new().unwrap();
        std::fs::create_dir(temp_dir.path().join("subdir")).unwrap();

        assert!(check_condition("dir_exists:subdir", temp_dir.path()));
        assert!(!check_condition("dir_exists:nonexistent", temp_dir.path()));
    }

    #[test]
    fn test_check_condition_invalid_format() {
        use tempfile::TempDir;
        use tidyflow_core::workspace::config::check_condition;

        let temp_dir = TempDir::new().unwrap();

        // 无效格式（没有冒号分隔）
        assert!(!check_condition("invalidcondition", temp_dir.path()));
    }
}

// ============================================================================
// state 模块测试
// ============================================================================

mod state_tests {
    use chrono::Utc;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use tidyflow_core::workspace::state::{
        AppState, ClientSettings, CustomCommand, EvolutionStageProfile, PersistedTokenEntry,
        Project, ProjectCommand, SetupResultSummary, Workspace, WorkspaceStatus, WorkspaceTodoItem,
    };

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
    fn test_app_state_default() {
        let state = AppState::default();
        assert_eq!(state.version, 1);
        assert!(state.projects.is_empty());
        assert!(state.client_settings.custom_commands.is_empty());
        assert!(state.paired_tokens.is_empty());
    }

    #[test]
    fn test_app_state_add_project() {
        let mut state = AppState::default();
        let project = create_test_project("test-project");

        state.add_project(project);
        assert_eq!(state.projects.len(), 1);
        assert!(state.get_project("test-project").is_some());
    }

    #[test]
    fn test_app_state_remove_project() {
        let mut state = AppState::default();
        let project = create_test_project("test-project");
        state.add_project(project);

        let removed = state.remove_project("test-project");
        assert!(removed.is_some());
        assert!(state.projects.is_empty());
    }

    #[test]
    fn test_app_state_remove_nonexistent() {
        let mut state = AppState::default();
        let removed = state.remove_project("nonexistent");
        assert!(removed.is_none());
    }

    #[test]
    fn test_app_state_list_projects() {
        let mut state = AppState::default();
        state.add_project(create_test_project("project-a"));
        state.add_project(create_test_project("project-b"));

        let list = state.list_projects();
        assert_eq!(list.len(), 2);
    }

    #[test]
    fn test_app_state_get_project_mut() {
        let mut state = AppState::default();
        state.add_project(create_test_project("test-project"));

        let project = state.get_project_mut("test-project");
        assert!(project.is_some());
        project.unwrap().default_branch = "develop".to_string();

        assert_eq!(
            state.get_project("test-project").unwrap().default_branch,
            "develop"
        );
    }

    #[test]
    fn test_project_add_workspace() {
        let mut project = create_test_project("test-project");
        let workspace = create_test_workspace("feature-1");

        project.add_workspace(workspace);
        assert_eq!(project.workspaces.len(), 1);
        assert!(project.get_workspace("feature-1").is_some());
    }

    #[test]
    fn test_project_remove_workspace() {
        let mut project = create_test_project("test-project");
        project.add_workspace(create_test_workspace("feature-1"));

        let removed = project.remove_workspace("feature-1");
        assert!(removed.is_some());
        assert!(project.workspaces.is_empty());
    }

    #[test]
    fn test_project_list_workspaces() {
        let mut project = create_test_project("test-project");
        project.add_workspace(create_test_workspace("ws-1"));
        project.add_workspace(create_test_workspace("ws-2"));

        let list = project.list_workspaces();
        assert_eq!(list.len(), 2);
    }

    #[test]
    fn test_project_worktrees_dir() {
        let project = create_test_project("test-project");
        let dir = project.worktrees_dir();

        assert!(dir.to_string_lossy().contains(".tidyflow"));
        assert!(dir.to_string_lossy().contains("workspaces"));
    }

    #[test]
    fn test_workspace_status_serialization() {
        let status = WorkspaceStatus::Ready;
        let json = serde_json::to_string(&status).unwrap();
        assert_eq!(json, "\"ready\"");

        let parsed: WorkspaceStatus = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, WorkspaceStatus::Ready);
    }

    #[test]
    fn test_workspace_status_all_variants() {
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
    fn test_client_settings_custom_commands() {
        let mut settings = ClientSettings::default();
        settings.custom_commands.push(CustomCommand {
            id: "cmd-1".to_string(),
            name: "Test Command".to_string(),
            icon: "terminal".to_string(),
            command: "echo test".to_string(),
        });

        assert_eq!(settings.custom_commands.len(), 1);
        assert_eq!(settings.custom_commands[0].id, "cmd-1");
    }

    #[test]
    fn test_client_settings_workspace_shortcuts() {
        let mut settings = ClientSettings::default();
        settings
            .workspace_shortcuts
            .insert("1".to_string(), "project/workspace".to_string());
        settings
            .workspace_shortcuts
            .insert("2".to_string(), "project/workspace2".to_string());

        assert_eq!(settings.workspace_shortcuts.len(), 2);
        assert_eq!(
            settings.workspace_shortcuts.get("1"),
            Some(&"project/workspace".to_string())
        );
    }

    #[test]
    fn test_client_settings_evolution_profiles() {
        let mut settings = ClientSettings::default();
        let profile = EvolutionStageProfile {
            stage: "direction".to_string(),
            ai_tool: "codex".to_string(),
            mode: Some("auto".to_string()),
            model: None,
            config_options: HashMap::new(),
        };

        settings
            .evolution_agent_profiles
            .insert("project/workspace".to_string(), vec![profile]);

        assert_eq!(settings.evolution_agent_profiles.len(), 1);
    }

    #[test]
    fn test_workspace_todo_item() {
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
    }

    #[test]
    fn test_project_command() {
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
    }

    #[test]
    fn test_persisted_token_entry() {
        let entry = PersistedTokenEntry {
            token_id: "token-123".to_string(),
            ws_token: "secret-token".to_string(),
            device_name: "iPhone".to_string(),
            issued_at_unix: 1000,
            expires_at_unix: 2000,
        };

        assert_eq!(entry.token_id, "token-123");
        assert!(entry.expires_at_unix > entry.issued_at_unix);
    }

    #[test]
    fn test_setup_result_summary() {
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
}

// ============================================================================
// state 序列化测试
// ============================================================================

mod serialization_tests {
    use tidyflow_core::workspace::state::{AppState, Project, Workspace, WorkspaceStatus};

    #[test]
    fn test_app_state_json_roundtrip() {
        let original = AppState::default();
        let json = serde_json::to_string(&original).unwrap();
        let parsed: AppState = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.version, original.version);
        assert_eq!(parsed.projects.len(), original.projects.len());
    }

    #[test]
    fn test_project_json_roundtrip() {
        let original = Project {
            name: "test-project".to_string(),
            root_path: std::path::PathBuf::from("/tmp/test"),
            remote_url: Some("https://github.com/test/test.git".to_string()),
            default_branch: "main".to_string(),
            created_at: chrono::Utc::now(),
            workspaces: std::collections::HashMap::new(),
            commands: vec![],
        };

        let json = serde_json::to_string(&original).unwrap();
        let parsed: Project = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.name, original.name);
        assert_eq!(parsed.default_branch, original.default_branch);
    }

    #[test]
    fn test_workspace_json_roundtrip() {
        let original = Workspace {
            name: "feature-1".to_string(),
            worktree_path: std::path::PathBuf::from("/tmp/test/ws"),
            branch: "feature/test".to_string(),
            status: WorkspaceStatus::Ready,
            created_at: chrono::Utc::now(),
            last_accessed: chrono::Utc::now(),
            setup_result: None,
        };

        let json = serde_json::to_string(&original).unwrap();
        let parsed: Workspace = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.name, original.name);
        assert_eq!(parsed.status, original.status);
    }
}

// ============================================================================
// 工作区生命周期与默认工作区语义测试（WI-001 / WI-005）
// ============================================================================

mod workspace_lifecycle_tests {
    use chrono::Utc;
    use std::collections::HashMap;
    use tidyflow_core::workspace::state::{
        AppState, Project, Workspace, WorkspaceStatus, DEFAULT_WORKSPACE_NAME,
    };

    fn make_project_with_workspaces(name: &str, workspace_names: &[(&str, WorkspaceStatus)]) -> Project {
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

    /// DEFAULT_WORKSPACE_NAME 常量值必须为 "default"
    #[test]
    fn default_workspace_name_constant_is_default() {
        assert_eq!(DEFAULT_WORKSPACE_NAME, "default");
    }

    /// WorkspaceStatus 序列化为 snake_case 字符串
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
            assert_eq!(json, format!("\"{expected}\""), "status {:?} 应序列化为 {expected}", status);
        }
    }

    /// WorkspaceStatus 反序列化
    #[test]
    fn workspace_status_deserializes_from_snake_case() {
        let ready: WorkspaceStatus = serde_json::from_str("\"ready\"").unwrap();
        assert_eq!(ready, WorkspaceStatus::Ready);
        let failed: WorkspaceStatus = serde_json::from_str("\"setup_failed\"").unwrap();
        assert_eq!(failed, WorkspaceStatus::SetupFailed);
    }

    /// 多项目场景下 `default` 不在 workspaces HashMap 中
    #[test]
    fn default_workspace_not_in_project_workspaces_hashmap() {
        let project = make_project_with_workspaces(
            "demo",
            &[("feature-x", WorkspaceStatus::Ready)],
        );
        // default 不应出现在 workspaces HashMap 中
        assert!(
            project.get_workspace(DEFAULT_WORKSPACE_NAME).is_none(),
            "default 工作区不应存储在 Project.workspaces 中"
        );
        // 命名工作区正常存在
        assert!(project.get_workspace("feature-x").is_some());
    }

    /// 多项目按名称排序，顺序稳定
    #[test]
    fn projects_sort_by_name_stable() {
        let mut state = AppState::default();
        state.add_project(make_project_with_workspaces("zeta", &[]));
        state.add_project(make_project_with_workspaces("alpha", &[]));
        state.add_project(make_project_with_workspaces("beta", &[]));

        let mut names: Vec<&str> = state.list_projects();
        names.sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()));
        assert_eq!(names, vec!["alpha", "beta", "zeta"]);
    }

    /// list_workspaces 响应中，default 工作区始终是第一项（手动前置，非字典序）
    #[test]
    fn default_workspace_sorts_before_named_workspaces() {
        // 模拟 list_workspaces 的排序逻辑：default 手动前置，其余按字典序
        let named_workspaces = vec!["alpha".to_string(), "zebra".to_string()];
        let mut all_workspaces = vec![DEFAULT_WORKSPACE_NAME.to_string()];
        let mut sorted_named = named_workspaces.clone();
        sorted_named.sort();
        all_workspaces.extend(sorted_named);

        assert_eq!(
            all_workspaces.first().map(|s| s.as_str()),
            Some(DEFAULT_WORKSPACE_NAME),
            "list_workspaces 返回的第一个工作区始终应为 default"
        );
        assert_eq!(all_workspaces, vec!["default", "alpha", "zebra"]);
    }

    /// WorkspaceStatus 变体全部可以被正确比较
    #[test]
    fn workspace_status_equality() {
        assert_eq!(WorkspaceStatus::Ready, WorkspaceStatus::Ready);
        assert_ne!(WorkspaceStatus::Ready, WorkspaceStatus::Creating);
        assert_ne!(WorkspaceStatus::SetupFailed, WorkspaceStatus::Destroying);
    }
}

// ============================================================================
// 多工作区隔离与资源管理测试
// ============================================================================

/// WI-001 / WI-003：验证多项目同名工作区状态隔离与 last_accessed 更新逻辑。
mod multi_workspace_isolation_tests {
    use chrono::Utc;
    use std::collections::HashMap;
    use std::time::Duration;
    use tidyflow_core::workspace::state::{
        AppState, Project, Workspace, WorkspaceStatus, DEFAULT_WORKSPACE_NAME,
    };

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

    /// 同名工作区在不同项目中具有不同路径，不会混淆状态上下文。
    #[test]
    fn same_workspace_name_in_different_projects_has_different_paths() {
        let proj_a = make_project("project-a", &["feature"]);
        let proj_b = make_project("project-b", &["feature"]);

        let ws_a = proj_a.get_workspace("feature").unwrap();
        let ws_b = proj_b.get_workspace("feature").unwrap();

        assert_ne!(
            ws_a.worktree_path, ws_b.worktree_path,
            "不同项目的同名工作区路径必须不同，否则文件索引缓存键会冲突"
        );
    }

    /// touch_workspace_last_accessed 只更新指定项目+工作区，不影响其他工作区。
    #[test]
    fn touch_workspace_last_accessed_updates_only_target() {
        let mut state = AppState::default();
        state.add_project(make_project("proj-a", &["ws1", "ws2"]));
        state.add_project(make_project("proj-b", &["ws1"]));

        // 记录初始访问时间
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

        // 稍微等待确保时间戳不同
        std::thread::sleep(Duration::from_millis(5));

        // 只 touch proj-a/ws1
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

        // proj-a/ws1 时间应更新（≥ before，通常更大）
        assert!(
            after_a_ws1 >= before_a_ws2,
            "touch 后 proj-a/ws1 的 last_accessed 应被更新"
        );
        // proj-a/ws2 未被 touch，时间不变
        assert_eq!(
            before_a_ws2, after_a_ws2,
            "未 touch 的 proj-a/ws2 last_accessed 不应改变"
        );
        // proj-b/ws1 未被 touch，时间不变
        assert_eq!(
            before_b_ws1, after_b_ws1,
            "未 touch 的 proj-b/ws1 last_accessed 不应改变"
        );
    }

    /// touch default 虚拟工作区静默跳过（default 不持久化，不应有副作用）。
    #[test]
    fn touch_default_workspace_is_no_op() {
        let mut state = AppState::default();
        state.add_project(make_project("proj", &["ws1"]));

        // 不应 panic，静默跳过
        state.touch_workspace_last_accessed("proj", DEFAULT_WORKSPACE_NAME);
        // ws1 未被改变
        assert!(state.get_project("proj").unwrap().get_workspace("ws1").is_some());
    }

    /// touch 不存在的项目或工作区静默跳过，不 panic。
    #[test]
    fn touch_nonexistent_project_or_workspace_is_no_op() {
        let mut state = AppState::default();
        state.add_project(make_project("proj", &["ws1"]));

        state.touch_workspace_last_accessed("no-such-project", "ws1");
        state.touch_workspace_last_accessed("proj", "no-such-workspace");
        // 仍然可以正常访问 proj/ws1
        assert!(state.get_project("proj").unwrap().get_workspace("ws1").is_some());
    }

    /// workspaces_sorted_by_last_accessed 返回所有命名工作区（跨项目），按 last_accessed 升序。
    #[test]
    fn workspaces_sorted_by_last_accessed_returns_all_named_workspaces() {
        let mut state = AppState::default();
        state.add_project(make_project("proj-a", &["ws1", "ws2"]));
        state.add_project(make_project("proj-b", &["ws3"]));

        let sorted = state.workspaces_sorted_by_last_accessed();
        // 三个命名工作区全部返回（不含 default 虚拟工作区）
        assert_eq!(sorted.len(), 3, "应返回全部 3 个命名工作区");
        // 验证单调非递减
        let times: Vec<_> = sorted.iter().map(|(_, _, w)| w.last_accessed).collect();
        for w in times.windows(2) {
            assert!(w[0] <= w[1], "last_accessed 应升序排列");
        }
    }

    /// 项目中无工作区时，workspaces_sorted_by_last_accessed 不会 panic。
    #[test]
    fn workspaces_sorted_by_last_accessed_empty_projects() {
        let mut state = AppState::default();
        state.add_project(make_project("proj-empty", &[]));
        let sorted = state.workspaces_sorted_by_last_accessed();
        assert!(sorted.is_empty());
    }
}

// ============================================================================
// cache_metrics 模块定向测试（WI-005）
// ============================================================================

mod workspace_cache_metrics {
    use tidyflow_core::workspace::cache_metrics::{
        self, WorkspaceCacheSnapshot, REBUILD_BUDGET_THRESHOLD,
    };

    fn root(id: &str) -> String {
        format!("/tmp/unit_test_cache_metrics/{}", id)
    }

    fn clean(id: &str) -> String {
        let r = root(id);
        cache_metrics::clear_metrics_for_path(&r);
        r
    }

    // --------------------------------------------------------
    // 基础计数正确性
    // --------------------------------------------------------

    #[test]
    fn file_cache_counters_count_correctly() {
        let r = clean("file_basic");
        cache_metrics::record_file_cache_hit(&r);
        cache_metrics::record_file_cache_hit(&r);
        cache_metrics::record_file_cache_miss(&r);
        cache_metrics::record_file_cache_rebuild(&r, 100);
        cache_metrics::record_file_cache_incremental_update(&r, 101);
        cache_metrics::record_file_cache_eviction(&r, "test_evict");

        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &r);
        assert_eq!(snap.file_cache.hit_count, 2);
        assert_eq!(snap.file_cache.miss_count, 1);
        assert_eq!(snap.file_cache.rebuild_count, 1);
        assert_eq!(snap.file_cache.incremental_update_count, 1);
        assert_eq!(snap.file_cache.eviction_count, 1);
    }

    #[test]
    fn git_cache_counters_count_correctly() {
        let r = clean("git_basic");
        cache_metrics::record_git_cache_hit(&r);
        cache_metrics::record_git_cache_miss(&r);
        cache_metrics::record_git_cache_miss(&r);
        cache_metrics::record_git_cache_rebuild(&r, 20);
        cache_metrics::record_git_cache_eviction(&r, "invalidated");

        let snap = WorkspaceCacheSnapshot::from_counters("p", "ws_git", &r);
        assert_eq!(snap.git_cache.hit_count, 1);
        assert_eq!(snap.git_cache.miss_count, 2);
        assert_eq!(snap.git_cache.rebuild_count, 1);
        assert_eq!(snap.git_cache.eviction_count, 1);
    }

    // --------------------------------------------------------
    // 预算判定由 Core 计算
    // --------------------------------------------------------

    #[test]
    fn budget_not_exceeded_below_threshold() {
        let r = clean("budget_below");
        for _ in 0..(REBUILD_BUDGET_THRESHOLD - 1) {
            cache_metrics::record_file_cache_rebuild(&r, 50);
        }
        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &r);
        assert!(!snap.budget_exceeded, "未超阈值不应标记 budget_exceeded");
    }

    #[test]
    fn budget_exceeded_at_threshold() {
        let r = clean("budget_at");
        for _ in 0..REBUILD_BUDGET_THRESHOLD {
            cache_metrics::record_file_cache_rebuild(&r, 50);
        }
        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &r);
        assert!(snap.budget_exceeded, "达到阈值应标记 budget_exceeded");
    }

    #[test]
    fn budget_exceeded_by_combined_file_and_git_rebuilds() {
        let r = clean("budget_combined");
        // 文件重建 + git 重建合并超过阈值
        let half = REBUILD_BUDGET_THRESHOLD / 2;
        for _ in 0..=half {
            cache_metrics::record_file_cache_rebuild(&r, 50);
        }
        for _ in 0..=half {
            cache_metrics::record_git_cache_rebuild(&r, 20);
        }
        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &r);
        assert!(snap.budget_exceeded, "文件+git 重建合并超阈值应标记 budget_exceeded");
    }

    // --------------------------------------------------------
    // 淘汰原因传播
    // --------------------------------------------------------

    #[test]
    fn eviction_reason_propagated_in_snapshot() {
        let r = clean("evict_reason");
        cache_metrics::record_file_cache_eviction(&r, "memory_pressure");
        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &r);
        assert_eq!(snap.last_eviction_reason.as_deref(), Some("memory_pressure"));
    }

    #[test]
    fn later_eviction_reason_overwrites_earlier() {
        let r = clean("evict_overwrite");
        cache_metrics::record_file_cache_eviction(&r, "ttl_expired");
        cache_metrics::record_git_cache_eviction(&r, "invalidated");
        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &r);
        // 最后一次淘汰原因为 invalidated
        assert_eq!(snap.last_eviction_reason.as_deref(), Some("invalidated"));
    }

    #[test]
    fn no_eviction_produces_none_reason() {
        let r = clean("no_evict");
        cache_metrics::record_file_cache_hit(&r);
        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &r);
        assert!(snap.last_eviction_reason.is_none());
    }

    // --------------------------------------------------------
    // 多项目隔离性（(project, workspace) 边界）
    // --------------------------------------------------------

    #[test]
    fn metrics_isolated_per_project_same_workspace_name() {
        let root_a = clean("iso_proj_a");
        let root_b = clean("iso_proj_b");

        for _ in 0..10 {
            cache_metrics::record_file_cache_hit(&root_a);
        }
        for _ in 0..3 {
            cache_metrics::record_file_cache_hit(&root_b);
        }

        let snap_a = WorkspaceCacheSnapshot::from_counters("project_a", "default", &root_a);
        let snap_b = WorkspaceCacheSnapshot::from_counters("project_b", "default", &root_b);

        assert_eq!(snap_a.file_cache.hit_count, 10, "project_a/default 指标被污染");
        assert_eq!(snap_b.file_cache.hit_count, 3, "project_b/default 指标被污染");
        assert_ne!(
            snap_a.file_cache.hit_count,
            snap_b.file_cache.hit_count,
            "同名 default 工作区必须按项目隔离"
        );
    }

    #[test]
    fn clear_metrics_resets_all_counters() {
        let r = clean("clear_test");
        cache_metrics::record_file_cache_hit(&r);
        cache_metrics::record_file_cache_rebuild(&r, 50);
        cache_metrics::record_git_cache_hit(&r);
        cache_metrics::clear_metrics_for_path(&r);

        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &r);
        assert_eq!(snap.file_cache.hit_count, 0);
        assert_eq!(snap.file_cache.rebuild_count, 0);
        assert_eq!(snap.git_cache.hit_count, 0);
        assert!(!snap.budget_exceeded);
    }
}

// ============================================================================
// 工作区资源监控守护测试（WI-001, WI-005）
// ============================================================================

mod workspace_cache_resource_guard {
    use tidyflow_core::workspace::cache_metrics::{
        self, WorkspaceCacheSnapshot, REBUILD_BUDGET_THRESHOLD,
    };

    fn clean(id: &str) -> String {
        let r = format!("/tmp/unit_test_resource_guard/{}", id);
        cache_metrics::clear_metrics_for_path(&r);
        r
    }

    /// 预算超限时 budget_exceeded 标志被正确设置，可用于资源守护决策。
    #[test]
    fn budget_guard_triggers_on_rebuild_storm() {
        let r = clean("guard_storm");
        for _ in 0..REBUILD_BUDGET_THRESHOLD {
            cache_metrics::record_file_cache_rebuild(&r, 30);
        }
        let snap = WorkspaceCacheSnapshot::from_counters("proj", "ws", &r);
        assert!(
            snap.budget_exceeded,
            "重建风暴后 budget_exceeded 应被设置，触发资源守护"
        );
    }

    /// 清理后预算超限标志复位，资源守护可以重新计入。
    #[test]
    fn budget_guard_resets_after_clear() {
        let r = clean("guard_reset");
        for _ in 0..REBUILD_BUDGET_THRESHOLD {
            cache_metrics::record_file_cache_rebuild(&r, 30);
        }
        let snap_before = WorkspaceCacheSnapshot::from_counters("proj", "ws", &r);
        assert!(snap_before.budget_exceeded, "清理前应超限");

        cache_metrics::clear_metrics_for_path(&r);
        let snap_after = WorkspaceCacheSnapshot::from_counters("proj", "ws", &r);
        assert!(
            !snap_after.budget_exceeded,
            "清理后 budget_exceeded 应复位"
        );
    }

    /// 多工作区间资源守护状态相互隔离，一个工作区超限不影响另一个。
    #[test]
    fn resource_guard_isolation_across_workspaces() {
        let r_hot = clean("guard_hot");
        let r_cold = clean("guard_cold");

        // r_hot 发生重建风暴
        for _ in 0..REBUILD_BUDGET_THRESHOLD {
            cache_metrics::record_file_cache_rebuild(&r_hot, 40);
        }
        // r_cold 只有少量命中
        cache_metrics::record_file_cache_hit(&r_cold);

        let snap_hot = WorkspaceCacheSnapshot::from_counters("proj", "hot_ws", &r_hot);
        let snap_cold = WorkspaceCacheSnapshot::from_counters("proj", "cold_ws", &r_cold);

        assert!(
            snap_hot.budget_exceeded,
            "热工作区应触发资源守护"
        );
        assert!(
            !snap_cold.budget_exceeded,
            "冷工作区不应被热工作区的超限状态污染"
        );
    }

    /// 淘汰事件被正确记录且资源守护可感知淘汰原因。
    #[test]
    fn resource_guard_detects_eviction_events() {
        let r = clean("guard_evict");
        cache_metrics::record_file_cache_eviction(&r, "memory_limit");
        cache_metrics::record_git_cache_eviction(&r, "ttl_expired");

        let snap = WorkspaceCacheSnapshot::from_counters("proj", "ws", &r);
        // 最后一次淘汰来自 git cache
        assert_eq!(
            snap.last_eviction_reason.as_deref(),
            Some("ttl_expired"),
            "资源守护应可感知最近一次淘汰原因"
        );
        assert_eq!(snap.file_cache.eviction_count, 1);
        assert_eq!(snap.git_cache.eviction_count, 1);
    }

    /// 无活动工作区（仅 hit，无 rebuild）不应触发资源守护预算超限。
    #[test]
    fn inactive_workspace_does_not_trigger_resource_guard() {
        let r = clean("guard_inactive");
        // 大量命中但无重建
        for _ in 0..100 {
            cache_metrics::record_file_cache_hit(&r);
            cache_metrics::record_git_cache_hit(&r);
        }
        let snap = WorkspaceCacheSnapshot::from_counters("proj", "ws", &r);
        assert!(
            !snap.budget_exceeded,
            "纯命中型工作区不应触发资源守护"
        );
    }
}
