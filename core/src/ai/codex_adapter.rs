use super::codex_client::{CodexAppServerClient, CodexModelInfo};
use super::codex_manager::CodexAppServerManager;
use super::session_status::AiSessionStatus;
use super::{
    AiAgent, AiAgentInfo, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiQuestionInfo, AiQuestionOption, AiQuestionRequest,
    AiSession, AiSlashCommand,
};
use async_trait::async_trait;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::warn;
use uuid::Uuid;

#[derive(Debug, Clone)]
struct PendingApproval {
    id: Value,
    method: String,
    question_ids: Vec<String>,
    session_id: String,
    tool_message_id: Option<String>,
}

pub struct CodexAppServerAgent {
    client: CodexAppServerClient,
    pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
    active_turns: Arc<Mutex<HashMap<String, String>>>,
}

impl CodexAppServerAgent {
    pub fn new(manager: Arc<CodexAppServerManager>) -> Self {
        Self {
            client: CodexAppServerClient::new(manager),
            pending_approvals: Arc::new(Mutex::new(HashMap::new())),
            active_turns: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn request_id_key(id: &Value) -> String {
        match id {
            Value::String(s) => format!("s:{}", s),
            Value::Number(n) => format!("n:{}", n),
            _ => format!("j:{}", id),
        }
    }

    fn parse_model_selection(model: Option<AiModelSelection>) -> (Option<String>, Option<String>) {
        match model {
            Some(m) => (Some(m.model_id), Some(m.provider_id)),
            None => (None, None),
        }
    }

    fn parse_collaboration_mode(agent: Option<&str>) -> Option<String> {
        let normalized = agent?.trim().to_lowercase();
        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    }

    fn is_thread_not_found_error(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("thread not found")
    }

    fn map_item_to_part(item: &Value) -> Option<AiPart> {
        let part_id = item.get("id")?.as_str()?.to_string();
        let kind = item.get("type")?.as_str()?.to_lowercase();
        match kind.as_str() {
            "agentmessage" => Some(AiPart {
                id: part_id,
                part_type: "text".to_string(),
                text: item
                    .get("text")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string()),
                mime: None,
                filename: None,
                url: None,
                synthetic: None,
                ignored: None,
                source: None,
                tool_name: None,
                tool_call_id: None,
                tool_state: None,
                tool_part_metadata: None,
            }),
            "reasoning" | "plan" => {
                let text = if kind == "plan" {
                    item.get("text")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string()
                } else {
                    let summary = item
                        .get("summary")
                        .and_then(|v| v.as_array())
                        .into_iter()
                        .flatten()
                        .filter_map(|v| v.as_str())
                        .collect::<Vec<_>>()
                        .join("\n");
                    let content = item
                        .get("content")
                        .and_then(|v| v.as_array())
                        .into_iter()
                        .flatten()
                        .filter_map(|v| v.as_str())
                        .collect::<Vec<_>>()
                        .join("\n");
                    if summary.is_empty() {
                        content
                    } else if content.is_empty() {
                        summary
                    } else {
                        format!("{}\n{}", summary, content)
                    }
                };
                Some(AiPart {
                    id: part_id,
                    part_type: "reasoning".to_string(),
                    text: Some(text),
                    mime: None,
                    filename: None,
                    url: None,
                    synthetic: None,
                    ignored: None,
                    source: None,
                    tool_name: None,
                    tool_call_id: None,
                    tool_state: None,
                    tool_part_metadata: None,
                })
            }
            "imageview" => Some(AiPart {
                id: part_id,
                part_type: "file".to_string(),
                text: None,
                mime: None,
                filename: None,
                url: item
                    .get("path")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string()),
                synthetic: None,
                ignored: None,
                source: None,
                tool_name: None,
                tool_call_id: None,
                tool_state: None,
                tool_part_metadata: None,
            }),
            "usermessage" => None,
            other => Some(AiPart {
                id: part_id,
                part_type: "tool".to_string(),
                text: None,
                mime: None,
                filename: None,
                url: None,
                synthetic: None,
                ignored: None,
                source: None,
                tool_name: Some(other.to_string()),
                tool_call_id: None,
                tool_state: Some(item.clone()),
                tool_part_metadata: None,
            }),
        }
    }

