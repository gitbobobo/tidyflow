//! SQLite 状态存储（sqlx）
//!
//! 负责：
//! - 初始化 schema
//! - 从 SQLite 读取并组装 AppState
//! - 将 AppState 全量事务写回 SQLite
//! - 首次从 legacy JSON (`~/.tidyflow/tidyflow.json`) 一次性迁移

use std::collections::HashMap;
use std::path::PathBuf;

use chrono::{DateTime, Utc};
use sqlx::{Pool, Row, Sqlite};

use super::sqlite_store;
use super::state::{
    AppState, ClientSettings, CustomCommand, EvolutionModelSelection, EvolutionStageProfile,
    KeybindingConfig, Project, ProjectCommand, RemoteAPIKeyEntry, SetupResultSummary, StateError,
    TemplateCommand, WorkflowTemplate, Workspace, WorkspaceRecoveryMeta, WorkspaceStatus,
    WorkspaceTodoItem, WorkspaceTerminalRecoveryEntry,
};

const DB_SCHEMA_VERSION: &str = "1";

#[derive(Clone)]
pub struct StateStore {
    pool: Pool<Sqlite>,
}

impl StateStore {
    pub fn db_path() -> PathBuf {
        sqlite_store::default_db_path()
    }

    pub fn legacy_json_path() -> PathBuf {
        sqlite_store::legacy_json_path()
    }

    pub async fn open_default() -> Result<Self, StateError> {
        let db_path = Self::db_path();
        sqlite_store::ensure_parent_dir_async(&db_path)
            .await
            .map_err(StateError::WriteError)?;

        let db_url = sqlite_store::sqlite_url(&db_path);
        let pool = sqlite_store::open_single_connection_pool(&db_url)
            .await
            .map_err(StateError::WriteError)?;

        let store = Self { pool };
        store.init_schema().await?;
        store.ensure_migrated_from_legacy_json().await?;
        Ok(store)
    }

    #[cfg(test)]
    pub async fn open_in_memory_for_test() -> Result<Self, StateError> {
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        let store = Self { pool };
        store.init_schema().await?;
        Ok(store)
    }

    pub async fn load(&self) -> Result<AppState, StateError> {
        self.init_schema().await?;

        let has_state = self.has_any_state().await?;
        if !has_state {
            return Ok(AppState::default());
        }

        let version = sqlx::query("SELECT value FROM meta WHERE key = 'state_version'")
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| StateError::ReadError(e.to_string()))?
            .and_then(|row| row.try_get::<String, _>("value").ok())
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(1);

