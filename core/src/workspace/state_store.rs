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
    PersistedTokenEntry, Project, ProjectCommand, SetupResultSummary, StateError, Workspace,
    WorkspaceStatus,
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
            SELECT merge_ai_agent, fixed_port, remote_access_enabled
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

        let paired_tokens = sqlx::query(
            r#"
            SELECT token_id, ws_token, device_name, issued_at_unix, expires_at_unix
            FROM paired_tokens
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| StateError::ReadError(e.to_string()))?
        .into_iter()
        .map(|row| PersistedTokenEntry {
            token_id: row.try_get("token_id").unwrap_or_default(),
            ws_token: row.try_get("ws_token").unwrap_or_default(),
            device_name: row.try_get("device_name").unwrap_or_default(),
            issued_at_unix: row
                .try_get::<i64, _>("issued_at_unix")
                .ok()
                .and_then(|v| u64::try_from(v).ok())
                .unwrap_or(0),
            expires_at_unix: row
                .try_get::<i64, _>("expires_at_unix")
                .ok()
                .and_then(|v| u64::try_from(v).ok())
                .unwrap_or(0),
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
                setup_success, setup_steps_total, setup_steps_completed, setup_last_error, setup_completed_at
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
            paired_tokens,
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
            "evolution_stage_profiles",
            "paired_tokens",
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
            INSERT INTO client_settings (id, merge_ai_agent, fixed_port, remote_access_enabled)
            VALUES (1, ?1, ?2, ?3)
            "#,
        )
        .bind(state.client_settings.merge_ai_agent.clone())
        .bind(i64::from(state.client_settings.fixed_port))
        .bind(if state.client_settings.remote_access_enabled {
            1_i64
        } else {
            0_i64
        })
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

        for token in &state.paired_tokens {
            sqlx::query(
                r#"
                INSERT INTO paired_tokens (ws_token, token_id, device_name, issued_at_unix, expires_at_unix)
                VALUES (?1, ?2, ?3, ?4, ?5)
                "#,
            )
            .bind(&token.ws_token)
            .bind(&token.token_id)
            .bind(&token.device_name)
            .bind(i64::try_from(token.issued_at_unix).unwrap_or(0))
            .bind(i64::try_from(token.expires_at_unix).unwrap_or(0))
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

                sqlx::query(
                    r#"
                    INSERT INTO workspaces (
                        project_name, name, worktree_path, branch, status, created_at, last_accessed,
                        setup_success, setup_steps_total, setup_steps_completed, setup_last_error, setup_completed_at
                    )
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
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
                PRIMARY KEY (project_name, name)
            )
            "#,
            r#"
            CREATE TABLE IF NOT EXISTS client_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                merge_ai_agent TEXT,
                fixed_port INTEGER NOT NULL DEFAULT 0,
                remote_access_enabled INTEGER NOT NULL DEFAULT 0
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
            CREATE TABLE IF NOT EXISTS paired_tokens (
                ws_token TEXT PRIMARY KEY,
                token_id TEXT NOT NULL,
                device_name TEXT NOT NULL,
                issued_at_unix INTEGER NOT NULL,
                expires_at_unix INTEGER NOT NULL
            )
            "#,
        ];

        for sql in schema_sql {
            sqlx::query(sql)
                .execute(&self.pool)
                .await
                .map_err(|e| StateError::WriteError(e.to_string()))?;
        }
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
        state.client_settings.custom_commands = vec![CustomCommand {
            id: "cmd-1".to_string(),
            name: "Build".to_string(),
            icon: "hammer".to_string(),
            command: "cargo build".to_string(),
        }];
        state.client_settings.workspace_shortcuts =
            HashMap::from([("1".to_string(), "demo/default".to_string())]);
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
        state.paired_tokens = vec![PersistedTokenEntry {
            token_id: "token-1".to_string(),
            ws_token: "ws-token-1".to_string(),
            device_name: "iPhone".to_string(),
            issued_at_unix: 1,
            expires_at_unix: 2,
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
        assert_eq!(loaded.client_settings.custom_commands.len(), 1);
        assert_eq!(
            loaded
                .client_settings
                .workspace_shortcuts
                .get("1")
                .map(String::as_str),
            Some("demo/default")
        );
        assert_eq!(loaded.paired_tokens.len(), 1);

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
}