    fn parse_user_text(item: &Value) -> String {
        let mut chunks = Vec::new();
        let content = item
            .get("content")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        for input in content {
            let kind = input
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_lowercase();
            match kind.as_str() {
                "text" => {
                    if let Some(text) = input.get("text").and_then(|v| v.as_str()) {
                        chunks.push(text.to_string());
                    }
                }
                "mention" => {
                    if let Some(path) = input.get("path").and_then(|v| v.as_str()) {
                        chunks.push(format!("@{}", path));
                    }
                }
                "localimage" => {
                    if let Some(path) = input.get("path").and_then(|v| v.as_str()) {
                        chunks.push(format!("[image:{}]", path));
                    }
                }
                "image" => {
                    if let Some(url) = input.get("url").and_then(|v| v.as_str()) {
                        chunks.push(format!("[image:{}]", url));
                    }
                }
                _ => {}
            }
        }
        chunks.join("\n")
    }

    fn map_turn_item_to_message(
        turn_id: &str,
        index: usize,
        item: &Value,
        pending_request_id: Option<&str>,
    ) -> Option<AiMessage> {
        let item_type = item
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_lowercase();
        let item_id = item
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!("{}-{}", turn_id, index));
        if item_type == "usermessage" {
            return Some(AiMessage {
                id: item_id.clone(),
                role: "user".to_string(),
                created_at: None,
                parts: vec![AiPart {
                    id: format!("{}-text", item_id),
                    part_type: "text".to_string(),
                    text: Some(Self::parse_user_text(item)),
                    mime: None,
                    filename: None,
                    url: None,
                    synthetic: None,
                    ignored: None,
                    source: None,
                    tool_name: None,
                    tool_call_id: None,
                    tool_state: None,
                    tool_part_metadata: None,
                }],
            });
        }
        Self::map_item_to_part(item).map(|mut part| {
            if part.part_type == "tool"
                && part
                    .tool_name
                    .as_deref()
                    .map(|name| name.eq_ignore_ascii_case("question"))
                    .unwrap_or(false)
            {
                if let Some(request_id) = pending_request_id {
                    part.tool_call_id = Some(request_id.to_string());
                    let mut metadata = part
                        .tool_part_metadata
                        .and_then(|v| v.as_object().cloned())
                        .unwrap_or_default();
                    metadata.insert(
                        "request_id".to_string(),
                        Value::String(request_id.to_string()),
                    );
                    metadata.insert("tool_message_id".to_string(), Value::String(item_id.clone()));
                    part.tool_part_metadata = Some(Value::Object(metadata));
                }
            }

            AiMessage {
                id: item_id,
                role: "assistant".to_string(),
                created_at: None,
                parts: vec![part],
            }
        })
    }

    fn normalize_filename(name: &str) -> String {
        let mut out = String::new();
        for ch in name.chars() {
            if ch.is_ascii_alphanumeric() || ch == '.' || ch == '-' || ch == '_' {
                out.push(ch);
            } else {
                out.push('_');
            }
        }
        if out.is_empty() {
            "image.bin".to_string()
        } else {
            out
        }
    }

    fn build_question_from_request(
        method: &str,
        request_id: &str,
        params: &Value,
    ) -> Option<(AiQuestionRequest, Vec<String>)> {
        let session_id = params.get("threadId")?.as_str()?.to_string();
        let item_id = params
            .get("itemId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        match method {
            "item/commandExecution/requestApproval" => {
                let command = params
                    .get("command")
                    .and_then(|v| v.as_str())
                    .unwrap_or("command");
                let q = AiQuestionInfo {
                    question: format!("允许执行命令？\n{}", command),
                    header: "Codex Approval".to_string(),
                    options: vec![
                        AiQuestionOption {
                            label: "accept".to_string(),
                            description: "允许本次执行".to_string(),
                        },
                        AiQuestionOption {
                            label: "decline".to_string(),
                            description: "拒绝本次执行".to_string(),
                        },
                        AiQuestionOption {
                            label: "cancel".to_string(),
                            description: "拒绝并中断本轮".to_string(),
                        },
                    ],
                    multiple: false,
                    custom: false,
                };
                Some((
                    AiQuestionRequest {
                        id: request_id.to_string(),
                        session_id,
                        questions: vec![q],
                        tool_message_id: item_id,
                        tool_call_id: None,
                    },
                    vec!["decision".to_string()],
                ))
            }
            "item/fileChange/requestApproval" => {
                let q = AiQuestionInfo {
                    question: "允许应用文件修改？".to_string(),
                    header: "Codex Approval".to_string(),
                    options: vec![
                        AiQuestionOption {
                            label: "accept".to_string(),
                            description: "允许本次修改".to_string(),
                        },
                        AiQuestionOption {
                            label: "decline".to_string(),
                            description: "拒绝本次修改".to_string(),
                        },
                        AiQuestionOption {
                            label: "cancel".to_string(),
                            description: "拒绝并中断本轮".to_string(),
                        },
                    ],
                    multiple: false,
                    custom: false,
                };
                Some((
                    AiQuestionRequest {
                        id: request_id.to_string(),
                        session_id,
                        questions: vec![q],
                        tool_message_id: item_id,
                        tool_call_id: None,
                    },
                    vec!["decision".to_string()],
                ))
            }
            "item/tool/requestUserInput" => {
                let questions = params
                    .get("questions")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                let mut mapped = Vec::new();
                let mut ids = Vec::new();
                for q in questions {
                    let Some(id) = q.get("id").and_then(|v| v.as_str()) else {
                        continue;
                    };
                    ids.push(id.to_string());
                    let options = q
                        .get("options")
                        .and_then(|v| v.as_array())
                        .into_iter()
                        .flatten()
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
                        .collect::<Vec<_>>();
                    mapped.push(AiQuestionInfo {
                        question: q
                            .get("question")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string(),
                        header: q
                            .get("header")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string(),
                        options,
                        multiple: false,
                        custom: q.get("isOther").and_then(|v| v.as_bool()).unwrap_or(true),
                    });
                }
                Some((
                    AiQuestionRequest {
                        id: request_id.to_string(),
                        session_id,
                        questions: mapped,
                        tool_message_id: item_id,
                        tool_call_id: None,
                    },
                    ids,
                ))
            }
            _ => None,
        }
    }

    async fn build_turn_stream(
        &self,
        session_id: String,
        turn_id: String,
        original_text: String,
    ) -> Result<AiEventStream, String> {
        let (tx, rx) = mpsc::unbounded_channel::<Result<AiEvent, String>>();
        let mut notifications = self.client.subscribe_notifications();
        let mut requests = self.client.subscribe_requests();
        let approvals = self.pending_approvals.clone();
        let active_turns = self.active_turns.clone();

        let user_message_id = format!("codex-user-{}-{}", session_id, turn_id);
        let _ = tx.send(Ok(AiEvent::MessageUpdated {
            message_id: user_message_id.clone(),
            role: "user".to_string(),
        }));
        let _ = tx.send(Ok(AiEvent::PartUpdated {
            message_id: user_message_id.clone(),
            part: AiPart {
                id: format!("{}-text", user_message_id),
                part_type: "text".to_string(),
                text: Some(original_text),
                mime: None,
                filename: None,
                url: None,
                synthetic: None,
                ignored: None,
                source: None,
                tool_name: None,
                tool_call_id: None,
                tool_state: None,
                tool_part_metadata: None,
            },
        }));

        tokio::spawn(async move {
            let mut known_assistant_messages = HashSet::<String>::new();
            loop {
                tokio::select! {
                    recv = notifications.recv() => {
                        match recv {
                            Ok(event) => {
                                let params = event.params.unwrap_or(Value::Null);
                                let thread_id = params.get("threadId").and_then(|v| v.as_str()).unwrap_or("");
                                let event_turn_id = params.get("turnId").and_then(|v| v.as_str()).unwrap_or("");
                                if thread_id != session_id || (!event_turn_id.is_empty() && event_turn_id != turn_id) {
                                    continue;
                                }
                                match event.method.as_str() {
                                    "item/agentMessage/delta" => {
                                        let item_id = params.get("itemId").and_then(|v| v.as_str()).unwrap_or("");
                                        if item_id.is_empty() {
                                            continue;
                                        }
                                        if !known_assistant_messages.contains(item_id) {
                                            known_assistant_messages.insert(item_id.to_string());
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: item_id.to_string(),
                                                role: "assistant".to_string(),
                                            }));
                                        }
                                        if let Some(delta) = params.get("delta").and_then(|v| v.as_str()) {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: item_id.to_string(),
                                                part_id: item_id.to_string(),
                                                part_type: "text".to_string(),
                                                field: "text".to_string(),
                                                delta: delta.to_string(),
                                            }));
                                        }
                                    }
                                    "item/reasoning/textDelta" | "item/reasoning/summaryTextDelta" => {
                                        let item_id = params.get("itemId").and_then(|v| v.as_str()).unwrap_or("");
                                        if item_id.is_empty() {
                                            continue;
                                        }
                                        if !known_assistant_messages.contains(item_id) {
                                            known_assistant_messages.insert(item_id.to_string());
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: item_id.to_string(),
                                                role: "assistant".to_string(),
                                            }));
                                        }
                                        if let Some(delta) = params.get("delta").and_then(|v| v.as_str()) {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: item_id.to_string(),
                                                part_id: item_id.to_string(),
                                                part_type: "reasoning".to_string(),
                                                field: "text".to_string(),
                                                delta: delta.to_string(),
                                            }));
                                        }
                                    }
                                    "item/started" | "item/completed" => {
                                        let Some(item) = params.get("item") else {
                                            continue;
                                        };
                                        let item_type = item
                                            .get("type")
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("")
                                            .to_lowercase();
                                        if item_type == "usermessage" {
                                            continue;
                                        }
                                        let Some(message_id) = item.get("id").and_then(|v| v.as_str()) else {
                                            continue;
                                        };
                                        if !known_assistant_messages.contains(message_id) {
                                            known_assistant_messages.insert(message_id.to_string());
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: message_id.to_string(),
                                                role: "assistant".to_string(),
                                            }));
                                        }
                                        if let Some(part) = CodexAppServerAgent::map_item_to_part(item) {
                                            let _ = tx.send(Ok(AiEvent::PartUpdated {
                                                message_id: message_id.to_string(),
                                                part,
                                            }));
                                        }
                                    }
                                    "error" => {
                                        let message = params
                                            .get("error")
                                            .and_then(|v| v.get("message"))
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("Codex app-server error");
                                        let _ = tx.send(Ok(AiEvent::Error {
                                            message: message.to_string(),
                                        }));
                                    }
                                    "turn/completed" => {
                                        let status = params
                                            .get("turn")
                                            .and_then(|v| v.get("status"))
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("");
                                        if status.eq_ignore_ascii_case("failed") {
                                            let message = params
                                                .get("turn")
                                                .and_then(|v| v.get("error"))
                                                .and_then(|v| v.get("message"))
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("Turn failed");
                                            let _ = tx.send(Ok(AiEvent::Error {
                                                message: message.to_string(),
                                            }));
                                        }
                                        let _ = tx.send(Ok(AiEvent::Done));
                                        active_turns.lock().await.remove(&session_id);
                                        break;
                                    }
                                    _ => {}
                                }
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                                let _ = tx.send(Err("Codex notification stream closed".to_string()));
                                active_turns.lock().await.remove(&session_id);
                                break;
                            }
                        }
                    }
                    recv = requests.recv() => {
                        match recv {
                            Ok(req) => {
                                let params = req.params.unwrap_or(Value::Null);
                                let thread_id = params.get("threadId").and_then(|v| v.as_str()).unwrap_or("");
                                let request_turn_id = params.get("turnId").and_then(|v| v.as_str()).unwrap_or("");
                                if thread_id != session_id || request_turn_id != turn_id {
                                    continue;
                                }
                                let request_key = CodexAppServerAgent::request_id_key(&req.id);
                                if let Some((question, question_ids)) = CodexAppServerAgent::build_question_from_request(&req.method, &request_key, &params) {
                                    let pending = PendingApproval {
                                        id: req.id,
                                        method: req.method.clone(),
                                        question_ids,
                                        session_id: question.session_id.clone(),
                                        tool_message_id: question.tool_message_id.clone(),
                                    };
                                    approvals.lock().await.insert(
                                        request_key.clone(),
                                        pending,
                                    );
                                    let _ = tx.send(Ok(AiEvent::QuestionAsked { request: question }));
                                }
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => {}
                        }
                    }
                }
            }
        });

        Ok(Box::pin(UnboundedReceiverStream::new(rx)))
    }

    fn provider_from_models(models: Vec<CodexModelInfo>) -> Vec<AiProviderInfo> {
        let mapped = models
            .into_iter()
            .map(|m| AiModelInfo {
                id: m.id.clone(),
                name: if m.display_name.is_empty() {
                    m.model.clone()
                } else {
                    m.display_name.clone()
                },
                provider_id: "codex".to_string(),
                supports_image_input: m
                    .input_modalities
                    .iter()
                    .any(|modality| modality.eq_ignore_ascii_case("image")),
            })
            .collect::<Vec<_>>();
        vec![AiProviderInfo {
            id: "codex".to_string(),
            name: "Codex".to_string(),
            models: mapped,
        }]
    }
}

