use super::codex_manager::CodexAppServerManager;
use super::copilot_client::{CopilotAcpClient, CopilotSessionMetadata, CopilotSessionSummary};
use super::{
    AiAgent, AiAgentInfo, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiSession, AiSlashCommand,
};
use async_trait::async_trait;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::debug;
use uuid::Uuid;

pub struct CopilotAcpAgent {
    client: CopilotAcpClient,
    metadata_by_directory: Arc<Mutex<HashMap<String, CopilotSessionMetadata>>>,
}

impl CopilotAcpAgent {
    pub fn new(manager: Arc<CodexAppServerManager>) -> Self {
        Self {
            client: CopilotAcpClient::new(manager),
            metadata_by_directory: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn normalize_directory(directory: &str) -> String {
        directory.trim_end_matches('/').to_string()
    }

    async fn cache_metadata(&self, directory: &str, metadata: CopilotSessionMetadata) {
        self.metadata_by_directory
            .lock()
            .await
            .insert(Self::normalize_directory(directory), metadata);
    }

    async fn metadata_for_directory(&self, directory: &str) -> CopilotSessionMetadata {
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

        CopilotSessionMetadata::default()
    }

    async fn list_sessions_for_directory(
        &self,
        directory: &str,
        max_pages: usize,
    ) -> Result<Vec<CopilotSessionSummary>, String> {
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
        metadata: &CopilotSessionMetadata,
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

    fn push_chunk_message(messages: &mut Vec<AiMessage>, role: &str, part_type: &str, text: &str) {
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

        let message_id = format!("copilot-history-{}", Uuid::new_v4());
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
            parts: vec![part],
        });
    }

    async fn collect_loaded_messages(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<(Vec<AiMessage>, CopilotSessionMetadata), String> {
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
                    match session_update.as_str() {
                        "user_message_chunk" => Self::push_chunk_message(&mut messages, "user", "text", &text),
                        "agent_thought_chunk" => Self::push_chunk_message(&mut messages, "assistant", "reasoning", &text),
                        "agent_message_chunk" => Self::push_chunk_message(&mut messages, "assistant", "text", &text),
                        other => {
                            debug!("Copilot: unknown sessionUpdate type in history: {}", other);
                        }
                    }
                }
            }
        }
    }
}

#[async_trait]
impl AiAgent for CopilotAcpAgent {
    async fn start(&self) -> Result<(), String> {
        self.client.ensure_started().await
    }

    async fn stop(&self) -> Result<(), String> {
        Ok(())
    }

    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String> {
        self.client.ensure_started().await?;
        let (session_id, metadata) = self.client.session_new(directory).await?;
        self.cache_metadata(directory, metadata).await;
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
        let client = self.client.clone();
        let directory = directory.to_string();
        let session_id = session_id.to_string();
        let original_text = message.to_string();
        let assistant_message_id = format!("copilot-assistant-{}", Uuid::new_v4());
        let user_message_id = format!("copilot-user-{}", Uuid::new_v4());

        let _ = tx.send(Ok(AiEvent::MessageUpdated {
            message_id: user_message_id.clone(),
            role: "user".to_string(),
        }));
        let _ = tx.send(Ok(AiEvent::PartUpdated {
            message_id: user_message_id.clone(),
            part: AiPart::new_text(
                format!("{}-text", user_message_id),
                original_text,
            ),
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
                            let _ = tx.send(Err("Copilot notification stream closed".to_string()));
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

                        let (part_type, should_emit) = match session_update.as_str() {
                            "agent_thought_chunk" => ("reasoning", true),
                            "agent_message_chunk" => ("text", true),
                            "user_message_chunk" => ("text", false),
                            other => {
                                debug!("Copilot: unknown sessionUpdate type in stream: {}", other);
                                ("text", false)
                            }
                        };
                        if !should_emit || text.is_empty() {
                            continue;
                        }

                        if !assistant_opened {
                            assistant_opened = true;
                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                message_id: assistant_message_id.clone(),
                                role: "assistant".to_string(),
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
        // Copilot ACP 当前未暴露删除会话接口。
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
        self.cache_metadata(directory, metadata).await;

        if let Some(limit) = limit {
            let limit = limit as usize;
            if messages.len() > limit {
                messages = messages.split_off(messages.len() - limit);
            }
        }
        Ok(messages)
    }

    async fn abort_session(&self, _directory: &str, _session_id: &str) -> Result<(), String> {
        self.client.ensure_started().await?;
        self.client.session_cancel(_session_id).await
    }

    async fn dispose_instance(&self, _directory: &str) -> Result<(), String> {
        Ok(())
    }

    async fn list_providers(&self, directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        let metadata = self.metadata_for_directory(directory).await;
        let mut models = metadata
            .models
            .into_iter()
            .map(|m| AiModelInfo {
                id: m.id.clone(),
                name: m.name,
                provider_id: "copilot".to_string(),
                supports_image_input: m.supports_image_input,
            })
            .collect::<Vec<_>>();
        if models.is_empty() {
            models.push(AiModelInfo {
                id: "default".to_string(),
                name: "Default".to_string(),
                provider_id: "copilot".to_string(),
                supports_image_input: true,
            });
        }
        Ok(vec![AiProviderInfo {
            id: "copilot".to_string(),
            name: "Copilot".to_string(),
            models,
        }])
    }

    async fn list_agents(&self, directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        let metadata = self.metadata_for_directory(directory).await;
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
                    default_provider_id: Some("copilot".to_string()),
                    default_model_id: default_model_id.clone(),
                }
            })
            .collect::<Vec<_>>();

        if agents.is_empty() {
            agents.push(AiAgentInfo {
                name: "agent".to_string(),
                description: Some("Copilot Agent mode".to_string()),
                mode: Some("primary".to_string()),
                color: Some("blue".to_string()),
                default_provider_id: Some("copilot".to_string()),
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
}
