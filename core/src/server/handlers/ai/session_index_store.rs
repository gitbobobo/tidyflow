use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use sqlx::{Pool, Row, Sqlite};
use tokio::sync::Mutex;

use crate::workspace::sqlite_store;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiSessionIndexEntry {
    pub project_name: String,
    pub workspace_name: String,
    pub ai_tool: String,
    pub directory: String,
    pub session_id: String,
    pub title: String,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

pub struct AiSessionIndexStore {
    db_url: String,
    pool: Mutex<Option<Pool<Sqlite>>>,
    schema_initialized: Arc<AtomicBool>,
}

impl AiSessionIndexStore {
    pub fn open_default() -> Result<Self, String> {
        let db_path = sqlite_store::default_db_path();
        sqlite_store::ensure_parent_dir(&db_path)
            .map_err(|e| format!("failed to create db parent directory: {}", e))?;

        Ok(Self {
            db_url: sqlite_store::sqlite_url(&db_path),
            pool: Mutex::new(None),
            schema_initialized: Arc::new(AtomicBool::new(false)),
        })
    }

    #[cfg(test)]
    pub fn open_in_memory_for_test() -> Result<Self, String> {
        Ok(Self {
            db_url: "sqlite::memory:".to_string(),
            pool: Mutex::new(None),
            schema_initialized: Arc::new(AtomicBool::new(false)),
        })
    }

    pub async fn record_created(
        &self,
        project_name: &str,
        workspace_name: &str,
        ai_tool: &str,
        directory: &str,
        session_id: &str,
        title: &str,
        created_at_ms: i64,
    ) -> Result<(), String> {
        self.ensure_schema().await?;
        let pool = self.pool().await?;

        sqlx::query(
            r#"
            INSERT INTO ai_session_index (
                project_name,
                workspace_name,
                ai_tool,
                directory,
                session_id,
                title,
                created_at_ms,
                updated_at_ms
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(project_name, workspace_name, ai_tool, session_id)
            DO UPDATE SET
                directory = excluded.directory,
                title = excluded.title,
                created_at_ms = excluded.created_at_ms,
                updated_at_ms = excluded.updated_at_ms
            "#,
        )
        .bind(project_name)
        .bind(workspace_name)
        .bind(ai_tool)
        .bind(directory)
        .bind(session_id)
        .bind(title)
        .bind(created_at_ms)
        .bind(created_at_ms)
        .execute(&pool)
        .await
        .map_err(|e| format!("failed to record ai session index: {}", e))?;

        Ok(())
    }

    pub async fn list(
        &self,
        project_name: &str,
        workspace_name: &str,
        ai_tool: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiSessionIndexEntry>, String> {
        self.ensure_schema().await?;
        let pool = self.pool().await?;

        let rows = if let Some(limit) = limit.filter(|v| *v > 0) {
            sqlx::query(
                r#"
                SELECT
                    project_name,
                    workspace_name,
                    ai_tool,
                    directory,
                    session_id,
                    title,
                    created_at_ms,
                    updated_at_ms
                FROM ai_session_index
                WHERE project_name = ?1 AND workspace_name = ?2 AND ai_tool = ?3
                ORDER BY updated_at_ms DESC, created_at_ms DESC
                LIMIT ?4
                "#,
            )
            .bind(project_name)
            .bind(workspace_name)
            .bind(ai_tool)
            .bind(i64::from(limit))
            .fetch_all(&pool)
            .await
        } else {
            sqlx::query(
                r#"
                SELECT
                    project_name,
                    workspace_name,
                    ai_tool,
                    directory,
                    session_id,
                    title,
                    created_at_ms,
                    updated_at_ms
                FROM ai_session_index
                WHERE project_name = ?1 AND workspace_name = ?2 AND ai_tool = ?3
                ORDER BY updated_at_ms DESC, created_at_ms DESC
                "#,
            )
            .bind(project_name)
            .bind(workspace_name)
            .bind(ai_tool)
            .fetch_all(&pool)
            .await
        }
        .map_err(|e| format!("failed to query ai session index list: {}", e))?;

        Ok(rows
            .into_iter()
            .map(|row| AiSessionIndexEntry {
                project_name: row.try_get("project_name").unwrap_or_default(),
                workspace_name: row.try_get("workspace_name").unwrap_or_default(),
                ai_tool: row.try_get("ai_tool").unwrap_or_default(),
                directory: row.try_get("directory").unwrap_or_default(),
                session_id: row.try_get("session_id").unwrap_or_default(),
                title: row.try_get("title").unwrap_or_default(),
                created_at_ms: row.try_get("created_at_ms").unwrap_or_default(),
                updated_at_ms: row.try_get("updated_at_ms").unwrap_or_default(),
            })
            .collect())
    }

    pub async fn touch_updated_at(
        &self,
        project_name: &str,
        workspace_name: &str,
        ai_tool: &str,
        session_id: &str,
        updated_at_ms: i64,
    ) -> Result<bool, String> {
        self.ensure_schema().await?;
        let pool = self.pool().await?;

        let result = sqlx::query(
            r#"
            UPDATE ai_session_index
            SET updated_at_ms = ?1
            WHERE project_name = ?2
              AND workspace_name = ?3
              AND ai_tool = ?4
              AND session_id = ?5
            "#,
        )
        .bind(updated_at_ms)
        .bind(project_name)
        .bind(workspace_name)
        .bind(ai_tool)
        .bind(session_id)
        .execute(&pool)
        .await
        .map_err(|e| format!("failed to touch ai session updated_at: {}", e))?;

        Ok(result.rows_affected() > 0)
    }

    pub async fn delete(
        &self,
        project_name: &str,
        workspace_name: &str,
        ai_tool: &str,
        session_id: &str,
    ) -> Result<bool, String> {
        self.ensure_schema().await?;
        let pool = self.pool().await?;

        let result = sqlx::query(
            r#"
            DELETE FROM ai_session_index
            WHERE project_name = ?1
              AND workspace_name = ?2
              AND ai_tool = ?3
              AND session_id = ?4
            "#,
        )
        .bind(project_name)
        .bind(workspace_name)
        .bind(ai_tool)
        .bind(session_id)
        .execute(&pool)
        .await
        .map_err(|e| format!("failed to delete ai session index entry: {}", e))?;

        Ok(result.rows_affected() > 0)
    }

    async fn ensure_schema(&self) -> Result<(), String> {
        if self.schema_initialized.load(Ordering::Acquire) {
            return Ok(());
        }

        let pool = self.pool().await?;
        for sql in [
            r#"
            CREATE TABLE IF NOT EXISTS ai_session_index (
                project_name TEXT NOT NULL,
                workspace_name TEXT NOT NULL,
                ai_tool TEXT NOT NULL,
                directory TEXT NOT NULL,
                session_id TEXT NOT NULL,
                title TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                PRIMARY KEY (project_name, workspace_name, ai_tool, session_id)
            )
            "#,
            r#"
            CREATE INDEX IF NOT EXISTS idx_ai_session_index_query
            ON ai_session_index (
                project_name,
                workspace_name,
                ai_tool,
                updated_at_ms DESC,
                created_at_ms DESC
            )
            "#,
        ] {
            sqlx::query(sql)
                .execute(&pool)
                .await
                .map_err(|e| format!("failed to initialize ai session index schema: {}", e))?;
        }

        self.schema_initialized.store(true, Ordering::Release);
        Ok(())
    }

    async fn pool(&self) -> Result<Pool<Sqlite>, String> {
        let mut guard = self.pool.lock().await;
        if let Some(pool) = guard.as_ref() {
            return Ok(pool.clone());
        }

        let pool = sqlite_store::open_single_connection_pool(&self.db_url)
            .await
            .map_err(|e| format!("failed to connect ai session index pool: {}", e))?;
        *guard = Some(pool.clone());
        Ok(pool)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn should_record_list_touch_and_delete_entries() {
        let store = AiSessionIndexStore::open_in_memory_for_test().expect("open in-memory store");

        store
            .record_created("p", "w", "codex", "/tmp/p/w", "s1", "会话 1", 100)
            .await
            .expect("record s1");
        store
            .record_created("p", "w", "codex", "/tmp/p/w", "s2", "会话 2", 200)
            .await
            .expect("record s2");

        let listed = store
            .list("p", "w", "codex", None)
            .await
            .expect("list entries");
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].session_id, "s2");
        assert_eq!(listed[1].session_id, "s1");

        let touched = store
            .touch_updated_at("p", "w", "codex", "s1", 300)
            .await
            .expect("touch s1");
        assert!(touched);

        let listed_after_touch = store
            .list("p", "w", "codex", None)
            .await
            .expect("list after touch");
        assert_eq!(listed_after_touch.len(), 2);
        assert_eq!(listed_after_touch[0].session_id, "s1");

        let listed_with_limit = store
            .list("p", "w", "codex", Some(1))
            .await
            .expect("list with limit");
        assert_eq!(listed_with_limit.len(), 1);
        assert_eq!(listed_with_limit[0].session_id, "s1");

        let deleted = store
            .delete("p", "w", "codex", "s1")
            .await
            .expect("delete s1");
        assert!(deleted);

        let listed_after_delete = store
            .list("p", "w", "codex", None)
            .await
            .expect("list after delete");
        assert_eq!(listed_after_delete.len(), 1);
        assert_eq!(listed_after_delete[0].session_id, "s2");
    }

    #[tokio::test]
    async fn should_keep_limit_zero_same_as_no_limit() {
        let store = AiSessionIndexStore::open_in_memory_for_test().expect("open in-memory store");

        store
            .record_created("p", "w", "codex", "/tmp/p/w", "s1", "会话 1", 100)
            .await
            .expect("record s1");
        store
            .record_created("p", "w", "codex", "/tmp/p/w", "s2", "会话 2", 200)
            .await
            .expect("record s2");

        let all = store.list("p", "w", "codex", None).await.expect("list all");
        let zero_limit = store
            .list("p", "w", "codex", Some(0))
            .await
            .expect("list zero limit");

        assert_eq!(all, zero_limit);
        assert_eq!(all.len(), 2);
    }
}