#[async_trait]
impl AiAgent for CodexAppServerAgent {
    async fn start(&self) -> Result<(), String> {
        self.client.ensure_started().await
    }

    async fn stop(&self) -> Result<(), String> {
        // 由 manager 生命周期管理，当前无需显式 stop。
        Ok(())
    }

    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String> {
        self.client.ensure_started().await?;
        let thread = self.client.thread_start(directory, title).await?;
        Ok(AiSession {
            id: thread.id,
            title: title.to_string(),
            updated_at: thread.updated_at_secs.saturating_mul(1000),
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

        let mut input = vec![CodexAppServerClient::text_input(message)];
        if let Some(files) = file_refs {
            for file in files {
                let absolute = format!("{}/{}", directory.trim_end_matches('/'), file);
                let name = PathBuf::from(&file)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("file")
                    .to_string();
                input.push(CodexAppServerClient::mention_input(&name, &absolute));
            }
        }
        if let Some(images) = image_parts {
            let temp_dir = std::env::temp_dir().join("tidyflow-codex-images");
            tokio::fs::create_dir_all(&temp_dir)
                .await
                .map_err(|e| format!("Failed to create Codex image temp dir: {}", e))?;
            for img in images {
                let filename = format!(
                    "{}-{}",
                    Uuid::new_v4(),
                    Self::normalize_filename(&img.filename)
                );
                let path = temp_dir.join(filename);
                tokio::fs::write(&path, &img.data)
                    .await
                    .map_err(|e| format!("Failed to write image temp file: {}", e))?;
                input.push(CodexAppServerClient::local_image_input(path));
            }
        }

        let (model_id, model_provider) = Self::parse_model_selection(model);
        let collaboration_mode = Self::parse_collaboration_mode(agent.as_deref());
        let turn_id = match self
            .client
            .turn_start(
                session_id,
                input.clone(),
                model_id.clone(),
                model_provider.clone(),
                collaboration_mode.clone(),
            )
            .await
        {
            Ok(turn_id) => turn_id,
            Err(err) if Self::is_thread_not_found_error(&err) => {
                self.client.thread_resume(directory, session_id).await?;
                self.client
                    .turn_start(
                        session_id,
                        input,
                        model_id,
                        model_provider,
                        collaboration_mode,
                    )
                    .await?
            }
            Err(err) => return Err(err),
        };
        self.active_turns
            .lock()
            .await
            .insert(session_id.to_string(), turn_id.clone());

        self.build_turn_stream(session_id.to_string(), turn_id, message.to_string())
            .await
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        self.client.ensure_started().await?;
        let sessions = self.client.thread_list(directory, 200).await?;
        Ok(sessions
            .into_iter()
            .map(|s| AiSession {
                id: s.id,
                title: if s.preview.trim().is_empty() {
                    "New Chat".to_string()
                } else {
                    s.preview
                },
                updated_at: s.updated_at_secs.saturating_mul(1000),
            })
            .collect())
    }

    async fn delete_session(&self, _directory: &str, session_id: &str) -> Result<(), String> {
        self.client.thread_archive(session_id).await
    }

    async fn list_messages(
        &self,
        _directory: &str,
        session_id: &str,
        _limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String> {
        self.client.ensure_started().await?;
        let response = self.client.thread_read(session_id, true).await?;
        let turns = response
            .get("thread")
            .and_then(|v| v.get("turns"))
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();

        let pending_request_id_by_item_id: HashMap<String, String> = self
            .pending_approvals
            .lock()
            .await
            .iter()
            .filter_map(|(request_id, pending)| {
                if pending.session_id != session_id {
                    return None;
                }
                let tool_message_id = pending.tool_message_id.clone()?;
                Some((tool_message_id, request_id.clone()))
            })
            .collect();

        let mut messages = Vec::new();
        for turn in turns {
            let turn_id = turn
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("turn")
                .to_string();
            let items = turn
                .get("items")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            for (idx, item) in items.iter().enumerate() {
                let item_id = item
                    .get("id")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| format!("{}-{}", turn_id, idx));
                let pending_request_id = pending_request_id_by_item_id
                    .get(&item_id)
                    .map(|s| s.as_str());
                if let Some(msg) =
                    Self::map_turn_item_to_message(&turn_id, idx, item, pending_request_id)
                {
                    messages.push(msg);
                }
            }
        }
        Ok(messages)
    }

    async fn abort_session(&self, _directory: &str, session_id: &str) -> Result<(), String> {
        let turn_id = self.active_turns.lock().await.get(session_id).cloned();
        if let Some(turn_id) = turn_id {
            self.client.turn_interrupt(session_id, &turn_id).await?;
        }
        Ok(())
    }

    async fn dispose_instance(&self, _directory: &str) -> Result<(), String> {
        Ok(())
    }

    async fn get_session_status(
        &self,
        _directory: &str,
        session_id: &str,
    ) -> Result<AiSessionStatus, String> {
        let is_busy = self.active_turns.lock().await.contains_key(session_id);
        Ok(if is_busy {
            AiSessionStatus::Busy
        } else {
            AiSessionStatus::Idle
        })
    }

    async fn list_providers(&self, _directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        self.client.ensure_started().await?;
        let models = self.client.model_list().await?;
        Ok(Self::provider_from_models(models))
    }

    async fn list_agents(&self, directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        let providers = self.list_providers(directory).await?;
        let default_model_id = providers
            .first()
            .and_then(|p| {
                p.models
                    .iter()
                    .find(|m| m.id == "default")
                    .or_else(|| p.models.first())
            })
            .map(|m| m.id.clone());

        let agents = self.client.agent_list().await?;
        Ok(agents
            .into_iter()
            .map(|agent| AiAgentInfo {
                name: agent.name.clone(),
                description: Some(format!("Codex {} mode", agent.name)),
                mode: Some("primary".to_string()),
                color: Some(if agent.collaboration_mode == "plan" {
                    "orange".to_string()
                } else {
                    "blue".to_string()
                }),
                default_provider_id: Some("codex".to_string()),
                default_model_id: default_model_id.clone(),
            })
            .collect())
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
        let key = request_id.to_string();
        let pending = self
            .pending_approvals
            .lock()
            .await
            .remove(&key)
            .ok_or_else(|| format!("Unknown Codex approval request: {}", request_id))?;

        let response = match pending.method.as_str() {
            "item/commandExecution/requestApproval" => {
                let decision = answers
                    .first()
                    .and_then(|a| a.first())
                    .map(|s| s.to_lowercase())
                    .unwrap_or_else(|| "accept".to_string());
                serde_json::json!({ "decision": decision })
            }
            "item/fileChange/requestApproval" => {
                let decision = answers
                    .first()
                    .and_then(|a| a.first())
                    .map(|s| s.to_lowercase())
                    .unwrap_or_else(|| "accept".to_string());
                serde_json::json!({ "decision": decision })
            }
            "item/tool/requestUserInput" => {
                let mut answer_map = serde_json::Map::new();
                for (idx, qid) in pending.question_ids.iter().enumerate() {
                    let ans = answers.get(idx).cloned().unwrap_or_default();
                    answer_map.insert(qid.clone(), serde_json::json!({ "answers": ans }));
                }
                serde_json::json!({ "answers": answer_map })
            }
            other => {
                warn!(
                    "Unsupported Codex request method in reply_question: {}",
                    other
                );
                serde_json::json!({})
            }
        };
        self.client
            .send_approval_response(pending.id, response)
            .await
    }

    async fn reject_question(&self, _directory: &str, request_id: &str) -> Result<(), String> {
        let key = request_id.to_string();
        let pending = self
            .pending_approvals
            .lock()
            .await
            .remove(&key)
            .ok_or_else(|| format!("Unknown Codex approval request: {}", request_id))?;

        let response = match pending.method.as_str() {
            "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
                serde_json::json!({ "decision": "cancel" })
            }
            "item/tool/requestUserInput" => serde_json::json!({ "answers": {} }),
            _ => serde_json::json!({}),
        };
        self.client
            .send_approval_response(pending.id, response)
            .await
    }
}
