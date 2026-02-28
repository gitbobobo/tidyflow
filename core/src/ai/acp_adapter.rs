use super::acp_client::{AcpClient, AcpConfigOptionInfo, AcpSessionMetadata, AcpSessionSummary};
use super::codex_manager::{AcpContentEncodingMode, CodexAppServerManager};
use super::context_usage::{extract_context_remaining_percent, AiSessionContextUsage};
use super::{
    AiAgent, AiAgentInfo, AiAudioPart, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiQuestionInfo, AiQuestionOption, AiQuestionRequest,
    AiSession, AiSessionConfigOption, AiSessionConfigOptionChoice,
    AiSessionConfigOptionChoiceGroup, AiSessionConfigValue, AiSessionSelectionHint, AiSlashCommand,
    AiToolCallLocation,
};
use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chrono::Utc;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio::time::Duration;
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::{debug, warn};
use url::Url;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct AcpBackendProfile {
    pub tool_id: String,
    pub provider_id: String,
    pub provider_name: String,
    pub message_id_prefix: String,
}

impl AcpBackendProfile {
    pub fn copilot() -> Self {
        Self {
            tool_id: "copilot".to_string(),
            provider_id: "copilot".to_string(),
            provider_name: "Copilot".to_string(),
            message_id_prefix: "copilot".to_string(),
        }
    }

    pub fn kimi() -> Self {
        Self {
            tool_id: "kimi".to_string(),
            provider_id: "kimi".to_string(),
            provider_name: "Kimi".to_string(),
            message_id_prefix: "kimi".to_string(),
        }
    }
}

#[derive(Debug, Clone)]
struct PermissionOption {
    option_id: String,
    normalized_name: String,
}

#[derive(Debug, Clone)]
struct PendingPermission {
    request_id: Value,
    session_id: String,
    options: Vec<PermissionOption>,
}

#[derive(Debug, Clone)]
struct CachedSessionRecord {
    title: String,
    updated_at_ms: i64,
    messages: Vec<AiMessage>,
}

