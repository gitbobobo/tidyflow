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
        assert!(!check_condition("file_exists:nonexistent.txt", temp_dir.path()));
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
        Project, ProjectCommand, SetupResultSummary, Workspace, WorkspaceStatus,
        WorkspaceTodoItem,
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
    use tidyflow_core::workspace::state::{
        AppState, ClientSettings, Project, Workspace, WorkspaceStatus,
    };

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
