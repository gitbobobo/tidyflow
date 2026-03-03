use super::client::KimiWireClient;
use super::process::KimiWireProcess;
use crate::ai::context_usage::AiSessionContextUsage;
use crate::ai::session_status::AiSessionStatus;
use crate::ai::shared::path_norm::normalize_directory_with_file_url as shared_normalize_directory;
use crate::ai::{
    AiAgent, AiAgentInfo, AiAudioPart, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiQuestionInfo, AiQuestionOption, AiQuestionRequest,
    AiSession, AiSessionConfigOption, AiSessionConfigValue, AiSessionSelectionHint, AiSlashCommand,
};
use async_trait::async_trait;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::{debug, warn};
use uuid::Uuid;

#[derive(Debug, Clone)]
struct KimiSessionRecord {
    id: String,
    title: String,
    updated_at: i64,
    directory: String,
    selection_hint: AiSessionSelectionHint,
    messages: Vec<AiMessage>,
    context_usage: Option<AiSessionContextUsage>,
}

#[derive(Debug, Clone)]
struct PendingApproval {
    runtime_key: String,
    jsonrpc_id: Value,
    request_id: String,
}

#[derive(Debug, Clone)]
struct ToolPartState {
    tool_call_id: String,
    part_id: String,
    tool_name: String,
    input_text: String,
    raw_input: Option<Value>,
    raw_output: Option<Value>,
    status: String,
}

impl ToolPartState {
    fn to_part(&self) -> AiPart {
        let mut part = AiPart::new_tool(self.part_id.clone(), self.tool_name.clone());
        part.source = Some(serde_json::json!({ "vendor": "kimi-wire" }));
        part.tool_call_id = Some(self.tool_call_id.clone());
        part.tool_raw_input = self.raw_input.clone();
        part.tool_raw_output = self.raw_output.clone();
        part.tool_state = Some(serde_json::json!({
            "status": self.status,
            "input": self.input_text,
            "output": self.raw_output,
        }));
        part
    }
}

#[derive(Clone)]
struct KimiWireRuntime {
    client: KimiWireClient,
}

pub struct KimiWireAgent {
    sessions: Arc<Mutex<HashMap<String, KimiSessionRecord>>>,
    runtimes: Arc<Mutex<HashMap<String, Arc<KimiWireRuntime>>>>,
    active_turns: Arc<Mutex<HashSet<String>>>,
    pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
}

impl KimiWireAgent {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            runtimes: Arc::new(Mutex::new(HashMap::new())),
            active_turns: Arc::new(Mutex::new(HashSet::new())),
            pending_approvals: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn now_ms() -> i64 {
        chrono::Utc::now().timestamp_millis()
    }

    fn normalize_directory(directory: &str) -> String {
        shared_normalize_directory(directory)
    }

    fn runtime_key(directory: &str, session_id: &str) -> String {
        format!("{}::{}", Self::normalize_directory(directory), session_id)
    }

