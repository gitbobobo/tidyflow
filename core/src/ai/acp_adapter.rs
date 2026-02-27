use super::acp_client::{AcpClient, AcpSessionMetadata, AcpSessionSummary};
use super::codex_manager::CodexAppServerManager;
use super::context_usage::{extract_context_remaining_percent, AiSessionContextUsage};
use super::{
    AiAgent, AiAgentInfo, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiQuestionInfo, AiQuestionOption, AiQuestionRequest,
    AiSession, AiSessionSelectionHint, AiSlashCommand,
};
use async_trait::async_trait;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::debug;
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
struct PendingPermission {
    request_id: Value,
}

pub struct AcpAgent {
    client: AcpClient,
    profile: AcpBackendProfile,
    metadata_by_directory: Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
    metadata_by_session: Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
    pending_permissions: Arc<Mutex<HashMap<String, PendingPermission>>>,
}

impl AcpAgent {
    pub fn new(manager: Arc<CodexAppServerManager>, profile: AcpBackendProfile) -> Self {
        Self {
            client: AcpClient::new(manager),
            profile,
            metadata_by_directory: Arc::new(Mutex::new(HashMap::new())),
            metadata_by_session: Arc::new(Mutex::new(HashMap::new())),
            pending_permissions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn new_copilot(manager: Arc<CodexAppServerManager>) -> Self {
        Self::new(manager, AcpBackendProfile::copilot())
    }

    pub fn new_kimi(manager: Arc<CodexAppServerManager>) -> Self {
        Self::new(manager, AcpBackendProfile::kimi())
    }

    fn normalize_directory(directory: &str) -> String {
        directory.trim_end_matches('/').to_string()
    }

    fn session_cache_key(directory: &str, session_id: &str) -> String {
        format!("{}::{}", Self::normalize_directory(directory), session_id)
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
            for item in page {
                if Self::normalize_directory(&item.cwd) == expected {
                    sessions.push(item);
                }
            }
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

    fn compose_message(
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
    ) -> String {
        let mut chunks = vec![message.to_string()];
        if let Some(files) = file_refs {
            if !files.is_empty() {
                chunks.push(format!("文件引用：\n{}", files.join("\n")));
            }
        }
        if let Some(images) = image_parts {
            if !images.is_empty() {
                let names = images
                    .iter()
                    .map(|img| format!("{} ({})", img.filename, img.mime))
                    .collect::<Vec<_>>()
                    .join("\n");
                chunks.push(format!("图片附件：\n{}", names));
            }
        }
        chunks.join("\n\n")
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

    fn build_question_from_permission_request(
        request_id: &Value,
        params: &Value,
    ) -> Option<AiQuestionRequest> {
        let session_id = params.get("sessionId")?.as_str()?.to_string();
        let tool_call = params.get("toolCall")?;
        let tool_call_id = tool_call
            .get("toolCallId")
            .and_then(|v| v.as_str())
            .map(String::from);
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
                                    Some(AiQuestionOption {
                                        label: opt.get("label")?.as_str()?.to_string(),
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
                                Some(AiQuestionOption {
                                    label: opt.get("name")?.as_str()?.to_string(),
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

        Some(AiQuestionRequest {
            id: Self::request_id_key(request_id),
            session_id,
            questions,
            tool_message_id: tool_call_id.clone(),
            tool_call_id,
        })
    }

    fn extract_update(event: &Value) -> Option<(String, String, String)> {
        let session_update = event
            .get("sessionUpdate")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let content = event.get("content")?;
        let content_type = content
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let text = content
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // text 为空时仍返回 Some，由调用方按需过滤
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
        let mut notifications = self.client.subscribe_notifications();
        let load_fut = self.client.session_load(directory, session_id);
        tokio::pin!(load_fut);
        let mut messages = Vec::<AiMessage>::new();

        loop {
            tokio::select! {
                load_result = &mut load_fut => {
                    match load_result {
                        Ok(metadata) => return Ok((messages, metadata)),
                        Err(err) if Self::is_session_already_loaded(&err) => {
                            let cached = self
                                .metadata_by_directory
                                .lock()
                                .await
                                .get(&Self::normalize_directory(directory))
                                .cloned()
                                .unwrap_or_default();
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
                    let Some((session_update, _content_type, text)) = Self::extract_update(update) else { continue };
                    let Some((part_type, should_emit)) =
                        Self::map_update_to_output(&session_update)
                    else {
                        debug!(
                            "{}: unknown sessionUpdate type in history: {}",
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
        Ok(AiSession {
            id: session_id,
            title: title.to_string(),
            updated_at: chrono::Utc::now().timestamp_millis(),
        })
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

        let metadata = self.metadata_for_directory(directory).await;
        let mode_id = Self::resolve_mode_id(&metadata, agent.as_deref());
        let model_id = model.map(|m| m.model_id);
        let composed = Self::compose_message(message, file_refs, image_parts);
        let prompt = vec![serde_json::json!({
            "type": "text",
            "text": composed
        })];

        let (tx, rx) = mpsc::unbounded_channel::<Result<AiEvent, String>>();
        let mut notifications = self.client.subscribe_notifications();
        let mut requests = self.client.subscribe_requests();
        let client = self.client.clone();
        let tool_id = self.profile.tool_id.clone();
        let message_id_prefix = self.profile.message_id_prefix.clone();
        let directory = directory.to_string();
        let session_id = session_id.to_string();
        let original_text = message.to_string();
        let assistant_message_id =
            format!("{}-assistant-{}", message_id_prefix, uuid::Uuid::new_v4());
        let user_message_id = format!("{}-user-{}", message_id_prefix, uuid::Uuid::new_v4());
        let pending_permissions = self.pending_permissions.clone();

        let _ = tx.send(Ok(AiEvent::MessageUpdated {
            message_id: user_message_id.clone(),
            role: "user".to_string(),
            selection_hint: None,
        }));
        let _ = tx.send(Ok(AiEvent::PartUpdated {
            message_id: user_message_id.clone(),
            part: AiPart::new_text(format!("{}-text", user_message_id), original_text),
        }));

        tokio::spawn(async move {
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
                        client.session_load(&directory, &session_id).await?;
                        client
                            .session_prompt(&session_id, prompt, model_id, mode_id)
                            .await
                    }
                    Err(err) => Err(err),
                }
            };
            tokio::pin!(request_fut);

            let mut assistant_opened = false;
            loop {
                tokio::select! {
                    request_result = &mut request_fut => {
                        match request_result {
                            Ok(_) => {
                                let _ = tx.send(Ok(AiEvent::Done));
                            }
                            Err(err) => {
                                let _ = tx.send(Err(err));
                            }
                        }
                        break;
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
                        let Some((session_update, _content_type, text)) = Self::extract_update(update) else { continue };

                        let Some((part_type, should_emit)) = Self::map_update_to_output(&session_update) else {
                            debug!(
                                "{}: unknown sessionUpdate type in stream: {}",
                                tool_id, session_update
                            );
                            continue;
                        };
                        if !should_emit || text.is_empty() {
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
                        if let Some(question_request) = Self::build_question_from_permission_request(&req.id, &params) {
                            let request_key = question_request.id.clone();
                            pending_permissions.lock().await.insert(request_key.clone(), PendingPermission {
                                request_id: req.id.clone(),
                            });
                            let _ = tx.send(Ok(AiEvent::QuestionAsked { request: question_request }));
                        }
                    }
                }
            }
        });

        Ok(Box::pin(UnboundedReceiverStream::new(rx)))
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        let sessions = self.list_sessions_for_directory(directory, 8).await?;
        Ok(sessions
            .into_iter()
            .map(|s| AiSession {
                id: s.id,
                title: s.title,
                updated_at: s.updated_at_ms,
            })
            .collect())
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
        let (mut messages, metadata) = self.collect_loaded_messages(directory, session_id).await?;
        self.cache_metadata(directory, metadata.clone()).await;
        self.cache_session_metadata(directory, session_id, metadata)
            .await;

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
            if let Ok(refreshed) = self.client.session_load(directory, session_id).await {
                self.cache_metadata(directory, refreshed.clone()).await;
                self.cache_session_metadata(directory, session_id, refreshed.clone())
                    .await;
                metadata = refreshed;
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
        self.client.session_cancel(_session_id).await
    }

    async fn dispose_instance(&self, _directory: &str) -> Result<(), String> {
        Ok(())
    }

    async fn get_session_context_usage(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionContextUsage>, String> {
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
        _answers: Vec<Vec<String>>,
    ) -> Result<(), String> {
        let pending = self
            .pending_permissions
            .lock()
            .await
            .remove(request_id)
            .ok_or_else(|| format!("Unknown permission request: {}", request_id))?;

        self.client
            .respond_to_permission_request(pending.request_id, "allow-once")
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
    use super::{AcpAgent, AcpBackendProfile};

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
    fn backend_profile_should_expose_expected_provider_ids() {
        let copilot = AcpBackendProfile::copilot();
        assert_eq!(copilot.provider_id, "copilot");
        assert_eq!(copilot.provider_name, "Copilot");

        let kimi = AcpBackendProfile::kimi();
        assert_eq!(kimi.provider_id, "kimi");
        assert_eq!(kimi.provider_name, "Kimi");
    }
}