        let last_updated = sqlx::query("SELECT value FROM meta WHERE key = 'last_updated'")
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| StateError::ReadError(e.to_string()))?
            .and_then(|row| row.try_get::<String, _>("value").ok())
            .and_then(|s| parse_rfc3339_utc(&s));

        let mut client_settings = ClientSettings::default();
        if let Some(row) = sqlx::query(
            r#"
            SELECT merge_ai_agent, fixed_port, remote_access_enabled, evolution_default_profiles_json
            FROM client_settings
            WHERE id = 1
            "#,
        )
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?
        {
            client_settings.merge_ai_agent = row.try_get("merge_ai_agent").ok();
            client_settings.fixed_port = row
                .try_get::<i64, _>("fixed_port")
                .ok()
                .and_then(|v| u16::try_from(v).ok())
                .unwrap_or(0);
            client_settings.remote_access_enabled = row
                .try_get::<i64, _>("remote_access_enabled")
                .ok()
                .unwrap_or(0)
                != 0;
            let evolution_default_profiles_json: String = row
                .try_get("evolution_default_profiles_json")
                .unwrap_or_else(|_| "[]".to_string());
            client_settings.evolution_default_profiles = serde_json::from_str(
                &evolution_default_profiles_json,
            )
            .unwrap_or_default();
        }

        client_settings.custom_commands = sqlx::query(
            r#"
            SELECT id, name, icon, command
            FROM custom_commands
            ORDER BY id
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?
        .into_iter()
        .map(|row| CustomCommand {
            id: row.try_get("id").unwrap_or_default(),
            name: row.try_get("name").unwrap_or_default(),
            icon: row.try_get("icon").unwrap_or_default(),
            command: row.try_get("command").unwrap_or_default(),
        })
        .collect();

        client_settings.workspace_shortcuts = sqlx::query(
            r#"
            SELECT key, value
            FROM workspace_shortcuts
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?
        .into_iter()
        .filter_map(|row| {
            let key: Option<String> = row.try_get("key").ok();
            let value: Option<String> = row.try_get("value").ok();
            match (key, value) {
                (Some(k), Some(v)) => Some((k, v)),
                _ => None,
            }
        })
        .collect();

        client_settings.keybindings = sqlx::query(
            r#"
            SELECT command_id, key_combination, context
            FROM keybindings
            ORDER BY command_id
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?
        .into_iter()
        .map(|row| KeybindingConfig {
            command_id: row.try_get("command_id").unwrap_or_default(),
            key_combination: row.try_get("key_combination").unwrap_or_default(),
            context: row.try_get("context").unwrap_or_default(),
        })
        .collect();

        // 加载用户自定义工作流模板
        let template_rows = sqlx::query(
            "SELECT id, name, description, tags, commands, env_vars, builtin FROM workflow_templates"
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?;
        for row in template_rows {
            let id: String = row.try_get("id").unwrap_or_default();
            let name: String = row.try_get("name").unwrap_or_default();
            let description: String = row.try_get("description").unwrap_or_default();
            let tags_json: String = row.try_get("tags").unwrap_or_else(|_| "[]".to_string());
            let commands_json: String =
                row.try_get("commands").unwrap_or_else(|_| "[]".to_string());
            let env_vars_json: String =
                row.try_get("env_vars").unwrap_or_else(|_| "[]".to_string());
            let builtin: bool = row.try_get::<i64, _>("builtin").unwrap_or(0) != 0;
            let tags: Vec<String> = serde_json::from_str(&tags_json).unwrap_or_default();
            let commands: Vec<TemplateCommand> =
                serde_json::from_str(&commands_json).unwrap_or_default();
            let env_vars: Vec<(String, String)> =
                serde_json::from_str(&env_vars_json).unwrap_or_default();
            client_settings.templates.push(WorkflowTemplate {
                id,
                name,
                description,
                tags,
                commands,
                env_vars,
                builtin,
            });
        }
        // 注入内置模板（始终从代码生成，不存储在数据库中）
        crate::application::project_admin::ensure_builtin_templates(&mut client_settings);

        let todo_rows = sqlx::query(
            r#"
            SELECT workspace_key, id, title, note, status, sort_order, created_at_ms, updated_at_ms
            FROM workspace_todos
            ORDER BY workspace_key, status, sort_order, created_at_ms
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?;
        let mut workspace_todos: HashMap<String, Vec<WorkspaceTodoItem>> = HashMap::new();
        for row in todo_rows {
            let workspace_key: String = row.try_get("workspace_key").unwrap_or_default();
            workspace_todos
                .entry(workspace_key)
                .or_default()
                .push(WorkspaceTodoItem {
                    id: row.try_get("id").unwrap_or_default(),
                    title: row.try_get("title").unwrap_or_default(),
                    note: row.try_get("note").ok(),
                    status: row
                        .try_get::<String, _>("status")
                        .unwrap_or_else(|_| "pending".to_string()),
                    order: row.try_get::<i64, _>("sort_order").unwrap_or(0),
                    created_at_ms: row.try_get::<i64, _>("created_at_ms").unwrap_or(0),
                    updated_at_ms: row.try_get::<i64, _>("updated_at_ms").unwrap_or(0),
                });
        }
        client_settings.workspace_todos = workspace_todos;

        let evolution_rows = sqlx::query(
            r#"
            SELECT workspace_key, stage, ai_tool, mode, model_provider_id, model_id, config_options_json
            FROM evolution_stage_profiles
            ORDER BY workspace_key, sort_order, stage
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?;
        let mut evolution_agent_profiles: HashMap<String, Vec<EvolutionStageProfile>> =
            HashMap::new();
        for row in evolution_rows {
            let workspace_key: String = row.try_get("workspace_key").unwrap_or_default();
            let stage: String = row.try_get("stage").unwrap_or_default();
            let ai_tool: String = row
                .try_get("ai_tool")
                .unwrap_or_else(|_| "codex".to_string());
            let mode: Option<String> = row.try_get("mode").ok();
            let provider_id: Option<String> = row.try_get("model_provider_id").ok();
            let model_id: Option<String> = row.try_get("model_id").ok();
            let config_options_json: String = row
                .try_get("config_options_json")
                .unwrap_or_else(|_| "{}".to_string());
            let config_options =
                serde_json::from_str::<HashMap<String, serde_json::Value>>(&config_options_json)
                    .unwrap_or_default();

            let model = match (provider_id, model_id) {
                (Some(provider_id), Some(model_id))
                    if !provider_id.trim().is_empty() && !model_id.trim().is_empty() =>
                {
                    Some(EvolutionModelSelection {
                        provider_id,
                        model_id,
                    })
                }
                _ => None,
            };

            evolution_agent_profiles
                .entry(workspace_key)
                .or_default()
                .push(EvolutionStageProfile {
                    stage,
                    ai_tool,
                    mode,
                    model,
                    config_options,
                });
        }
        client_settings.evolution_agent_profiles = evolution_agent_profiles;
        client_settings.migrate();

        let remote_api_keys = sqlx::query(
            r#"
            SELECT key_id, name, api_key, created_at_unix, last_used_at_unix
            FROM remote_api_keys
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?
        .into_iter()
        .map(|row| RemoteAPIKeyEntry {
            key_id: row.try_get("key_id").unwrap_or_default(),
            name: row.try_get("name").unwrap_or_default(),
            api_key: row.try_get("api_key").unwrap_or_default(),
            created_at_unix: row
                .try_get::<i64, _>("created_at_unix")
                .ok()
                .and_then(|v| u64::try_from(v).ok())
                .unwrap_or(0),
            last_used_at_unix: row
                .try_get::<Option<i64>, _>("last_used_at_unix")
                .ok()
                .flatten()
                .and_then(|v| u64::try_from(v).ok()),
        })
        .collect();

        let project_rows = sqlx::query(
            r#"
            SELECT name, root_path, remote_url, default_branch, created_at
            FROM projects
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?;

        let command_rows = sqlx::query(
            r#"
            SELECT project_name, id, name, icon, command, blocking, interactive
            FROM project_commands
            ORDER BY project_name, id
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?;
        let mut project_commands: HashMap<String, Vec<ProjectCommand>> = HashMap::new();
        for row in command_rows {
            let project_name: String = row.try_get("project_name").unwrap_or_default();
            project_commands
                .entry(project_name)
                .or_default()
                .push(ProjectCommand {
                    id: row.try_get("id").unwrap_or_default(),
                    name: row.try_get("name").unwrap_or_default(),
                    icon: row.try_get("icon").unwrap_or_default(),
                    command: row.try_get("command").unwrap_or_default(),
                    blocking: row.try_get::<i64, _>("blocking").ok().unwrap_or(0) != 0,
                    interactive: row.try_get::<i64, _>("interactive").ok().unwrap_or(0) != 0,
                });
        }

        let workspace_rows = sqlx::query(
            r#"
            SELECT
                project_name, name, worktree_path, branch, status, created_at, last_accessed,
                setup_success, setup_steps_total, setup_steps_completed, setup_last_error, setup_completed_at,
                recovery_state, recovery_cursor, recovery_failed_context, recovery_interrupted_at
            FROM workspaces
            ORDER BY project_name, name
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?;
        let mut project_workspaces: HashMap<String, HashMap<String, Workspace>> = HashMap::new();
        for row in workspace_rows {
            let project_name: String = row.try_get("project_name").unwrap_or_default();
            let name: String = row.try_get("name").unwrap_or_default();
            let status_raw: String = row
                .try_get("status")
                .unwrap_or_else(|_| "ready".to_string());
            let created_at = row
                .try_get::<String, _>("created_at")
                .ok()
                .and_then(|s| parse_rfc3339_utc(&s))
                .unwrap_or_else(Utc::now);
            let last_accessed = row
                .try_get::<String, _>("last_accessed")
                .ok()
                .and_then(|s| parse_rfc3339_utc(&s))
                .unwrap_or_else(Utc::now);

            let setup_success = row
                .try_get::<Option<i64>, _>("setup_success")
                .ok()
                .flatten();
            let setup_result = if let Some(success) = setup_success {
                let steps_total = row
                    .try_get::<Option<i64>, _>("setup_steps_total")
                    .ok()
                    .flatten()
                    .and_then(|v| usize::try_from(v).ok())
                    .unwrap_or(0);
                let steps_completed = row
                    .try_get::<Option<i64>, _>("setup_steps_completed")
                    .ok()
                    .flatten()
                    .and_then(|v| usize::try_from(v).ok())
                    .unwrap_or(0);
                let last_error = row
                    .try_get::<Option<String>, _>("setup_last_error")
                    .ok()
                    .flatten();
                let completed_at = row
                    .try_get::<Option<String>, _>("setup_completed_at")
                    .ok()
                    .flatten()
                    .and_then(|s| parse_rfc3339_utc(&s))
                    .unwrap_or_else(Utc::now);
                Some(SetupResultSummary {
                    success: success != 0,
                    steps_total,
                    steps_completed,
                    last_error,
                    completed_at,
                })
            } else {
                None
            };

            // 恢复元数据：旧快照中缺失时回退为 None（可恢复）
            let recovery_meta = row
                .try_get::<Option<String>, _>("recovery_state")
                .ok()
                .flatten()
                .map(|state| WorkspaceRecoveryMeta {
                    recovery_state: state,
                    recovery_cursor: row
                        .try_get::<Option<String>, _>("recovery_cursor")
                        .ok()
                        .flatten(),
                    failed_context: row
                        .try_get::<Option<String>, _>("recovery_failed_context")
                        .ok()
                        .flatten(),
                    interrupted_at: row
                        .try_get::<Option<String>, _>("recovery_interrupted_at")
                        .ok()
                        .flatten()
                        .and_then(|s| parse_rfc3339_utc(&s)),
                });

            let workspace = Workspace {
                name: name.clone(),
                worktree_path: PathBuf::from(
                    row.try_get::<String, _>("worktree_path")
                        .unwrap_or_default(),
                ),
                branch: row.try_get("branch").unwrap_or_default(),
                status: parse_workspace_status(&status_raw),
                created_at,
                last_accessed,
                setup_result,
                recovery_meta,
            };

            project_workspaces
                .entry(project_name)
                .or_default()
                .insert(name, workspace);
        }

        let mut projects: HashMap<String, Project> = HashMap::new();
        for row in project_rows {
            let name: String = row.try_get("name").unwrap_or_default();
            let created_at = row
                .try_get::<String, _>("created_at")
                .ok()
                .and_then(|s| parse_rfc3339_utc(&s))
                .unwrap_or_else(Utc::now);
            projects.insert(
                name.clone(),
                Project {
                    name: name.clone(),
                    root_path: PathBuf::from(
                        row.try_get::<String, _>("root_path").unwrap_or_default(),
                    ),
                    remote_url: row.try_get("remote_url").ok(),
                    default_branch: row
                        .try_get("default_branch")
                        .unwrap_or_else(|_| "main".to_string()),
                    created_at,
                    workspaces: project_workspaces.remove(&name).unwrap_or_default(),
                    commands: project_commands.remove(&name).unwrap_or_default(),
                },
            );
        }

        Ok(AppState {
            version,
            projects,
            last_updated,
            client_settings,
            remote_api_keys,
        })
    }

    pub async fn save(&self, state: &AppState) -> Result<(), StateError> {
        self.init_schema().await?;

        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;

        for table in [
            "projects",
            "project_commands",
            "workspaces",
            "custom_commands",
            "workspace_shortcuts",
            "workspace_todos",
            "evolution_stage_profiles",
            "remote_api_keys",
            "keybindings",
        ] {
            let sql = format!("DELETE FROM {}", table);
            sqlx::query(&sql)
                .execute(&mut *tx)
                .await
                .map_err(|e| StateError::WriteError(e.to_string()))?;
        }

        sqlx::query("DELETE FROM client_settings")
            .execute(&mut *tx)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;

        sqlx::query(
            r#"
            INSERT INTO client_settings (
                id,
                merge_ai_agent,
                fixed_port,
                remote_access_enabled,
                evolution_default_profiles_json
            )
            VALUES (1, ?1, ?2, ?3, ?4)
            "#,
        )
        .bind(state.client_settings.merge_ai_agent.clone())
        .bind(i64::from(state.client_settings.fixed_port))
        .bind(if state.client_settings.remote_access_enabled {
            1_i64
        } else {
            0_i64
        })
        .bind(
            serde_json::to_string(&state.client_settings.evolution_default_profiles)
                .map_err(|e| StateError::WriteError(e.to_string()))?,
        )
        .execute(&mut *tx)
        .await
        .map_err(|e| StateError::WriteError(e.to_string()))?;

        for command in &state.client_settings.custom_commands {
            sqlx::query(
                r#"
                INSERT INTO custom_commands (id, name, icon, command)
                VALUES (?1, ?2, ?3, ?4)
                "#,
            )
            .bind(&command.id)
            .bind(&command.name)
            .bind(&command.icon)
            .bind(&command.command)
            .execute(&mut *tx)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        }

        for (key, value) in &state.client_settings.workspace_shortcuts {
            sqlx::query(
                r#"
                INSERT INTO workspace_shortcuts (key, value)
                VALUES (?1, ?2)
                "#,
            )
            .bind(key)
            .bind(value)
            .execute(&mut *tx)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        }

        for kb in &state.client_settings.keybindings {
            sqlx::query(
                r#"
                INSERT INTO keybindings (command_id, key_combination, context)
                VALUES (?1, ?2, ?3)
                "#,
            )
            .bind(&kb.command_id)
            .bind(&kb.key_combination)
            .bind(&kb.context)
            .execute(&mut *tx)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        }

        // 保存用户自定义工作流模板（内置模板不存储到数据库）
        sqlx::query("DELETE FROM workflow_templates WHERE builtin = 0")
            .execute(&mut *tx)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        for tpl in &state.client_settings.templates {
            if tpl.builtin {
                continue;
            }
            sqlx::query(
                "INSERT OR REPLACE INTO workflow_templates (id, name, description, tags, commands, env_vars, builtin) VALUES (?, ?, ?, ?, ?, ?, ?)"
            )
            .bind(&tpl.id)
            .bind(&tpl.name)
            .bind(&tpl.description)
            .bind(serde_json::to_string(&tpl.tags).unwrap_or_else(|_| "[]".to_string()))
            .bind(serde_json::to_string(&tpl.commands).unwrap_or_else(|_| "[]".to_string()))
            .bind(serde_json::to_string(&tpl.env_vars).unwrap_or_else(|_| "[]".to_string()))
            .bind(0i64)
            .execute(&mut *tx)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        }

        for (workspace_key, todos) in &state.client_settings.workspace_todos {
            for todo in todos {
                sqlx::query(
                    r#"
                    INSERT INTO workspace_todos (
                        workspace_key, id, title, note, status, sort_order, created_at_ms, updated_at_ms
                    )
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    "#,
                )
                .bind(workspace_key)
                .bind(&todo.id)
                .bind(&todo.title)
                .bind(todo.note.clone())
                .bind(&todo.status)
                .bind(todo.order)
                .bind(todo.created_at_ms)
                .bind(todo.updated_at_ms)
                .execute(&mut *tx)
                .await
                .map_err(|e| StateError::WriteError(e.to_string()))?;
            }
        }

        for (workspace_key, profiles) in &state.client_settings.evolution_agent_profiles {
            for (idx, profile) in profiles.iter().enumerate() {
                let (provider_id, model_id) = profile
                    .model
                    .as_ref()
                    .map(|m| (Some(m.provider_id.clone()), Some(m.model_id.clone())))
                    .unwrap_or((None, None));
                let config_options_json = serde_json::to_string(&profile.config_options)
                    .map_err(|e| StateError::WriteError(e.to_string()))?;
                sqlx::query(
                    r#"
                    INSERT INTO evolution_stage_profiles (
                        workspace_key, stage, ai_tool, mode, model_provider_id, model_id, config_options_json, sort_order
                    )
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    "#,
                )
                .bind(workspace_key)
                .bind(&profile.stage)
                .bind(&profile.ai_tool)
                .bind(profile.mode.clone())
                .bind(provider_id)
                .bind(model_id)
                .bind(config_options_json)
                .bind(i64::try_from(idx).unwrap_or(0))
                .execute(&mut *tx)
                .await
                .map_err(|e| StateError::WriteError(e.to_string()))?;
            }
        }

        for key in &state.remote_api_keys {
            sqlx::query(
                r#"
                INSERT INTO remote_api_keys (key_id, name, api_key, created_at_unix, last_used_at_unix)
                VALUES (?1, ?2, ?3, ?4, ?5)
                "#,
            )
            .bind(&key.key_id)
            .bind(&key.name)
            .bind(&key.api_key)
            .bind(i64::try_from(key.created_at_unix).unwrap_or(0))
            .bind(key.last_used_at_unix.and_then(|value| i64::try_from(value).ok()))
            .execute(&mut *tx)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        }

        for project in state.projects.values() {
            sqlx::query(
                r#"
                INSERT INTO projects (name, root_path, remote_url, default_branch, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5)
                "#,
            )
            .bind(&project.name)
            .bind(project.root_path.to_string_lossy().to_string())
            .bind(project.remote_url.clone())
            .bind(&project.default_branch)
            .bind(project.created_at.to_rfc3339())
            .execute(&mut *tx)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;

            for command in &project.commands {
                sqlx::query(
                    r#"
                    INSERT INTO project_commands (project_name, id, name, icon, command, blocking, interactive)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                    "#,
                )
                .bind(&project.name)
                .bind(&command.id)
                .bind(&command.name)
                .bind(&command.icon)
                .bind(&command.command)
                .bind(if command.blocking { 1_i64 } else { 0_i64 })
                .bind(if command.interactive { 1_i64 } else { 0_i64 })
                .execute(&mut *tx)
                .await
                .map_err(|e| StateError::WriteError(e.to_string()))?;
            }

            for workspace in project.workspaces.values() {
                let (
                    setup_success,
                    setup_steps_total,
                    setup_steps_completed,
                    setup_last_error,
                    setup_completed_at,
                ) = if let Some(summary) = workspace.setup_result.as_ref() {
                    (
                        Some(if summary.success { 1_i64 } else { 0_i64 }),
                        Some(i64::try_from(summary.steps_total).unwrap_or(0)),
                        Some(i64::try_from(summary.steps_completed).unwrap_or(0)),
                        summary.last_error.clone(),
                        Some(summary.completed_at.to_rfc3339()),
                    )
                } else {
                    (None, None, None, None, None)
                };

                let (
                    recovery_state,
                    recovery_cursor,
                    recovery_failed_context,
                    recovery_interrupted_at,
                ) = if let Some(meta) = workspace.recovery_meta.as_ref() {
                    (
                        Some(meta.recovery_state.clone()),
                        meta.recovery_cursor.clone(),
                        meta.failed_context.clone(),
                        meta.interrupted_at.map(|t| t.to_rfc3339()),
                    )
                } else {
                    (None, None, None, None)
                };

                sqlx::query(
                    r#"
                    INSERT INTO workspaces (
                        project_name, name, worktree_path, branch, status, created_at, last_accessed,
                        setup_success, setup_steps_total, setup_steps_completed, setup_last_error, setup_completed_at,
                        recovery_state, recovery_cursor, recovery_failed_context, recovery_interrupted_at
                    )
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
                    "#,
                )
                .bind(&project.name)
                .bind(&workspace.name)
                .bind(workspace.worktree_path.to_string_lossy().to_string())
                .bind(&workspace.branch)
                .bind(workspace_status_to_str(&workspace.status))
                .bind(workspace.created_at.to_rfc3339())
                .bind(workspace.last_accessed.to_rfc3339())
                .bind(setup_success)
                .bind(setup_steps_total)
                .bind(setup_steps_completed)
                .bind(setup_last_error)
                .bind(setup_completed_at)
                .bind(recovery_state)
                .bind(recovery_cursor)
                .bind(recovery_failed_context)
                .bind(recovery_interrupted_at)
                .execute(&mut *tx)
                .await
                .map_err(|e| StateError::WriteError(e.to_string()))?;
            }
        }

        let last_updated = state
            .last_updated
            .as_ref()
            .cloned()
            .unwrap_or_else(Utc::now)
            .to_rfc3339();
        self.upsert_meta(&mut tx, "schema_version", DB_SCHEMA_VERSION)
            .await?;
        self.upsert_meta(&mut tx, "state_initialized", "1").await?;
        self.upsert_meta(&mut tx, "state_version", &state.version.to_string())
            .await?;
        self.upsert_meta(&mut tx, "last_updated", &last_updated)
            .await?;

        tx.commit()
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))
    }

    async fn upsert_meta(
        &self,
        tx: &mut sqlx::Transaction<'_, Sqlite>,
        key: &str,
        value: &str,
    ) -> Result<(), StateError> {
        sqlx::query(
            r#"
            INSERT INTO meta (key, value)
            VALUES (?1, ?2)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            "#,
        )
        .bind(key)
        .bind(value)
        .execute(&mut **tx)
        .await
        .map_err(|e| StateError::WriteError(e.to_string()))?;
        Ok(())
    }

    async fn has_any_state(&self) -> Result<bool, StateError> {
        let count = sqlx::query("SELECT COUNT(1) AS count FROM client_settings")
            .fetch_one(&self.pool)
            .await
            .map_err(|e| StateError::ReadError(e.to_string()))?
            .try_get::<i64, _>("count")
            .unwrap_or(0);
        if count > 0 {
            return Ok(true);
        }

        let project_count = sqlx::query("SELECT COUNT(1) AS count FROM projects")
            .fetch_one(&self.pool)
            .await
            .map_err(|e| StateError::ReadError(e.to_string()))?
            .try_get::<i64, _>("count")
            .unwrap_or(0);
        Ok(project_count > 0)
    }

    async fn ensure_migrated_from_legacy_json(&self) -> Result<(), StateError> {
        if self.has_any_state().await? {
            return Ok(());
        }

        let legacy_path = Self::legacy_json_path();
        if !legacy_path.exists() {
            return Ok(());
        }

        let content = tokio::fs::read_to_string(&legacy_path)
            .await
            .map_err(|e| StateError::ReadError(e.to_string()))?;
        let mut state: AppState =
            serde_json::from_str(&content).map_err(|e| StateError::ParseError(e.to_string()))?;
        state.client_settings.migrate();
        self.save(&state).await?;

        let backup_path = legacy_path.with_extension("json.migrated.bak");
        if backup_path.exists() {
            let _ = tokio::fs::remove_file(&backup_path).await;
        }
        tokio::fs::rename(&legacy_path, &backup_path)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        Ok(())
    }

    async fn init_schema(&self) -> Result<(), StateError> {
        let schema_sql = [
            r#"
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS projects (
                name TEXT PRIMARY KEY,
                root_path TEXT NOT NULL,
                remote_url TEXT,
                default_branch TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS project_commands (
                project_name TEXT NOT NULL,
                id TEXT NOT NULL,
                name TEXT NOT NULL,
                icon TEXT NOT NULL,
                command TEXT NOT NULL,
                blocking INTEGER NOT NULL DEFAULT 0,
                interactive INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (project_name, id)
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS workspaces (
                project_name TEXT NOT NULL,
                name TEXT NOT NULL,
                worktree_path TEXT NOT NULL,
                branch TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_accessed TEXT NOT NULL,
                setup_success INTEGER,
                setup_steps_total INTEGER,
                setup_steps_completed INTEGER,
                setup_last_error TEXT,
                setup_completed_at TEXT,
                recovery_state TEXT,
                recovery_cursor TEXT,
                recovery_failed_context TEXT,
                recovery_interrupted_at TEXT,
                PRIMARY KEY (project_name, name)
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS client_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                merge_ai_agent TEXT,
                fixed_port INTEGER NOT NULL DEFAULT 0,
                remote_access_enabled INTEGER NOT NULL DEFAULT 0,
                evolution_default_profiles_json TEXT NOT NULL DEFAULT '[]'
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS custom_commands (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                icon TEXT NOT NULL,
                command TEXT NOT NULL
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS workspace_shortcuts (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS workspace_todos (
                workspace_key TEXT NOT NULL,
                id TEXT NOT NULL,
                title TEXT NOT NULL,
                note TEXT,
                status TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                PRIMARY KEY (workspace_key, id)
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS evolution_stage_profiles (
                workspace_key TEXT NOT NULL,
                stage TEXT NOT NULL,
                ai_tool TEXT NOT NULL,
                mode TEXT,
                model_provider_id TEXT,
                model_id TEXT,
                config_options_json TEXT NOT NULL DEFAULT '{}',
                sort_order INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (workspace_key, stage)
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS remote_api_keys (
                key_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                api_key TEXT NOT NULL,
                created_at_unix INTEGER NOT NULL,
                last_used_at_unix INTEGER
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS keybindings (
                command_id TEXT NOT NULL,
                key_combination TEXT NOT NULL,
                context TEXT NOT NULL,
                PRIMARY KEY (command_id)
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS workflow_templates (
                id TEXT NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                tags TEXT NOT NULL DEFAULT '[]',
                commands TEXT NOT NULL DEFAULT '[]',
                env_vars TEXT NOT NULL DEFAULT '[]',
                builtin INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (id)
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS terminal_recovery (
                term_id TEXT NOT NULL,
                project TEXT NOT NULL,
                workspace TEXT NOT NULL,
                workspace_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                shell TEXT NOT NULL,
                name TEXT,
                icon TEXT,
                recovery_state TEXT NOT NULL DEFAULT 'pending',
                failed_reason TEXT,
                recorded_at TEXT NOT NULL,
                PRIMARY KEY (term_id)
            )
            "#,
        ];

        for sql in schema_sql {
            sqlx::query(sql)
                .execute(&self.pool)
                .await
                .map_err(|e| StateError::WriteError(e.to_string()))?;
        }
        self.ensure_client_settings_columns().await?;
        self.ensure_workspace_recovery_columns().await?;
        let _ = sqlx::query("DELETE FROM paired_tokens")
            .execute(&self.pool)
            .await;
        Ok(())
    }

    /// 为旧版数据库的 workspaces 表追加恢复元数据列（幂等，列已存在时跳过）
    async fn ensure_workspace_recovery_columns(&self) -> Result<(), StateError> {
        let migrations: &[&str] = &[
            "ALTER TABLE workspaces ADD COLUMN recovery_state TEXT",
            "ALTER TABLE workspaces ADD COLUMN recovery_cursor TEXT",
            "ALTER TABLE workspaces ADD COLUMN recovery_failed_context TEXT",
            "ALTER TABLE workspaces ADD COLUMN recovery_interrupted_at TEXT",
        ];
        for sql in migrations {
            match sqlx::query(sql).execute(&self.pool).await {
                Ok(_) => {}
                Err(e) => {
                    let msg = e.to_string();
                    if !msg.contains("duplicate column name") {
                        return Err(StateError::WriteError(msg));
                    }
                }
            }
        }
        Ok(())
    }

    async fn ensure_client_settings_columns(&self) -> Result<(), StateError> {
        let result = sqlx::query(
            "ALTER TABLE client_settings ADD COLUMN evolution_default_profiles_json TEXT NOT NULL DEFAULT '[]'",
        )
        .execute(&self.pool)
        .await;

        match result {
            Ok(_) => Ok(()),
            Err(err) => {
                let message = err.to_string();
                if message.contains("duplicate column name") {
                    Ok(())
                } else {
                    Err(StateError::WriteError(message))
                }
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // 终端恢复元数据持久化（WI-002）
    // ──────────────────────────────────────────────────────────────────────────

    /// 保存终端恢复元数据列表（Core 关闭前快照活跃终端信息，下次启动用于恢复）
    ///
    /// 按 (project, workspace, term_id) 三元组严格隔离，先清空指定工作区旧记录再写入新记录。
    pub async fn save_terminal_recovery_entries(
        &self,
        project: &str,
        workspace: &str,
        entries: &[WorkspaceTerminalRecoveryEntry],
    ) -> Result<(), StateError> {
        // 清除该工作区的旧恢复记录
        sqlx::query("DELETE FROM terminal_recovery WHERE project = ? AND workspace = ?")
            .bind(project)
            .bind(workspace)
            .execute(&self.pool)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;

        for entry in entries {
            sqlx::query(r#"
                INSERT INTO terminal_recovery
                    (term_id, project, workspace, workspace_path, cwd, shell, name, icon,
                     recovery_state, failed_reason, recorded_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            "#)
            .bind(&entry.term_id)
            .bind(project)
            .bind(workspace)
            .bind(&entry.workspace_path)
            .bind(&entry.cwd)
            .bind(&entry.shell)
            .bind(&entry.name)
            .bind(&entry.icon)
            .bind(&entry.recovery_state)
            .bind(&entry.failed_reason)
            .bind(entry.recorded_at.to_rfc3339())
            .execute(&self.pool)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        }
        Ok(())
    }

    /// 加载所有终端恢复元数据，按 (project, workspace) 分组返回
    pub async fn load_terminal_recovery_entries(
        &self,
    ) -> Result<Vec<(String, String, WorkspaceTerminalRecoveryEntry)>, StateError> {
        let rows = sqlx::query(
            r#"SELECT term_id, project, workspace, workspace_path, cwd, shell,
                      name, icon, recovery_state, failed_reason, recorded_at
               FROM terminal_recovery
               WHERE recovery_state IN ('pending', 'recovering')
               ORDER BY project, workspace, term_id"#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?;

        let mut result = Vec::new();
        for row in rows {
            let recorded_at_str: String = row.try_get("recorded_at").unwrap_or_default();
            let recorded_at = parse_rfc3339_utc(&recorded_at_str)
                .unwrap_or_else(chrono::Utc::now);
            let project: String = row.try_get("project").unwrap_or_default();
            let workspace: String = row.try_get("workspace").unwrap_or_default();
            let entry = WorkspaceTerminalRecoveryEntry {
                term_id: row.try_get("term_id").unwrap_or_default(),
                workspace_path: row.try_get("workspace_path").unwrap_or_default(),
                cwd: row.try_get("cwd").unwrap_or_default(),
                shell: row.try_get("shell").unwrap_or_default(),
                name: row.try_get("name").ok().flatten(),
                icon: row.try_get("icon").ok().flatten(),
                recovery_state: row.try_get("recovery_state").unwrap_or_else(|_| "pending".to_string()),
                failed_reason: row.try_get("failed_reason").ok().flatten(),
                recorded_at,
            };
            result.push((project, workspace, entry));
        }
        Ok(result)
    }

    /// 更新指定终端的恢复状态（恢复成功或失败时调用）
    pub async fn update_terminal_recovery_state(
        &self,
        term_id: &str,
        recovery_state: &str,
        failed_reason: Option<&str>,
    ) -> Result<(), StateError> {
        sqlx::query(
            "UPDATE terminal_recovery SET recovery_state = ?, failed_reason = ? WHERE term_id = ?",
        )
        .bind(recovery_state)
        .bind(failed_reason)
        .bind(term_id)
        .execute(&self.pool)
        .await
        .map_err(|e| StateError::WriteError(e.to_string()))?;
        Ok(())
    }

    /// 清除已完成恢复（recovered/failed）的终端记录
    pub async fn clear_completed_terminal_recovery_entries(&self) -> Result<(), StateError> {
        sqlx::query(
            "DELETE FROM terminal_recovery WHERE recovery_state IN ('recovered', 'failed')",
        )
        .execute(&self.pool)
        .await
        .map_err(|e| StateError::WriteError(e.to_string()))?;
        Ok(())
    }

    /// 清除指定工作区的所有终端恢复记录（工作区删除时调用）
    pub async fn clear_terminal_recovery_for_workspace(
        &self,
        project: &str,
        workspace: &str,
    ) -> Result<(), StateError> {
        sqlx::query("DELETE FROM terminal_recovery WHERE project = ? AND workspace = ?")
            .bind(project)
            .bind(workspace)
            .execute(&self.pool)
            .await
            .map_err(|e| StateError::WriteError(e.to_string()))?;
        Ok(())
    }
}

fn parse_rfc3339_utc(raw: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn parse_workspace_status(raw: &str) -> WorkspaceStatus {
    match raw.trim().to_ascii_lowercase().as_str() {
        "creating" => WorkspaceStatus::Creating,
        "initializing" => WorkspaceStatus::Initializing,
        "setup_failed" => WorkspaceStatus::SetupFailed,
        "destroying" => WorkspaceStatus::Destroying,
        _ => WorkspaceStatus::Ready,
    }
}

fn workspace_status_to_str(status: &WorkspaceStatus) -> &'static str {
    match status {
        WorkspaceStatus::Creating => "creating",
        WorkspaceStatus::Initializing => "initializing",
        WorkspaceStatus::Ready => "ready",
        WorkspaceStatus::SetupFailed => "setup_failed",
        WorkspaceStatus::Destroying => "destroying",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use std::collections::HashMap;

    #[tokio::test]
    async fn in_memory_roundtrip_should_persist_core_state() {
        let store = StateStore::open_in_memory_for_test()
            .await
            .expect("in-memory store should initialize");

        let now = Utc::now();
        let mut state = AppState::default();
        state.version = 42;
        state.last_updated = Some(now);
        state.client_settings.merge_ai_agent = Some("codex".to_string());
        state.client_settings.fixed_port = 18439;
        state.client_settings.remote_access_enabled = true;
        state.client_settings.evolution_default_profiles = vec![EvolutionStageProfile {
            stage: "auto_commit".to_string(),
            ai_tool: "opencode".to_string(),
            mode: Some("agent".to_string()),
            model: None,
            config_options: HashMap::new(),
        }];
        state.client_settings.custom_commands = vec![CustomCommand {
            id: "cmd-1".to_string(),
            name: "Build".to_string(),
            icon: "hammer".to_string(),
            command: "cargo build".to_string(),
        }];
        state.client_settings.workspace_shortcuts =
            HashMap::from([("1".to_string(), "demo/default".to_string())]);
        state.client_settings.workspace_todos = HashMap::from([(
            "demo:feature-a".to_string(),
            vec![WorkspaceTodoItem {
                id: "todo-1".to_string(),
                title: "补测试".to_string(),
                note: Some("补充回归用例".to_string()),
                status: "in_progress".to_string(),
                order: 0,
                created_at_ms: 1760000000000,
                updated_at_ms: 1760000001000,
            }],
        )]);
        state.client_settings.evolution_agent_profiles = HashMap::from([(
            "demo/default".to_string(),
            vec![EvolutionStageProfile {
                stage: "general".to_string(),
                ai_tool: "codex".to_string(),
                mode: Some("default".to_string()),
                model: Some(EvolutionModelSelection {
                    provider_id: "openai".to_string(),
                    model_id: "gpt-5".to_string(),
                }),
                config_options: HashMap::new(),
            }],
        )]);
        state.remote_api_keys = vec![RemoteAPIKeyEntry {
            key_id: "key-1".to_string(),
            name: "我的 iPhone".to_string(),
            api_key: "tfk_ws-token-1".to_string(),
            created_at_unix: 1,
            last_used_at_unix: Some(2),
        }];

        let project = Project {
            name: "demo".to_string(),
            root_path: PathBuf::from("/tmp/demo"),
            remote_url: Some("git@example.com/demo.git".to_string()),
            default_branch: "main".to_string(),
            created_at: now,
            workspaces: HashMap::from([(
                "feature-a".to_string(),
                Workspace {
                    name: "feature-a".to_string(),
                    worktree_path: PathBuf::from("/tmp/demo/.worktrees/feature-a"),
                    branch: "feature/a".to_string(),
                    status: WorkspaceStatus::Ready,
                    created_at: now,
                    last_accessed: now,
                    setup_result: Some(SetupResultSummary {
                        success: true,
                        steps_total: 3,
                        steps_completed: 3,
                        last_error: None,
                        completed_at: now,
                    }),
                    recovery_meta: None,
                },
            )]),
            commands: vec![ProjectCommand {
                id: "pc-1".to_string(),
                name: "Test".to_string(),
                icon: "checkmark".to_string(),
                command: "cargo test".to_string(),
                blocking: true,
                interactive: false,
            }],
        };
        state.projects.insert(project.name.clone(), project);

        store.save(&state).await.expect("state save should succeed");
        let loaded = store.load().await.expect("state load should succeed");

        assert_eq!(loaded.version, 42);
        assert_eq!(loaded.client_settings.fixed_port, 18439);
        assert!(loaded.client_settings.remote_access_enabled);
        assert_eq!(
            loaded.client_settings.merge_ai_agent.as_deref(),
            Some("codex")
        );
        assert_eq!(loaded.client_settings.evolution_default_profiles.len(), 1);
        assert_eq!(
            loaded.client_settings.evolution_default_profiles[0].ai_tool,
            "opencode"
        );
        assert_eq!(loaded.client_settings.custom_commands.len(), 1);
        assert_eq!(
            loaded
                .client_settings
                .workspace_shortcuts
                .get("1")
                .map(String::as_str),
            Some("demo/default")
        );
        assert_eq!(
            loaded
                .client_settings
                .workspace_todos
                .get("demo:feature-a")
                .map(|items| items.len()),
            Some(1)
        );
        assert_eq!(
            loaded
                .client_settings
                .workspace_todos
                .get("demo:feature-a")
                .and_then(|items| items.first())
                .map(|item| item.status.as_str()),
            Some("in_progress")
        );
        assert_eq!(loaded.remote_api_keys.len(), 1);

        let loaded_project = loaded.projects.get("demo").expect("project should exist");
        assert_eq!(loaded_project.commands.len(), 1);
        assert_eq!(loaded_project.workspaces.len(), 1);
        let loaded_workspace = loaded_project
            .workspaces
            .get("feature-a")
            .expect("workspace should exist");
        assert!(matches!(loaded_workspace.status, WorkspaceStatus::Ready));
        assert!(loaded_workspace
            .setup_result
            .as_ref()
            .is_some_and(|r| r.success));
    }

    /// CHK-003: 工作区恢复元数据按 (project, workspace) 复合键 roundtrip
    #[tokio::test]
    async fn workspace_recovery_meta_roundtrip_preserves_composite_key() {
        use crate::workspace::state::WorkspaceRecoveryMeta;
        let store = StateStore::open_in_memory_for_test()
            .await
            .expect("in-memory store should initialize");

        let now = Utc::now();
        let interrupted_at = now;

        let mut state = AppState::default();
        let ws_interrupted = Workspace {
            name: "feature-interrupted".to_string(),
            worktree_path: PathBuf::from("/tmp/proj-a/.worktrees/feature-interrupted"),
            branch: "feature/interrupted".to_string(),
            status: WorkspaceStatus::Initializing,
            created_at: now,
            last_accessed: now,
            setup_result: None,
            recovery_meta: Some(WorkspaceRecoveryMeta {
                recovery_state: "interrupted".to_string(),
                recovery_cursor: Some("step-2-init".to_string()),
                failed_context: Some(r#"{"cycle_id":"c1","stage":"initializing"}"#.to_string()),
                interrupted_at: Some(interrupted_at),
            }),
        };

        // project-a: feature-interrupted（中断态）
        let mut proj_a = Project {
            name: "project-a".to_string(),
            root_path: PathBuf::from("/tmp/proj-a"),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: now,
            workspaces: HashMap::new(),
            commands: vec![],
        };
        proj_a
            .workspaces
            .insert(ws_interrupted.name.clone(), ws_interrupted.clone());

        // project-b: 同名 feature-interrupted 但状态为 Ready、无恢复元数据
        let ws_ready = Workspace {
            name: "feature-interrupted".to_string(),
            worktree_path: PathBuf::from("/tmp/proj-b/.worktrees/feature-interrupted"),
            branch: "feature/interrupted".to_string(),
            status: WorkspaceStatus::Ready,
            created_at: now,
            last_accessed: now,
            setup_result: None,
            recovery_meta: None,
        };
        let mut proj_b = Project {
            name: "project-b".to_string(),
            root_path: PathBuf::from("/tmp/proj-b"),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: now,
            workspaces: HashMap::new(),
            commands: vec![],
        };
        proj_b
            .workspaces
            .insert(ws_ready.name.clone(), ws_ready.clone());

        state.projects.insert(proj_a.name.clone(), proj_a);
        state.projects.insert(proj_b.name.clone(), proj_b);

        store.save(&state).await.expect("save should succeed");
        let loaded = store.load().await.expect("load should succeed");

        // project-a 中断态应完整恢复，恢复元数据不应泄漏到 project-b
        let loaded_a = loaded
            .projects
            .get("project-a")
            .expect("project-a should exist");
        let loaded_ws_a = loaded_a
            .workspaces
            .get("feature-interrupted")
            .expect("workspace should exist in project-a");
        assert!(
            matches!(loaded_ws_a.status, WorkspaceStatus::Initializing),
            "project-a workspace status should be Initializing"
        );
        let meta_a = loaded_ws_a
            .recovery_meta
            .as_ref()
            .expect("recovery_meta should be present in project-a");
        assert_eq!(meta_a.recovery_state, "interrupted");
        assert_eq!(
            meta_a.recovery_cursor.as_deref(),
            Some("step-2-init"),
            "recovery_cursor should roundtrip"
        );
        assert!(
            meta_a.failed_context.is_some(),
            "failed_context should roundtrip"
        );
        assert!(
            meta_a.interrupted_at.is_some(),
            "interrupted_at should roundtrip"
        );

        // project-b 同名工作区不应受 project-a 的中断态污染
        let loaded_b = loaded
            .projects
            .get("project-b")
            .expect("project-b should exist");
        let loaded_ws_b = loaded_b
            .workspaces
            .get("feature-interrupted")
            .expect("workspace should exist in project-b");
        assert!(
            matches!(loaded_ws_b.status, WorkspaceStatus::Ready),
            "project-b workspace status should remain Ready"
        );
        assert!(
            loaded_ws_b.recovery_meta.is_none(),
            "project-b workspace should have no recovery_meta (no cross-workspace leakage)"
        );
    }

    /// CHK-003: 旧快照（无 recovery 列）加载时不应崩溃，应回退为 None
    #[tokio::test]
    async fn workspace_missing_recovery_columns_falls_back_gracefully() {
        use crate::workspace::state::WorkspaceRecoveryMeta;
        let store = StateStore::open_in_memory_for_test()
            .await
            .expect("in-memory store should initialize");

        let now = Utc::now();
        let mut state = AppState::default();

        // 保存一个无恢复元数据的工作区（模拟旧快照）
        let ws_normal = Workspace {
            name: "normal".to_string(),
            worktree_path: PathBuf::from("/tmp/proj/.worktrees/normal"),
            branch: "feature/normal".to_string(),
            status: WorkspaceStatus::Ready,
            created_at: now,
            last_accessed: now,
            setup_result: None,
            recovery_meta: None, // 无恢复元数据
        };
        let mut proj = Project {
            name: "proj".to_string(),
            root_path: PathBuf::from("/tmp/proj"),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: now,
            workspaces: HashMap::new(),
            commands: vec![],
        };
        proj.workspaces.insert(ws_normal.name.clone(), ws_normal);
        state.projects.insert(proj.name.clone(), proj);

        store.save(&state).await.expect("save should succeed");
        let loaded = store.load().await.expect("load should succeed");

        let ws = loaded
            .projects
            .get("proj")
            .and_then(|p| p.workspaces.get("normal"))
            .expect("workspace should exist");
        assert!(
            ws.recovery_meta.is_none(),
            "missing recovery columns should fall back to None without crashing"
        );

        // 验证 WorkspaceRecoveryMeta::none() 帮助方法语义
        let meta = WorkspaceRecoveryMeta::none();
        assert_eq!(meta.recovery_state, "none");
        assert!(!meta.needs_attention());

        let interrupted_meta = WorkspaceRecoveryMeta {
            recovery_state: "interrupted".to_string(),
            recovery_cursor: None,
            failed_context: None,
            interrupted_at: None,
        };
        assert!(interrupted_meta.needs_attention());
    }
}