    fn sanitize_tool_call_id(raw: &str) -> String {
        raw.chars()
            .map(|ch| {
                if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                    ch
                } else {
                    '_'
                }
            })
            .collect::<String>()
    }

    fn compose_user_input(
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        audio_parts: Option<Vec<AiAudioPart>>,
    ) -> String {
        let mut chunks = vec![message.to_string()];

        if let Some(files) = file_refs {
            if !files.is_empty() {
                chunks.push(format!("文件引用：\n{}", files.join("\n")));
            }
        }

        if let Some(images) = image_parts {
            if !images.is_empty() {
                let lines = images
                    .into_iter()
                    .map(|img| format!("{} ({})", img.filename, img.mime))
                    .collect::<Vec<_>>()
                    .join("\n");
                chunks.push(format!("图片附件：\n{}", lines));
            }
        }

        if let Some(audios) = audio_parts {
            if !audios.is_empty() {
                let lines = audios
                    .into_iter()
                    .map(|audio| format!("{} ({})", audio.filename, audio.mime))
                    .collect::<Vec<_>>()
                    .join("\n");
                chunks.push(format!("音频附件：\n{}", lines));
            }
        }

        chunks.join("\n\n")
    }

    async fn get_or_create_runtime(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Arc<KimiWireRuntime>, String> {
        let runtime_key = Self::runtime_key(directory, session_id);
        {
            let runtimes = self.runtimes.lock().await;
            if let Some(runtime) = runtimes.get(&runtime_key) {
                return Ok(runtime.clone());
            }
        }

        let process = Arc::new(KimiWireProcess::new(
            Self::normalize_directory(directory),
            session_id.to_string(),
        ));
        let client = KimiWireClient::new(process);
        let runtime = Arc::new(KimiWireRuntime { client });

        self.runtimes
            .lock()
            .await
            .insert(runtime_key, runtime.clone());
        Ok(runtime)
    }

    async fn clear_pending_approvals_for_runtime(&self, runtime_key: &str) {
        let mut pending = self.pending_approvals.lock().await;
        pending.retain(|_, item| item.runtime_key != runtime_key);
    }

    async fn clear_pending_approvals_for_runtime_in_map(
        pending_map: &Arc<Mutex<HashMap<String, PendingApproval>>>,
        runtime_key: &str,
    ) {
        let mut pending = pending_map.lock().await;
        pending.retain(|_, item| item.runtime_key != runtime_key);
    }

    fn select_approval_from_answers(answers: Vec<Vec<String>>) -> bool {
        for group in answers {
            for answer in group {
                let normalized = answer.trim().to_ascii_lowercase();
                if normalized.contains("allow")
                    || normalized.contains("approve")
                    || normalized.contains("yes")
                    || normalized.contains("允许")
                    || normalized.contains("同意")
                {
                    return true;
                }
            }
        }
        false
    }

    fn parse_json_or_string(raw: &str) -> Value {
        serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_string()))
    }

    fn parse_tool_result_output_text(output: &Value) -> Option<String> {
        if let Some(text) = output.as_str() {
            return Some(text.to_string());
        }

        let Some(items) = output.as_array() else {
            return None;
        };

        let mut out = String::new();
        for item in items {
            if let Some(text) = item.get("text").and_then(|v| v.as_str()) {
                out.push_str(text);
                continue;
            }
            if let Some(text) = item.get("think").and_then(|v| v.as_str()) {
                out.push_str(text);
                continue;
            }
            if let Some(text) = item.as_str() {
                out.push_str(text);
            }
        }

        if out.trim().is_empty() {
            None
        } else {
            Some(out)
        }
    }

    #[cfg(test)]
    pub(crate) async fn insert_runtime_for_test(
        &self,
        directory: &str,
        session_id: &str,
        client: KimiWireClient,
    ) {
        let key = Self::runtime_key(directory, session_id);
        self.runtimes
            .lock()
            .await
            .insert(key.clone(), Arc::new(KimiWireRuntime { client }));
    }
}

impl Default for KimiWireAgent {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl AiAgent for KimiWireAgent {
    async fn start(&self) -> Result<(), String> {
        // 轻量启动：仅在首次消息发送时懒启动子进程。
        Ok(())
    }

