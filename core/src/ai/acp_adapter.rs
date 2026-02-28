use super::acp_client::{AcpClient, AcpSessionMetadata, AcpSessionSummary};
use super::codex_manager::CodexAppServerManager;
use super::context_usage::{extract_context_remaining_percent, AiSessionContextUsage};
use super::{
    AiAgent, AiAgentInfo, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiQuestionInfo, AiQuestionOption, AiQuestionRequest,
    AiSession, AiSessionSelectionHint, AiSlashCommand,
};
use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chrono::Utc;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
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

pub struct AcpAgent {
    client: AcpClient,
    profile: AcpBackendProfile,
    metadata_by_directory: Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
    metadata_by_session: Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
    pending_permissions: Arc<Mutex<HashMap<String, PendingPermission>>>,
    cached_sessions: Arc<Mutex<HashMap<String, HashMap<String, CachedSessionRecord>>>>,
    runtime_yolo_sessions: Arc<Mutex<HashSet<String>>>,
}

impl AcpAgent {
    const SESSION_LOAD_TIMEOUT_SECS: u64 = 4;
    const PLAN_HISTORY_LIMIT: usize = 20;

    pub fn new(manager: Arc<CodexAppServerManager>, profile: AcpBackendProfile) -> Self {
        Self {
            client: AcpClient::new(manager),
            profile,
            metadata_by_directory: Arc::new(Mutex::new(HashMap::new())),
            metadata_by_session: Arc::new(Mutex::new(HashMap::new())),
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
            if !meta.models.is_empty() || !meta.modes.is_empty() {
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

    fn normalize_current_mode_update(raw: &str) -> bool {
        let normalized = Self::normalized_update_token(raw);
        normalized == "current_mode_update" || normalized == "currentmodeupdate"
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

    fn resolve_resource_link(directory: &str, file_ref: &str) -> Option<(String, String)> {
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
            return Some((uri, name));
        }

        let input_path = Path::new(&normalized_ref);
        let resolved = if input_path.is_absolute() {
            input_path.to_path_buf()
        } else {
            PathBuf::from(directory).join(input_path)
        };

        let uri = Url::from_file_path(&resolved).ok()?.to_string();
        let name = resolved
            .file_name()
            .map(|v| v.to_string_lossy().to_string())
            .unwrap_or_else(|| normalized_ref.clone());
        Some((uri, name))
    }

    fn compose_prompt_parts(
        directory: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        supports_image: bool,
        supports_resource_link: bool,
    ) -> Vec<Value> {
        let mut prompt_parts = Vec::<Value>::new();
        let mut fallback_blocks = Vec::<String>::new();
        let mut text_body = message.to_string();

        if let Some(files) = file_refs {
            if !files.is_empty() {
                if supports_resource_link {
                    let mut unresolved = Vec::<String>::new();
                    for file_ref in files {
                        if let Some((uri, name)) = Self::resolve_resource_link(directory, &file_ref)
                        {
                            prompt_parts
                                .push(AcpClient::build_prompt_resource_link_part(uri, name));
                        } else {
                            unresolved.push(file_ref);
                        }
                    }
                    if !unresolved.is_empty() {
                        fallback_blocks.push(format!(
                            "文件引用（无法解析为 resource_link）：\n{}",
                            unresolved.join("\n")
                        ));
                    }
                } else {
                    fallback_blocks.push(format!("文件引用：\n{}", files.join("\n")));
                }
            }
        }

        if let Some(images) = image_parts {
            if !images.is_empty() {
                if supports_image {
                    for img in images {
                        let mime = img.mime.trim().to_lowercase();
                        let mime = if mime.is_empty() {
                            "application/octet-stream".to_string()
                        } else {
                            mime
                        };
                        let data_url = format!("data:{};base64,{}", mime, BASE64.encode(&img.data));
                        prompt_parts.push(AcpClient::build_prompt_image_part(mime, data_url));
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
            return Some(found.option_id.clone());
        }

        pending.options.first().map(|option| option.option_id.clone())
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
            vec![AiQuestionInfo {
                question: title.to_string(),
                header: "Permission".to_string(),
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
            .and_then(|v| v.get("text"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // content 可能为空（如 terminal update），此时返回空 type/text 供上层判定。
        Some((session_update, content_type, text))
    }

    fn map_update_to_output(session_update: &str) -> Option<(&'static str, bool)> {
        match session_update {
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
        let mut observed_mode_id: Option<String> = None;

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
                        self.client.session_set_mode(session_id, target_mode_id).await
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
        let supports_image = self.client.supports_content_type("image").await;
        let supports_resource_link = self.client.supports_content_type("resource_link").await;
        let prompt = Self::compose_prompt_parts(
            directory,
            message,
            file_refs,
            image_parts,
            supports_image,
            supports_resource_link,
        );

        let (tx, rx) = mpsc::unbounded_channel::<Result<AiEvent, String>>();
        let mut notifications = self.client.subscribe_notifications();
        let mut requests = self.client.subscribe_requests();
        let client = self.client.clone();
        let tool_id = self.profile.tool_id.clone();
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
                            match content_type.as_str() {
                                "tool_call" => {
                                    if !assistant_opened {
                                        assistant_opened = true;
                                        let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                            message_id: assistant_message_id.clone(),
                                            role: "assistant".to_string(),
                                            selection_hint: None,
                                        }));
                                    }
                                    let tool_call_id = content
                                        .get("toolCallId")
                                        .or_else(|| content.get("tool_call_id"))
                                        .or_else(|| content.get("id"))
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let part_id = if tool_call_id.is_empty() {
                                        format!("{}-tool-{}", assistant_message_id, Uuid::new_v4())
                                    } else {
                                        tool_part_ids
                                            .entry(tool_call_id.clone())
                                            .or_insert_with(|| format!("{}-tool-{}", assistant_message_id, tool_call_id.replace(':', "_")))
                                            .clone()
                                    };
                                    let tool_name = content
                                        .get("toolName")
                                        .or_else(|| content.get("tool_name"))
                                        .or_else(|| content.get("name"))
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("unknown")
                                        .to_string();
                                    let status = content
                                        .get("status")
                                        .or_else(|| content.get("state"))
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("running")
                                        .to_string();
                                    let _ = tx.send(Ok(AiEvent::PartUpdated {
                                        message_id: assistant_message_id.clone(),
                                        part: AiPart {
                                            id: part_id,
                                            part_type: "tool".to_string(),
                                            tool_name: Some(tool_name),
                                            tool_call_id: if tool_call_id.is_empty() {
                                                None
                                            } else {
                                                Some(tool_call_id)
                                            },
                                            tool_state: Some(serde_json::json!({ "status": status })),
                                            tool_part_metadata: Some(Value::Object(content.clone())),
                                            ..Default::default()
                                        },
                                    }));
                                    continue;
                                }
                                "tool_call_update" => {
                                    if !assistant_opened {
                                        assistant_opened = true;
                                        let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                            message_id: assistant_message_id.clone(),
                                            role: "assistant".to_string(),
                                            selection_hint: None,
                                        }));
                                    }
                                    let tool_call_id = content
                                        .get("toolCallId")
                                        .or_else(|| content.get("tool_call_id"))
                                        .or_else(|| content.get("id"))
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let part_id = if tool_call_id.is_empty() {
                                        format!("{}-tool-{}", assistant_message_id, Uuid::new_v4())
                                    } else {
                                        tool_part_ids
                                            .entry(tool_call_id.clone())
                                            .or_insert_with(|| format!("{}-tool-{}", assistant_message_id, tool_call_id.replace(':', "_")))
                                            .clone()
                                    };
                                    if let Some(status) = content
                                        .get("status")
                                        .or_else(|| content.get("state"))
                                        .and_then(|v| v.as_str())
                                    {
                                        let _ = tx.send(Ok(AiEvent::PartUpdated {
                                            message_id: assistant_message_id.clone(),
                                            part: AiPart {
                                                id: part_id.clone(),
                                                part_type: "tool".to_string(),
                                                tool_name: content
                                                    .get("toolName")
                                                    .or_else(|| content.get("tool_name"))
                                                    .or_else(|| content.get("name"))
                                                    .and_then(|v| v.as_str())
                                                    .map(|v| v.to_string()),
                                                tool_call_id: if tool_call_id.is_empty() {
                                                    None
                                                } else {
                                                    Some(tool_call_id.clone())
                                                },
                                                tool_state: Some(serde_json::json!({ "status": status })),
                                                tool_part_metadata: Some(Value::Object(content.clone())),
                                                ..Default::default()
                                            },
                                        }));
                                    }
                                    if let Some(progress) = content
                                        .get("progress")
                                        .or_else(|| content.get("message"))
                                        .and_then(|v| v.as_str())
                                    {
                                        if !progress.is_empty() {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
                                                part_id: part_id.clone(),
                                                part_type: "tool".to_string(),
                                                field: "progress".to_string(),
                                                delta: progress.to_string(),
                                            }));
                                        }
                                    }
                                    if let Some(output) = content
                                        .get("output")
                                        .or_else(|| content.get("text"))
                                        .or_else(|| content.get("delta"))
                                        .and_then(|v| v.as_str())
                                    {
                                        if !output.is_empty() {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
                                                part_id: part_id.clone(),
                                                part_type: "tool".to_string(),
                                                field: "output".to_string(),
                                                delta: output.to_string(),
                                            }));
                                        }
                                    }
                                    continue;
                                }
                                "image" => {
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
                                            id: format!("{}-file-{}", assistant_message_id, Uuid::new_v4()),
                                            part_type: "file".to_string(),
                                            mime: content
                                                .get("mimeType")
                                                .or_else(|| content.get("mime"))
                                                .and_then(|v| v.as_str())
                                                .map(|v| v.to_string()),
                                            filename: content
                                                .get("filename")
                                                .or_else(|| content.get("name"))
                                                .and_then(|v| v.as_str())
                                                .map(|v| v.to_string()),
                                            url: content
                                                .get("url")
                                                .and_then(|v| v.as_str())
                                                .map(|v| v.to_string()),
                                            ..Default::default()
                                        },
                                    }));
                                    continue;
                                }
                                "resource_link" | "resource" => {
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
                                            id: format!("{}-file-{}", assistant_message_id, Uuid::new_v4()),
                                            part_type: "file".to_string(),
                                            filename: content
                                                .get("resource")
                                                .and_then(|v| v.get("name"))
                                                .or_else(|| content.get("name"))
                                                .and_then(|v| v.as_str())
                                                .map(|v| v.to_string()),
                                            url: content
                                                .get("resource")
                                                .and_then(|v| v.get("uri"))
                                                .or_else(|| content.get("uri"))
                                                .and_then(|v| v.as_str())
                                                .map(|v| v.to_string()),
                                            ..Default::default()
                                        },
                                    }));
                                    continue;
                                }
                                "text" | "reasoning" => {
                                    // 继续走下方的通用 chunk 增量路径
                                }
                                _ => {
                                    warn!(
                                        "{}: unknown ACP content type in stream, ignore: {}",
                                        tool_id, content_type
                                    );
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
        let hint = AiSessionSelectionHint {
            agent: Self::current_agent_name(&metadata),
            model_provider_id: metadata
                .current_model_id
                .as_ref()
                .map(|_| self.profile.provider_id.clone()),
            model_id: metadata.current_model_id.clone(),
        };
        debug!(
            "ACP session_selection_hint: directory={}, session_id={}, models_count={}, modes_count={}, current_model_id={:?}, current_mode_id={:?}, resolved_agent={:?}",
            directory,
            session_id,
            metadata.models.len(),
            metadata.modes.len(),
            metadata.current_model_id,
            metadata.current_mode_id,
            hint.agent
        );
        if hint.agent.is_none() && hint.model_id.is_none() {
            Ok(None)
        } else {
            Ok(Some(hint))
        }
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

    async fn list_slash_commands(&self, _directory: &str) -> Result<Vec<AiSlashCommand>, String> {
        Ok(vec![AiSlashCommand {
            name: "new".to_string(),
            description: "新建会话".to_string(),
            action: "client".to_string(),
        }])
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
    use crate::ai::{AiImagePart, AiSession};
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
            true,
            true,
        );

        assert_eq!(parts[0].get("type").and_then(|v| v.as_str()), Some("text"));
        assert_eq!(
            parts[0].get("text").and_then(|v| v.as_str()),
            Some("请分析这些内容")
        );

        let image_count = parts
            .iter()
            .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("image"))
            .count();
        let resource_count = parts
            .iter()
            .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource_link"))
            .count();
        assert_eq!(image_count, 1);
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
            false,
            false,
        );

        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0].get("type").and_then(|v| v.as_str()), Some("text"));
        let text = parts[0].get("text").and_then(|v| v.as_str()).unwrap_or("");
        assert!(text.contains("原始问题"));
        assert!(text.contains("文件引用："));
        assert!(text.contains("图片附件："));
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