#[derive(Debug, Clone)]
struct ResolvedPromptFileRef {
    original: String,
    path: PathBuf,
    uri: String,
    name: String,
    mime: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AcpPlanEntry {
    content: String,
    status: String,
    priority: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AcpPlanSnapshot {
    revision: u64,
    updated_at_ms: i64,
    entries: Vec<AcpPlanEntry>,
}

#[derive(Debug, Clone)]
struct ParsedToolCallUpdate {
    tool_call_id: Option<String>,
    tool_name: String,
    tool_kind: Option<String>,
    tool_title: Option<String>,
    status: Option<String>,
    raw_input: Option<Value>,
    raw_output: Option<Value>,
    locations: Option<Vec<AiToolCallLocation>>,
    progress_delta: Option<String>,
    output_delta: Option<String>,
    tool_part_metadata: Value,
}

static UNKNOWN_CONTENT_TYPE_COUNT: AtomicU64 = AtomicU64::new(0);
static TOOL_CALL_UPDATE_MISSING_ID_COUNT: AtomicU64 = AtomicU64::new(0);
static FOLLOW_ALONG_CREATE_FAILURE_COUNT: AtomicU64 = AtomicU64::new(0);
static FOLLOW_ALONG_RELEASE_FAILURE_COUNT: AtomicU64 = AtomicU64::new(0);

pub struct AcpAgent {
    client: AcpClient,
    profile: AcpBackendProfile,
    metadata_by_directory: Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
    metadata_by_session: Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
    slash_commands_by_directory: Arc<Mutex<HashMap<String, Vec<AiSlashCommand>>>>,
    slash_commands_by_session: Arc<Mutex<HashMap<String, Vec<AiSlashCommand>>>>,
    pending_permissions: Arc<Mutex<HashMap<String, PendingPermission>>>,
    cached_sessions: Arc<Mutex<HashMap<String, HashMap<String, CachedSessionRecord>>>>,
    runtime_yolo_sessions: Arc<Mutex<HashSet<String>>>,
}

impl AcpAgent {
    const SESSION_LOAD_TIMEOUT_SECS: u64 = 4;
    const PLAN_HISTORY_LIMIT: usize = 20;
    const EMBED_TEXT_LIMIT_BYTES: usize = 256 * 1024;
    const EMBED_BLOB_LIMIT_BYTES: usize = 1024 * 1024;

    pub fn new(manager: Arc<CodexAppServerManager>, profile: AcpBackendProfile) -> Self {
        Self {
            client: AcpClient::new(manager),
            profile,
            metadata_by_directory: Arc::new(Mutex::new(HashMap::new())),
            metadata_by_session: Arc::new(Mutex::new(HashMap::new())),
            slash_commands_by_directory: Arc::new(Mutex::new(HashMap::new())),
            slash_commands_by_session: Arc::new(Mutex::new(HashMap::new())),
            pending_permissions: Arc::new(Mutex::new(HashMap::new())),
            cached_sessions: Arc::new(Mutex::new(HashMap::new())),
            runtime_yolo_sessions: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    pub fn new_copilot(manager: Arc<CodexAppServerManager>) -> Self {
        Self::new(manager, AcpBackendProfile::copilot())
    }

    pub fn new_kimi(manager: Arc<CodexAppServerManager>) -> Self {
        Self::new(manager, AcpBackendProfile::kimi())
    }

    fn normalize_directory(directory: &str) -> String {
        let trimmed = directory.trim();
        if trimmed.is_empty() {
            return String::new();
        }
        let as_path = if let Ok(url) = Url::parse(trimmed) {
            if url.scheme().eq_ignore_ascii_case("file") {
                url.to_file_path()
                    .ok()
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_else(|| trimmed.to_string())
            } else {
                trimmed.to_string()
            }
        } else {
            trimmed.to_string()
        };
        as_path.trim_end_matches('/').to_string()
    }

    fn session_cache_key(directory: &str, session_id: &str) -> String {
        format!("{}::{}", Self::normalize_directory(directory), session_id)
    }

    fn should_auto_enable_runtime_yolo(&self) -> bool {
        self.profile.tool_id == "kimi"
    }

    async fn ensure_runtime_yolo_for_session(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<(), String> {
        if !self.should_auto_enable_runtime_yolo() {
            return Ok(());
        }

        let session_key = Self::session_cache_key(directory, session_id);
        {
            let sessions = self.runtime_yolo_sessions.lock().await;
            if sessions.contains(&session_key) {
                return Ok(());
            }
        }

        let yolo_prompt = vec![serde_json::json!({
            "type": "text",
            "text": "/yolo"
        })];
        let supports_load_session = self.client.supports_load_session().await;
        let result = match self
            .client
            .session_prompt(session_id, yolo_prompt.clone(), None, None)
            .await
        {
            Ok(_) => Ok(()),
            Err(err) if Self::is_session_not_found(&err) => {
                if supports_load_session {
                    self.client.session_load(directory, session_id).await?;
                    self.client
                        .session_prompt(session_id, yolo_prompt, None, None)
                        .await
                        .map(|_| ())
                } else {
                    Err(err)
                }
            }
            Err(err) => Err(err),
        };

        match result {
            Ok(()) => {
                self.runtime_yolo_sessions.lock().await.insert(session_key);
                Ok(())
            }
            Err(err) => Err(format!("enable kimi runtime yolo failed: {}", err)),
        }
    }

    fn now_ms() -> i64 {
        Utc::now().timestamp_millis()
    }

    fn normalized_title(raw: Option<&str>) -> Option<String> {
        let title = raw?;
        let trimmed = title.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    }

    async fn upsert_cached_session_in_map(
        cache: &Arc<Mutex<HashMap<String, HashMap<String, CachedSessionRecord>>>>,
        directory: &str,
        session_id: &str,
        title: Option<&str>,
        updated_at_ms: Option<i64>,
    ) {
        let directory_key = Self::normalize_directory(directory);
        let mut sessions = cache.lock().await;
        let by_session = sessions.entry(directory_key).or_default();
        let entry =
            by_session
                .entry(session_id.to_string())
                .or_insert_with(|| CachedSessionRecord {
                    title: Self::normalized_title(title).unwrap_or_else(|| "New Chat".to_string()),
                    updated_at_ms: updated_at_ms.unwrap_or_else(Self::now_ms),
                    messages: Vec::new(),
                });
        if let Some(next_title) = Self::normalized_title(title) {
            entry.title = next_title;
        }
        entry.updated_at_ms = entry
            .updated_at_ms
            .max(updated_at_ms.unwrap_or_else(Self::now_ms));
    }

    async fn append_cached_message_in_map(
        cache: &Arc<Mutex<HashMap<String, HashMap<String, CachedSessionRecord>>>>,
        directory: &str,
        session_id: &str,
        message: AiMessage,
    ) {
        let directory_key = Self::normalize_directory(directory);
        let mut sessions = cache.lock().await;
        let by_session = sessions.entry(directory_key).or_default();
        let entry =
            by_session
                .entry(session_id.to_string())
                .or_insert_with(|| CachedSessionRecord {
                    title: "New Chat".to_string(),
                    updated_at_ms: Self::now_ms(),
                    messages: Vec::new(),
                });
        entry.messages.push(message);
        entry.updated_at_ms = Self::now_ms();
    }

    async fn replace_cached_messages_in_map(
        cache: &Arc<Mutex<HashMap<String, HashMap<String, CachedSessionRecord>>>>,
        directory: &str,
        session_id: &str,
        messages: Vec<AiMessage>,
    ) {
        let directory_key = Self::normalize_directory(directory);
        let mut sessions = cache.lock().await;
        let by_session = sessions.entry(directory_key).or_default();
        let entry =
            by_session
                .entry(session_id.to_string())
                .or_insert_with(|| CachedSessionRecord {
                    title: "New Chat".to_string(),
                    updated_at_ms: Self::now_ms(),
                    messages: Vec::new(),
                });
        entry.messages = messages;
        entry.updated_at_ms = Self::now_ms();
    }

    async fn upsert_cached_session(
        &self,
        directory: &str,
        session_id: &str,
        title: Option<&str>,
        updated_at_ms: Option<i64>,
    ) {
        Self::upsert_cached_session_in_map(
            &self.cached_sessions,
            directory,
            session_id,
            title,
            updated_at_ms,
        )
        .await;
    }

    async fn append_cached_message(&self, directory: &str, session_id: &str, message: AiMessage) {
        Self::append_cached_message_in_map(&self.cached_sessions, directory, session_id, message)
            .await;
    }

    async fn replace_cached_messages(
        &self,
        directory: &str,
        session_id: &str,
        messages: Vec<AiMessage>,
    ) {
        Self::replace_cached_messages_in_map(
            &self.cached_sessions,
            directory,
            session_id,
            messages,
        )
        .await;
    }

    async fn cached_messages_for_session(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Option<Vec<AiMessage>> {
        let directory_key = Self::normalize_directory(directory);
        let sessions = self.cached_sessions.lock().await;
        sessions
            .get(&directory_key)
            .and_then(|by_session| by_session.get(session_id))
            .map(|entry| entry.messages.clone())
    }

    async fn cached_sessions_for_directory(&self, directory: &str) -> Vec<AiSession> {
        let directory_key = Self::normalize_directory(directory);
        let sessions = self.cached_sessions.lock().await;
        let mut cached = sessions
            .get(&directory_key)
            .map(|by_session| {
                by_session
                    .iter()
                    .map(|(session_id, entry)| AiSession {
                        id: session_id.clone(),
                        title: entry.title.clone(),
                        updated_at: entry.updated_at_ms,
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        cached.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        cached
    }

    fn merge_sessions(remote: Vec<AiSession>, cached: Vec<AiSession>) -> Vec<AiSession> {
        let mut merged = HashMap::<String, AiSession>::new();
        for session in cached.into_iter().chain(remote.into_iter()) {
            if let Some(existing) = merged.get_mut(&session.id) {
                existing.updated_at = existing.updated_at.max(session.updated_at);
                if existing.title.trim().is_empty() && !session.title.trim().is_empty() {
                    existing.title = session.title;
                }
            } else {
                merged.insert(session.id.clone(), session);
            }
        }
        let mut sessions = merged.into_values().collect::<Vec<_>>();
        sessions.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        sessions
    }

    fn build_cached_user_message(message_id: String, text: String) -> AiMessage {
        AiMessage {
            id: message_id.clone(),
            role: "user".to_string(),
            created_at: Some(Self::now_ms()),
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: vec![AiPart::new_text(format!("{}-text", message_id), text)],
        }
    }

    fn normalize_optional_string(value: Option<&Value>) -> Option<String> {
        value
            .and_then(|v| v.as_str())
            .map(|v| v.trim())
            .filter(|v| !v.is_empty())
            .map(|v| v.to_string())
    }

    fn parse_plan_entry(value: &Value) -> Option<AcpPlanEntry> {
        let obj = value.as_object()?;
        let content = Self::normalize_optional_string(obj.get("content"))?;
        let status = Self::normalize_optional_string(obj.get("status"))?;
        let priority = Self::normalize_optional_string(obj.get("priority"));
        Some(AcpPlanEntry {
            content,
            status,
            priority,
        })
    }

    fn extract_plan_entries(update: &Value) -> Option<Vec<AcpPlanEntry>> {
        let entries_value = update
            .get("entries")
            .or_else(|| update.get("content").and_then(|v| v.get("entries")))?;
        let items = entries_value.as_array()?;
        Some(
            items
                .iter()
                .filter_map(Self::parse_plan_entry)
                .collect::<Vec<_>>(),
        )
    }

    fn is_plan_update(session_update: &str) -> bool {
        Self::normalized_update_token(session_update) == "plan"
    }

    fn apply_plan_update(
        current: &mut Option<AcpPlanSnapshot>,
        history: &mut Vec<AcpPlanSnapshot>,
        revision: &mut u64,
        entries: Vec<AcpPlanEntry>,
    ) -> AcpPlanSnapshot {
        if let Some(previous) = current.take() {
            history.push(previous);
            if history.len() > Self::PLAN_HISTORY_LIMIT {
                let overflow = history.len() - Self::PLAN_HISTORY_LIMIT;
                history.drain(0..overflow);
            }
        }
        *revision = revision.saturating_add(1);
        let snapshot = AcpPlanSnapshot {
            revision: *revision,
            updated_at_ms: Self::now_ms(),
            entries,
        };
        *current = Some(snapshot.clone());
        snapshot
    }

    fn plan_entries_to_value(entries: &[AcpPlanEntry]) -> Value {
        Value::Array(
            entries
                .iter()
                .map(|entry| {
                    let mut obj = serde_json::Map::new();
                    obj.insert("content".to_string(), Value::String(entry.content.clone()));
                    obj.insert("status".to_string(), Value::String(entry.status.clone()));
                    if let Some(priority) = entry.priority.clone() {
                        obj.insert("priority".to_string(), Value::String(priority));
                    }
                    Value::Object(obj)
                })
                .collect::<Vec<_>>(),
        )
    }

    fn plan_snapshot_to_value(snapshot: &AcpPlanSnapshot) -> Value {
        serde_json::json!({
            "revision": snapshot.revision,
            "updated_at_ms": snapshot.updated_at_ms,
            "entries": Self::plan_entries_to_value(&snapshot.entries),
        })
    }

    fn build_plan_source(current: &AcpPlanSnapshot, history: &[AcpPlanSnapshot]) -> Value {
        let history_values = history
            .iter()
            .map(Self::plan_snapshot_to_value)
            .collect::<Vec<_>>();
        serde_json::json!({
            "vendor": "acp",
            "item_type": "plan",
            "protocol": "agent-plan",
            "revision": current.revision,
            "updated_at_ms": current.updated_at_ms,
            "entries": Self::plan_entries_to_value(&current.entries),
            "history": history_values,
        })
    }

    fn build_plan_part(
        message_id: &str,
        current: &AcpPlanSnapshot,
        history: &[AcpPlanSnapshot],
    ) -> AiPart {
        AiPart {
            id: format!("{}-plan", message_id),
            part_type: "plan".to_string(),
            source: Some(Self::build_plan_source(current, history)),
            ..Default::default()
        }
    }

    fn flush_plan_snapshot_for_history(
        messages: &mut Vec<AiMessage>,
        message_id_prefix: &str,
        next_message_index: &mut u64,
        plan_current: &mut Option<AcpPlanSnapshot>,
        plan_history: &mut Vec<AcpPlanSnapshot>,
    ) {
        let Some(current) = plan_current.take() else {
            return;
        };
        *next_message_index = next_message_index.saturating_add(1);
        let message_id = format!(
            "{}-assistant-plan-{}",
            message_id_prefix, next_message_index
        );
        let plan_part = Self::build_plan_part(&message_id, &current, plan_history);
        messages.push(AiMessage {
            id: message_id,
            role: "assistant".to_string(),
            created_at: Some(Self::now_ms()),
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: vec![plan_part],
        });
        plan_history.clear();
    }

    fn build_cached_assistant_message(
        message_id: String,
        reasoning_text: String,
        answer_text: String,
        plan_current: Option<AcpPlanSnapshot>,
        plan_history: Vec<AcpPlanSnapshot>,
    ) -> Option<AiMessage> {
        let mut parts = Vec::new();
        if !reasoning_text.is_empty() {
            parts.push(AiPart {
                id: format!("{}-reasoning", message_id),
                part_type: "reasoning".to_string(),
                text: Some(reasoning_text),
                ..Default::default()
            });
        }
        if !answer_text.is_empty() {
            parts.push(AiPart::new_text(
                format!("{}-text", message_id),
                answer_text,
            ));
        }
        if let Some(current) = plan_current.as_ref() {
            parts.push(Self::build_plan_part(&message_id, current, &plan_history));
        }
        if parts.is_empty() {
            return None;
        }
        Some(AiMessage {
            id: message_id,
            role: "assistant".to_string(),
            created_at: Some(Self::now_ms()),
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts,
        })
    }

    async fn cache_metadata(&self, directory: &str, metadata: AcpSessionMetadata) {
        self.metadata_by_directory
            .lock()
            .await
            .insert(Self::normalize_directory(directory), metadata);
    }

    async fn cache_session_metadata(
        &self,
        directory: &str,
        session_id: &str,
        metadata: AcpSessionMetadata,
    ) {
        self.metadata_by_session
            .lock()
            .await
            .insert(Self::session_cache_key(directory, session_id), metadata);
    }

    async fn metadata_for_session(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Option<AcpSessionMetadata> {
        self.metadata_by_session
            .lock()
            .await
            .get(&Self::session_cache_key(directory, session_id))
            .cloned()
    }

    async fn metadata_for_directory(&self, directory: &str) -> AcpSessionMetadata {
        let key = Self::normalize_directory(directory);
        if let Some(meta) = self.metadata_by_directory.lock().await.get(&key).cloned() {
            if !meta.models.is_empty() || !meta.modes.is_empty() || !meta.config_options.is_empty()
            {
                return meta;
            }
        }

        // 缓存为空时，通过 session/new 主动获取模型/模式元数据。
        // 不用 session/load 是为了避免把历史会话置为 loaded 导致后续
        // "Session ... is already loaded" 错误。session/new 创建的会话
        // 后续可被正常使用或自然过期，不会产生副作用。
        if self.client.ensure_started().await.is_ok() {
            if let Ok((_session_id, metadata)) = self.client.session_new(directory).await {
                self.cache_metadata(directory, metadata.clone()).await;
                return metadata;
            }
        }

        AcpSessionMetadata::default()
    }

    async fn list_sessions_for_directory(
        &self,
        directory: &str,
        max_pages: usize,
    ) -> Result<Vec<AcpSessionSummary>, String> {
        self.client.ensure_started().await?;
        let expected = Self::normalize_directory(directory);
        let mut sessions = Vec::new();
        let mut cursor: Option<String> = None;

        for _ in 0..max_pages {
            let (page, next_cursor) = self.client.session_list_page(cursor.as_deref()).await?;
            let (selected, used_fallback) = Self::select_sessions_for_directory(page, &expected);
            if used_fallback {
                warn!(
                    "{}: session/list missing cwd for current directory, fallback to unknown-cwd sessions",
                    self.profile.tool_id
                );
            }
            sessions.extend(selected);
            match next_cursor {
                Some(next) if !next.is_empty() => cursor = Some(next),
                _ => break,
            }
        }

        sessions.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms));
        Ok(sessions)
    }

    fn normalize_mode_name(raw: &str) -> String {
        raw.trim().to_lowercase()
    }

    fn normalize_non_empty_token(raw: &str) -> Option<String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    }

    fn is_set_mode_unsupported(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("-32601")
            || normalized.contains("method not found")
            || normalized.contains("unknown method")
            || normalized.contains("not supported")
    }

    fn is_set_config_option_unsupported(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("-32601")
            || normalized.contains("method not found")
            || normalized.contains("unknown method")
            || normalized.contains("not supported")
            || normalized.contains("set_config_option")
    }

    fn is_rpc_method_unsupported(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("-32601")
            || normalized.contains("method not found")
            || normalized.contains("unknown method")
            || normalized.contains("not supported")
            || normalized.contains("unsupported")
    }

    fn normalize_tool_status(raw: Option<&str>, default_status: &str) -> String {
        let token = raw
            .map(Self::normalized_update_token)
            .unwrap_or_else(|| Self::normalized_update_token(default_status));
        if token.is_empty() {
            return "running".to_string();
        }
        if matches!(
            token.as_str(),
            "pending" | "queued" | "todo" | "created" | "scheduled"
        ) {
            return "pending".to_string();
        }
        if token == "awaiting_input"
            || token == "requires_input"
            || token == "waiting_input"
            || token == "waiting_for_input"
        {
            return "awaiting_input".to_string();
        }
        if token == "running"
            || token == "in_progress"
            || token.contains("progress")
            || token == "executing"
            || token == "active"
        {
            return "running".to_string();
        }
        if token == "completed"
            || token == "done"
            || token == "success"
            || token == "succeeded"
            || token == "finished"
        {
            return "completed".to_string();
        }
        if token == "error"
            || token == "failed"
            || token == "rejected"
            || token == "cancelled"
            || token == "canceled"
            || token == "aborted"
        {
            return "error".to_string();
        }
        token
    }

    fn status_is_terminal(status: &str) -> bool {
        matches!(
            status,
            "completed" | "error" | "done" | "failed" | "cancelled" | "canceled"
        )
    }

    fn log_unknown_content_type(tool_id: &str, context: &str, content_type: &str) {
        let count = UNKNOWN_CONTENT_TYPE_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
        warn!(
            "{}: unknown ACP content type in {}, type={}, count={}",
            tool_id, context, content_type, count
        );
    }

    fn log_missing_tool_call_id(tool_id: &str, context: &str) {
        let count = TOOL_CALL_UPDATE_MISSING_ID_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
        warn!(
            "{}: tool_call_update missing toolCallId in {}, fallback to random part id, count={}",
            tool_id, context, count
        );
    }

    fn log_follow_along_failure(tool_id: &str, operation: &str, detail: &str) {
        let count = match operation {
            "create" => FOLLOW_ALONG_CREATE_FAILURE_COUNT.fetch_add(1, Ordering::Relaxed) + 1,
            "release" => FOLLOW_ALONG_RELEASE_FAILURE_COUNT.fetch_add(1, Ordering::Relaxed) + 1,
            _ => 0,
        };
        if count > 0 {
            warn!(
                "{}: ACP follow-along {} failed, count={}, detail={}",
                tool_id, operation, count, detail
            );
        } else {
            warn!(
                "{}: ACP follow-along {} failed, detail={}",
                tool_id, operation, detail
            );
        }
    }

    fn tool_status_rank(status: &str) -> u8 {
        match status {
            "unknown" => 0,
            "pending" => 1,
            "running" | "in_progress" | "awaiting_input" => 2,
            "completed" | "done" | "success" | "succeeded" => 3,
            "error" | "failed" | "rejected" | "cancelled" | "canceled" => 4,
            _ => 1,
        }
    }

    fn resolve_merged_tool_status(previous: Option<&str>, incoming: &str) -> String {
        let incoming_normalized = Self::normalize_tool_status(Some(incoming), "running");
        let Some(previous_raw) = previous else {
            return incoming_normalized;
        };
        let previous_normalized = Self::normalize_tool_status(Some(previous_raw), "running");

        if Self::status_is_terminal(&previous_normalized)
            && !Self::status_is_terminal(&incoming_normalized)
        {
            return previous_normalized;
        }

        let previous_rank = Self::tool_status_rank(&previous_normalized);
        let incoming_rank = Self::tool_status_rank(&incoming_normalized);
        if incoming_rank >= previous_rank {
            incoming_normalized
        } else {
            previous_normalized
        }
    }

    fn parse_u32_from_value(value: Option<&Value>) -> Option<u32> {
        match value {
            Some(Value::Number(num)) => num.as_u64().map(|v| v as u32),
            Some(Value::String(text)) => text.trim().parse::<u32>().ok(),
            _ => None,
        }
    }

    fn parse_tool_call_location(value: &Value) -> Option<AiToolCallLocation> {
        let obj = value.as_object()?;
        let range = obj.get("range").and_then(|v| v.as_object());
        let start = range
            .and_then(|r| r.get("start"))
            .and_then(|v| v.as_object());
        let end = range.and_then(|r| r.get("end")).and_then(|v| v.as_object());
        let uri = obj
            .get("uri")
            .or_else(|| obj.get("url"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token);
        let path = obj
            .get("path")
            .or_else(|| obj.get("file"))
            .or_else(|| obj.get("filePath"))
            .or_else(|| obj.get("file_path"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token);
        let line = Self::parse_u32_from_value(
            obj.get("line")
                .or_else(|| start.and_then(|it| it.get("line"))),
        );
        let column = Self::parse_u32_from_value(
            obj.get("column")
                .or_else(|| start.and_then(|it| it.get("column"))),
        );
        let end_line = Self::parse_u32_from_value(
            obj.get("endLine")
                .or_else(|| obj.get("end_line"))
                .or_else(|| end.and_then(|it| it.get("line"))),
        );
        let end_column = Self::parse_u32_from_value(
            obj.get("endColumn")
                .or_else(|| obj.get("end_column"))
                .or_else(|| end.and_then(|it| it.get("column"))),
        );
        let label = obj
            .get("label")
            .or_else(|| obj.get("title"))
            .or_else(|| obj.get("name"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token);

        if uri.is_none()
            && path.is_none()
            && line.is_none()
            && column.is_none()
            && end_line.is_none()
            && end_column.is_none()
            && label.is_none()
        {
            return None;
        }
        Some(AiToolCallLocation {
            uri,
            path,
            line,
            column,
            end_line,
            end_column,
            label,
        })
    }

    fn parse_tool_call_locations(
        content: &serde_json::Map<String, Value>,
    ) -> Option<Vec<AiToolCallLocation>> {
        let locations_value = content
            .get("locations")
            .or_else(|| content.get("toolCallLocations"))
            .or_else(|| content.get("tool_call_locations"));
        let mut locations = Vec::new();
        if let Some(items) = locations_value.and_then(|v| v.as_array()) {
            for item in items {
                if let Some(parsed) = Self::parse_tool_call_location(item) {
                    locations.push(parsed);
                }
            }
        }
        if locations.is_empty() {
            None
        } else {
            Some(locations)
        }
    }

    fn tool_locations_to_json(locations: &[AiToolCallLocation]) -> Value {
        Value::Array(
            locations
                .iter()
                .map(|location| {
                    serde_json::json!({
                        "uri": location.uri,
                        "path": location.path,
                        "line": location.line,
                        "column": location.column,
                        "endLine": location.end_line,
                        "endColumn": location.end_column,
                        "label": location.label,
                    })
                })
                .collect::<Vec<_>>(),
        )
    }

    fn extract_tool_output_text(value: &Value) -> Option<String> {
        match value {
            Value::String(text) => Self::normalize_non_empty_token(text),
            Value::Object(obj) => {
                let pick_str = |keys: &[&str]| -> Option<String> {
                    keys.iter().find_map(|key| {
                        obj.get(*key)
                            .and_then(|v| v.as_str())
                            .and_then(Self::normalize_non_empty_token)
                    })
                };
                let content_type = obj
                    .get("type")
                    .and_then(|v| v.as_str())
                    .map(Self::normalized_update_token)
                    .unwrap_or_default();
                if content_type == "terminal" {
                    return pick_str(&["output", "text", "delta", "message"]);
                }
                if content_type == "diff" {
                    return pick_str(&["diff", "patch", "text", "delta"]);
                }
                if content_type == "markdown" || content_type == "md" {
                    return pick_str(&["markdown", "text", "content"]);
                }
                pick_str(&["text", "content", "output", "delta"])
            }
            _ => None,
        }
    }

    fn parse_tool_call_update_content(
        content: &serde_json::Map<String, Value>,
    ) -> Option<ParsedToolCallUpdate> {
        let content_type = Self::normalized_content_type(content);
        if content_type != "tool_call" && content_type != "tool_call_update" {
            return None;
        }
        let tool_call_id = content
            .get("toolCallId")
            .or_else(|| content.get("tool_call_id"))
            .or_else(|| content.get("id"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token);
        let tool_kind = content
            .get("kind")
            .or_else(|| content.get("toolKind"))
            .or_else(|| content.get("tool_kind"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token);
        let tool_name = content
            .get("toolName")
            .or_else(|| content.get("tool_name"))
            .or_else(|| content.get("name"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token)
            .or_else(|| tool_kind.clone())
            .unwrap_or_else(|| "unknown".to_string());
        let tool_title = content
            .get("title")
            .or_else(|| content.get("label"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token);
        let status = Some(Self::normalize_tool_status(
            content
                .get("status")
                .or_else(|| content.get("state"))
                .and_then(|v| v.as_str()),
            if content_type == "tool_call" {
                "running"
            } else {
                "unknown"
            },
        ));
        let raw_input = content
            .get("rawInput")
            .or_else(|| content.get("raw_input"))
            .or_else(|| content.get("input"))
            .cloned()
            .filter(|v| !v.is_null());
        let nested_content = content.get("content").cloned().filter(|v| !v.is_null());
        let raw_output = content
            .get("rawOutput")
            .or_else(|| content.get("raw_output"))
            .cloned()
            .filter(|v| !v.is_null())
            .or_else(|| nested_content.clone());
        let locations = Self::parse_tool_call_locations(content).or_else(|| {
            raw_output
                .as_ref()
                .and_then(|v| v.get("locations"))
                .and_then(|v| v.as_array())
                .map(|rows| {
                    rows.iter()
                        .filter_map(Self::parse_tool_call_location)
                        .collect::<Vec<_>>()
                })
                .filter(|rows| !rows.is_empty())
        });

        let progress_delta = content
            .get("progress")
            .or_else(|| content.get("message"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token)
            .or_else(|| {
                nested_content
                    .as_ref()
                    .and_then(Self::extract_tool_output_text)
                    .filter(|_| {
                        nested_content
                            .as_ref()
                            .and_then(|v| v.get("type"))
                            .and_then(|v| v.as_str())
                            .map(|token| Self::normalized_update_token(token) == "terminal")
                            .unwrap_or(false)
                    })
            });

        let output_delta = content
            .get("output")
            .or_else(|| content.get("text"))
            .or_else(|| content.get("delta"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token)
            .or_else(|| {
                nested_content
                    .as_ref()
                    .and_then(Self::extract_tool_output_text)
            });

        Some(ParsedToolCallUpdate {
            tool_call_id,
            tool_name,
            tool_kind,
            tool_title,
            status,
            raw_input,
            raw_output,
            locations,
            progress_delta,
            output_delta,
            tool_part_metadata: Value::Object(content.clone()),
        })
    }

    fn tool_state_from_parsed_tool_update(parsed: &ParsedToolCallUpdate) -> Value {
        let mut state = serde_json::Map::<String, Value>::new();
        state.insert(
            "status".to_string(),
            Value::String(
                parsed
                    .status
                    .clone()
                    .unwrap_or_else(|| "running".to_string()),
            ),
        );
        if let Some(title) = parsed.tool_title.clone() {
            state.insert("title".to_string(), Value::String(title));
        }
        if let Some(raw_input) = parsed.raw_input.clone() {
            state.insert("input".to_string(), raw_input);
        }
        if let Some(raw_output) = parsed.raw_output.clone() {
            state.insert("raw".to_string(), raw_output.clone());
            if let Some(output_text) = Self::extract_tool_output_text(&raw_output) {
                state.insert("output".to_string(), Value::String(output_text));
            }
        }
        let mut metadata = serde_json::Map::<String, Value>::new();
        if let Some(kind) = parsed.tool_kind.clone() {
            metadata.insert("kind".to_string(), Value::String(kind));
        }
        if let Some(tool_call_id) = parsed.tool_call_id.clone() {
            metadata.insert("tool_call_id".to_string(), Value::String(tool_call_id));
        }
        if let Some(locations) = parsed.locations.as_ref() {
            metadata.insert(
                "locations".to_string(),
                Self::tool_locations_to_json(locations),
            );
        }
        if !metadata.is_empty() {
            state.insert("metadata".to_string(), Value::Object(metadata));
        }
        Value::Object(state)
    }

    fn append_tool_state_deltas(
        tool_state: &mut Value,
        progress_delta: Option<&str>,
        output_delta: Option<&str>,
    ) {
        let Some(obj) = tool_state.as_object_mut() else {
            return;
        };
        if let Some(progress) = progress_delta.and_then(Self::normalize_non_empty_token) {
            let metadata = obj
                .entry("metadata".to_string())
                .or_insert_with(|| Value::Object(serde_json::Map::new()));
            if let Some(metadata_obj) = metadata.as_object_mut() {
                let lines = metadata_obj
                    .entry("progress_lines".to_string())
                    .or_insert_with(|| Value::Array(Vec::new()));
                if let Some(array) = lines.as_array_mut() {
                    array.push(Value::String(progress));
                }
            }
        }
        if let Some(output) = output_delta.and_then(Self::normalize_non_empty_token) {
            let previous = obj.get("output").and_then(|v| v.as_str()).unwrap_or("");
            let merged = if previous.ends_with(&output) {
                previous.to_string()
            } else {
                format!("{}{}", previous, output)
            };
            obj.insert("output".to_string(), Value::String(merged));
        }
    }

    fn merge_progress_lines(previous: Option<&Value>, incoming: Option<&Value>) -> Option<Value> {
        let mut lines = Vec::<String>::new();
        if let Some(rows) = previous.and_then(|v| v.as_array()) {
            for row in rows {
                if let Some(text) = row.as_str().and_then(Self::normalize_non_empty_token) {
                    lines.push(text);
                }
            }
        }
        if let Some(rows) = incoming.and_then(|v| v.as_array()) {
            for row in rows {
                if let Some(text) = row.as_str().and_then(Self::normalize_non_empty_token) {
                    lines.push(text);
                }
            }
        }
        if lines.is_empty() {
            None
        } else {
            Some(Value::Array(
                lines.into_iter().map(Value::String).collect::<Vec<_>>(),
            ))
        }
    }

    fn merge_tool_output(
        previous: Option<&str>,
        incoming: Option<&str>,
        output_delta: Option<&str>,
    ) -> Option<String> {
        let prev = previous.unwrap_or("");
        let incoming = incoming.unwrap_or("");
        let delta = output_delta.and_then(Self::normalize_non_empty_token);

        if let Some(delta) = delta {
            let mut merged = String::from(prev);
            merged.push_str(&delta);
            return Self::normalize_non_empty_token(&merged);
        }

        if prev.is_empty() {
            return Self::normalize_non_empty_token(incoming);
        }
        if incoming.is_empty() {
            return Self::normalize_non_empty_token(prev);
        }
        if incoming.starts_with(prev) {
            return Some(incoming.to_string());
        }
        if prev.ends_with(incoming) {
            return Some(prev.to_string());
        }
        let mut merged = String::from(prev);
        merged.push_str(incoming);
        Self::normalize_non_empty_token(&merged)
    }

    fn merge_tool_state(previous: Option<&Value>, parsed: &ParsedToolCallUpdate) -> Value {
        let mut incoming = Self::tool_state_from_parsed_tool_update(parsed);
        Self::append_tool_state_deltas(
            &mut incoming,
            parsed.progress_delta.as_deref(),
            parsed.output_delta.as_deref(),
        );

        let mut merged_obj = previous
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        let incoming_obj = incoming.as_object().cloned().unwrap_or_default();

        let previous_status = merged_obj.get("status").and_then(|v| v.as_str());
        let incoming_status = incoming_obj
            .get("status")
            .and_then(|v| v.as_str())
            .unwrap_or("running");
        let resolved_status = Self::resolve_merged_tool_status(previous_status, incoming_status);
        merged_obj.insert("status".to_string(), Value::String(resolved_status));

        for key in ["title", "input", "raw", "error", "attachments", "time"] {
            if let Some(value) = incoming_obj.get(key) {
                merged_obj.insert(key.to_string(), value.clone());
            }
        }

        let merged_output = Self::merge_tool_output(
            merged_obj.get("output").and_then(|v| v.as_str()),
            incoming_obj.get("output").and_then(|v| v.as_str()),
            parsed.output_delta.as_deref(),
        );
        if let Some(output) = merged_output {
            merged_obj.insert("output".to_string(), Value::String(output));
        }

        let mut merged_metadata = merged_obj
            .get("metadata")
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        let incoming_metadata = incoming_obj
            .get("metadata")
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        for (key, value) in incoming_metadata {
            if key == "progress_lines" {
                if let Some(lines) =
                    Self::merge_progress_lines(merged_metadata.get("progress_lines"), Some(&value))
                {
                    merged_metadata.insert("progress_lines".to_string(), lines);
                }
            } else {
                merged_metadata.insert(key, value);
            }
        }
        if !merged_metadata.is_empty() {
            merged_obj.insert("metadata".to_string(), Value::Object(merged_metadata));
        }

        Value::Object(merged_obj)
    }

    fn normalize_current_mode_update(raw: &str) -> bool {
        let normalized = Self::normalized_update_token(raw);
        normalized == "current_mode_update" || normalized == "currentmodeupdate"
    }

    fn is_config_option_update(raw: &str) -> bool {
        let normalized = Self::normalized_update_token(raw);
        normalized == "config_option_update" || normalized == "configoptionupdate"
    }

    fn is_config_options_update(raw: &str) -> bool {
        let normalized = Self::normalized_update_token(raw);
        normalized == "config_options_update" || normalized == "configoptionsupdate"
    }

    fn is_available_commands_update(raw: &str) -> bool {
        let normalized = Self::normalized_update_token(raw);
        matches!(
            normalized.as_str(),
            "available_commands_update"
                | "availablecommandsupdate"
                | "available_command_update"
                | "availablecommandupdate"
        )
    }

    fn extract_available_command_hint(value: &Value) -> Option<String> {
        let pick = |candidate: Option<&Value>| -> Option<String> {
            candidate
                .and_then(|it| it.as_str())
                .and_then(Self::normalize_non_empty_token)
        };

        let obj = value.as_object()?;
        pick(obj.get("inputHint"))
            .or_else(|| pick(obj.get("input_hint")))
            .or_else(|| pick(obj.get("hint")))
            .or_else(|| pick(obj.get("input")))
            .or_else(|| {
                obj.get("input")
                    .and_then(|input| input.get("hint"))
                    .and_then(|hint| hint.as_str())
                    .and_then(Self::normalize_non_empty_token)
            })
    }

    fn parse_available_command(
        value: &Value,
        fallback_name: Option<&str>,
    ) -> Option<AiSlashCommand> {
        let normalized_name = |name: Option<&str>| {
            name.and_then(Self::normalize_non_empty_token)
                .map(|it| it.trim_start_matches('/').trim().to_string())
                .and_then(|it| Self::normalize_non_empty_token(&it))
        };

        let (name, description, input_hint) = if let Some(obj) = value.as_object() {
            let name = normalized_name(
                obj.get("name")
                    .or_else(|| obj.get("command"))
                    .or_else(|| obj.get("id"))
                    .and_then(|it| it.as_str())
                    .or(fallback_name),
            )?;
            let description = obj
                .get("description")
                .or_else(|| obj.get("title"))
                .or_else(|| obj.get("summary"))
                .and_then(|it| it.as_str())
                .and_then(Self::normalize_non_empty_token)
                .unwrap_or_default();
            let input_hint = Self::extract_available_command_hint(value);
            (name, description, input_hint)
        } else {
            let name = normalized_name(fallback_name)?;
            let description = value
                .as_str()
                .and_then(Self::normalize_non_empty_token)
                .unwrap_or_default();
            (name, description, None)
        };

        Some(AiSlashCommand {
            name,
            description,
            action: "agent".to_string(),
            input_hint,
        })
    }

    fn looks_like_available_command(value: &Value) -> bool {
        value.as_object().is_some_and(|obj| {
            obj.contains_key("name")
                || obj.contains_key("command")
                || obj.contains_key("id")
                || obj.contains_key("input")
                || obj.contains_key("inputHint")
                || obj.contains_key("input_hint")
                || obj.contains_key("hint")
        })
    }

    fn extract_available_commands(update: &Value) -> Vec<AiSlashCommand> {
        let mut results = Vec::<AiSlashCommand>::new();
        let mut name_to_index = HashMap::<String, usize>::new();

        let mut push_command = |command: AiSlashCommand| {
            let key = command.name.to_lowercase();
            if let Some(index) = name_to_index.get(&key).copied() {
                results[index] = command;
            } else {
                name_to_index.insert(key, results.len());
                results.push(command);
            }
        };

        for source in [Some(update), update.get("content")] {
            let Some(source) = source else { continue };
            if let Some(command) = Self::parse_available_command(source, None) {
                push_command(command);
            } else if Self::looks_like_available_command(source) {
                warn!(
                    "ACP available_commands_update: skip invalid command source: {}",
                    source
                );
            }

            for key in ["availableCommands", "available_commands", "commands"] {
                if let Some(items) = source.get(key).and_then(|it| it.as_array()) {
                    for item in items {
                        if let Some(command) = Self::parse_available_command(item, None) {
                            push_command(command);
                        } else {
                            warn!(
                                "ACP available_commands_update: skip invalid command item key={}, value={}",
                                key, item
                            );
                        }
                    }
                }
                if let Some(map) = source.get(key).and_then(|it| it.as_object()) {
                    for (fallback_name, item) in map {
                        if let Some(command) =
                            Self::parse_available_command(item, Some(fallback_name.as_str()))
                        {
                            push_command(command);
                        } else {
                            warn!(
                                "ACP available_commands_update: skip invalid mapped command key={}, fallback_name={}, value={}",
                                key, fallback_name, item
                            );
                        }
                    }
                }
            }
        }

        results
    }

    fn extract_config_option_updates(update: &Value) -> Vec<(String, Value)> {
        let mut results = Vec::<(String, Value)>::new();
        let mut seen = HashSet::<String>::new();
        let mut add_pair = |option_id: String, value: Value| {
            let trimmed = option_id.trim().to_string();
            if trimmed.is_empty() || value.is_null() {
                return;
            }
            let key = trimmed.to_lowercase();
            if !seen.insert(key) {
                return;
            }
            results.push((trimmed, value));
        };

        let parse_single = |value: &Value| -> Option<(String, Value)> {
            let obj = value.as_object()?;
            let option_id = obj
                .get("optionId")
                .or_else(|| obj.get("option_id"))
                .or_else(|| obj.get("id"))
                .and_then(|it| it.as_str())
                .map(|it| it.trim().to_string())
                .filter(|it| !it.is_empty())?;
            let option_value = obj
                .get("value")
                .or_else(|| obj.get("currentValue"))
                .or_else(|| obj.get("current_value"))
                .cloned()?;
            Some((option_id, option_value))
        };

        let parse_from_map =
            |map: &serde_json::Map<String, Value>, add_pair: &mut dyn FnMut(String, Value)| {
                for (option_id, value) in map {
                    if option_id.trim().is_empty() || value.is_null() {
                        continue;
                    }
                    if value.is_object() {
                        if let Some((id, option_value)) = parse_single(value) {
                            add_pair(id, option_value);
                            continue;
                        }
                    }
                    add_pair(option_id.clone(), value.clone());
                }
            };

        for source in [Some(update), update.get("content")] {
            let Some(source) = source else { continue };
            if let Some((option_id, value)) = parse_single(source) {
                add_pair(option_id, value);
            }

            for key in [
                "configOptions",
                "config_options",
                "options",
                "values",
                "config",
                "configValues",
                "config_values",
            ] {
                if let Some(items) = source.get(key).and_then(|it| it.as_array()) {
                    for item in items {
                        if let Some((option_id, value)) = parse_single(item) {
                            add_pair(option_id, value);
                        }
                    }
                    continue;
                }
                if let Some(map) = source.get(key).and_then(|it| it.as_object()) {
                    parse_from_map(map, &mut add_pair);
                }
            }
        }

        results
    }

    async fn cache_available_commands(
        slash_commands_by_directory: &Arc<Mutex<HashMap<String, Vec<AiSlashCommand>>>>,
        slash_commands_by_session: &Arc<Mutex<HashMap<String, Vec<AiSlashCommand>>>>,
        directory: &str,
        session_id: Option<&str>,
        commands: Vec<AiSlashCommand>,
    ) {
        let directory_key = Self::normalize_directory(directory);
        {
            let mut by_directory = slash_commands_by_directory.lock().await;
            by_directory.insert(directory_key, commands.clone());
        }
        if let Some(session_id) = session_id.and_then(Self::normalize_non_empty_token) {
            let session_key = Self::session_cache_key(directory, &session_id);
            let mut by_session = slash_commands_by_session.lock().await;
            by_session.insert(session_key, commands);
        }
    }

    async fn slash_commands_for(
        &self,
        directory: &str,
        session_id: Option<&str>,
    ) -> Vec<AiSlashCommand> {
        if let Some(session_id) = session_id.and_then(Self::normalize_non_empty_token) {
            let key = Self::session_cache_key(directory, &session_id);
            let by_session = self.slash_commands_by_session.lock().await;
            if let Some(commands) = by_session.get(&key) {
                return commands.clone();
            }
        }

        let by_directory = self.slash_commands_by_directory.lock().await;
        by_directory
            .get(&Self::normalize_directory(directory))
            .cloned()
            .unwrap_or_default()
    }

    fn extract_current_mode_id(update: &Value) -> Option<String> {
        let pick = |value: &Value| -> Option<String> {
            value
                .get("currentModeId")
                .or_else(|| value.get("current_mode_id"))
                .or_else(|| value.get("modeId"))
                .or_else(|| value.get("mode_id"))
                .and_then(|v| v.as_str())
                .and_then(Self::normalize_non_empty_token)
                .or_else(|| {
                    value
                        .get("mode")
                        .and_then(|v| {
                            v.as_str().map(|v| v.to_string()).or_else(|| {
                                v.get("id")
                                    .or_else(|| v.get("modeId"))
                                    .or_else(|| v.get("mode_id"))
                                    .and_then(|it| it.as_str())
                                    .map(|it| it.to_string())
                            })
                        })
                        .and_then(|v| Self::normalize_non_empty_token(&v))
                })
        };

        pick(update).or_else(|| update.get("content").and_then(pick))
    }

    fn apply_current_mode_to_metadata(metadata: &mut AcpSessionMetadata, mode_id: &str) {
        let Some(raw_mode_id) = Self::normalize_non_empty_token(mode_id) else {
            return;
        };

        let resolved_mode_id = metadata
            .modes
            .iter()
            .find(|mode| mode.id == raw_mode_id || mode.id.eq_ignore_ascii_case(&raw_mode_id))
            .map(|mode| mode.id.clone())
            .unwrap_or_else(|| raw_mode_id.clone());
        metadata.current_mode_id = Some(resolved_mode_id.clone());

        let exists = metadata.modes.iter().any(|mode| {
            mode.id == resolved_mode_id || mode.id.eq_ignore_ascii_case(&resolved_mode_id)
        });
        if !exists {
            metadata.modes.push(super::acp_client::AcpModeInfo {
                id: resolved_mode_id.clone(),
                name: resolved_mode_id,
                description: None,
            });
        }
    }

    async fn apply_current_mode_to_caches(
        metadata_by_directory: &Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
        metadata_by_session: &Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
        directory: &str,
        session_id: &str,
        mode_id: &str,
    ) {
        let directory_key = Self::normalize_directory(directory);
        {
            let mut by_directory = metadata_by_directory.lock().await;
            let entry = by_directory.entry(directory_key.clone()).or_default();
            Self::apply_current_mode_to_metadata(entry, mode_id);
        }
        {
            let mut by_session = metadata_by_session.lock().await;
            let key = Self::session_cache_key(directory, session_id);
            let entry = by_session.entry(key).or_default();
            Self::apply_current_mode_to_metadata(entry, mode_id);
        }
    }

    fn apply_current_model_to_metadata(metadata: &mut AcpSessionMetadata, model_id: &str) {
        let Some(raw_model_id) = Self::normalize_non_empty_token(model_id) else {
            return;
        };

        let resolved_model_id = metadata
            .models
            .iter()
            .find(|model| model.id == raw_model_id || model.id.eq_ignore_ascii_case(&raw_model_id))
            .map(|model| model.id.clone())
            .unwrap_or_else(|| raw_model_id.clone());
        metadata.current_model_id = Some(resolved_model_id.clone());

        let exists = metadata.models.iter().any(|model| {
            model.id == resolved_model_id || model.id.eq_ignore_ascii_case(&resolved_model_id)
        });
        if !exists {
            metadata.models.push(super::acp_client::AcpModelInfo {
                id: resolved_model_id.clone(),
                name: resolved_model_id,
                supports_image_input: true,
            });
        }
    }

    fn normalized_category(category: Option<&str>, option_id: &str) -> String {
        if let Some(category) = category.map(|it| it.trim().to_lowercase()) {
            if !category.is_empty() {
                return category;
            }
        }
        option_id.trim().to_lowercase()
    }

    fn value_to_string(value: &Value) -> Option<String> {
        if let Some(text) = value.as_str() {
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
        let obj = value.as_object()?;
        obj.get("id")
            .or_else(|| obj.get("modeId"))
            .or_else(|| obj.get("mode_id"))
            .or_else(|| obj.get("modelId"))
            .or_else(|| obj.get("model_id"))
            .or_else(|| obj.get("value"))
            .and_then(|it| it.as_str())
            .map(|it| it.trim().to_string())
            .filter(|it| !it.is_empty())
    }

    fn resolve_choice_string(option: &AcpConfigOptionInfo, value: &Value) -> Option<String> {
        if let Some(raw) = Self::value_to_string(value) {
            return Some(raw);
        }
        option
            .options
            .iter()
            .find_map(|choice| Self::value_to_string(&choice.value))
    }

    fn resolve_mode_id_from_option(option: &AcpConfigOptionInfo, value: &Value) -> Option<String> {
        let candidate = Self::resolve_choice_string(option, value)?;
        if !candidate.is_empty() {
            return Some(candidate);
        }
        None
    }

    fn resolve_model_id_from_option(option: &AcpConfigOptionInfo, value: &Value) -> Option<String> {
        let candidate = Self::resolve_choice_string(option, value)?;
        if let Some((_, suffix)) = candidate.split_once('/') {
            let trimmed = suffix.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
        Some(candidate)
    }

    fn apply_config_value_to_metadata(
        metadata: &mut AcpSessionMetadata,
        option_id: &str,
        value: Value,
    ) {
        let option_id = option_id.trim();
        if option_id.is_empty() {
            return;
        }
        metadata
            .config_values
            .insert(option_id.to_string(), value.clone());
        if let Some(index) = metadata.config_options.iter().position(|option| {
            option.option_id == option_id || option.option_id.eq_ignore_ascii_case(option_id)
        }) {
            let category = {
                let option = &metadata.config_options[index];
                Self::normalized_category(option.category.as_deref(), &option.option_id)
            };
            let resolved_mode = if category == "mode" {
                let option = &metadata.config_options[index];
                Self::resolve_mode_id_from_option(option, &value)
            } else {
                None
            };
            let resolved_model = if category == "model" {
                let option = &metadata.config_options[index];
                Self::resolve_model_id_from_option(option, &value)
            } else {
                None
            };

            if let Some(option) = metadata.config_options.get_mut(index) {
                option.current_value = Some(value.clone());
            }
            if let Some(mode_id) = resolved_mode {
                Self::apply_current_mode_to_metadata(metadata, &mode_id);
            } else if let Some(model_id) = resolved_model {
                Self::apply_current_model_to_metadata(metadata, &model_id);
            }
            return;
        }

        if let Some(existing) = metadata.config_options.iter_mut().find(|option| {
            option.option_id == option_id || option.option_id.eq_ignore_ascii_case(option_id)
        }) {
            existing.current_value = Some(value);
            return;
        }

        metadata.config_options.push(AcpConfigOptionInfo {
            option_id: option_id.to_string(),
            category: None,
            name: option_id.to_string(),
            description: None,
            current_value: Some(value),
            options: Vec::new(),
            option_groups: Vec::new(),
            raw: None,
        });
    }

    async fn apply_config_value_to_caches(
        metadata_by_directory: &Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
        metadata_by_session: &Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
        directory: &str,
        session_id: &str,
        option_id: &str,
        value: Value,
    ) {
        let directory_key = Self::normalize_directory(directory);
        {
            let mut by_directory = metadata_by_directory.lock().await;
            let entry = by_directory.entry(directory_key.clone()).or_default();
            Self::apply_config_value_to_metadata(entry, option_id, value.clone());
        }
        {
            let mut by_session = metadata_by_session.lock().await;
            let key = Self::session_cache_key(directory, session_id);
            let entry = by_session.entry(key).or_default();
            Self::apply_config_value_to_metadata(entry, option_id, value);
        }
    }

    fn session_config_values(metadata: &AcpSessionMetadata) -> Option<HashMap<String, Value>> {
        if metadata.config_values.is_empty() {
            return None;
        }
        Some(metadata.config_values.clone())
    }

    fn resolve_mode_id(
        metadata: &AcpSessionMetadata,
        selected_agent: Option<&str>,
    ) -> Option<String> {
        if let Some(agent) = selected_agent {
            let normalized = Self::normalize_mode_name(agent);
            if !normalized.is_empty() {
                if normalized == "default" || normalized == "agent" {
                    if let Some(mode) = metadata
                        .modes
                        .iter()
                        .find(|m| m.id.to_lowercase().contains("#agent"))
                    {
                        return Some(mode.id.clone());
                    }
                }
                if normalized == "plan" {
                    if let Some(mode) = metadata
                        .modes
                        .iter()
                        .find(|m| m.id.to_lowercase().contains("#plan"))
                    {
                        return Some(mode.id.clone());
                    }
                }
                if let Some(mode) = metadata.modes.iter().find(|m| {
                    Self::normalize_mode_name(&m.id) == normalized
                        || Self::normalize_mode_name(&m.name) == normalized
                }) {
                    return Some(mode.id.clone());
                }
            }
        }

        metadata
            .current_mode_id
            .clone()
            .or_else(|| metadata.modes.first().map(|m| m.id.clone()))
    }

    fn current_agent_name(metadata: &AcpSessionMetadata) -> Option<String> {
        let current_mode_id = metadata.current_mode_id.as_deref()?;
        if let Some(mode) = metadata
            .modes
            .iter()
            .find(|m| m.id == current_mode_id || m.id.eq_ignore_ascii_case(current_mode_id))
        {
            let normalized_name = Self::normalize_mode_name(&mode.name);
            if !normalized_name.is_empty() {
                return Some(normalized_name);
            }
            let fallback = Self::normalize_mode_name(&mode.id);
            if !fallback.is_empty() {
                return Some(fallback);
            }
        }

        // 兜底：直接基于 mode id 粗略映射常见语义
        let normalized = current_mode_id.to_lowercase();
        if normalized.contains("#plan") {
            return Some("plan".to_string());
        }
        if normalized.contains("#agent") {
            return Some("agent".to_string());
        }

        let fallback = Self::normalize_mode_name(current_mode_id);
        if fallback.is_empty() {
            None
        } else {
            Some(fallback)
        }
    }

    fn map_config_option_choice(
        choice: &super::acp_client::AcpConfigOptionChoice,
    ) -> AiSessionConfigOptionChoice {
        AiSessionConfigOptionChoice {
            value: choice.value.clone(),
            label: choice.label.clone(),
            description: choice.description.clone(),
        }
    }

    fn map_config_option_group(
        group: &super::acp_client::AcpConfigOptionGroup,
    ) -> AiSessionConfigOptionChoiceGroup {
        AiSessionConfigOptionChoiceGroup {
            label: group.label.clone(),
            options: group
                .options
                .iter()
                .map(Self::map_config_option_choice)
                .collect::<Vec<_>>(),
        }
    }

    fn map_config_option(option: &AcpConfigOptionInfo) -> AiSessionConfigOption {
        AiSessionConfigOption {
            option_id: option.option_id.clone(),
            category: option.category.clone(),
            name: option.name.clone(),
            description: option.description.clone(),
            current_value: option.current_value.clone(),
            options: option
                .options
                .iter()
                .map(Self::map_config_option_choice)
                .collect::<Vec<_>>(),
            option_groups: option
                .option_groups
                .iter()
                .map(Self::map_config_option_group)
                .collect::<Vec<_>>(),
            raw: option.raw.clone(),
        }
    }

    fn map_config_options(options: &[AcpConfigOptionInfo]) -> Vec<AiSessionConfigOption> {
        options
            .iter()
            .map(Self::map_config_option)
            .collect::<Vec<_>>()
    }

    fn selection_hint_from_metadata(
        metadata: &AcpSessionMetadata,
        provider_id: &str,
    ) -> Option<AiSessionSelectionHint> {
        let hint = AiSessionSelectionHint {
            agent: Self::current_agent_name(metadata),
            model_provider_id: metadata
                .current_model_id
                .as_ref()
                .map(|_| provider_id.to_string()),
            model_id: metadata.current_model_id.clone(),
            config_options: Self::session_config_values(metadata),
        };
        if hint.agent.is_none() && hint.model_id.is_none() && hint.config_options.is_none() {
            None
        } else {
            Some(hint)
        }
    }

    fn strip_file_ref_location_suffix(file_ref: &str) -> String {
        let trimmed = file_ref.trim();
        if let Some((head, tail)) = trimmed.rsplit_once(':') {
            if tail.chars().all(|ch| ch.is_ascii_digit()) {
                if let Some((head2, tail2)) = head.rsplit_once(':') {
                    if tail2.chars().all(|ch| ch.is_ascii_digit()) {
                        return head2.to_string();
                    }
                }
                return head.to_string();
            }
        }
        trimmed.to_string()
    }

    fn normalize_attachment_mime(raw: &str) -> String {
        let mime = raw.trim().to_ascii_lowercase();
        if mime.is_empty() {
            "application/octet-stream".to_string()
        } else {
            mime
        }
    }

    fn mime_from_path(path: &Path) -> String {
        mime_guess::from_path(path)
            .first_or_octet_stream()
            .essence_str()
            .to_string()
    }

    fn mime_is_text(mime: &str) -> bool {
        let normalized = mime.trim().to_ascii_lowercase();
        normalized.starts_with("text/")
            || normalized.ends_with("+json")
            || normalized.ends_with("+xml")
            || matches!(
                normalized.as_str(),
                "application/json"
                    | "application/xml"
                    | "application/yaml"
                    | "application/x-yaml"
                    | "application/toml"
                    | "application/javascript"
                    | "application/x-javascript"
                    | "application/typescript"
                    | "application/sql"
            )
    }

    fn decode_utf8_text(bytes: &[u8]) -> Option<String> {
        if bytes.contains(&0) {
            return None;
        }
        String::from_utf8(bytes.to_vec()).ok()
    }

    fn resolve_prompt_file_ref(directory: &str, file_ref: &str) -> Option<ResolvedPromptFileRef> {
        let normalized_ref = Self::strip_file_ref_location_suffix(file_ref);
        if normalized_ref.trim().is_empty() {
            return None;
        }

        if let Ok(url) = Url::parse(&normalized_ref) {
            if !url.scheme().eq_ignore_ascii_case("file") {
                return None;
            }
            let path = url.to_file_path().ok()?;
            let uri = Url::from_file_path(&path).ok()?.to_string();
            let name = path
                .file_name()
                .map(|v| v.to_string_lossy().to_string())
                .unwrap_or_else(|| normalized_ref.clone());
            let mime = Self::mime_from_path(&path);
            return Some(ResolvedPromptFileRef {
                original: file_ref.to_string(),
                path,
                uri,
                name,
                mime,
            });
        }

        let input_path = Path::new(&normalized_ref);
        let path = if input_path.is_absolute() {
            input_path.to_path_buf()
        } else {
            PathBuf::from(directory).join(input_path)
        };

        let uri = Url::from_file_path(&path).ok()?.to_string();
        let name = path
            .file_name()
            .map(|v| v.to_string_lossy().to_string())
            .unwrap_or_else(|| normalized_ref.clone());
        let mime = Self::mime_from_path(&path);
        Some(ResolvedPromptFileRef {
            original: file_ref.to_string(),
            path,
            uri,
            name,
            mime,
        })
    }

    fn build_embedded_resource_part(
        file_ref: &ResolvedPromptFileRef,
    ) -> Result<Option<Value>, String> {
        let metadata = std::fs::metadata(&file_ref.path)
            .map_err(|e| format!("读取文件元数据失败：{} ({})", file_ref.path.display(), e))?;
        let size = metadata.len() as usize;

        let mime = Self::normalize_attachment_mime(&file_ref.mime);
        let declared_text = Self::mime_is_text(&mime);
        if declared_text && size > Self::EMBED_TEXT_LIMIT_BYTES {
            return Ok(None);
        }
        if size > Self::EMBED_BLOB_LIMIT_BYTES {
            return Ok(None);
        }

        let bytes = std::fs::read(&file_ref.path)
            .map_err(|e| format!("读取文件内容失败：{} ({})", file_ref.path.display(), e))?;
        let is_text = declared_text || Self::decode_utf8_text(&bytes).is_some();
        if is_text {
            if bytes.len() > Self::EMBED_TEXT_LIMIT_BYTES {
                return Ok(None);
            }
            if let Some(text) = Self::decode_utf8_text(&bytes) {
                return Ok(Some(AcpClient::build_prompt_resource_text_part(
                    file_ref.uri.clone(),
                    file_ref.name.clone(),
                    mime,
                    text,
                )));
            }
        }

        if bytes.len() > Self::EMBED_BLOB_LIMIT_BYTES {
            return Ok(None);
        }

        Ok(Some(AcpClient::build_prompt_resource_blob_part(
            file_ref.uri.clone(),
            file_ref.name.clone(),
            mime,
            BASE64.encode(bytes),
        )))
    }

    fn compose_prompt_parts(
        directory: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        audio_parts: Option<Vec<AiAudioPart>>,
        encoding_mode: AcpContentEncodingMode,
        supports_image: bool,
        supports_audio: bool,
        supports_resource: bool,
        supports_resource_link: bool,
    ) -> Vec<Value> {
        let mut prompt_parts = Vec::<Value>::new();
        let mut fallback_blocks = Vec::<String>::new();
        let mut text_body = message.to_string();

        if let Some(files) = file_refs {
            if !files.is_empty() {
                let mut unresolved = Vec::<String>::new();
                for file_ref in files {
                    let Some(resolved) = Self::resolve_prompt_file_ref(directory, &file_ref) else {
                        unresolved.push(file_ref);
                        continue;
                    };

                    let mut encoded = false;
                    if supports_resource {
                        match Self::build_embedded_resource_part(&resolved) {
                            Ok(Some(resource_part)) => {
                                prompt_parts.push(resource_part);
                                encoded = true;
                            }
                            Ok(None) => {
                                debug!(
                                    "ACP resource embed exceeded limit, fallback to resource_link: {}",
                                    resolved.path.display()
                                );
                            }
                            Err(err) => {
                                warn!(
                                    "ACP resource embed failed, fallback to resource_link: path={}, error={}",
                                    resolved.path.display(),
                                    err
                                );
                            }
                        }
                    }
                    if !encoded && supports_resource_link {
                        prompt_parts.push(AcpClient::build_prompt_resource_link_part(
                            encoding_mode,
                            resolved.uri.clone(),
                            resolved.name.clone(),
                            Some(resolved.mime.clone()),
                        ));
                        encoded = true;
                    }
                    if !encoded {
                        unresolved.push(resolved.original);
                    }
                }
                if !unresolved.is_empty() {
                    fallback_blocks.push(format!("文件引用：\n{}", unresolved.join("\n")));
                }
            }
        }

        if let Some(images) = image_parts {
            if !images.is_empty() {
                if supports_image {
                    for img in images {
                        let mime = Self::normalize_attachment_mime(&img.mime);
                        prompt_parts.push(AcpClient::build_prompt_image_part(
                            encoding_mode,
                            mime,
                            BASE64.encode(img.data),
                        ));
                    }
                } else {
                    let names = images
                        .iter()
                        .map(|img| format!("{} ({})", img.filename, img.mime))
                        .collect::<Vec<_>>()
                        .join("\n");
                    fallback_blocks.push(format!("图片附件：\n{}", names));
                }
            }
        }

        if let Some(audios) = audio_parts {
            if !audios.is_empty() {
                if supports_audio {
                    for audio in audios {
                        let mime = Self::normalize_attachment_mime(&audio.mime);
                        prompt_parts.push(AcpClient::build_prompt_audio_part(
                            encoding_mode,
                            mime,
                            BASE64.encode(audio.data),
                        ));
                    }
                } else {
                    let names = audios
                        .iter()
                        .map(|audio| format!("{} ({})", audio.filename, audio.mime))
                        .collect::<Vec<_>>()
                        .join("\n");
                    fallback_blocks.push(format!("音频附件：\n{}", names));
                }
            }
        }

        if !fallback_blocks.is_empty() {
            if !text_body.trim().is_empty() {
                text_body.push_str("\n\n");
            }
            text_body.push_str(&fallback_blocks.join("\n\n"));
        }

        if !text_body.trim().is_empty() || prompt_parts.is_empty() {
            prompt_parts.insert(0, AcpClient::build_prompt_text_part(text_body));
        }
        prompt_parts
    }

    fn is_session_not_found(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("session") && normalized.contains("not found")
    }

    fn is_session_already_loaded(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("session")
            && normalized.contains("already")
            && normalized.contains("loaded")
    }

    fn request_id_key(id: &Value) -> String {
        match id {
            Value::String(s) => format!("s:{}", s),
            Value::Number(n) => format!("n:{}", n),
            _ => format!("j:{}", id),
        }
    }

    fn parse_permission_options(params: &Value) -> Vec<PermissionOption> {
        let mut options = Vec::new();
        let mut seen_option_ids = HashSet::new();
        let Some(rows) = params.get("options").and_then(|v| v.as_array()) else {
            return options;
        };
        for row in rows {
            let Some(option_id) = row
                .get("optionId")
                .or_else(|| row.get("option_id"))
                .or_else(|| row.get("id"))
                .and_then(|v| v.as_str())
                .and_then(Self::normalize_non_empty_token)
            else {
                continue;
            };
            let option_id_key = option_id.to_lowercase();
            if !seen_option_ids.insert(option_id_key) {
                continue;
            }
            let name = row
                .get("name")
                .or_else(|| row.get("label"))
                .and_then(|v| v.as_str())
                .and_then(Self::normalize_non_empty_token)
                .unwrap_or_else(|| option_id.clone());
            options.push(PermissionOption {
                option_id,
                normalized_name: Self::normalize_mode_name(&name),
            });
        }
        options
    }

    fn resolve_permission_option_id(
        pending: &PendingPermission,
        answers: &[Vec<String>],
    ) -> Option<String> {
        let candidates = answers
            .iter()
            .flat_map(|group| group.iter())
            .filter_map(|answer| Self::normalize_non_empty_token(answer))
            .collect::<Vec<_>>();

        for candidate in &candidates {
            if let Some(found) = pending.options.iter().find(|option| {
                option.option_id == *candidate || option.option_id.eq_ignore_ascii_case(candidate)
            }) {
                return Some(found.option_id.clone());
            }
        }

        for candidate in &candidates {
            let normalized = Self::normalize_mode_name(candidate);
            if normalized.is_empty() {
                continue;
            }
            if let Some(found) = pending
                .options
                .iter()
                .find(|option| option.normalized_name == normalized)
            {
                return Some(found.option_id.clone());
            }
        }

        if let Some(found) = pending.options.iter().find(|option| {
            option.option_id.eq_ignore_ascii_case("allow-once")
                || option.option_id.eq_ignore_ascii_case("allow_once")
        }) {
            warn!(
                "permission request {} missing explicit optionId mapping, fallback to allow-once",
                Self::request_id_key(&pending.request_id)
            );
            return Some(found.option_id.clone());
        }

        let fallback = pending
            .options
            .first()
            .map(|option| option.option_id.clone());
        if let Some(option_id) = fallback.as_deref() {
            warn!(
                "permission request {} missing optionId mapping, fallback to first option={}",
                Self::request_id_key(&pending.request_id),
                option_id
            );
        }
        fallback
    }

    fn build_question_from_permission_request(
        request_id: &Value,
        params: &Value,
    ) -> Option<(AiQuestionRequest, Vec<PermissionOption>)> {
        let session_id = params.get("sessionId")?.as_str()?.to_string();
        let tool_call = params.get("toolCall")?;
        let tool_call_id = tool_call
            .get("toolCallId")
            .and_then(|v| v.as_str())
            .map(String::from);
        let permission_options = Self::parse_permission_options(params);
        let raw_input = tool_call.get("rawInput").cloned().unwrap_or(Value::Null);
        let tool_kind = tool_call
            .get("kind")
            .or_else(|| tool_call.get("toolKind"))
            .or_else(|| tool_call.get("tool_kind"))
            .and_then(|v| v.as_str())
            .and_then(Self::normalize_non_empty_token);

        let questions = if let Some(qs) = raw_input.get("questions").and_then(|v| v.as_array()) {
            qs.iter()
                .filter_map(|q| {
                    let question = q.get("question")?.as_str()?.to_string();
                    let header = q
                        .get("header")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let options = q
                        .get("options")
                        .and_then(|v| v.as_array())
                        .map(|arr| {
                            arr.iter()
                                .filter_map(|opt| {
                                    let label = opt
                                        .get("label")
                                        .or_else(|| opt.get("name"))
                                        .and_then(|v| v.as_str())
                                        .and_then(Self::normalize_non_empty_token)?;
                                    Some(AiQuestionOption {
                                        option_id: opt
                                            .get("optionId")
                                            .or_else(|| opt.get("option_id"))
                                            .or_else(|| opt.get("id"))
                                            .and_then(|v| v.as_str())
                                            .and_then(Self::normalize_non_empty_token),
                                        label,
                                        description: opt
                                            .get("description")
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("")
                                            .to_string(),
                                    })
                                })
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    let multiple = q.get("multiple").and_then(|v| v.as_bool()).unwrap_or(false);
                    let custom = q.get("custom").and_then(|v| v.as_bool()).unwrap_or(true);
                    Some(AiQuestionInfo {
                        question,
                        header,
                        options,
                        multiple,
                        custom,
                    })
                })
                .collect()
        } else {
            let title = tool_call
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or("Permission required");
            let header = tool_kind
                .clone()
                .map(|kind| format!("Permission ({})", kind))
                .unwrap_or_else(|| "Permission".to_string());
            vec![AiQuestionInfo {
                question: title.to_string(),
                header,
                options: params
                    .get("options")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|opt| {
                                let label = opt
                                    .get("name")
                                    .or_else(|| opt.get("label"))
                                    .and_then(|v| v.as_str())
                                    .and_then(Self::normalize_non_empty_token)?;
                                Some(AiQuestionOption {
                                    option_id: opt
                                        .get("optionId")
                                        .or_else(|| opt.get("option_id"))
                                        .or_else(|| opt.get("id"))
                                        .and_then(|v| v.as_str())
                                        .and_then(Self::normalize_non_empty_token),
                                    label,
                                    description: opt
                                        .get("kind")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string(),
                                })
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
                multiple: false,
                custom: false,
            }]
        };

        Some((
            AiQuestionRequest {
                id: Self::request_id_key(request_id),
                session_id,
                questions,
                tool_message_id: tool_call_id.clone(),
                tool_call_id,
            },
            permission_options,
        ))
    }

    fn extract_update(event: &Value) -> Option<(String, String, String)> {
        let session_update = event
            .get("sessionUpdate")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let content = event.get("content");
        let content_type = content
            .and_then(|v| v.get("type"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let text = content
            .and_then(|v| v.as_object())
            .and_then(|obj| {
                obj.get("text")
                    .and_then(|v| v.as_str())
                    .and_then(Self::normalize_non_empty_token)
                    .or_else(|| Self::extract_tool_output_text(&Value::Object(obj.clone())))
            })
            .unwrap_or_default();
        // content 可能为空（如 terminal update），此时返回空 type/text 供上层判定。
        Some((session_update, content_type, text))
    }

    fn build_acp_content_source(content: &serde_json::Map<String, Value>) -> Value {
        serde_json::json!({
            "vendor": "acp",
            "annotations": content.get("annotations").cloned().unwrap_or(Value::Null),
            "content": Value::Object(content.clone()),
        })
    }

    fn normalized_content_type(content: &serde_json::Map<String, Value>) -> String {
        content
            .get("type")
            .and_then(|v| v.as_str())
            .map(|v| v.trim().to_ascii_lowercase())
            .unwrap_or_default()
    }

    fn content_data_url(
        mime: Option<&str>,
        data: Option<&str>,
        url: Option<&str>,
    ) -> Option<String> {
        if let Some(url) = url.and_then(Self::normalize_non_empty_token) {
            return Some(url);
        }
        let data = data.and_then(Self::normalize_non_empty_token)?;
        let mime = mime
            .and_then(Self::normalize_non_empty_token)
            .unwrap_or_else(|| "application/octet-stream".to_string());
        Some(format!("data:{};base64,{}", mime, data))
    }

    fn map_content_to_non_text_parts(
        message_id: &str,
        content: &serde_json::Map<String, Value>,
    ) -> Vec<AiPart> {
        let content_type = Self::normalized_content_type(content);
        if content_type.is_empty() {
            return Vec::new();
        }

        let source = Some(Self::build_acp_content_source(content));
        let resource = content.get("resource").and_then(|v| v.as_object());

        let pick_str = |keys: &[&str], map: &serde_json::Map<String, Value>| -> Option<String> {
            keys.iter().find_map(|key| {
                map.get(*key)
                    .and_then(|v| v.as_str())
                    .and_then(Self::normalize_non_empty_token)
            })
        };

        let make_file_part = |mime: Option<String>,
                              filename: Option<String>,
                              url: Option<String>|
         -> Option<AiPart> {
            if mime.is_none() && filename.is_none() && url.is_none() {
                return None;
            }
            Some(AiPart {
                id: format!("{}-file-{}", message_id, Uuid::new_v4()),
                part_type: "file".to_string(),
                mime,
                filename,
                url,
                source: source.clone(),
                ..Default::default()
            })
        };

        match content_type.as_str() {
            "image" | "audio" => {
                let mime = pick_str(&["mimeType", "mime"], content);
                let filename = pick_str(&["filename", "name"], content);
                let url = Self::content_data_url(
                    mime.as_deref(),
                    pick_str(&["data"], content).as_deref(),
                    pick_str(&["url"], content).as_deref(),
                );
                make_file_part(mime, filename, url)
                    .into_iter()
                    .collect::<Vec<_>>()
            }
            "resource" => {
                let text = resource
                    .and_then(|res| pick_str(&["text"], res))
                    .or_else(|| pick_str(&["text"], content));
                if let Some(text) = text {
                    return vec![AiPart {
                        id: format!("{}-text-{}", message_id, Uuid::new_v4()),
                        part_type: "text".to_string(),
                        text: Some(text),
                        source,
                        ..Default::default()
                    }];
                }

                let mime = resource
                    .and_then(|res| pick_str(&["mimeType", "mime"], res))
                    .or_else(|| pick_str(&["mimeType", "mime"], content));
                let filename = resource
                    .and_then(|res| pick_str(&["name", "filename"], res))
                    .or_else(|| pick_str(&["name", "filename"], content));
                let uri = resource
                    .and_then(|res| pick_str(&["uri"], res))
                    .or_else(|| pick_str(&["uri"], content));
                let blob = resource
                    .and_then(|res| pick_str(&["blob"], res))
                    .or_else(|| pick_str(&["blob"], content));
                let url = Self::content_data_url(mime.as_deref(), blob.as_deref(), uri.as_deref());
                make_file_part(mime, filename, url)
                    .into_iter()
                    .collect::<Vec<_>>()
            }
            "resource_link" => {
                let mime = pick_str(&["mimeType", "mime"], content)
                    .or_else(|| resource.and_then(|res| pick_str(&["mimeType", "mime"], res)));
                let filename = pick_str(&["name", "filename"], content)
                    .or_else(|| resource.and_then(|res| pick_str(&["name", "filename"], res)));
                let uri = pick_str(&["uri"], content)
                    .or_else(|| resource.and_then(|res| pick_str(&["uri"], res)));
                let url = Self::content_data_url(mime.as_deref(), None, uri.as_deref());
                make_file_part(mime, filename, url)
                    .into_iter()
                    .collect::<Vec<_>>()
            }
            "markdown" | "diff" | "terminal" => {
                let text = Self::extract_tool_output_text(&Value::Object(content.clone()))
                    .or_else(|| pick_str(&["text"], content));
                if let Some(text) = text {
                    vec![AiPart {
                        id: format!("{}-text-{}", message_id, Uuid::new_v4()),
                        part_type: "text".to_string(),
                        text: Some(text),
                        source,
                        ..Default::default()
                    }]
                } else {
                    Vec::new()
                }
            }
            _ => Vec::new(),
        }
    }

    fn role_for_session_update(session_update: &str) -> &'static str {
        if session_update.eq_ignore_ascii_case("user_message_chunk") {
            "user"
        } else {
            "assistant"
        }
    }

    fn push_structured_parts_message(
        messages: &mut Vec<AiMessage>,
        message_id_prefix: &str,
        role: &str,
        parts: Vec<AiPart>,
    ) {
        if parts.is_empty() {
            return;
        }
        if let Some(last) = messages.last_mut() {
            if last.role.eq_ignore_ascii_case(role) {
                last.parts.extend(parts);
                return;
            }
        }
        let message_id = format!("{}-history-{}", message_id_prefix, Uuid::new_v4());
        messages.push(AiMessage {
            id: message_id,
            role: role.to_string(),
            created_at: None,
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts,
        });
    }

    fn map_update_to_output(session_update: &str) -> Option<(&'static str, bool)> {
        let normalized = Self::normalized_update_token(session_update);
        match normalized.as_str() {
            "agent_thought_chunk" => Some(("reasoning", true)),
            "agent_message_chunk" => Some(("text", true)),
            "user_message_chunk" => Some(("text", false)),
            _ => None,
        }
    }

    fn normalized_update_token(raw: &str) -> String {
        raw.trim()
            .to_lowercase()
            .replace('-', "_")
            .replace(' ', "_")
    }

    fn is_terminal_update(session_update: &str, content_type: &str) -> bool {
        let update = Self::normalized_update_token(session_update);
        if !update.is_empty() {
            if update.contains("chunk") {
                return false;
            }
            if matches!(
                update.as_str(),
                "done"
                    | "idle"
                    | "session_idle"
                    | "session_done"
                    | "session_completed"
                    | "session_complete"
                    | "turn_done"
                    | "turn_completed"
                    | "turn_complete"
                    | "agent_turn_done"
                    | "agent_turn_completed"
                    | "agent_turn_complete"
            ) {
                return true;
            }
            if update.contains("complete")
                || update.contains("finished")
                || update.ends_with("_end")
                || update.ends_with("_ended")
                || update.contains("cancelled")
                || update.contains("canceled")
            {
                return true;
            }
        }

        let content = Self::normalized_update_token(content_type);
        matches!(content.as_str(), "done" | "end" | "completed" | "finished")
    }

    fn is_error_update(session_update: &str, content_type: &str) -> bool {
        let update = Self::normalized_update_token(session_update);
        if update.contains("error") || update.contains("failed") || update.contains("failure") {
            return true;
        }
        let content = Self::normalized_update_token(content_type);
        content == "error" || content == "failed"
    }

    fn parse_prompt_stop_reason(result: &Value) -> Result<String, String> {
        let stop_reason = result
            .get("stopReason")
            .or_else(|| result.get("stop_reason"))
            .and_then(|v| v.as_str())
            .map(|v| v.trim().to_lowercase())
            .filter(|v| !v.is_empty())
            .ok_or_else(|| "ACP session/prompt result missing string stopReason".to_string())?;
        const ALLOWED: &[&str] = &[
            "end_turn",
            "max_tokens",
            "stop_sequence",
            "tool_use",
            "cancelled",
            "error",
        ];
        if !ALLOWED
            .iter()
            .any(|allowed| allowed == &stop_reason.as_str())
        {
            return Err(format!(
                "ACP session/prompt returned unsupported stopReason: {}",
                stop_reason
            ));
        }
        Ok(stop_reason)
    }

    async fn reject_pending_permissions_for_session(
        pending_permissions: &Arc<Mutex<HashMap<String, PendingPermission>>>,
        client: &AcpClient,
        session_id: &str,
    ) {
        let pending = {
            let mut guard = pending_permissions.lock().await;
            let keys = guard
                .iter()
                .filter_map(|(key, value)| {
                    if value.session_id == session_id {
                        Some(key.clone())
                    } else {
                        None
                    }
                })
                .collect::<Vec<_>>();
            let mut drained = Vec::new();
            for key in keys {
                if let Some(item) = guard.remove(&key) {
                    drained.push(item);
                }
            }
            drained
        };

        for item in pending {
            if let Err(err) = client.reject_permission_request(item.request_id).await {
                warn!(
                    "ACP reject pending permission failed: session_id={}, error={}",
                    session_id, err
                );
            }
        }
    }

    fn select_sessions_for_directory(
        page: Vec<AcpSessionSummary>,
        expected_directory: &str,
    ) -> (Vec<AcpSessionSummary>, bool) {
        let expected = Self::normalize_directory(expected_directory);
        let mut exact = Vec::new();
        let mut unknown_cwd = Vec::new();

        for item in page {
            let normalized_cwd = Self::normalize_directory(&item.cwd);
            if normalized_cwd.is_empty() {
                unknown_cwd.push(item);
                continue;
            }
            if normalized_cwd == expected {
                exact.push(item);
            }
        }

        if exact.is_empty() && !unknown_cwd.is_empty() {
            return (unknown_cwd, true);
        }
        (exact, false)
    }

    fn push_chunk_message(
        messages: &mut Vec<AiMessage>,
        message_id_prefix: &str,
        role: &str,
        part_type: &str,
        text: &str,
    ) {
        if text.is_empty() {
            return;
        }
        if let Some(last) = messages.last_mut() {
            if last.role.eq_ignore_ascii_case(role) {
                if let Some(last_part) = last.parts.last_mut() {
                    if last_part.part_type == part_type {
                        let mut merged = last_part.text.clone().unwrap_or_default();
                        merged.push_str(text);
                        last_part.text = Some(merged);
                        return;
                    }
                }
            }
        }

        let message_id = format!("{}-history-{}", message_id_prefix, Uuid::new_v4());
        let part = if part_type == "text" {
            AiPart::new_text(format!("{}-{}", message_id, part_type), text.to_string())
        } else {
            AiPart {
                id: format!("{}-{}", message_id, part_type),
                part_type: part_type.to_string(),
                text: Some(text.to_string()),
                ..Default::default()
            }
        };
        messages.push(AiMessage {
            id: message_id,
            role: role.to_string(),
            created_at: None,
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: vec![part],
        });
    }

    async fn collect_loaded_messages(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<(Vec<AiMessage>, AcpSessionMetadata), String> {
        if !self.client.supports_load_session().await {
            debug!(
                "{}: loadSession capability unsupported, skip session/load for history collection",
                self.profile.tool_id
            );
            let cached = if let Some(meta) = self.metadata_for_session(directory, session_id).await
            {
                meta
            } else {
                self.metadata_by_directory
                    .lock()
                    .await
                    .get(&Self::normalize_directory(directory))
                    .cloned()
                    .unwrap_or_default()
            };
            return Ok((Vec::new(), cached));
        }

        let mut notifications = self.client.subscribe_notifications();
        let load_fut = self.client.session_load(directory, session_id);
        tokio::pin!(load_fut);
        let mut messages = Vec::<AiMessage>::new();
        let mut history_plan_current: Option<AcpPlanSnapshot> = None;
        let mut history_plan_history: Vec<AcpPlanSnapshot> = Vec::new();
        let mut history_plan_revision: u64 = 0;
        let mut history_plan_message_index: u64 = 0;
        let mut history_tool_part_ids = HashMap::<String, String>::new();
        let mut history_tool_states = HashMap::<String, Value>::new();
        let mut observed_mode_id: Option<String> = None;
        let mut observed_config_values: HashMap<String, Value> = HashMap::new();

        loop {
            tokio::select! {
                load_result = &mut load_fut => {
                    match load_result {
                        Ok(mut metadata) => {
                            Self::flush_plan_snapshot_for_history(
                                &mut messages,
                                &self.profile.message_id_prefix,
                                &mut history_plan_message_index,
                                &mut history_plan_current,
                                &mut history_plan_history,
                            );
                            if let Some(mode_id) = observed_mode_id.as_deref() {
                                Self::apply_current_mode_to_metadata(&mut metadata, mode_id);
                            }
                            for (option_id, option_value) in observed_config_values.clone() {
                                Self::apply_config_value_to_metadata(
                                    &mut metadata,
                                    &option_id,
                                    option_value,
                                );
                            }
                            return Ok((messages, metadata));
                        }
                        Err(err) if Self::is_session_already_loaded(&err) => {
                            Self::flush_plan_snapshot_for_history(
                                &mut messages,
                                &self.profile.message_id_prefix,
                                &mut history_plan_message_index,
                                &mut history_plan_current,
                                &mut history_plan_history,
                            );
                            let mut cached = self
                                .metadata_by_directory
                                .lock()
                                .await
                                .get(&Self::normalize_directory(directory))
                                .cloned()
                                .unwrap_or_default();
                            if let Some(mode_id) = observed_mode_id.as_deref() {
                                Self::apply_current_mode_to_metadata(&mut cached, mode_id);
                            }
                            for (option_id, option_value) in observed_config_values.clone() {
                                Self::apply_config_value_to_metadata(
                                    &mut cached,
                                    &option_id,
                                    option_value,
                                );
                            }
                            return Ok((messages, cached));
                        }
                        Err(err) => return Err(err),
                    }
                }
                recv = notifications.recv() => {
                    let Ok(notification) = recv else { continue };
                    if notification.method != "session/update" {
                        continue;
                    }
                    let params = notification.params.unwrap_or(Value::Null);
                    let event_session_id = params.get("sessionId").and_then(|v| v.as_str()).unwrap_or("");
                    if event_session_id != session_id {
                        continue;
                    }
                    let Some(update) = params.get("update") else { continue };
                    let Some((session_update, content_type, text)) = Self::extract_update(update) else { continue };
                    if Self::normalize_current_mode_update(&session_update) {
                        if let Some(mode_id) = Self::extract_current_mode_id(update) {
                            observed_mode_id = Some(mode_id);
                        }
                        continue;
                    }
                    if Self::is_config_option_update(&session_update)
                        || Self::is_config_options_update(&session_update)
                    {
                        for (option_id, option_value) in Self::extract_config_option_updates(update)
                        {
                            observed_config_values.insert(option_id, option_value);
                        }
                        continue;
                    }
                    if Self::is_available_commands_update(&session_update) {
                        let commands = Self::extract_available_commands(update);
                        Self::cache_available_commands(
                            &self.slash_commands_by_directory,
                            &self.slash_commands_by_session,
                            directory,
                            Some(session_id),
                            commands,
                        )
                        .await;
                        continue;
                    }
                    if Self::is_plan_update(&session_update) {
                        let Some(entries) = Self::extract_plan_entries(update) else {
                            warn!(
                                "{}: plan update missing entries array in history, ignore: {}",
                                self.profile.tool_id, session_update
                            );
                            continue;
                        };
                        Self::apply_plan_update(
                            &mut history_plan_current,
                            &mut history_plan_history,
                            &mut history_plan_revision,
                            entries,
                        );
                        continue;
                    }
                    if Self::is_terminal_update(&session_update, &content_type) {
                        Self::flush_plan_snapshot_for_history(
                            &mut messages,
                            &self.profile.message_id_prefix,
                            &mut history_plan_message_index,
                            &mut history_plan_current,
                            &mut history_plan_history,
                        );
                        continue;
                    }
                    if let Some(content) = update.get("content").and_then(|v| v.as_object()) {
                        if let Some(parsed) = Self::parse_tool_call_update_content(content) {
                            let part_id = if let Some(tool_call_id) = parsed.tool_call_id.as_ref() {
                                history_tool_part_ids
                                    .entry(tool_call_id.clone())
                                    .or_insert_with(|| {
                                        format!(
                                            "{}-tool-{}",
                                            self.profile.message_id_prefix,
                                            tool_call_id.replace(':', "_")
                                        )
                                    })
                                    .clone()
                            } else {
                                Self::log_missing_tool_call_id(&self.profile.tool_id, "history");
                                format!("{}-tool-{}", self.profile.message_id_prefix, Uuid::new_v4())
                            };
                            let tool_state = Self::merge_tool_state(
                                history_tool_states.get(&part_id),
                                &parsed,
                            );
                            history_tool_states.insert(part_id.clone(), tool_state.clone());
                            let part = AiPart {
                                id: part_id,
                                part_type: "tool".to_string(),
                                tool_name: Some(parsed.tool_name.clone()),
                                tool_call_id: parsed.tool_call_id.clone(),
                                tool_kind: parsed.tool_kind.clone(),
                                tool_title: parsed.tool_title.clone(),
                                tool_raw_input: parsed.raw_input.clone(),
                                tool_raw_output: parsed.raw_output.clone(),
                                tool_locations: parsed.locations.clone(),
                                tool_state: Some(tool_state),
                                tool_part_metadata: Some(parsed.tool_part_metadata.clone()),
                                ..Default::default()
                            };
                            Self::push_structured_parts_message(
                                &mut messages,
                                &self.profile.message_id_prefix,
                                Self::role_for_session_update(&session_update),
                                vec![part],
                            );
                            continue;
                        }
                        let history_message_id =
                            format!("{}-history-{}", self.profile.message_id_prefix, Uuid::new_v4());
                        let content_parts =
                            Self::map_content_to_non_text_parts(&history_message_id, content);
                        if !content_parts.is_empty() {
                            Self::push_structured_parts_message(
                                &mut messages,
                                &self.profile.message_id_prefix,
                                Self::role_for_session_update(&session_update),
                                content_parts,
                            );
                            continue;
                        }
                        if content_type != "text" && content_type != "reasoning" {
                            Self::log_unknown_content_type(
                                &self.profile.tool_id,
                                "history",
                                &content_type,
                            );
                            let fallback = serde_json::to_string_pretty(content)
                                .unwrap_or_else(|_| Value::Object(content.clone()).to_string());
                            Self::push_structured_parts_message(
                                &mut messages,
                                &self.profile.message_id_prefix,
                                Self::role_for_session_update(&session_update),
                                vec![AiPart {
                                    id: history_message_id,
                                    part_type: "text".to_string(),
                                    text: Some(fallback),
                                    source: Some(serde_json::json!({
                                        "vendor": "acp",
                                        "content_type": content_type
                                    })),
                                    ..Default::default()
                                }],
                            );
                            continue;
                        }
                    }
                    let Some((part_type, should_emit)) =
                        Self::map_update_to_output(&session_update)
                    else {
                        warn!(
                            "{}: unknown sessionUpdate type in history, ignore: {}",
                            self.profile.tool_id, session_update
                        );
                        continue;
                    };
                    if !should_emit || text.is_empty() {
                        continue;
                    }
                    Self::push_chunk_message(
                        &mut messages,
                        &self.profile.message_id_prefix,
                        "assistant",
                        part_type,
                        &text,
                    );
                }
            }
        }
    }

    async fn apply_config_overrides_before_send(
        &self,
        directory: &str,
        session_id: &str,
        metadata: &mut AcpSessionMetadata,
        overrides: &HashMap<String, AiSessionConfigValue>,
        base_model: Option<AiModelSelection>,
        base_agent: Option<String>,
    ) -> Result<(Option<AiModelSelection>, Option<String>), String> {
        if overrides.is_empty() {
            return Ok((base_model, base_agent));
        }

        let mut effective_model = base_model;
        let mut effective_agent = base_agent;
        let supports_set_config_option = self.client.supports_set_config_option().await;
        let supports_load_session = self.client.supports_load_session().await;

        let mut keys = overrides.keys().cloned().collect::<Vec<_>>();
        keys.sort();

        for option_id in keys {
            let Some(option_value) = overrides.get(&option_id).cloned() else {
                continue;
            };
            let option_meta = metadata
                .config_options
                .iter()
                .find(|option| {
                    option.option_id == option_id
                        || option.option_id.eq_ignore_ascii_case(&option_id)
                })
                .cloned();
            let category = option_meta
                .as_ref()
                .map(|option| {
                    Self::normalized_category(option.category.as_deref(), &option.option_id)
                })
                .unwrap_or_else(|| option_id.trim().to_lowercase());

            let set_result: Result<(), String> = if supports_set_config_option {
                match self
                    .client
                    .session_set_config_option(session_id, &option_id, option_value.clone())
                    .await
                {
                    Ok(()) => Ok(()),
                    Err(err) if Self::is_session_not_found(&err) && supports_load_session => {
                        self.client.session_load(directory, session_id).await?;
                        self.client
                            .session_set_config_option(session_id, &option_id, option_value.clone())
                            .await
                    }
                    Err(err) => Err(err),
                }
            } else {
                Err("session/set_config_option capability unsupported".to_string())
            };

            match set_result {
                Ok(()) => {
                    Self::apply_config_value_to_metadata(
                        metadata,
                        &option_id,
                        option_value.clone(),
                    );
                    if category == "mode" {
                        effective_agent = None;
                    } else if category == "model" {
                        effective_model = None;
                    }
                }
                Err(err)
                    if Self::is_set_config_option_unsupported(&err)
                        || !supports_set_config_option =>
                {
                    if category == "mode" {
                        let mode_id = option_meta
                            .as_ref()
                            .and_then(|option| {
                                Self::resolve_mode_id_from_option(option, &option_value)
                            })
                            .or_else(|| Self::value_to_string(&option_value));
                        if let Some(mode_id) = mode_id {
                            let mode_result =
                                match self.client.session_set_mode(session_id, &mode_id).await {
                                    Ok(()) => Ok(()),
                                    Err(mode_err)
                                        if Self::is_session_not_found(&mode_err)
                                            && supports_load_session =>
                                    {
                                        self.client.session_load(directory, session_id).await?;
                                        self.client.session_set_mode(session_id, &mode_id).await
                                    }
                                    Err(mode_err) => Err(mode_err),
                                };
                            match mode_result {
                                Ok(()) => {
                                    Self::apply_current_mode_to_metadata(metadata, &mode_id);
                                    Self::apply_config_value_to_metadata(
                                        metadata,
                                        &option_id,
                                        option_value.clone(),
                                    );
                                    effective_agent = None;
                                    warn!(
                                        "{}: fallback to session/set_mode for config option '{}'",
                                        self.profile.tool_id, option_id
                                    );
                                }
                                Err(mode_err) => return Err(mode_err),
                            }
                        } else {
                            warn!(
                                "{}: config option '{}' category=mode fallback failed: unresolved mode id",
                                self.profile.tool_id, option_id
                            );
                        }
                    } else if category == "model" {
                        let model_id = option_meta
                            .as_ref()
                            .and_then(|option| {
                                Self::resolve_model_id_from_option(option, &option_value)
                            })
                            .or_else(|| Self::value_to_string(&option_value));
                        if let Some(model_id) = model_id {
                            let provider_id = effective_model
                                .as_ref()
                                .map(|model| model.provider_id.clone())
                                .unwrap_or_else(|| self.profile.provider_id.clone());
                            effective_model = Some(AiModelSelection {
                                provider_id,
                                model_id: model_id.clone(),
                            });
                            Self::apply_current_model_to_metadata(metadata, &model_id);
                            Self::apply_config_value_to_metadata(
                                metadata,
                                &option_id,
                                option_value.clone(),
                            );
                            warn!(
                                "{}: fallback to prompt.model for config option '{}'",
                                self.profile.tool_id, option_id
                            );
                        }
                    } else if category == "thought_level" {
                        debug!(
                            "{}: config option '{}' category=thought_level has no legacy fallback: {}",
                            self.profile.tool_id, option_id, err
                        );
                        Self::apply_config_value_to_metadata(
                            metadata,
                            &option_id,
                            option_value.clone(),
                        );
                    } else {
                        warn!(
                            "{}: ignore config option '{}' (category={}) fallback because set_config_option unsupported: {}",
                            self.profile.tool_id, option_id, category, err
                        );
                        Self::apply_config_value_to_metadata(
                            metadata,
                            &option_id,
                            option_value.clone(),
                        );
                    }
                }
                Err(err) => {
                    if category == "thought_level" {
                        debug!(
                            "{}: apply thought_level config '{}' failed (ignored): {}",
                            self.profile.tool_id, option_id, err
                        );
                        continue;
                    }
                    return Err(err);
                }
            }
        }

        Ok((effective_model, effective_agent))
    }
}

#[async_trait]
impl AiAgent for AcpAgent {
    async fn start(&self) -> Result<(), String> {
        self.client.ensure_started().await
    }

    async fn stop(&self) -> Result<(), String> {
        Ok(())
    }

    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String> {
        self.client.ensure_started().await?;
        let (session_id, metadata) = self.client.session_new(directory).await?;
        self.cache_metadata(directory, metadata.clone()).await;
        self.cache_session_metadata(directory, &session_id, metadata)
            .await;
        let session = AiSession {
            id: session_id,
            title: title.to_string(),
            updated_at: chrono::Utc::now().timestamp_millis(),
        };
        self.upsert_cached_session(
            directory,
            &session.id,
            Some(&session.title),
            Some(session.updated_at),
        )
        .await;
        Ok(session)
    }

    async fn send_message(
        &self,
        directory: &str,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        audio_parts: Option<Vec<AiAudioPart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
    ) -> Result<AiEventStream, String> {
        self.client.ensure_started().await?;
        self.ensure_runtime_yolo_for_session(directory, session_id)
            .await?;

        let mut metadata = self.metadata_for_directory(directory).await;
        let mode_id = Self::resolve_mode_id(&metadata, agent.as_deref());
        let model_id = model.map(|m| m.model_id);
        let supports_load_session = self.client.supports_load_session().await;
        if let Some(target_mode_id) = mode_id.as_ref() {
            let needs_switch = metadata
                .current_mode_id
                .as_ref()
                .map(|current| !current.eq_ignore_ascii_case(target_mode_id))
                .unwrap_or(true);
            if needs_switch {
                let switch_result = match self
                    .client
                    .session_set_mode(session_id, target_mode_id)
                    .await
                {
                    Ok(()) => Ok(()),
                    Err(err) if Self::is_session_not_found(&err) && supports_load_session => {
                        self.client.session_load(directory, session_id).await?;
                        self.client
                            .session_set_mode(session_id, target_mode_id)
                            .await
                    }
                    Err(err) => Err(err),
                };
                match switch_result {
                    Ok(()) => {
                        Self::apply_current_mode_to_metadata(&mut metadata, target_mode_id);
                        self.cache_metadata(directory, metadata.clone()).await;
                        self.cache_session_metadata(directory, session_id, metadata.clone())
                            .await;
                    }
                    Err(err) if Self::is_set_mode_unsupported(&err) => {
                        warn!(
                            "{}: ACP session/set_mode unsupported, fallback to prompt.mode, error={}",
                            self.profile.tool_id, err
                        );
                    }
                    Err(err) => return Err(err),
                }
            }
        }
        if !self.client.supports_content_type("text").await {
            return Err("ACP 服务端 promptCapabilities 不支持 text，无法发送消息".to_string());
        }
        let encoding_mode = self.client.prompt_encoding_mode().await;
        let supports_image = self.client.supports_content_type("image").await;
        let supports_audio = self.client.supports_content_type("audio").await;
        let supports_resource = self.client.supports_content_type("resource").await;
        let supports_resource_link = self.client.supports_content_type("resource_link").await;
        let prompt = Self::compose_prompt_parts(
            directory,
            message,
            file_refs,
            image_parts,
            audio_parts,
            encoding_mode,
            supports_image,
            supports_audio,
            supports_resource,
            supports_resource_link,
        );

        let (tx, rx) = mpsc::unbounded_channel::<Result<AiEvent, String>>();
        let mut notifications = self.client.subscribe_notifications();
        let mut requests = self.client.subscribe_requests();
        let client = self.client.clone();
        let tool_id = self.profile.tool_id.clone();
        let provider_id = self.profile.provider_id.clone();
        let message_id_prefix = self.profile.message_id_prefix.clone();
        let directory = directory.to_string();
        let cache_directory = directory.clone();
        let session_id = session_id.to_string();
        let cache_session_id = session_id.clone();
        let original_text = message.to_string();
        let assistant_message_id =
            format!("{}-assistant-{}", message_id_prefix, uuid::Uuid::new_v4());
        let user_message_id = format!("{}-user-{}", message_id_prefix, uuid::Uuid::new_v4());
        let pending_permissions = self.pending_permissions.clone();
        let cached_sessions = self.cached_sessions.clone();
        let metadata_by_directory = self.metadata_by_directory.clone();
        let metadata_by_session = self.metadata_by_session.clone();
        let slash_commands_by_directory = self.slash_commands_by_directory.clone();
        let slash_commands_by_session = self.slash_commands_by_session.clone();

        let _ = tx.send(Ok(AiEvent::MessageUpdated {
            message_id: user_message_id.clone(),
            role: "user".to_string(),
            selection_hint: None,
        }));
        let _ = tx.send(Ok(AiEvent::PartUpdated {
            message_id: user_message_id.clone(),
            part: AiPart::new_text(format!("{}-text", user_message_id), original_text),
        }));
        self.upsert_cached_session(directory.as_str(), &session_id, None, None)
            .await;
        self.append_cached_message(
            directory.as_str(),
            &session_id,
            Self::build_cached_user_message(user_message_id.clone(), message.to_string()),
        )
        .await;

        tokio::spawn(async move {
            let mut buffered_assistant_reasoning = String::new();
            let mut buffered_assistant_text = String::new();
            let mut buffered_plan_current: Option<AcpPlanSnapshot> = None;
            let mut buffered_plan_history: Vec<AcpPlanSnapshot> = Vec::new();
            let mut buffered_plan_revision: u64 = 0;
            let mut assistant_opened = false;
            let mut tool_part_ids = HashMap::<String, String>::new();
            let mut tool_states_by_part = HashMap::<String, Value>::new();
            let mut follow_terminal_ids = HashMap::<String, String>::new();
            let mut follow_along_supported = true;
            let mut request_completed = false;
            let mut terminal_seen = false;
            let mut stop_reason: Option<String> = None;
            let mut done_emitted = false;

            let request_fut = async {
                match client
                    .session_prompt(
                        &session_id,
                        prompt.clone(),
                        model_id.clone(),
                        mode_id.clone(),
                    )
                    .await
                {
                    Ok(result) => Ok(result),
                    Err(err) if Self::is_session_not_found(&err) => {
                        if supports_load_session {
                            client.session_load(&directory, &session_id).await?;
                            client
                                .session_prompt(&session_id, prompt, model_id, mode_id)
                                .await
                        } else {
                            Err(err)
                        }
                    }
                    Err(err) => Err(err),
                }
            };
            tokio::pin!(request_fut);
            loop {
                if done_emitted {
                    break;
                }
                if request_completed && terminal_seen && !done_emitted {
                    let Some(reason) = stop_reason.clone() else {
                        let _ = tx.send(Err(
                            "ACP request completed but stopReason is unavailable".to_string()
                        ));
                        break;
                    };
                    let _ = tx.send(Ok(AiEvent::Done {
                        stop_reason: Some(reason),
                    }));
                    done_emitted = true;
                    continue;
                }

                tokio::select! {
                    request_result = &mut request_fut, if !request_completed => {
                        match request_result {
                            Ok(result) => {
                                let parsed_stop_reason = match Self::parse_prompt_stop_reason(&result) {
                                    Ok(stop_reason) => stop_reason,
                                    Err(err) => {
                                        let _ = tx.send(Err(err));
                                        break;
                                    }
                                };
                                request_completed = true;
                                terminal_seen = true;
                                stop_reason = Some(parsed_stop_reason);
                            }
                            Err(err) => {
                                let _ = tx.send(Err(err));
                                break;
                            }
                        }
                    }
                    recv = notifications.recv() => {
                        let Ok(notification) = recv else {
                            let _ = tx.send(Err(format!("{} notification stream closed", tool_id)));
                            break;
                        };
                        if notification.method != "session/update" {
                            continue;
                        }
                        let params = notification.params.unwrap_or(Value::Null);
                        let event_session_id = params.get("sessionId").and_then(|v| v.as_str()).unwrap_or("");
                        if event_session_id != session_id {
                            continue;
                        }
                        let Some(update) = params.get("update") else { continue };
                        let Some((session_update, content_type, text)) = Self::extract_update(update) else { continue };
                        if Self::normalize_current_mode_update(&session_update) {
                            if let Some(mode_id) = Self::extract_current_mode_id(update) {
                                Self::apply_current_mode_to_caches(
                                    &metadata_by_directory,
                                    &metadata_by_session,
                                    &cache_directory,
                                    &cache_session_id,
                                    &mode_id,
                                )
                                .await;
                            }
                            continue;
                        }
                        if Self::is_config_option_update(&session_update)
                            || Self::is_config_options_update(&session_update)
                        {
                            let updates = Self::extract_config_option_updates(update);
                            if updates.is_empty() {
                                continue;
                            }
                            for (option_id, option_value) in updates {
                                Self::apply_config_value_to_caches(
                                    &metadata_by_directory,
                                    &metadata_by_session,
                                    &cache_directory,
                                    &cache_session_id,
                                    &option_id,
                                    option_value,
                                )
                                .await;
                            }

                            let metadata_snapshot = {
                                let key = Self::session_cache_key(&cache_directory, &cache_session_id);
                                let by_session = metadata_by_session.lock().await;
                                by_session.get(&key).cloned()
                            };
                            let metadata_snapshot = if let Some(meta) = metadata_snapshot {
                                meta
                            } else {
                                let directory_key = Self::normalize_directory(&cache_directory);
                                let by_directory = metadata_by_directory.lock().await;
                                by_directory.get(&directory_key).cloned().unwrap_or_default()
                            };
                            let _ = tx.send(Ok(AiEvent::SessionConfigOptionsUpdated {
                                session_id: cache_session_id.clone(),
                                options: Self::map_config_options(&metadata_snapshot.config_options),
                                selection_hint: Self::selection_hint_from_metadata(
                                    &metadata_snapshot,
                                    &provider_id,
                                ),
                            }));
                            continue;
                        }
                        if Self::is_available_commands_update(&session_update) {
                            let commands = Self::extract_available_commands(update);
                            Self::cache_available_commands(
                                &slash_commands_by_directory,
                                &slash_commands_by_session,
                                &cache_directory,
                                Some(&cache_session_id),
                                commands.clone(),
                            )
                            .await;
                            let _ = tx.send(Ok(AiEvent::SlashCommandsUpdated {
                                session_id: cache_session_id.clone(),
                                commands,
                            }));
                            continue;
                        }

                        if Self::is_plan_update(&session_update) {
                            let Some(entries) = Self::extract_plan_entries(update) else {
                                warn!(
                                    "{}: plan update missing entries array, ignore: {}",
                                    tool_id, session_update
                                );
                                continue;
                            };
                            let snapshot = Self::apply_plan_update(
                                &mut buffered_plan_current,
                                &mut buffered_plan_history,
                                &mut buffered_plan_revision,
                                entries,
                            );
                            if !assistant_opened {
                                assistant_opened = true;
                                let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                    message_id: assistant_message_id.clone(),
                                    role: "assistant".to_string(),
                                    selection_hint: None,
                                }));
                            }
                            let _ = tx.send(Ok(AiEvent::PartUpdated {
                                message_id: assistant_message_id.clone(),
                                part: Self::build_plan_part(
                                    &assistant_message_id,
                                    &snapshot,
                                    &buffered_plan_history,
                                ),
                            }));
                            continue;
                        }

                        if Self::is_error_update(&session_update, &content_type) {
                            let err_msg = if text.is_empty() {
                                format!("{} stream error update: {}", tool_id, session_update)
                            } else {
                                text.clone()
                            };
                            let _ = tx.send(Err(err_msg));
                            break;
                        }

                        if Self::is_terminal_update(&session_update, &content_type) {
                            terminal_seen = true;
                            continue;
                        }

                        if let Some(content) = update.get("content").and_then(|v| v.as_object()) {
                            if let Some(parsed) = Self::parse_tool_call_update_content(content) {
                                if !assistant_opened {
                                    assistant_opened = true;
                                    let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                        message_id: assistant_message_id.clone(),
                                        role: "assistant".to_string(),
                                        selection_hint: None,
                                    }));
                                }
                                let part_id = if let Some(tool_call_id) = parsed.tool_call_id.as_ref() {
                                    tool_part_ids
                                        .entry(tool_call_id.clone())
                                        .or_insert_with(|| {
                                            format!(
                                                "{}-tool-{}",
                                                assistant_message_id,
                                                tool_call_id.replace(':', "_")
                                            )
                                        })
                                        .clone()
                                } else {
                                    Self::log_missing_tool_call_id(&tool_id, "stream");
                                    format!("{}-tool-{}", assistant_message_id, Uuid::new_v4())
                                };

                                let tool_state = Self::merge_tool_state(
                                    tool_states_by_part.get(&part_id),
                                    &parsed,
                                );
                                tool_states_by_part.insert(part_id.clone(), tool_state.clone());

                                let _ = tx.send(Ok(AiEvent::PartUpdated {
                                    message_id: assistant_message_id.clone(),
                                    part: AiPart {
                                        id: part_id.clone(),
                                        part_type: "tool".to_string(),
                                        tool_name: Some(parsed.tool_name.clone()),
                                        tool_call_id: parsed.tool_call_id.clone(),
                                        tool_kind: parsed.tool_kind.clone(),
                                        tool_title: parsed.tool_title.clone(),
                                        tool_raw_input: parsed.raw_input.clone(),
                                        tool_raw_output: parsed.raw_output.clone(),
                                        tool_locations: parsed.locations.clone(),
                                        tool_state: Some(tool_state),
                                        tool_part_metadata: Some(parsed.tool_part_metadata.clone()),
                                        ..Default::default()
                                    },
                                }));

                                if let Some(progress) = parsed.progress_delta.as_deref() {
                                    let _ = tx.send(Ok(AiEvent::PartDelta {
                                        message_id: assistant_message_id.clone(),
                                        part_id: part_id.clone(),
                                        part_type: "tool".to_string(),
                                        field: "progress".to_string(),
                                        delta: progress.to_string(),
                                    }));
                                }
                                if let Some(output) = parsed.output_delta.as_deref() {
                                    let _ = tx.send(Ok(AiEvent::PartDelta {
                                        message_id: assistant_message_id.clone(),
                                        part_id: part_id.clone(),
                                        part_type: "tool".to_string(),
                                        field: "output".to_string(),
                                        delta: output.to_string(),
                                    }));
                                }

                                let tool_kind = parsed
                                    .tool_kind
                                    .as_deref()
                                    .map(Self::normalized_update_token)
                                    .unwrap_or_default();
                                if follow_along_supported && tool_kind == "terminal" {
                                    let tool_call_key = parsed
                                        .tool_call_id
                                        .clone()
                                        .unwrap_or_else(|| part_id.clone());
                                    let status = parsed
                                        .status
                                        .clone()
                                        .unwrap_or_else(|| "running".to_string());
                                    if !Self::status_is_terminal(&status)
                                        && !follow_terminal_ids.contains_key(&tool_call_key)
                                    {
                                        match client.terminal_create(&session_id, &tool_call_key).await {
                                            Ok(terminal_id) => {
                                                follow_terminal_ids.insert(tool_call_key.clone(), terminal_id);
                                            }
                                            Err(err) => {
                                                if Self::is_rpc_method_unsupported(&err) {
                                                    follow_along_supported = false;
                                                    Self::log_follow_along_failure(
                                                        &tool_id,
                                                        "create",
                                                        &err,
                                                    );
                                                    warn!(
                                                        "{}: ACP terminal/create unsupported, fallback to plain stream output: {}",
                                                        tool_id, err
                                                    );
                                                } else {
                                                    Self::log_follow_along_failure(
                                                        &tool_id,
                                                        "create",
                                                        &err,
                                                    );
                                                    warn!(
                                                        "{}: ACP terminal/create failed, continue without follow-along: {}",
                                                        tool_id, err
                                                    );
                                                }
                                            }
                                        }
                                    } else if Self::status_is_terminal(&status) {
                                        if let Some(terminal_id) = follow_terminal_ids.remove(&tool_call_key) {
                                            if let Err(err) = client.terminal_release(&terminal_id).await {
                                                Self::log_follow_along_failure(
                                                    &tool_id,
                                                    "release",
                                                    &format!("terminal_id={}, error={}", terminal_id, err),
                                                );
                                                warn!(
                                                    "{}: ACP terminal/release failed, terminal_id={}, error={}",
                                                    tool_id, terminal_id, err
                                                );
                                            }
                                        }
                                    }
                                }
                                continue;
                            }

                            match content_type.as_str() {
                                "image" | "audio" | "resource_link" | "resource" | "markdown" | "diff" | "terminal" => {
                                    let parts =
                                        Self::map_content_to_non_text_parts(&assistant_message_id, content);
                                    if parts.is_empty() {
                                        continue;
                                    }
                                    if !assistant_opened {
                                        assistant_opened = true;
                                        let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                            message_id: assistant_message_id.clone(),
                                            role: "assistant".to_string(),
                                            selection_hint: None,
                                        }));
                                    }
                                    for part in parts {
                                        let _ = tx.send(Ok(AiEvent::PartUpdated {
                                            message_id: assistant_message_id.clone(),
                                            part,
                                        }));
                                    }
                                    continue;
                                }
                                "text" | "reasoning" => {
                                    // 继续走下方的通用 chunk 增量路径
                                }
                                _ => {
                                    Self::log_unknown_content_type(&tool_id, "stream", &content_type);
                                    let fallback = serde_json::to_string_pretty(content)
                                        .unwrap_or_else(|_| Value::Object(content.clone()).to_string());
                                    if !assistant_opened {
                                        assistant_opened = true;
                                        let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                            message_id: assistant_message_id.clone(),
                                            role: "assistant".to_string(),
                                            selection_hint: None,
                                        }));
                                    }
                                    let _ = tx.send(Ok(AiEvent::PartUpdated {
                                        message_id: assistant_message_id.clone(),
                                        part: AiPart {
                                            id: format!(
                                                "{}-content-{}",
                                                assistant_message_id,
                                                Uuid::new_v4()
                                            ),
                                            part_type: "text".to_string(),
                                            text: Some(fallback),
                                            source: Some(serde_json::json!({
                                                "vendor": "acp",
                                                "content_type": content_type
                                            })),
                                            ..Default::default()
                                        },
                                    }));
                                    continue;
                                }
                            }
                        }

                        let Some((part_type, should_emit)) = Self::map_update_to_output(&session_update) else {
                            warn!(
                                "{}: unknown sessionUpdate type in stream, ignore: {}",
                                tool_id, session_update
                            );
                            continue;
                        };
                        if !should_emit || text.is_empty() {
                            continue;
                        }
                        if part_type == "reasoning" {
                            buffered_assistant_reasoning.push_str(&text);
                        } else if part_type == "text" {
                            buffered_assistant_text.push_str(&text);
                        }
                        if !assistant_opened {
                            assistant_opened = true;
                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                message_id: assistant_message_id.clone(),
                                role: "assistant".to_string(),
                                selection_hint: None,
                            }));
                        }
                        let part_id = format!("{}-{}", assistant_message_id, part_type);
                        let _ = tx.send(Ok(AiEvent::PartDelta {
                            message_id: assistant_message_id.clone(),
                            part_id,
                            part_type: part_type.to_string(),
                            field: "text".to_string(),
                            delta: text,
                        }));
                    }
                    recv = requests.recv() => {
                        let Ok(req) = recv else { continue };
                        if req.method != "session/request_permission" {
                            continue;
                        }
                        let params = req.params.unwrap_or(Value::Null);
                        let event_session_id = params.get("sessionId").and_then(|v| v.as_str()).unwrap_or("");
                        if event_session_id != session_id {
                            continue;
                        }
                        if let Some((question_request, permission_options)) =
                            Self::build_question_from_permission_request(&req.id, &params)
                        {
                            let request_key = question_request.id.clone();
                            pending_permissions.lock().await.insert(request_key.clone(), PendingPermission {
                                request_id: req.id.clone(),
                                session_id: session_id.clone(),
                                options: permission_options,
                            });
                            let _ = tx.send(Ok(AiEvent::QuestionAsked { request: question_request }));
                        }
                    }
                }
            }

            if !follow_terminal_ids.is_empty() {
                let pending_releases = follow_terminal_ids.drain().collect::<Vec<_>>();
                for (_tool_call_key, terminal_id) in pending_releases {
                    if let Err(err) = client.terminal_release(&terminal_id).await {
                        Self::log_follow_along_failure(
                            &tool_id,
                            "release",
                            &format!("terminal_id={}, error={}", terminal_id, err),
                        );
                        warn!(
                            "{}: ACP terminal/release failed on stream teardown, terminal_id={}, error={}",
                            tool_id, terminal_id, err
                        );
                    }
                }
            }

            Self::reject_pending_permissions_for_session(
                &pending_permissions,
                &client,
                &session_id,
            )
            .await;

            if let Some(cached_assistant) = Self::build_cached_assistant_message(
                assistant_message_id.clone(),
                buffered_assistant_reasoning,
                buffered_assistant_text,
                buffered_plan_current,
                buffered_plan_history,
            ) {
                Self::append_cached_message_in_map(
                    &cached_sessions,
                    &cache_directory,
                    &cache_session_id,
                    cached_assistant,
                )
                .await;
            }
            Self::upsert_cached_session_in_map(
                &cached_sessions,
                &cache_directory,
                &cache_session_id,
                None,
                Some(Self::now_ms()),
            )
            .await;
        });

        Ok(Box::pin(UnboundedReceiverStream::new(rx)))
    }

    async fn send_message_with_config(
        &self,
        directory: &str,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        audio_parts: Option<Vec<AiAudioPart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
        config_overrides: Option<HashMap<String, AiSessionConfigValue>>,
    ) -> Result<AiEventStream, String> {
        let mut metadata =
            if let Some(cached) = self.metadata_for_session(directory, session_id).await {
                cached
            } else {
                self.metadata_for_directory(directory).await
            };

        let (effective_model, effective_agent) = if let Some(overrides) = config_overrides.as_ref()
        {
            self.apply_config_overrides_before_send(
                directory,
                session_id,
                &mut metadata,
                overrides,
                model,
                agent,
            )
            .await?
        } else {
            (model, agent)
        };

        self.cache_metadata(directory, metadata.clone()).await;
        self.cache_session_metadata(directory, session_id, metadata)
            .await;

        self.send_message(
            directory,
            session_id,
            message,
            file_refs,
            image_parts,
            audio_parts,
            effective_model,
            effective_agent,
        )
        .await
    }

    async fn list_session_config_options(
        &self,
        directory: &str,
        session_id: Option<&str>,
    ) -> Result<Vec<AiSessionConfigOption>, String> {
        self.client.ensure_started().await?;
        let mut metadata = if let Some(session_id) = session_id {
            self.metadata_for_session(directory, session_id)
                .await
                .unwrap_or_default()
        } else {
            self.metadata_for_directory(directory).await
        };

        if metadata.config_options.is_empty() {
            if let Some(session_id) = session_id {
                if self.client.supports_load_session().await {
                    if let Ok(refreshed) = self.client.session_load(directory, session_id).await {
                        metadata = refreshed;
                    }
                }
            } else {
                metadata = self.metadata_for_directory(directory).await;
            }
        }

        self.cache_metadata(directory, metadata.clone()).await;
        if let Some(session_id) = session_id {
            self.cache_session_metadata(directory, session_id, metadata.clone())
                .await;
        }

        Ok(Self::map_config_options(&metadata.config_options))
    }

    async fn set_session_config_option(
        &self,
        directory: &str,
        session_id: &str,
        option_id: &str,
        value: AiSessionConfigValue,
    ) -> Result<(), String> {
        self.client.ensure_started().await?;
        let supports_load_session = self.client.supports_load_session().await;
        let supports_set_config = self.client.supports_set_config_option().await;

        let mut metadata =
            if let Some(cached) = self.metadata_for_session(directory, session_id).await {
                cached
            } else {
                self.metadata_for_directory(directory).await
            };
        let option_meta = metadata
            .config_options
            .iter()
            .find(|option| {
                option.option_id == option_id || option.option_id.eq_ignore_ascii_case(option_id)
            })
            .cloned();
        let category = option_meta
            .as_ref()
            .map(|option| Self::normalized_category(option.category.as_deref(), &option.option_id))
            .unwrap_or_else(|| option_id.trim().to_lowercase());

        let set_result = if supports_set_config {
            match self
                .client
                .session_set_config_option(session_id, option_id, value.clone())
                .await
            {
                Ok(()) => Ok(()),
                Err(err) if Self::is_session_not_found(&err) && supports_load_session => {
                    self.client.session_load(directory, session_id).await?;
                    self.client
                        .session_set_config_option(session_id, option_id, value.clone())
                        .await
                }
                Err(err) => Err(err),
            }
        } else {
            Err("session/set_config_option capability unsupported".to_string())
        };

        match set_result {
            Ok(()) => {
                Self::apply_config_value_to_metadata(&mut metadata, option_id, value.clone());
            }
            Err(err) if Self::is_set_config_option_unsupported(&err) || !supports_set_config => {
                if category == "mode" {
                    let mode_id = option_meta
                        .as_ref()
                        .and_then(|option| Self::resolve_mode_id_from_option(option, &value))
                        .or_else(|| Self::value_to_string(&value))
                        .ok_or_else(|| {
                            format!(
                                "session/set_config_option fallback failed: unresolved mode for option '{}'",
                                option_id
                            )
                        })?;
                    match self.client.session_set_mode(session_id, &mode_id).await {
                        Ok(()) => {
                            Self::apply_current_mode_to_metadata(&mut metadata, &mode_id);
                            Self::apply_config_value_to_metadata(
                                &mut metadata,
                                option_id,
                                value.clone(),
                            );
                        }
                        Err(mode_err)
                            if Self::is_session_not_found(&mode_err) && supports_load_session =>
                        {
                            self.client.session_load(directory, session_id).await?;
                            self.client.session_set_mode(session_id, &mode_id).await?;
                            Self::apply_current_mode_to_metadata(&mut metadata, &mode_id);
                            Self::apply_config_value_to_metadata(
                                &mut metadata,
                                option_id,
                                value.clone(),
                            );
                        }
                        Err(mode_err) => return Err(mode_err),
                    }
                } else if category == "model" || category == "thought_level" {
                    Self::apply_config_value_to_metadata(&mut metadata, option_id, value.clone());
                } else {
                    return Err(err);
                }
            }
            Err(err) => return Err(err),
        }

        self.cache_metadata(directory, metadata.clone()).await;
        self.cache_session_metadata(directory, session_id, metadata)
            .await;
        Ok(())
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        let remote_sessions = self
            .list_sessions_for_directory(directory, 8)
            .await?
            .into_iter()
            .map(|s| AiSession {
                id: s.id,
                title: s.title,
                updated_at: s.updated_at_ms,
            })
            .collect::<Vec<_>>();
        let cached_sessions = self.cached_sessions_for_directory(directory).await;
        if remote_sessions.is_empty() && !cached_sessions.is_empty() {
            warn!(
                "{}: session/list returned empty, using cached sessions, directory={}, cached_count={}",
                self.profile.tool_id,
                directory,
                cached_sessions.len()
            );
        }
        Ok(Self::merge_sessions(remote_sessions, cached_sessions))
    }

    async fn delete_session(&self, _directory: &str, _session_id: &str) -> Result<(), String> {
        // ACP 当前未暴露删除会话接口。
        Ok(())
    }

    async fn list_messages(
        &self,
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String> {
        self.client.ensure_started().await?;
        let (mut messages, metadata) = match tokio::time::timeout(
            Duration::from_secs(Self::SESSION_LOAD_TIMEOUT_SECS),
            self.collect_loaded_messages(directory, session_id),
        )
        .await
        {
            Ok(Ok(v)) => v,
            Ok(Err(err)) => return Err(err),
            Err(_) => {
                warn!(
                    "{}: session/load timeout in list_messages, session_id={}",
                    self.profile.tool_id, session_id
                );
                (
                    Vec::new(),
                    self.metadata_for_session(directory, session_id)
                        .await
                        .unwrap_or_default(),
                )
            }
        };
        self.cache_metadata(directory, metadata.clone()).await;
        self.cache_session_metadata(directory, session_id, metadata)
            .await;
        if messages.is_empty() {
            if let Some(cached) = self
                .cached_messages_for_session(directory, session_id)
                .await
            {
                warn!(
                    "{}: list_messages fallback to cached history, session_id={}, cached_messages_count={}",
                    self.profile.tool_id,
                    session_id,
                    cached.len()
                );
                messages = cached;
            }
        } else {
            self.replace_cached_messages(directory, session_id, messages.clone())
                .await;
        }

        if let Some(limit) = limit {
            let limit = limit as usize;
            if messages.len() > limit {
                messages = messages.split_off(messages.len() - limit);
            }
        }
        Ok(messages)
    }

    async fn session_selection_hint(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionSelectionHint>, String> {
        let mut metadata =
            if let Some(meta) = self.metadata_for_session(directory, session_id).await {
                meta
            } else {
                self.metadata_for_directory(directory).await
            };
        if metadata.current_model_id.is_none()
            && metadata.current_mode_id.is_none()
            && metadata.models.is_empty()
            && metadata.modes.is_empty()
        {
            if self.client.supports_load_session().await {
                match tokio::time::timeout(
                    Duration::from_secs(Self::SESSION_LOAD_TIMEOUT_SECS),
                    self.client.session_load(directory, session_id),
                )
                .await
                {
                    Ok(Ok(refreshed)) => {
                        self.cache_metadata(directory, refreshed.clone()).await;
                        self.cache_session_metadata(directory, session_id, refreshed.clone())
                            .await;
                        metadata = refreshed;
                    }
                    Ok(Err(err)) => {
                        debug!(
                            "{} session_selection_hint load failed: session_id={}, error={}",
                            self.profile.tool_id, session_id, err
                        );
                    }
                    Err(_) => {
                        warn!(
                            "{} session_selection_hint load timeout: session_id={}",
                            self.profile.tool_id, session_id
                        );
                    }
                }
            }
        }
        let hint = Self::selection_hint_from_metadata(&metadata, &self.profile.provider_id);
        debug!(
            "ACP session_selection_hint: directory={}, session_id={}, models_count={}, modes_count={}, config_values_count={}, current_model_id={:?}, current_mode_id={:?}, resolved_agent={:?}",
            directory,
            session_id,
            metadata.models.len(),
            metadata.modes.len(),
            metadata.config_values.len(),
            metadata.current_model_id,
            metadata.current_mode_id,
            hint.as_ref().and_then(|it| it.agent.clone())
        );
        Ok(hint)
    }

    async fn abort_session(&self, _directory: &str, _session_id: &str) -> Result<(), String> {
        self.client.ensure_started().await?;
        self.client.session_cancel(_session_id).await?;
        Self::reject_pending_permissions_for_session(
            &self.pending_permissions,
            &self.client,
            _session_id,
        )
        .await;
        Ok(())
    }

    async fn dispose_instance(&self, _directory: &str) -> Result<(), String> {
        Ok(())
    }

    async fn get_session_context_usage(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionContextUsage>, String> {
        if !self.client.supports_load_session().await {
            debug!(
                "{}: loadSession capability unsupported, skip session/load for context usage",
                self.profile.tool_id
            );
            return Ok(None);
        }
        let raw = self.client.session_load_raw(directory, session_id).await?;
        Ok(Some(AiSessionContextUsage {
            context_remaining_percent: extract_context_remaining_percent(&raw),
        }))
    }

    async fn list_providers(&self, directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        let metadata = self.metadata_for_directory(directory).await;
        let provider_id = self.profile.provider_id.clone();
        let mut models = metadata
            .models
            .into_iter()
            .map(|m| AiModelInfo {
                id: m.id.clone(),
                name: m.name,
                provider_id: provider_id.clone(),
                supports_image_input: m.supports_image_input,
            })
            .collect::<Vec<_>>();
        if models.is_empty() {
            models.push(AiModelInfo {
                id: "default".to_string(),
                name: "Default".to_string(),
                provider_id: provider_id.clone(),
                supports_image_input: true,
            });
        }
        Ok(vec![AiProviderInfo {
            id: provider_id,
            name: self.profile.provider_name.clone(),
            models,
        }])
    }

    async fn list_agents(&self, directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        let metadata = self.metadata_for_directory(directory).await;
        let provider_id = self.profile.provider_id.clone();
        let default_model_id = metadata
            .current_model_id
            .clone()
            .or_else(|| metadata.models.first().map(|m| m.id.clone()))
            .or_else(|| Some("default".to_string()));
        let mut agents = metadata
            .modes
            .into_iter()
            .map(|mode| {
                let normalized_name = Self::normalize_mode_name(&mode.name);
                let name = if normalized_name.is_empty() {
                    Self::normalize_mode_name(&mode.id)
                } else {
                    normalized_name
                };
                let color = if mode.id.to_lowercase().contains("#plan") {
                    Some("orange".to_string())
                } else {
                    Some("blue".to_string())
                };
                AiAgentInfo {
                    name,
                    description: mode.description,
                    mode: Some("primary".to_string()),
                    color,
                    default_provider_id: Some(provider_id.clone()),
                    default_model_id: default_model_id.clone(),
                }
            })
            .collect::<Vec<_>>();

        if agents.is_empty() {
            agents.push(AiAgentInfo {
                name: "agent".to_string(),
                description: Some(format!("{} Agent mode", self.profile.provider_name)),
                mode: Some("primary".to_string()),
                color: Some("blue".to_string()),
                default_provider_id: Some(provider_id),
                default_model_id,
            });
        }
        Ok(agents)
    }

    async fn list_slash_commands(
        &self,
        directory: &str,
        session_id: Option<&str>,
    ) -> Result<Vec<AiSlashCommand>, String> {
        Ok(self.slash_commands_for(directory, session_id).await)
    }

    async fn reply_question(
        &self,
        _directory: &str,
        request_id: &str,
        answers: Vec<Vec<String>>,
    ) -> Result<(), String> {
        let pending = self
            .pending_permissions
            .lock()
            .await
            .remove(request_id)
            .ok_or_else(|| format!("Unknown permission request: {}", request_id))?;

        let option_id = Self::resolve_permission_option_id(&pending, &answers)
            .unwrap_or_else(|| "allow-once".to_string());
        self.client
            .respond_to_permission_request(pending.request_id, &option_id)
            .await
    }

    async fn reject_question(&self, _directory: &str, request_id: &str) -> Result<(), String> {
        let pending = self
            .pending_permissions
            .lock()
            .await
            .remove(request_id)
            .ok_or_else(|| format!("Unknown permission request: {}", request_id))?;

        self.client
            .reject_permission_request(pending.request_id)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::{AcpAgent, AcpBackendProfile, AcpPlanEntry, AcpSessionSummary};
    use crate::ai::codex_manager::{AcpContentEncodingMode, CodexAppServerManager};
    use crate::ai::{AiAudioPart, AiImagePart, AiSession, AiSlashCommand};
    use serde_json::json;
    use std::{collections::HashMap, sync::Arc};
    use tokio::sync::Mutex;

    #[test]
    fn map_update_to_output_should_follow_acp_mapping_contract() {
        assert_eq!(
            AcpAgent::map_update_to_output("agent_thought_chunk"),
            Some(("reasoning", true))
        );
        assert_eq!(
            AcpAgent::map_update_to_output("agent_message_chunk"),
            Some(("text", true))
        );
        assert_eq!(
            AcpAgent::map_update_to_output("user_message_chunk"),
            Some(("text", false))
        );
        assert_eq!(AcpAgent::map_update_to_output("unknown"), None);
    }

    #[test]
    fn terminal_update_detection_should_cover_common_variants() {
        assert!(AcpAgent::is_terminal_update("turn_complete", ""));
        assert!(AcpAgent::is_terminal_update("session_idle", ""));
        assert!(AcpAgent::is_terminal_update("foo_completed", ""));
        assert!(AcpAgent::is_terminal_update("", "done"));
        assert!(!AcpAgent::is_terminal_update("agent_message_chunk", ""));
    }

    #[test]
    fn extract_available_commands_should_parse_common_shapes_and_input_hint() {
        let update = json!({
            "availableCommands": [
                {
                    "name": "/build",
                    "description": "构建项目",
                    "input": { "hint": "--release" }
                }
            ],
            "available_commands": [
                {
                    "name": "test",
                    "description": "运行测试",
                    "input_hint": "--unit"
                }
            ],
            "content": {
                "commands": {
                    "deploy": {
                        "description": "发布",
                        "input": { "hint": "--prod" }
                    },
                    "/lint": {
                        "description": "静态检查",
                        "inputHint": "--fix"
                    }
                }
            }
        });

        let commands = AcpAgent::extract_available_commands(&update);
        assert_eq!(commands.len(), 4);

        let find = |name: &str| commands.iter().find(|command| command.name == name);
        assert_eq!(
            find("build").and_then(|command| command.input_hint.as_deref()),
            Some("--release")
        );
        assert_eq!(
            find("test").and_then(|command| command.input_hint.as_deref()),
            Some("--unit")
        );
        assert_eq!(
            find("deploy").and_then(|command| command.input_hint.as_deref()),
            Some("--prod")
        );
        assert_eq!(
            find("lint").and_then(|command| command.input_hint.as_deref()),
            Some("--fix")
        );
    }

    #[test]
    fn extract_available_commands_should_dedup_case_insensitive_with_latest_overwrite() {
        let update = json!({
            "availableCommands": [
                { "name": "Build", "description": "旧描述" },
                { "name": "build", "description": "新描述", "input_hint": "--release" }
            ],
            "content": {
                "available_commands": [
                    { "name": "BUILD", "description": "最终描述", "input": { "hint": "--fast" } }
                ]
            }
        });

        let commands = AcpAgent::extract_available_commands(&update);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].name, "BUILD");
        assert_eq!(commands[0].description, "最终描述");
        assert_eq!(commands[0].input_hint.as_deref(), Some("--fast"));
    }

    #[tokio::test]
    async fn slash_commands_for_should_prefer_session_cache_then_fallback_directory() {
        let manager = Arc::new(CodexAppServerManager::new(std::env::temp_dir()));
        let agent = AcpAgent::new(manager, AcpBackendProfile::copilot());
        let directory = "/tmp/tidyflow";

        AcpAgent::cache_available_commands(
            &agent.slash_commands_by_directory,
            &agent.slash_commands_by_session,
            directory,
            None,
            vec![AiSlashCommand {
                name: "build".to_string(),
                description: "目录命令".to_string(),
                action: "agent".to_string(),
                input_hint: Some("--release".to_string()),
            }],
        )
        .await;

        let fallback = agent.slash_commands_for(directory, Some("session-A")).await;
        assert_eq!(fallback.len(), 1);
        assert_eq!(fallback[0].name, "build");

        AcpAgent::cache_available_commands(
            &agent.slash_commands_by_directory,
            &agent.slash_commands_by_session,
            directory,
            Some("session-A"),
            vec![AiSlashCommand {
                name: "test".to_string(),
                description: "会话命令".to_string(),
                action: "agent".to_string(),
                input_hint: Some("--unit".to_string()),
            }],
        )
        .await;

        let from_session = agent.slash_commands_for(directory, Some("session-A")).await;
        assert_eq!(from_session.len(), 1);
        assert_eq!(from_session[0].name, "test");
        assert_eq!(from_session[0].input_hint.as_deref(), Some("--unit"));

        let fallback_other_session = agent.slash_commands_for(directory, Some("session-B")).await;
        assert_eq!(fallback_other_session.len(), 1);
        assert_eq!(fallback_other_session[0].name, "test");
    }

    #[test]
    fn extract_plan_entries_should_parse_top_level_entries() {
        let update = json!({
            "sessionUpdate": "plan",
            "entries": [
                { "content": "实现解析器", "status": "in_progress", "priority": "high" },
                { "content": "补测试", "status": "pending" }
            ]
        });
        let entries = AcpAgent::extract_plan_entries(&update).expect("entries should parse");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].content, "实现解析器");
        assert_eq!(entries[0].status, "in_progress");
        assert_eq!(entries[0].priority.as_deref(), Some("high"));
        assert_eq!(entries[1].content, "补测试");
        assert_eq!(entries[1].status, "pending");
        assert_eq!(entries[1].priority, None);
    }

    #[test]
    fn extract_plan_entries_should_parse_content_entries() {
        let update = json!({
            "sessionUpdate": "plan",
            "content": {
                "entries": [
                    { "content": "A", "status": "completed" }
                ]
            }
        });
        let entries = AcpAgent::extract_plan_entries(&update).expect("entries should parse");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].content, "A");
        assert_eq!(entries[0].status, "completed");
    }

    #[test]
    fn extract_plan_entries_should_allow_empty_entries() {
        let update = json!({
            "sessionUpdate": "plan",
            "entries": []
        });
        let entries = AcpAgent::extract_plan_entries(&update).expect("entries should parse");
        assert!(entries.is_empty());
    }

    #[test]
    fn extract_plan_entries_should_skip_invalid_entries() {
        let update = json!({
            "sessionUpdate": "plan",
            "entries": [
                { "content": "有效", "status": "pending" },
                { "content": "", "status": "pending" },
                { "status": "pending" },
                { "content": "缺状态" }
            ]
        });
        let entries = AcpAgent::extract_plan_entries(&update).expect("entries should parse");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].content, "有效");
        assert_eq!(entries[0].status, "pending");
    }

    #[test]
    fn apply_plan_update_should_replace_current_and_keep_history() {
        let mut current = None;
        let mut history = Vec::new();
        let mut revision = 0;

        let first = AcpAgent::apply_plan_update(
            &mut current,
            &mut history,
            &mut revision,
            vec![AcpPlanEntry {
                content: "步骤一".to_string(),
                status: "pending".to_string(),
                priority: None,
            }],
        );
        assert_eq!(first.revision, 1);
        assert!(history.is_empty());

        let second = AcpAgent::apply_plan_update(
            &mut current,
            &mut history,
            &mut revision,
            vec![AcpPlanEntry {
                content: "步骤一".to_string(),
                status: "completed".to_string(),
                priority: Some("high".to_string()),
            }],
        );
        assert_eq!(second.revision, 2);
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].revision, 1);
        assert_eq!(current.expect("current should exist").revision, 2);
    }

    #[test]
    fn apply_plan_update_should_cap_history_size() {
        let mut current = None;
        let mut history = Vec::new();
        let mut revision = 0;

        for index in 0..25 {
            let status = if index % 2 == 0 {
                "pending".to_string()
            } else {
                "in_progress".to_string()
            };
            AcpAgent::apply_plan_update(
                &mut current,
                &mut history,
                &mut revision,
                vec![AcpPlanEntry {
                    content: format!("步骤{}", index + 1),
                    status,
                    priority: None,
                }],
            );
        }

        assert_eq!(revision, 25);
        assert_eq!(history.len(), AcpAgent::PLAN_HISTORY_LIMIT);
        assert_eq!(history.first().map(|item| item.revision), Some(5));
        assert_eq!(history.last().map(|item| item.revision), Some(24));
        assert_eq!(current.as_ref().map(|item| item.revision), Some(25));
    }

    #[test]
    fn build_plan_source_should_include_current_and_history() {
        let mut current = None;
        let mut history = Vec::new();
        let mut revision = 0;

        AcpAgent::apply_plan_update(
            &mut current,
            &mut history,
            &mut revision,
            vec![AcpPlanEntry {
                content: "实现解析器".to_string(),
                status: "pending".to_string(),
                priority: None,
            }],
        );
        let latest = AcpAgent::apply_plan_update(
            &mut current,
            &mut history,
            &mut revision,
            vec![AcpPlanEntry {
                content: "实现解析器".to_string(),
                status: "in_progress".to_string(),
                priority: Some("high".to_string()),
            }],
        );

        let source = AcpAgent::build_plan_source(&latest, &history);
        assert_eq!(source.get("vendor").and_then(|v| v.as_str()), Some("acp"));
        assert_eq!(
            source.get("item_type").and_then(|v| v.as_str()),
            Some("plan")
        );
        assert_eq!(
            source.get("protocol").and_then(|v| v.as_str()),
            Some("agent-plan")
        );
        assert_eq!(source.get("revision").and_then(|v| v.as_u64()), Some(2));
        assert_eq!(
            source
                .get("entries")
                .and_then(|v| v.as_array())
                .and_then(|items| items.first())
                .and_then(|entry| entry.get("status"))
                .and_then(|v| v.as_str()),
            Some("in_progress")
        );
        assert_eq!(
            source
                .get("history")
                .and_then(|v| v.as_array())
                .map(|items| items.len()),
            Some(1)
        );
        assert_eq!(
            source
                .get("history")
                .and_then(|v| v.as_array())
                .and_then(|items| items.first())
                .and_then(|snapshot| snapshot.get("revision"))
                .and_then(|v| v.as_u64()),
            Some(1)
        );
    }

    #[test]
    fn flush_plan_snapshot_for_history_should_emit_plan_message() {
        let mut messages = Vec::new();
        let mut index = 0;
        let mut current = Some(super::AcpPlanSnapshot {
            revision: 2,
            updated_at_ms: 200,
            entries: vec![AcpPlanEntry {
                content: "补测试".to_string(),
                status: "in_progress".to_string(),
                priority: None,
            }],
        });
        let mut history = vec![super::AcpPlanSnapshot {
            revision: 1,
            updated_at_ms: 100,
            entries: vec![AcpPlanEntry {
                content: "补测试".to_string(),
                status: "pending".to_string(),
                priority: None,
            }],
        }];

        AcpAgent::flush_plan_snapshot_for_history(
            &mut messages,
            "tidyflow",
            &mut index,
            &mut current,
            &mut history,
        );

        assert_eq!(index, 1);
        assert!(current.is_none());
        assert!(history.is_empty());
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].role, "assistant");
        assert_eq!(messages[0].parts.len(), 1);
        assert_eq!(messages[0].parts[0].part_type, "plan");
        let source = messages[0].parts[0]
            .source
            .as_ref()
            .expect("plan source should exist");
        assert_eq!(source.get("revision").and_then(|v| v.as_u64()), Some(2));
        assert_eq!(
            source
                .get("history")
                .and_then(|v| v.as_array())
                .map(|items| items.len()),
            Some(1)
        );
    }

    #[test]
    fn compose_prompt_parts_should_build_native_contents_when_supported() {
        let parts = AcpAgent::compose_prompt_parts(
            "/tmp/workspace",
            "请分析这些内容",
            Some(vec![
                "/tmp/workspace/src/main.rs:12:5".to_string(),
                "docs/spec.md".to_string(),
            ]),
            Some(vec![AiImagePart {
                filename: "diagram.png".to_string(),
                mime: "image/png".to_string(),
                data: vec![1, 2, 3, 4],
            }]),
            Some(vec![AiAudioPart {
                filename: "voice.wav".to_string(),
                mime: "audio/wav".to_string(),
                data: vec![5, 6, 7, 8],
            }]),
            AcpContentEncodingMode::New,
            true,
            true,
            false,
            true,
        );

        assert_eq!(parts[0].get("type").and_then(|v| v.as_str()), Some("text"));
        assert_eq!(
            parts[0].get("text").and_then(|v| v.as_str()),
            Some("请分析这些内容")
        );
        assert_eq!(
            parts[1].get("type").and_then(|v| v.as_str()),
            Some("resource_link")
        );
        assert_eq!(
            parts[2].get("type").and_then(|v| v.as_str()),
            Some("resource_link")
        );
        assert_eq!(parts[3].get("type").and_then(|v| v.as_str()), Some("image"));
        assert_eq!(parts[4].get("type").and_then(|v| v.as_str()), Some("audio"));

        let image_count = parts
            .iter()
            .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("image"))
            .count();
        let audio_count = parts
            .iter()
            .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("audio"))
            .count();
        let resource_count = parts
            .iter()
            .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource_link"))
            .count();
        assert_eq!(image_count, 1);
        assert_eq!(audio_count, 1);
        assert_eq!(resource_count, 2);
    }

    #[test]
    fn compose_prompt_parts_should_fallback_to_text_when_capability_missing() {
        let parts = AcpAgent::compose_prompt_parts(
            "/tmp/workspace",
            "原始问题",
            Some(vec!["docs/spec.md".to_string()]),
            Some(vec![AiImagePart {
                filename: "diagram.png".to_string(),
                mime: "image/png".to_string(),
                data: vec![9, 9, 9],
            }]),
            Some(vec![AiAudioPart {
                filename: "voice.wav".to_string(),
                mime: "audio/wav".to_string(),
                data: vec![1, 2, 3],
            }]),
            AcpContentEncodingMode::Legacy,
            false,
            false,
            false,
            false,
        );

        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0].get("type").and_then(|v| v.as_str()), Some("text"));
        let text = parts[0].get("text").and_then(|v| v.as_str()).unwrap_or("");
        assert!(text.contains("原始问题"));
        assert!(text.contains("文件引用："));
        assert!(text.contains("图片附件："));
        assert!(text.contains("音频附件："));
    }

    #[test]
    fn compose_prompt_parts_should_encode_image_audio_by_mode() {
        let new_parts = AcpAgent::compose_prompt_parts(
            "/tmp/workspace",
            "hello",
            None,
            Some(vec![AiImagePart {
                filename: "a.png".to_string(),
                mime: "image/png".to_string(),
                data: vec![1, 2],
            }]),
            Some(vec![AiAudioPart {
                filename: "a.wav".to_string(),
                mime: "audio/wav".to_string(),
                data: vec![3, 4],
            }]),
            AcpContentEncodingMode::New,
            true,
            true,
            false,
            false,
        );
        let new_image = new_parts
            .iter()
            .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("image"))
            .expect("new image part");
        assert!(new_image.get("data").is_some());
        assert!(new_image.get("url").is_none());
        let new_audio = new_parts
            .iter()
            .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("audio"))
            .expect("new audio part");
        assert!(new_audio.get("data").is_some());
        assert!(new_audio.get("url").is_none());

        let legacy_parts = AcpAgent::compose_prompt_parts(
            "/tmp/workspace",
            "hello",
            None,
            Some(vec![AiImagePart {
                filename: "a.png".to_string(),
                mime: "image/png".to_string(),
                data: vec![1, 2],
            }]),
            Some(vec![AiAudioPart {
                filename: "a.wav".to_string(),
                mime: "audio/wav".to_string(),
                data: vec![3, 4],
            }]),
            AcpContentEncodingMode::Legacy,
            true,
            true,
            false,
            false,
        );
        let legacy_image = legacy_parts
            .iter()
            .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("image"))
            .expect("legacy image part");
        assert!(legacy_image.get("url").is_some());
        assert!(legacy_image.get("data").is_none());
        let legacy_audio = legacy_parts
            .iter()
            .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("audio"))
            .expect("legacy audio part");
        assert!(legacy_audio.get("url").is_some());
        assert!(legacy_audio.get("data").is_none());
    }

    #[test]
    fn compose_prompt_parts_should_embed_resource_text_and_blob_when_supported() {
        let temp = tempfile::tempdir().expect("temp dir");
        let text_path = temp.path().join("a.txt");
        let bin_path = temp.path().join("b.bin");
        std::fs::write(&text_path, "hello resource text").expect("write text");
        std::fs::write(&bin_path, vec![0, 159, 1, 2, 3]).expect("write bin");

        let parts = AcpAgent::compose_prompt_parts(
            temp.path().to_string_lossy().as_ref(),
            "资源测试",
            Some(vec![
                text_path.to_string_lossy().to_string(),
                bin_path.to_string_lossy().to_string(),
            ]),
            None,
            None,
            AcpContentEncodingMode::New,
            false,
            false,
            true,
            true,
        );

        let resource_parts = parts
            .iter()
            .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource"))
            .collect::<Vec<_>>();
        assert_eq!(resource_parts.len(), 2);
        assert!(resource_parts.iter().any(|part| {
            part.get("resource")
                .and_then(|v| v.get("text"))
                .and_then(|v| v.as_str())
                == Some("hello resource text")
        }));
        assert!(resource_parts.iter().any(|part| {
            part.get("resource")
                .and_then(|v| v.get("blob"))
                .and_then(|v| v.as_str())
                .is_some()
        }));
    }

    #[test]
    fn compose_prompt_parts_should_downgrade_large_text_resource_to_link() {
        let temp = tempfile::tempdir().expect("temp dir");
        let big_text_path = temp.path().join("big.txt");
        let payload = "a".repeat(AcpAgent::EMBED_TEXT_LIMIT_BYTES + 1);
        std::fs::write(&big_text_path, payload).expect("write big text");

        let parts = AcpAgent::compose_prompt_parts(
            temp.path().to_string_lossy().as_ref(),
            "资源超限",
            Some(vec![big_text_path.to_string_lossy().to_string()]),
            None,
            None,
            AcpContentEncodingMode::New,
            false,
            false,
            true,
            true,
        );

        assert!(parts
            .iter()
            .any(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource_link")));
        assert!(!parts
            .iter()
            .any(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource")));
    }

    #[test]
    fn map_content_to_non_text_parts_should_parse_supported_blocks() {
        let image = json!({
            "type": "image",
            "mimeType": "image/png",
            "data": "AQID",
            "annotations": { "origin": "stream" }
        });
        let image_parts =
            AcpAgent::map_content_to_non_text_parts("m1", image.as_object().expect("object"));
        assert_eq!(image_parts.len(), 1);
        assert_eq!(image_parts[0].part_type, "file");
        assert_eq!(image_parts[0].mime.as_deref(), Some("image/png"));
        assert!(image_parts[0]
            .url
            .as_deref()
            .is_some_and(|url| url.starts_with("data:image/png;base64,AQID")));

        let audio = json!({
            "type": "audio",
            "mime": "audio/wav",
            "url": "https://example.com/a.wav"
        });
        let audio_parts =
            AcpAgent::map_content_to_non_text_parts("m2", audio.as_object().expect("object"));
        assert_eq!(audio_parts.len(), 1);
        assert_eq!(audio_parts[0].part_type, "file");
        assert_eq!(
            audio_parts[0].url.as_deref(),
            Some("https://example.com/a.wav")
        );

        let resource_text = json!({
            "type": "resource",
            "resource": {
                "text": "embedded text"
            }
        });
        let resource_text_parts = AcpAgent::map_content_to_non_text_parts(
            "m3",
            resource_text.as_object().expect("object"),
        );
        assert_eq!(resource_text_parts.len(), 1);
        assert_eq!(resource_text_parts[0].part_type, "text");
        assert_eq!(
            resource_text_parts[0].text.as_deref(),
            Some("embedded text")
        );

        let resource_blob = json!({
            "type": "resource",
            "resource": {
                "mimeType": "application/octet-stream",
                "blob": "AAEC"
            }
        });
        let resource_blob_parts = AcpAgent::map_content_to_non_text_parts(
            "m4",
            resource_blob.as_object().expect("object"),
        );
        assert_eq!(resource_blob_parts.len(), 1);
        assert_eq!(resource_blob_parts[0].part_type, "file");
        assert!(resource_blob_parts[0]
            .url
            .as_deref()
            .is_some_and(|url| url.starts_with("data:application/octet-stream;base64,AAEC")));

        let resource_link_new = json!({
            "type": "resource_link",
            "uri": "file:///tmp/a.txt",
            "name": "a.txt"
        });
        let resource_link_new_parts = AcpAgent::map_content_to_non_text_parts(
            "m5",
            resource_link_new.as_object().expect("object"),
        );
        assert_eq!(resource_link_new_parts.len(), 1);
        assert_eq!(
            resource_link_new_parts[0].url.as_deref(),
            Some("file:///tmp/a.txt")
        );

        let resource_link_legacy = json!({
            "type": "resource_link",
            "resource": {
                "uri": "file:///tmp/b.txt",
                "name": "b.txt"
            }
        });
        let resource_link_legacy_parts = AcpAgent::map_content_to_non_text_parts(
            "m6",
            resource_link_legacy.as_object().expect("object"),
        );
        assert_eq!(resource_link_legacy_parts.len(), 1);
        assert_eq!(
            resource_link_legacy_parts[0].url.as_deref(),
            Some("file:///tmp/b.txt")
        );

        let markdown = json!({
            "type": "markdown",
            "markdown": "## 标题"
        });
        let markdown_parts =
            AcpAgent::map_content_to_non_text_parts("m7", markdown.as_object().expect("object"));
        assert_eq!(markdown_parts.len(), 1);
        assert_eq!(markdown_parts[0].part_type, "text");
        assert_eq!(markdown_parts[0].text.as_deref(), Some("## 标题"));

        let diff = json!({
            "type": "diff",
            "diff": "@@ -1 +1 @@\n-old\n+new"
        });
        let diff_parts =
            AcpAgent::map_content_to_non_text_parts("m8", diff.as_object().expect("object"));
        assert_eq!(diff_parts.len(), 1);
        assert_eq!(diff_parts[0].part_type, "text");
        assert!(diff_parts[0]
            .text
            .as_deref()
            .is_some_and(|text| text.contains("+new")));

        let terminal = json!({
            "type": "terminal",
            "output": "npm test"
        });
        let terminal_parts =
            AcpAgent::map_content_to_non_text_parts("m9", terminal.as_object().expect("object"));
        assert_eq!(terminal_parts.len(), 1);
        assert_eq!(terminal_parts[0].part_type, "text");
        assert_eq!(terminal_parts[0].text.as_deref(), Some("npm test"));
    }

    #[test]
    fn parse_tool_call_update_content_should_extract_full_tool_fields() {
        let content = json!({
            "type": "tool_call_update",
            "toolCallId": "call-1",
            "toolName": "bash",
            "kind": "terminal",
            "title": "执行测试",
            "status": "in_progress",
            "rawInput": {
                "command": "npm test"
            },
            "rawOutput": {
                "type": "terminal",
                "output": "running..."
            },
            "locations": [
                {
                    "path": "src/main.ts",
                    "line": 10,
                    "column": 2,
                    "endLine": 10,
                    "endColumn": 20,
                    "label": "diagnostic"
                }
            ],
            "progress": "30%",
            "output": "running..."
        });
        let parsed = AcpAgent::parse_tool_call_update_content(content.as_object().expect("object"))
            .expect("should parse tool_call_update");
        assert_eq!(parsed.tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(parsed.tool_name, "bash");
        assert_eq!(parsed.tool_kind.as_deref(), Some("terminal"));
        assert_eq!(parsed.tool_title.as_deref(), Some("执行测试"));
        assert_eq!(parsed.status.as_deref(), Some("running"));
        assert!(parsed.raw_input.is_some());
        assert!(parsed.raw_output.is_some());
        assert_eq!(
            parsed
                .locations
                .as_ref()
                .and_then(|rows| rows.first())
                .and_then(|row| row.path.as_deref()),
            Some("src/main.ts")
        );
        assert_eq!(parsed.progress_delta.as_deref(), Some("30%"));
        assert_eq!(parsed.output_delta.as_deref(), Some("running..."));
    }

    #[test]
    fn parse_tool_call_update_content_should_preserve_unknown_fields_in_metadata() {
        let content = json!({
            "type": "tool_call_update",
            "toolCallId": "call-meta",
            "toolName": "task",
            "status": "running",
            "customPayload": {
                "foo": "bar",
                "nested": [1, 2, 3]
            }
        });
        let parsed = AcpAgent::parse_tool_call_update_content(content.as_object().expect("object"))
            .expect("should parse");
        assert_eq!(
            parsed
                .tool_part_metadata
                .get("customPayload")
                .and_then(|v| v.get("foo"))
                .and_then(|v| v.as_str()),
            Some("bar")
        );
    }

    #[test]
    fn merge_tool_state_should_handle_incremental_and_out_of_order_updates() {
        let completed = super::ParsedToolCallUpdate {
            tool_call_id: Some("call-merge".to_string()),
            tool_name: "terminal".to_string(),
            tool_kind: Some("terminal".to_string()),
            tool_title: Some("执行".to_string()),
            status: Some("completed".to_string()),
            raw_input: Some(json!({"command": "npm test"})),
            raw_output: Some(json!({"type": "terminal", "output": "done"})),
            locations: None,
            progress_delta: Some("100%".to_string()),
            output_delta: Some("done".to_string()),
            tool_part_metadata: json!({ "type": "tool_call_update" }),
        };
        let late_running = super::ParsedToolCallUpdate {
            tool_call_id: Some("call-merge".to_string()),
            tool_name: "terminal".to_string(),
            tool_kind: Some("terminal".to_string()),
            tool_title: None,
            status: Some("running".to_string()),
            raw_input: None,
            raw_output: Some(json!({"type": "terminal", "output": "late"})),
            locations: None,
            progress_delta: Some("50%".to_string()),
            output_delta: Some("late".to_string()),
            tool_part_metadata: json!({ "type": "tool_call_update" }),
        };

        let merged_first = AcpAgent::merge_tool_state(None, &completed);
        assert_eq!(
            merged_first.get("status").and_then(|v| v.as_str()),
            Some("completed")
        );
        assert_eq!(
            merged_first.get("output").and_then(|v| v.as_str()),
            Some("done")
        );

        let merged_second = AcpAgent::merge_tool_state(Some(&merged_first), &late_running);
        assert_eq!(
            merged_second.get("status").and_then(|v| v.as_str()),
            Some("completed")
        );
        assert_eq!(
            merged_second.get("output").and_then(|v| v.as_str()),
            Some("donelate")
        );
        let progress_len = merged_second
            .get("metadata")
            .and_then(|v| v.get("progress_lines"))
            .and_then(|v| v.as_array())
            .map(|rows| rows.len());
        assert_eq!(progress_len, Some(2));
    }

    #[test]
    fn normalize_tool_status_should_cover_acp_variants() {
        assert_eq!(
            AcpAgent::normalize_tool_status(Some("in_progress"), "running"),
            "running"
        );
        assert_eq!(
            AcpAgent::normalize_tool_status(Some("requires_input"), "running"),
            "awaiting_input"
        );
        assert_eq!(
            AcpAgent::normalize_tool_status(Some("done"), "running"),
            "completed"
        );
        assert_eq!(
            AcpAgent::normalize_tool_status(Some("failed"), "running"),
            "error"
        );
    }

    #[test]
    fn parse_prompt_stop_reason_should_validate_contract() {
        assert_eq!(
            AcpAgent::parse_prompt_stop_reason(&json!({ "stopReason": "end_turn" }))
                .expect("end_turn should be accepted"),
            "end_turn"
        );
        assert!(AcpAgent::parse_prompt_stop_reason(&json!({})).is_err());
        assert!(
            AcpAgent::parse_prompt_stop_reason(&json!({ "stopReason": "custom_reason" })).is_err()
        );
    }

    #[test]
    fn select_sessions_for_directory_should_fallback_to_unknown_cwd_when_needed() {
        let page = vec![
            AcpSessionSummary {
                id: "a".to_string(),
                title: "A".to_string(),
                cwd: "".to_string(),
                updated_at_ms: 1,
            },
            AcpSessionSummary {
                id: "b".to_string(),
                title: "B".to_string(),
                cwd: "".to_string(),
                updated_at_ms: 2,
            },
        ];

        let (selected, used_fallback) =
            AcpAgent::select_sessions_for_directory(page, "/tmp/workspace");
        assert!(used_fallback);
        assert_eq!(selected.len(), 2);
    }

    #[test]
    fn select_sessions_for_directory_should_prefer_exact_matches() {
        let page = vec![
            AcpSessionSummary {
                id: "a".to_string(),
                title: "A".to_string(),
                cwd: "/tmp/workspace".to_string(),
                updated_at_ms: 1,
            },
            AcpSessionSummary {
                id: "b".to_string(),
                title: "B".to_string(),
                cwd: "".to_string(),
                updated_at_ms: 2,
            },
            AcpSessionSummary {
                id: "c".to_string(),
                title: "C".to_string(),
                cwd: "/tmp/other".to_string(),
                updated_at_ms: 3,
            },
        ];

        let (selected, used_fallback) =
            AcpAgent::select_sessions_for_directory(page, "/tmp/workspace");
        assert!(!used_fallback);
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].id, "a");
    }

    #[test]
    fn normalize_directory_should_handle_file_urls() {
        assert_eq!(
            AcpAgent::normalize_directory("file:///tmp/workspace"),
            "/tmp/workspace"
        );
    }

    #[test]
    fn backend_profile_should_expose_expected_provider_ids() {
        let copilot = AcpBackendProfile::copilot();
        assert_eq!(copilot.provider_id, "copilot");
        assert_eq!(copilot.provider_name, "Copilot");

        let kimi = AcpBackendProfile::kimi();
        assert_eq!(kimi.provider_id, "kimi");
        assert_eq!(kimi.provider_name, "Kimi");
    }

    #[test]
    fn merge_sessions_should_include_cached_sessions_when_remote_empty() {
        let cached = vec![AiSession {
            id: "cached-1".to_string(),
            title: "Cached".to_string(),
            updated_at: 42,
        }];
        let merged = AcpAgent::merge_sessions(Vec::new(), cached);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].id, "cached-1");
    }

    #[test]
    fn merge_sessions_should_merge_same_id_and_keep_newest_timestamp() {
        let remote = vec![AiSession {
            id: "same".to_string(),
            title: "Remote".to_string(),
            updated_at: 100,
        }];
        let cached = vec![AiSession {
            id: "same".to_string(),
            title: "Cached".to_string(),
            updated_at: 200,
        }];
        let merged = AcpAgent::merge_sessions(remote, cached);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].id, "same");
        assert_eq!(merged[0].updated_at, 200);
    }

    #[test]
    fn build_cached_assistant_message_should_capture_reasoning_and_text() {
        let message = AcpAgent::build_cached_assistant_message(
            "assistant-1".to_string(),
            "思考".to_string(),
            "回答".to_string(),
            None,
            Vec::new(),
        )
        .expect("assistant message should exist");
        assert_eq!(message.role, "assistant");
        assert_eq!(message.parts.len(), 2);
        assert_eq!(message.parts[0].part_type, "reasoning");
        assert_eq!(message.parts[1].part_type, "text");
    }

    #[test]
    fn build_cached_assistant_message_should_capture_plan_part() {
        let message = AcpAgent::build_cached_assistant_message(
            "assistant-2".to_string(),
            String::new(),
            String::new(),
            Some(super::AcpPlanSnapshot {
                revision: 2,
                updated_at_ms: 123,
                entries: vec![AcpPlanEntry {
                    content: "实现计划卡".to_string(),
                    status: "in_progress".to_string(),
                    priority: Some("high".to_string()),
                }],
            }),
            vec![super::AcpPlanSnapshot {
                revision: 1,
                updated_at_ms: 122,
                entries: vec![AcpPlanEntry {
                    content: "实现计划卡".to_string(),
                    status: "pending".to_string(),
                    priority: None,
                }],
            }],
        )
        .expect("assistant message should exist");
        assert_eq!(message.role, "assistant");
        assert_eq!(message.parts.len(), 1);
        assert_eq!(message.parts[0].part_type, "plan");
        let source = message.parts[0]
            .source
            .as_ref()
            .expect("plan source should exist");
        assert_eq!(
            source.get("protocol").and_then(|v| v.as_str()),
            Some("agent-plan")
        );
        assert_eq!(source.get("revision").and_then(|v| v.as_u64()), Some(2));
        assert_eq!(
            source
                .get("history")
                .and_then(|v| v.as_array())
                .map(|items| items.len()),
            Some(1)
        );
    }

    #[test]
    fn resolve_permission_option_id_should_prefer_option_id_and_name_fallback() {
        let pending = super::PendingPermission {
            request_id: json!(1),
            session_id: "s1".to_string(),
            options: vec![
                super::PermissionOption {
                    option_id: "code".to_string(),
                    normalized_name: "开始实现".to_string(),
                },
                super::PermissionOption {
                    option_id: "allow-once".to_string(),
                    normalized_name: "手动确认".to_string(),
                },
            ],
        };

        let by_id = AcpAgent::resolve_permission_option_id(&pending, &[vec!["code".to_string()]]);
        assert_eq!(by_id.as_deref(), Some("code"));

        let by_name =
            AcpAgent::resolve_permission_option_id(&pending, &[vec!["开始实现".to_string()]]);
        assert_eq!(by_name.as_deref(), Some("code"));
    }

    #[test]
    fn resolve_permission_option_id_should_fallback_to_allow_once_then_first() {
        let pending_with_allow_once = super::PendingPermission {
            request_id: json!(1),
            session_id: "s1".to_string(),
            options: vec![
                super::PermissionOption {
                    option_id: "reject".to_string(),
                    normalized_name: "拒绝".to_string(),
                },
                super::PermissionOption {
                    option_id: "allow-once".to_string(),
                    normalized_name: "一次允许".to_string(),
                },
            ],
        };
        let resolved = AcpAgent::resolve_permission_option_id(&pending_with_allow_once, &[]);
        assert_eq!(resolved.as_deref(), Some("allow-once"));

        let pending_without_allow_once = super::PendingPermission {
            request_id: json!(1),
            session_id: "s1".to_string(),
            options: vec![
                super::PermissionOption {
                    option_id: "reject".to_string(),
                    normalized_name: "拒绝".to_string(),
                },
                super::PermissionOption {
                    option_id: "code".to_string(),
                    normalized_name: "开始实现".to_string(),
                },
            ],
        };
        let fallback_first =
            AcpAgent::resolve_permission_option_id(&pending_without_allow_once, &[]);
        assert_eq!(fallback_first.as_deref(), Some("reject"));
    }

    #[test]
    fn apply_current_mode_to_metadata_should_add_unknown_mode() {
        let mut metadata = crate::ai::acp_client::AcpSessionMetadata::default();
        AcpAgent::apply_current_mode_to_metadata(&mut metadata, "code");
        assert_eq!(metadata.current_mode_id.as_deref(), Some("code"));
        assert_eq!(metadata.modes.len(), 1);
        assert_eq!(metadata.modes[0].id, "code");
        assert_eq!(metadata.modes[0].name, "code");
    }

    #[test]
    fn extract_current_mode_id_should_support_common_payload_shapes() {
        let top_level = json!({
            "currentModeId": "code"
        });
        assert_eq!(
            AcpAgent::extract_current_mode_id(&top_level).as_deref(),
            Some("code")
        );

        let mode_id = json!({
            "modeId": "plan"
        });
        assert_eq!(
            AcpAgent::extract_current_mode_id(&mode_id).as_deref(),
            Some("plan")
        );

        let nested_mode = json!({
            "content": {
                "mode": {
                    "id": "agent"
                }
            }
        });
        assert_eq!(
            AcpAgent::extract_current_mode_id(&nested_mode).as_deref(),
            Some("agent")
        );
    }

    #[tokio::test]
    async fn apply_current_mode_to_caches_should_update_directory_and_session() {
        let metadata_by_directory = Arc::new(Mutex::new(HashMap::new()));
        let metadata_by_session = Arc::new(Mutex::new(HashMap::new()));
        AcpAgent::apply_current_mode_to_caches(
            &metadata_by_directory,
            &metadata_by_session,
            "/tmp/workspace",
            "session-1",
            "code",
        )
        .await;

        let dir_meta = metadata_by_directory
            .lock()
            .await
            .get("/tmp/workspace")
            .cloned()
            .expect("directory metadata should exist");
        assert_eq!(dir_meta.current_mode_id.as_deref(), Some("code"));

        let session_meta = metadata_by_session
            .lock()
            .await
            .get("/tmp/workspace::session-1")
            .cloned()
            .expect("session metadata should exist");
        assert_eq!(session_meta.current_mode_id.as_deref(), Some("code"));
    }
}