    async fn stop(&self) -> Result<(), String> {
        let runtimes = self
            .runtimes
            .lock()
            .await
            .values()
            .cloned()
            .collect::<Vec<_>>();
        for runtime in runtimes {
            let _ = runtime.client.stop().await;
        }
        self.runtimes.lock().await.clear();
        self.active_turns.lock().await.clear();
        self.pending_approvals.lock().await.clear();
        Ok(())
    }

    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String> {
        let normalized_directory = Self::normalize_directory(directory);
        let session = AiSession {
            id: format!("kimi-{}", Uuid::new_v4()),
            title: title.to_string(),
            updated_at: Self::now_ms(),
        };

        self.sessions.lock().await.insert(
            session.id.clone(),
            KimiSessionRecord {
                id: session.id.clone(),
                title: session.title.clone(),
                updated_at: session.updated_at,
                directory: normalized_directory,
                selection_hint: AiSessionSelectionHint::default(),
                messages: Vec::new(),
                context_usage: None,
            },
        );

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
        let normalized_directory = Self::normalize_directory(directory);

        let selection_hint = {
            let mut sessions = self.sessions.lock().await;
            let session = sessions
                .get_mut(session_id)
                .ok_or_else(|| format!("Kimi session not found: {}", session_id))?;
            if session.directory != normalized_directory {
                return Err(format!(
                    "Kimi session directory mismatch: session_id={}, expected={}, got={}",
                    session_id, session.directory, normalized_directory
                ));
            }

            session.updated_at = Self::now_ms();
            if let Some(model_selection) = model.as_ref() {
                session.selection_hint.model_provider_id =
                    Some(model_selection.provider_id.clone());
                session.selection_hint.model_id = Some(model_selection.model_id.clone());
            }
            if let Some(agent_name) = agent.as_ref() {
                let normalized_agent = agent_name.trim().to_ascii_lowercase();
                if !normalized_agent.is_empty() {
                    session.selection_hint.agent = Some(normalized_agent);
                }
            }
            session.selection_hint.clone()
        };

        let runtime_key = Self::runtime_key(&normalized_directory, session_id);
        {
            let mut active = self.active_turns.lock().await;
            if !active.insert(runtime_key.clone()) {
                return Err("Kimi 会话正在处理中，请稍后重试".to_string());
            }
        }

        let runtime = match self
            .get_or_create_runtime(&normalized_directory, session_id)
            .await
        {
            Ok(runtime) => runtime,
            Err(err) => {
                self.active_turns.lock().await.remove(&runtime_key);
                return Err(err);
            }
        };

        let composed_input = Self::compose_user_input(message, file_refs, image_parts, audio_parts);
        let user_message_id = format!("kimi-user-{}", Uuid::new_v4());
        let assistant_message_id = format!("kimi-assistant-{}", Uuid::new_v4());

        {
            let mut sessions = self.sessions.lock().await;
            if let Some(session) = sessions.get_mut(session_id) {
                session.messages.push(AiMessage {
                    id: user_message_id.clone(),
                    role: "user".to_string(),
                    created_at: Some(Self::now_ms()),
                    agent: selection_hint.agent.clone(),
                    model_provider_id: selection_hint.model_provider_id.clone(),
                    model_id: selection_hint.model_id.clone(),
                    parts: vec![AiPart {
                        id: format!("{}-text", user_message_id),
                        part_type: "text".to_string(),
                        text: Some(message.to_string()),
                        source: Some(serde_json::json!({ "vendor": "kimi-wire" })),
                        ..Default::default()
                    }],
                });
            }
        }

        let (tx, rx) = mpsc::unbounded_channel::<Result<AiEvent, String>>();
        let _ = tx.send(Ok(AiEvent::MessageUpdated {
            message_id: user_message_id.clone(),
            role: "user".to_string(),
            selection_hint: None,
        }));
        let _ = tx.send(Ok(AiEvent::PartUpdated {
            message_id: user_message_id.clone(),
            part: AiPart {
                id: format!("{}-text", user_message_id),
                part_type: "text".to_string(),
                text: Some(message.to_string()),
                source: Some(serde_json::json!({ "vendor": "kimi-wire" })),
                ..Default::default()
            },
        }));

        let mut events_rx = runtime.client.subscribe_events();
        let mut requests_rx = runtime.client.subscribe_requests();

        let runtime_for_task = runtime.clone();
        let sessions = self.sessions.clone();
        let active_turns = self.active_turns.clone();
        let pending_approvals = self.pending_approvals.clone();
        let runtime_key_for_task = runtime_key.clone();
        let session_id_for_task = session_id.to_string();
        let selection_hint_for_task = selection_hint.clone();
        let composed_input_for_task = composed_input.clone();

        tokio::spawn(async move {
            let reasoning_part_id = format!("{}-reasoning", assistant_message_id);
            let text_part_id = format!("{}-text", assistant_message_id);
            let mut reasoning_text = String::new();
            let mut assistant_text = String::new();
            let mut tool_order = Vec::<String>::new();
            let mut tool_states = HashMap::<String, ToolPartState>::new();
            let mut active_tool_call_id: Option<String> = None;
            let mut assistant_opened = false;
            let mut context_usage: Option<f64> = None;
            let mut prompt_finished = false;
            let mut turn_end_seen = false;
            let mut stop_reason: Option<String> = None;

            let slash_commands = runtime_for_task.client.slash_commands().await;
            if !slash_commands.is_empty() {
                let _ = tx.send(Ok(AiEvent::SlashCommandsUpdated {
                    session_id: session_id_for_task.clone(),
                    commands: slash_commands,
                }));
            }

            let prompt_fut = runtime_for_task.client.prompt(composed_input_for_task);
            tokio::pin!(prompt_fut);

            loop {
                if prompt_finished && turn_end_seen {
                    let _ = tx.send(Ok(AiEvent::Done {
                        stop_reason: stop_reason.clone(),
                    }));
                    break;
                }

                tokio::select! {
                    prompt_result = &mut prompt_fut, if !prompt_finished => {
                        match prompt_result {
                            Ok(result) => {
                                prompt_finished = true;
                                stop_reason = result
                                    .get("status")
                                    .and_then(|v| v.as_str())
                                    .map(|v| v.to_string());
                            }
                            Err(err) => {
                                let _ = tx.send(Err(err));
                                break;
                            }
                        }
                    }
                    recv = events_rx.recv() => {
                        let Ok(event) = recv else {
                            let _ = tx.send(Err("Kimi Wire 事件流已关闭".to_string()));
                            break;
                        };

                        match event.event_type.as_str() {
                            "TurnBegin" | "StepBegin" => {}
                            "TurnEnd" => {
                                turn_end_seen = true;
                            }
                            "StatusUpdate" => {
                                if let Some(value) = event.payload.get("context_usage").and_then(|v| v.as_f64()) {
                                    context_usage = Some(value);
                                }
                            }
                            "ContentPart" => {
                                let Some(part_type) = event.payload.get("type").and_then(|v| v.as_str()) else {
                                    continue;
                                };
                                if part_type == "think" {
                                    let Some(delta) = event.payload.get("think").and_then(|v| v.as_str()) else {
                                        continue;
                                    };
                                    if delta.is_empty() {
                                        continue;
                                    }
                                    reasoning_text.push_str(delta);
                                    if !assistant_opened {
                                        assistant_opened = true;
                                        let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                            message_id: assistant_message_id.clone(),
                                            role: "assistant".to_string(),
                                            selection_hint: None,
                                        }));
                                    }
                                    let _ = tx.send(Ok(AiEvent::PartDelta {
                                        message_id: assistant_message_id.clone(),
                                        part_id: reasoning_part_id.clone(),
                                        part_type: "reasoning".to_string(),
                                        field: "text".to_string(),
                                        delta: delta.to_string(),
                                    }));
                                } else if part_type == "text" {
                                    let Some(delta) = event.payload.get("text").and_then(|v| v.as_str()) else {
                                        continue;
                                    };
                                    if delta.is_empty() {
                                        continue;
                                    }
                                    assistant_text.push_str(delta);
                                    if !assistant_opened {
                                        assistant_opened = true;
                                        let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                            message_id: assistant_message_id.clone(),
                                            role: "assistant".to_string(),
                                            selection_hint: None,
                                        }));
                                    }
                                    let _ = tx.send(Ok(AiEvent::PartDelta {
                                        message_id: assistant_message_id.clone(),
                                        part_id: text_part_id.clone(),
                                        part_type: "text".to_string(),
                                        field: "text".to_string(),
                                        delta: delta.to_string(),
                                    }));
                                }
                            }
                            "ToolCall" => {
                                let Some(tool_call_id) = event.payload.get("id").and_then(|v| v.as_str()) else {
                                    continue;
                                };
                                let tool_name = event
                                    .payload
                                    .pointer("/function/name")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("tool")
                                    .to_string();
                                let args = event
                                    .payload
                                    .pointer("/function/arguments")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                let part_id = format!(
                                    "{}-tool-{}",
                                    assistant_message_id,
                                    KimiWireAgent::sanitize_tool_call_id(tool_call_id)
                                );
                                let entry = tool_states
                                    .entry(tool_call_id.to_string())
                                    .or_insert_with(|| ToolPartState {
                                        tool_call_id: tool_call_id.to_string(),
                                        part_id: part_id.clone(),
                                        tool_name: tool_name.clone(),
                                        input_text: String::new(),
                                        raw_input: None,
                                        raw_output: None,
                                        status: "running".to_string(),
                                    });
                                entry.tool_name = tool_name;
                                entry.status = "running".to_string();
                                if !args.is_empty() {
                                    entry.input_text = args.clone();
                                    entry.raw_input = Some(KimiWireAgent::parse_json_or_string(&args));
                                }
                                if !tool_order.iter().any(|id| id == tool_call_id) {
                                    tool_order.push(tool_call_id.to_string());
                                }
                                active_tool_call_id = Some(tool_call_id.to_string());

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
                                    part: entry.to_part(),
                                }));
                            }
                            "ToolCallPart" => {
                                let Some(arguments_part) = event
                                    .payload
                                    .get("arguments_part")
                                    .and_then(|v| v.as_str())
                                else {
                                    continue;
                                };
                                let Some(current_tool_call_id) = active_tool_call_id.as_ref() else {
                                    continue;
                                };
                                let Some(state) = tool_states.get_mut(current_tool_call_id) else {
                                    continue;
                                };
                                state.input_text.push_str(arguments_part);
                                state.raw_input = Some(KimiWireAgent::parse_json_or_string(&state.input_text));

                                let _ = tx.send(Ok(AiEvent::PartDelta {
                                    message_id: assistant_message_id.clone(),
                                    part_id: state.part_id.clone(),
                                    part_type: "tool".to_string(),
                                    field: "input".to_string(),
                                    delta: arguments_part.to_string(),
                                }));
                            }
                            "ToolResult" => {
                                let Some(tool_call_id) = event
                                    .payload
                                    .get("tool_call_id")
                                    .and_then(|v| v.as_str())
                                else {
                                    continue;
                                };
                                let output = event.payload.pointer("/return_value/output").cloned();
                                let is_error = event
                                    .payload
                                    .pointer("/return_value/is_error")
                                    .and_then(|v| v.as_bool())
                                    .unwrap_or(false);

                                let entry = tool_states
                                    .entry(tool_call_id.to_string())
                                    .or_insert_with(|| ToolPartState {
                                        tool_call_id: tool_call_id.to_string(),
                                        part_id: format!(
                                            "{}-tool-{}",
                                            assistant_message_id,
                                            KimiWireAgent::sanitize_tool_call_id(tool_call_id)
                                        ),
                                        tool_name: "tool".to_string(),
                                        input_text: String::new(),
                                        raw_input: None,
                                        raw_output: None,
                                        status: "running".to_string(),
                                    });
                                entry.status = if is_error {
                                    "failed".to_string()
                                } else {
                                    "completed".to_string()
                                };
                                entry.raw_output = output.clone();
                                if !tool_order.iter().any(|id| id == tool_call_id) {
                                    tool_order.push(tool_call_id.to_string());
                                }

                                if let Some(output) = output {
                                    if let Some(delta) = KimiWireAgent::parse_tool_result_output_text(&output) {
                                        let _ = tx.send(Ok(AiEvent::PartDelta {
                                            message_id: assistant_message_id.clone(),
                                            part_id: entry.part_id.clone(),
                                            part_type: "tool".to_string(),
                                            field: "output".to_string(),
                                            delta,
                                        }));
                                    }
                                }

                                let _ = tx.send(Ok(AiEvent::PartUpdated {
                                    message_id: assistant_message_id.clone(),
                                    part: entry.to_part(),
                                }));
                            }
                            "Error" => {
                                let message = event
                                    .payload
                                    .get("message")
                                    .and_then(|v| v.as_str())
                                    .or_else(|| event.payload.get("error").and_then(|v| v.as_str()))
                                    .unwrap_or("Kimi Wire stream error")
                                    .to_string();
                                let _ = tx.send(Err(message));
                                break;
                            }
                            _ => {}
                        }
                    }
                    recv = requests_rx.recv() => {
                        let Ok(request) = recv else { continue; };
                        if request.request_type != "ApprovalRequest" {
                            continue;
                        }

                        let request_id = request
                            .payload
                            .get("id")
                            .and_then(|v| v.as_str())
                            .map(|v| v.to_string())
                            .unwrap_or_else(|| Uuid::new_v4().to_string());
                        let header = request
                            .payload
                            .get("sender")
                            .and_then(|v| v.as_str())
                            .unwrap_or("权限审批")
                            .to_string();
                        let question = request
                            .payload
                            .get("description")
                            .and_then(|v| v.as_str())
                            .or_else(|| request.payload.get("action").and_then(|v| v.as_str()))
                            .unwrap_or("允许执行该操作吗？")
                            .to_string();
                        let tool_call_id = request
                            .payload
                            .get("tool_call_id")
                            .and_then(|v| v.as_str())
                            .map(|v| v.to_string());

                        pending_approvals.lock().await.insert(
                            request_id.clone(),
                            PendingApproval {
                                runtime_key: runtime_key_for_task.clone(),
                                jsonrpc_id: request.id.clone(),
                                request_id: request_id.clone(),
                            },
                        );

                        let _ = tx.send(Ok(AiEvent::QuestionAsked {
                            request: AiQuestionRequest {
                                id: request_id,
                                session_id: session_id_for_task.clone(),
                                questions: vec![AiQuestionInfo {
                                    question,
                                    header,
                                    options: vec![
                                        AiQuestionOption {
                                            option_id: Some("allow-once".to_string()),
                                            label: "允许".to_string(),
                                            description: "允许本次操作".to_string(),
                                        },
                                        AiQuestionOption {
                                            option_id: Some("reject".to_string()),
                                            label: "拒绝".to_string(),
                                            description: "拒绝本次操作".to_string(),
                                        },
                                    ],
                                    multiple: false,
                                    custom: false,
                                }],
                                tool_message_id: Some(assistant_message_id.clone()),
                                tool_call_id,
                            },
                        }));
                    }
                }
            }

            let mut assistant_parts = Vec::<AiPart>::new();
            if !reasoning_text.is_empty() {
                assistant_parts.push(AiPart {
                    id: reasoning_part_id,
                    part_type: "reasoning".to_string(),
                    text: Some(reasoning_text),
                    source: Some(serde_json::json!({ "vendor": "kimi-wire" })),
                    ..Default::default()
                });
            }

            for tool_call_id in tool_order {
                if let Some(state) = tool_states.get(&tool_call_id) {
                    assistant_parts.push(state.to_part());
                }
            }

            if !assistant_text.is_empty() {
                assistant_parts.push(AiPart {
                    id: text_part_id,
                    part_type: "text".to_string(),
                    text: Some(assistant_text),
                    source: Some(serde_json::json!({ "vendor": "kimi-wire" })),
                    ..Default::default()
                });
            }

            if !assistant_parts.is_empty() {
                let mut sessions = sessions.lock().await;
                if let Some(session) = sessions.get_mut(&session_id_for_task) {
                    session.updated_at = KimiWireAgent::now_ms();
                    if let Some(percent) = context_usage {
                        session.context_usage = Some(AiSessionContextUsage {
                            context_remaining_percent: Some(percent),
                        });
                    }
                    session.messages.push(AiMessage {
                        id: assistant_message_id,
                        role: "assistant".to_string(),
                        created_at: Some(KimiWireAgent::now_ms()),
                        agent: selection_hint_for_task.agent.clone(),
                        model_provider_id: selection_hint_for_task.model_provider_id.clone(),
                        model_id: selection_hint_for_task.model_id.clone(),
                        parts: assistant_parts,
                    });
                }
            }

            active_turns.lock().await.remove(&runtime_key_for_task);
            KimiWireAgent::clear_pending_approvals_for_runtime_in_map(
                &pending_approvals,
                &runtime_key_for_task,
            )
            .await;
        });

        Ok(Box::pin(UnboundedReceiverStream::new(rx)))
    }

    async fn list_session_config_options(
        &self,
        _directory: &str,
        _session_id: Option<&str>,
    ) -> Result<Vec<AiSessionConfigOption>, String> {
        Ok(vec![])
    }

    async fn set_session_config_option(
        &self,
        _directory: &str,
        _session_id: &str,
        _option_id: &str,
        _value: AiSessionConfigValue,
    ) -> Result<(), String> {
        Err("Kimi Wire 当前不支持会话配置项".to_string())
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        let normalized = Self::normalize_directory(directory);
        let mut sessions = self
            .sessions
            .lock()
            .await
            .values()
            .filter(|session| session.directory == normalized)
            .map(|session| AiSession {
                id: session.id.clone(),
                title: session.title.clone(),
                updated_at: session.updated_at,
            })
            .collect::<Vec<_>>();
        sessions.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        Ok(sessions)
    }

    async fn delete_session(&self, directory: &str, session_id: &str) -> Result<(), String> {
        let runtime_key = Self::runtime_key(directory, session_id);
        if let Some(runtime) = self.runtimes.lock().await.remove(&runtime_key) {
            let _ = runtime.client.stop().await;
        }
        self.active_turns.lock().await.remove(&runtime_key);
        self.sessions.lock().await.remove(session_id);
        self.clear_pending_approvals_for_runtime(&runtime_key).await;
        Ok(())
    }

    async fn list_messages(
        &self,
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String> {
        let normalized = Self::normalize_directory(directory);
        let session = self
            .sessions
            .lock()
            .await
            .get(session_id)
            .cloned()
            .ok_or_else(|| format!("Kimi session not found: {}", session_id))?;

        if session.directory != normalized {
            return Err(format!(
                "Kimi session directory mismatch: session_id={}, expected={}, got={}",
                session_id, session.directory, normalized
            ));
        }

        let mut messages = session.messages;
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
        let normalized = Self::normalize_directory(directory);
        let session = self
            .sessions
            .lock()
            .await
            .get(session_id)
            .cloned()
            .ok_or_else(|| format!("Kimi session not found: {}", session_id))?;

        if session.directory != normalized {
            return Ok(None);
        }

        if session.selection_hint.agent.is_none()
            && session.selection_hint.model_provider_id.is_none()
            && session.selection_hint.model_id.is_none()
        {
            Ok(None)
        } else {
            Ok(Some(session.selection_hint))
        }
    }

    async fn abort_session(&self, directory: &str, session_id: &str) -> Result<(), String> {
        let runtime_key = Self::runtime_key(directory, session_id);
        let runtime = {
            let runtimes = self.runtimes.lock().await;
            runtimes.get(&runtime_key).cloned()
        };
        if let Some(runtime) = runtime {
            if let Err(err) = runtime.client.cancel().await {
                warn!(
                    "Kimi Wire cancel failed: session_id={}, runtime_key={}, error={}",
                    session_id, runtime_key, err
                );
            }
        }
        self.clear_pending_approvals_for_runtime(&runtime_key).await;
        Ok(())
    }

    async fn dispose_instance(&self, directory: &str) -> Result<(), String> {
        let normalized = Self::normalize_directory(directory);
        let targets = {
            let runtimes = self.runtimes.lock().await;
            runtimes
                .iter()
                .filter(|(key, _)| key.starts_with(&(normalized.clone() + "::")))
                .map(|(key, runtime)| (key.clone(), runtime.clone()))
                .collect::<Vec<_>>()
        };

        for (key, runtime) in targets {
            let _ = runtime.client.stop().await;
            self.runtimes.lock().await.remove(&key);
            self.active_turns.lock().await.remove(&key);
            self.clear_pending_approvals_for_runtime(&key).await;
        }
        Ok(())
    }

    async fn get_session_status(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<AiSessionStatus, String> {
        let runtime_key = Self::runtime_key(directory, session_id);
        if self.active_turns.lock().await.contains(&runtime_key) {
            Ok(AiSessionStatus::Busy)
        } else {
            Ok(AiSessionStatus::Idle)
        }
    }

    async fn get_session_context_usage(
        &self,
        _directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionContextUsage>, String> {
        Ok(self
            .sessions
            .lock()
            .await
            .get(session_id)
            .and_then(|session| session.context_usage.clone()))
    }

    async fn list_providers(&self, _directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        Ok(vec![AiProviderInfo {
            id: "kimi".to_string(),
            name: "Kimi".to_string(),
            models: vec![AiModelInfo {
                id: "default".to_string(),
                name: "Default".to_string(),
                provider_id: "kimi".to_string(),
                supports_image_input: false,
            }],
        }])
    }

    async fn list_agents(&self, _directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        Ok(vec![AiAgentInfo {
            name: "agent".to_string(),
            description: Some("Kimi Wire 默认代理".to_string()),
            mode: Some("primary".to_string()),
            color: Some("blue".to_string()),
            default_provider_id: Some("kimi".to_string()),
            default_model_id: Some("default".to_string()),
        }])
    }

    async fn list_slash_commands(
        &self,
        directory: &str,
        session_id: Option<&str>,
    ) -> Result<Vec<AiSlashCommand>, String> {
        if let Some(session_id) = session_id {
            let runtime_key = Self::runtime_key(directory, session_id);
            if let Some(runtime) = self.runtimes.lock().await.get(&runtime_key).cloned() {
                return Ok(runtime.client.slash_commands().await);
            }
        }

        let normalized = Self::normalize_directory(directory);
        let candidate = {
            let runtimes = self.runtimes.lock().await;
            runtimes
                .iter()
                .find(|(key, _)| key.starts_with(&(normalized.clone() + "::")))
                .map(|(_, runtime)| runtime.clone())
        };

        if let Some(runtime) = candidate {
            return Ok(runtime.client.slash_commands().await);
        }
        Ok(vec![])
    }

    async fn reply_question(
        &self,
        _directory: &str,
        request_id: &str,
        answers: Vec<Vec<String>>,
    ) -> Result<(), String> {
        let pending = self
            .pending_approvals
            .lock()
            .await
            .remove(request_id)
            .ok_or_else(|| format!("Unknown Kimi approval request: {}", request_id))?;

        let runtime = self
            .runtimes
            .lock()
            .await
            .get(&pending.runtime_key)
            .cloned()
            .ok_or_else(|| format!("Kimi runtime not found for request: {}", request_id))?;

        let approved = Self::select_approval_from_answers(answers);
        debug!(
            "Kimi approval response: request_id={}, approved={}",
            pending.request_id, approved
        );
        runtime
            .client
            .respond_approval(pending.jsonrpc_id, approved, pending.request_id)
            .await
    }

    async fn reject_question(&self, _directory: &str, request_id: &str) -> Result<(), String> {
        let pending = self
            .pending_approvals
            .lock()
            .await
            .remove(request_id)
            .ok_or_else(|| format!("Unknown Kimi approval request: {}", request_id))?;

        let runtime = self
            .runtimes
            .lock()
            .await
            .get(&pending.runtime_key)
            .cloned()
            .ok_or_else(|| format!("Kimi runtime not found for request: {}", request_id))?;

        runtime
            .client
            .respond_approval(pending.jsonrpc_id, false, pending.request_id)
            .await
    }
}
