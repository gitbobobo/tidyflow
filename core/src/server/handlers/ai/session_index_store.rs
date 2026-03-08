use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64_URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use sqlx::{Pool, QueryBuilder, Row, Sqlite};
use tokio::sync::Mutex;

use crate::workspace::sqlite_store;

const AI_SESSION_LIST_DEFAULT_PAGE_SIZE: u32 = 50;
const AI_SESSION_LIST_MAX_PAGE_SIZE: u32 = 200;

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiSessionIndexPage {
    pub entries: Vec<AiSessionIndexEntry>,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct AiSessionIndexCursor {
    updated_at_ms: i64,
    created_at_ms: i64,
    ai_tool: String,
    session_id: String,
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

    pub async fn list_page(
        &self,
        project_name: &str,
        workspace_name: &str,
        filter_ai_tool: Option<&str>,
        cursor: Option<&str>,
        limit: Option<u32>,
    ) -> Result<AiSessionIndexPage, String> {
        self.ensure_schema().await?;
        let pool = self.pool().await?;
        let page_size = normalize_session_list_page_size(limit);
        let decoded_cursor = decode_cursor(cursor);
        let effective_cursor = decoded_cursor.and_then(|decoded| match filter_ai_tool {
            Some(filter) if decoded.ai_tool != filter => None,
            _ => Some(decoded),
        });

        let mut builder = QueryBuilder::<Sqlite>::new(
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
            WHERE project_name =
            "#,
        );
        builder.push_bind(project_name);
        builder.push(" AND workspace_name = ");
        builder.push_bind(workspace_name);
        if let Some(filter_ai_tool) = filter_ai_tool {
            builder.push(" AND ai_tool = ");
            builder.push_bind(filter_ai_tool);
        }
        if let Some(cursor) = effective_cursor.as_ref() {
            builder.push(" AND (updated_at_ms < ");
            builder.push_bind(cursor.updated_at_ms);
            builder.push(" OR (updated_at_ms = ");
            builder.push_bind(cursor.updated_at_ms);
            builder.push(" AND created_at_ms < ");
            builder.push_bind(cursor.created_at_ms);
            builder.push(") OR (updated_at_ms = ");
            builder.push_bind(cursor.updated_at_ms);
            builder.push(" AND created_at_ms = ");
            builder.push_bind(cursor.created_at_ms);
            builder.push(" AND ai_tool > ");
            builder.push_bind(&cursor.ai_tool);
            builder.push(") OR (updated_at_ms = ");
            builder.push_bind(cursor.updated_at_ms);
            builder.push(" AND created_at_ms = ");
            builder.push_bind(cursor.created_at_ms);
            builder.push(" AND ai_tool = ");
            builder.push_bind(&cursor.ai_tool);
            builder.push(" AND session_id > ");
            builder.push_bind(&cursor.session_id);
            builder.push("))");
        }
        builder.push(
            " ORDER BY updated_at_ms DESC, created_at_ms DESC, ai_tool ASC, session_id ASC LIMIT ",
        );
        builder.push_bind(i64::from(page_size + 1));

        let rows = builder
            .build()
            .fetch_all(&pool)
            .await
            .map_err(|e| format!("failed to query ai session index page: {}", e))?;

        let mut entries = rows.into_iter().map(map_row_to_entry).collect::<Vec<_>>();
        let has_more = entries.len() > page_size as usize;
        if has_more {
            entries.truncate(page_size as usize);
        }
        let next_cursor = if has_more {
            entries.last().map(encode_cursor)
        } else {
            None
        };

        Ok(AiSessionIndexPage {
            entries,
            has_more,
            next_cursor,
        })
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

    /// 更新会话标题
    pub async fn update_title(
        &self,
        project_name: &str,
        workspace_name: &str,
        ai_tool: &str,
        session_id: &str,
        new_title: &str,
        updated_at_ms: i64,
    ) -> Result<bool, String> {
        self.ensure_schema().await?;
        let pool = self.pool().await?;

        let result = sqlx::query(
            r#"
            UPDATE ai_session_index
            SET title = ?1, updated_at_ms = ?2
            WHERE project_name = ?3
              AND workspace_name = ?4
              AND ai_tool = ?5
              AND session_id = ?6
            "#,
        )
        .bind(new_title)
        .bind(updated_at_ms)
        .bind(project_name)
        .bind(workspace_name)
        .bind(ai_tool)
        .bind(session_id)
        .execute(&pool)
        .await
        .map_err(|e| format!("failed to update ai session title: {}", e))?;

        Ok(result.rows_affected() > 0)
    }

    /// 按标题关键词搜索会话
    pub async fn search(
        &self,
        project_name: &str,
        workspace_name: &str,
        ai_tool: &str,
        query: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiSessionIndexEntry>, String> {
        self.ensure_schema().await?;
        let pool = self.pool().await?;

        let pattern = format!("%{}%", query);
        let limit_val = limit.unwrap_or(50).max(1) as i64;

        let rows = sqlx::query(
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
              AND title LIKE ?4
            ORDER BY updated_at_ms DESC, created_at_ms DESC, ai_tool ASC, session_id ASC
            LIMIT ?5
            "#,
        )
        .bind(project_name)
        .bind(workspace_name)
        .bind(ai_tool)
        .bind(&pattern)
        .bind(limit_val)
        .fetch_all(&pool)
        .await
        .map_err(|e| format!("failed to search ai session index: {}", e))?;

        Ok(rows.into_iter().map(map_row_to_entry).collect())
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
            r#"
            CREATE INDEX IF NOT EXISTS idx_ai_session_index_workspace_query
            ON ai_session_index (
                project_name,
                workspace_name,
                updated_at_ms DESC,
                created_at_ms DESC,
                ai_tool ASC,
                session_id ASC
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

fn normalize_session_list_page_size(limit: Option<u32>) -> u32 {
    match limit.unwrap_or(AI_SESSION_LIST_DEFAULT_PAGE_SIZE) {
        0 => AI_SESSION_LIST_DEFAULT_PAGE_SIZE,
        raw => raw.min(AI_SESSION_LIST_MAX_PAGE_SIZE),
    }
}

fn map_row_to_entry(row: sqlx::sqlite::SqliteRow) -> AiSessionIndexEntry {
    AiSessionIndexEntry {
        project_name: row.try_get("project_name").unwrap_or_default(),
        workspace_name: row.try_get("workspace_name").unwrap_or_default(),
        ai_tool: row.try_get("ai_tool").unwrap_or_default(),
        directory: row.try_get("directory").unwrap_or_default(),
        session_id: row.try_get("session_id").unwrap_or_default(),
        title: row.try_get("title").unwrap_or_default(),
        created_at_ms: row.try_get("created_at_ms").unwrap_or_default(),
        updated_at_ms: row.try_get("updated_at_ms").unwrap_or_default(),
    }
}

fn encode_cursor(entry: &AiSessionIndexEntry) -> String {
    let cursor = AiSessionIndexCursor {
        updated_at_ms: entry.updated_at_ms,
        created_at_ms: entry.created_at_ms,
        ai_tool: entry.ai_tool.clone(),
        session_id: entry.session_id.clone(),
    };
    let bytes = serde_json::to_vec(&cursor).unwrap_or_default();
    BASE64_URL_SAFE_NO_PAD.encode(bytes)
}

fn decode_cursor(cursor: Option<&str>) -> Option<AiSessionIndexCursor> {
    let cursor = cursor.map(str::trim).filter(|it| !it.is_empty())?;
    let decoded = BASE64_URL_SAFE_NO_PAD.decode(cursor).ok()?;
    serde_json::from_slice::<AiSessionIndexCursor>(&decoded).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn should_record_page_touch_and_delete_entries() {
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
            .list_page("p", "w", Some("codex"), None, None)
            .await
            .expect("list entries");
        assert_eq!(listed.entries.len(), 2);
        assert_eq!(listed.entries[0].session_id, "s2");
        assert_eq!(listed.entries[1].session_id, "s1");
        assert!(!listed.has_more);

        let touched = store
            .touch_updated_at("p", "w", "codex", "s1", 300)
            .await
            .expect("touch s1");
        assert!(touched);

        let listed_after_touch = store
            .list_page("p", "w", Some("codex"), None, None)
            .await
            .expect("list after touch");
        assert_eq!(listed_after_touch.entries.len(), 2);
        assert_eq!(listed_after_touch.entries[0].session_id, "s1");

        let listed_with_limit = store
            .list_page("p", "w", Some("codex"), None, Some(1))
            .await
            .expect("list with limit");
        assert_eq!(listed_with_limit.entries.len(), 1);
        assert_eq!(listed_with_limit.entries[0].session_id, "s1");
        assert!(listed_with_limit.has_more);
        assert!(listed_with_limit.next_cursor.is_some());

        let deleted = store
            .delete("p", "w", "codex", "s1")
            .await
            .expect("delete s1");
        assert!(deleted);

        let listed_after_delete = store
            .list_page("p", "w", Some("codex"), None, None)
            .await
            .expect("list after delete");
        assert_eq!(listed_after_delete.entries.len(), 1);
        assert_eq!(listed_after_delete.entries[0].session_id, "s2");
    }

    #[tokio::test]
    async fn should_keep_limit_zero_same_as_default_page_size() {
        let store = AiSessionIndexStore::open_in_memory_for_test().expect("open in-memory store");

        store
            .record_created("p", "w", "codex", "/tmp/p/w", "s1", "会话 1", 100)
            .await
            .expect("record s1");
        store
            .record_created("p", "w", "codex", "/tmp/p/w", "s2", "会话 2", 200)
            .await
            .expect("record s2");

        let all = store
            .list_page("p", "w", Some("codex"), None, None)
            .await
            .expect("list all");
        let zero_limit = store
            .list_page("p", "w", Some("codex"), None, Some(0))
            .await
            .expect("list zero limit");

        assert_eq!(all, zero_limit);
        assert_eq!(all.entries.len(), 2);
    }

    #[tokio::test]
    async fn should_paginate_across_all_tools_with_stable_cursor_order() {
        let store = AiSessionIndexStore::open_in_memory_for_test().expect("open in-memory store");

        store
            .record_created("p", "w", "opencode", "/tmp/p/w", "s1", "会话 1", 100)
            .await
            .expect("record s1");
        store
            .record_created("p", "w", "codex", "/tmp/p/w", "s2", "会话 2", 100)
            .await
            .expect("record s2");
        store
            .record_created("p", "w", "copilot", "/tmp/p/w", "s3", "会话 3", 90)
            .await
            .expect("record s3");
        store
            .touch_updated_at("p", "w", "opencode", "s1", 200)
            .await
            .expect("touch s1");
        store
            .touch_updated_at("p", "w", "codex", "s2", 200)
            .await
            .expect("touch s2");

        let first_page = store
            .list_page("p", "w", None, None, Some(1))
            .await
            .expect("first page");
        assert_eq!(first_page.entries.len(), 1);
        assert_eq!(first_page.entries[0].ai_tool, "codex");
        assert_eq!(first_page.entries[0].session_id, "s2");
        assert!(first_page.has_more);

        let second_page = store
            .list_page("p", "w", None, first_page.next_cursor.as_deref(), Some(1))
            .await
            .expect("second page");
        assert_eq!(second_page.entries.len(), 1);
        assert_eq!(second_page.entries[0].ai_tool, "opencode");
        assert_eq!(second_page.entries[0].session_id, "s1");
        assert!(second_page.has_more);

        let third_page = store
            .list_page("p", "w", None, second_page.next_cursor.as_deref(), Some(1))
            .await
            .expect("third page");
        assert_eq!(third_page.entries.len(), 1);
        assert_eq!(third_page.entries[0].ai_tool, "copilot");
        assert_eq!(third_page.entries[0].session_id, "s3");
        assert!(!third_page.has_more);
    }

    #[tokio::test]
    async fn should_fallback_to_first_page_when_cursor_invalid() {
        let store = AiSessionIndexStore::open_in_memory_for_test().expect("open in-memory store");

        store
            .record_created("p", "w", "codex", "/tmp/p/w", "s1", "会话 1", 100)
            .await
            .expect("record s1");
        store
            .record_created("p", "w", "opencode", "/tmp/p/w", "s2", "会话 2", 200)
            .await
            .expect("record s2");

        let first_page = store
            .list_page("p", "w", None, None, Some(1))
            .await
            .expect("first page");
        let invalid_cursor_page = store
            .list_page("p", "w", None, Some("not-a-valid-cursor"), Some(1))
            .await
            .expect("invalid cursor page");

        assert_eq!(first_page.entries, invalid_cursor_page.entries);
        assert_eq!(first_page.has_more, invalid_cursor_page.has_more);
    }
}
