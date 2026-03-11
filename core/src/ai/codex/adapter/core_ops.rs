use super::*;

impl CodexAppServerAgent {
    const CONTEXT_BASELINE_TOKENS: f64 = 12_000.0;

    pub fn new(manager: Arc<CodexAppServerManager>) -> Self {
        Self {
            client: CodexAppServerClient::new(manager),
            pending_approvals: Arc::new(Mutex::new(HashMap::new())),
            active_turns: Arc::new(Mutex::new(HashMap::new())),
            selection_hints: Arc::new(Mutex::new(HashMap::new())),
            context_usage_by_session: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub(super) fn compute_remaining_percent(
        tokens_in_context_window: f64,
        context_window: f64,
    ) -> Option<f64> {
        if !tokens_in_context_window.is_finite() || !context_window.is_finite() {
            return None;
        }
        let baseline = Self::CONTEXT_BASELINE_TOKENS;
        if context_window <= baseline {
            return Some(0.0);
        }
        let effective_window = context_window - baseline;
        let used = (tokens_in_context_window - baseline).max(0.0);
        let remaining = (effective_window - used).max(0.0);
        Some(((remaining / effective_window) * 100.0).clamp(0.0, 100.0))
    }

    pub(super) fn json_value_to_f64(value: Option<&Value>) -> Option<f64> {
        match value {
            Some(Value::Number(n)) => n.as_f64(),
            Some(Value::String(s)) => s.trim().parse::<f64>().ok(),
            _ => None,
        }
    }

    pub(super) fn append_audio_fallback_text(
        message: &str,
        audio_parts: Option<&[AiAudioPart]>,
    ) -> String {
        shared_append_audio_fallback_text(message, audio_parts)
    }

    pub(super) fn extract_context_usage_from_notification(
        method: &str,
        params: &Value,
    ) -> Option<(String, AiSessionContextUsage)> {
        match method {
            "thread/tokenUsage/updated" => {
                let session_id = params.get("threadId")?.as_str()?.to_string();
                let total_tokens = Self::json_value_to_f64(
                    params
                        .pointer("/tokenUsage/last/totalTokens")
                        .or_else(|| params.pointer("/tokenUsage/total/totalTokens")),
                )?;
                let context_window =
                    Self::json_value_to_f64(params.pointer("/tokenUsage/modelContextWindow"))?;
                let percent = Self::compute_remaining_percent(total_tokens, context_window)?;
                Some((
                    session_id,
                    AiSessionContextUsage {
                        context_remaining_percent: Some(percent),
                    },
                ))
            }
            "codex/event/token_count" => {
                let session_id = params.get("conversationId")?.as_str()?.to_string();
                let total_tokens = Self::json_value_to_f64(
                    params
                        .pointer("/msg/info/last_token_usage/total_tokens")
                        .or_else(|| params.pointer("/msg/info/total_token_usage/total_tokens")),
                )?;
                let context_window = Self::json_value_to_f64(
                    params
                        .pointer("/msg/info/model_context_window")
                        .or_else(|| params.pointer("/msg/model_context_window")),
                )?;
                let percent = Self::compute_remaining_percent(total_tokens, context_window)?;
                Some((
                    session_id,
                    AiSessionContextUsage {
                        context_remaining_percent: Some(percent),
                    },
                ))
            }
            _ => None,
        }
    }

    pub(super) async fn update_context_usage_cache(
        cache: &Arc<Mutex<HashMap<String, AiSessionContextUsage>>>,
        method: &str,
        params: &Value,
    ) {
        if let Some((session_id, usage)) =
            Self::extract_context_usage_from_notification(method, params)
        {
            cache.lock().await.insert(session_id, usage);
        }
    }

    pub(super) fn selection_hint_from_thread_payload(
        value: &Value,
    ) -> Option<AiSessionSelectionHint> {
        selection_hint::selection_hint_from_thread_payload(value)
    }

    pub(super) fn request_id_key(id: &Value) -> String {
        shared_request_id_key(id)
    }

    pub(super) fn canonical_method(method: &str) -> String {
        method
            .chars()
            .filter(|ch| ch.is_ascii_alphanumeric())
            .flat_map(|ch| ch.to_lowercase())
            .collect::<String>()
    }

    pub(super) fn method_in(method: &str, candidates: &[&str]) -> bool {
        let canonical = Self::canonical_method(method);
        candidates
            .iter()
            .any(|candidate| canonical == Self::canonical_method(candidate))
    }

    pub(super) fn first_string_by_pointers(value: &Value, pointers: &[&str]) -> Option<String> {
        pointers.iter().find_map(|pointer| {
            value
                .pointer(pointer)
                .and_then(|v| shared_json_value_to_trimmed_string(v))
        })
    }

    pub(super) fn should_ignore_error_notification(params: &Value) -> bool {
        if params
            .pointer("/willRetry")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            return true;
        }
        if params
            .pointer("/will_retry")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            return true;
        }
        false
    }

    pub(super) fn build_question_prompt_part(request: &AiQuestionRequest) -> (String, AiPart) {
        question::build_question_prompt_part(request)
    }

    pub(super) fn parse_model_selection(
        model: Option<AiModelSelection>,
    ) -> (Option<String>, Option<String>) {
        match model {
            Some(m) => (Some(m.model_id), Some(m.provider_id)),
            None => (None, None),
        }
    }

    pub(super) fn normalize_model_variant(value: &str) -> Option<String> {
        let normalized = value.trim().to_lowercase();
        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    }

    pub(super) fn default_model(models: &[CodexModelInfo]) -> Option<CodexModelInfo> {
        models
            .iter()
            .find(|m| m.is_default)
            .or_else(|| models.first())
            .cloned()
    }

    pub(super) fn resolve_model_by_id(
        models: &[CodexModelInfo],
        model_id: Option<&str>,
    ) -> Option<CodexModelInfo> {
        let selected = model_id
            .map(str::trim)
            .filter(|candidate| !candidate.is_empty())
            .and_then(|candidate| {
                models
                    .iter()
                    .find(|m| {
                        m.id.eq_ignore_ascii_case(candidate)
                            || m.model.eq_ignore_ascii_case(candidate)
                    })
                    .cloned()
            });
        selected.or_else(|| Self::default_model(models))
    }

    pub(super) fn model_variants(model: &CodexModelInfo) -> Vec<String> {
        let mut variants = Vec::new();
        for effort in &model.supported_reasoning_efforts {
            if !variants.contains(&effort.value) {
                variants.push(effort.value.clone());
            }
        }
        if variants.is_empty() {
            if let Some(default_effort) = model
                .default_reasoning_effort
                .as_deref()
                .and_then(Self::normalize_model_variant)
            {
                variants.push(default_effort);
            }
        }
        variants
    }

    pub(super) fn resolve_model_variant_current_value(
        model: &CodexModelInfo,
        requested_value: Option<&serde_json::Value>,
    ) -> Option<String> {
        let allowed = Self::model_variants(model);
        if allowed.is_empty() {
            return None;
        }

        requested_value
            .and_then(|value| value.as_str())
            .and_then(Self::normalize_model_variant)
            .filter(|value| allowed.iter().any(|candidate| candidate == value))
            .or_else(|| {
                model
                    .default_reasoning_effort
                    .as_deref()
                    .and_then(Self::normalize_model_variant)
                    .filter(|value| allowed.iter().any(|candidate| candidate == value))
            })
    }

    pub(super) fn build_model_variant_option(
        model: &CodexModelInfo,
        current_value: Option<&serde_json::Value>,
    ) -> Option<AiSessionConfigOption> {
        let variants = Self::model_variants(model);
        if variants.is_empty() {
            return None;
        }

        let options = variants
            .iter()
            .map(|variant| {
                let description = model
                    .supported_reasoning_efforts
                    .iter()
                    .find(|effort| effort.value == *variant)
                    .and_then(|effort| effort.description.clone());
                AiSessionConfigOptionChoice {
                    value: serde_json::json!(variant),
                    label: variant.clone(),
                    description,
                }
            })
            .collect();

        Some(AiSessionConfigOption {
            option_id: "model_variant".to_string(),
            category: Some("model_variant".to_string()),
            name: "模型变体".to_string(),
            description: Some(
                model
                    .description
                    .clone()
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or_else(|| format!("控制 {} 的推理深度。", model.display_name)),
            ),
            current_value: Self::resolve_model_variant_current_value(model, current_value)
                .map(serde_json::Value::String),
            options,
            option_groups: vec![],
            raw: None,
        })
    }

    pub(super) fn parse_collaboration_mode(agent: Option<&str>) -> Option<String> {
        let normalized = agent?.trim().to_lowercase();
        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    }

    pub(super) fn is_thread_not_found_error(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("thread not found")
    }

    pub(super) fn map_item_to_part(item: &Value, status: &str) -> Option<AiPart> {
        tool_mapping::map_item_to_part(item, status)
    }

    pub(super) fn parse_user_text(item: &Value) -> String {
        tool_mapping::parse_user_text(item)
    }

    pub(super) fn render_turn_plan_update(params: &Value) -> String {
        stream::render_turn_plan_update(params)
    }

    pub(super) fn extract_tool_output_delta(
        method: &str,
        params: &Value,
    ) -> Option<(String, String, String)> {
        stream::extract_tool_output_delta(method, params)
    }

    /// Codex 事件名在版本迭代中可能变化，这里为未知 delta 事件提供文本兜底映射。
    pub(super) fn extract_generic_text_delta(
        method: &str,
        params: &Value,
    ) -> Option<(String, String, String, String)> {
        stream::extract_generic_text_delta(method, params)
    }

    pub(super) fn user_message_id(session_id: &str, turn_id: &str) -> String {
        stream::user_message_id(session_id, turn_id)
    }

    pub(super) fn assistant_message_id(session_id: &str, turn_id: &str) -> String {
        stream::assistant_message_id(session_id, turn_id)
    }

    pub(super) fn map_turn_items_to_messages(
        session_id: &str,
        turn_id: &str,
        items: &[Value],
        pending_request_id_by_item_id: &HashMap<String, String>,
    ) -> Vec<AiMessage> {
        stream::map_turn_items_to_messages(
            session_id,
            turn_id,
            items,
            pending_request_id_by_item_id,
        )
    }

    pub(super) fn normalize_filename(name: &str) -> String {
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

    pub(super) fn build_question_from_request(
        method: &str,
        request_id: &str,
        params: &Value,
    ) -> Option<(AiQuestionRequest, Vec<String>)> {
        question::build_question_from_request(method, request_id, params)
    }

    pub(super) async fn build_turn_stream(
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
        let context_usage_by_session = self.context_usage_by_session.clone();
        let client = self.client.clone();
        let user_message_id = Self::user_message_id(&session_id, &turn_id);
        let assistant_message_id = Self::assistant_message_id(&session_id, &turn_id);
        let _ = tx.send(Ok(AiEvent::MessageUpdated {
            message_id: user_message_id.clone(),
            role: "user".to_string(),
            selection_hint: None,
        }));
        let _ = tx.send(Ok(AiEvent::PartUpdated {
            message_id: user_message_id.clone(),
            part: AiPart::new_text(format!("{}-text", user_message_id), original_text.clone()),
        }));

        tokio::spawn(async move {
            let mut assistant_announced = false;
            loop {
                tokio::select! {
                    recv = notifications.recv() => {
                        match recv {
                            Ok(event) => {
                                let params = event.params.unwrap_or(Value::Null);
                                Self::update_context_usage_cache(
                                    &context_usage_by_session,
                                    &event.method,
                                    &params,
                                )
                                .await;
                                let thread_id = Self::first_string_by_pointers(
                                    &params,
                                    &["/threadId", "/thread_id", "/sessionId", "/session_id"],
                                )
                                .unwrap_or_default();
                                let event_turn_id = Self::first_string_by_pointers(
                                    &params,
                                    &["/turnId", "/turn_id"],
                                )
                                .unwrap_or_default();
                                if thread_id != session_id || (!event_turn_id.is_empty() && event_turn_id != turn_id) {
                                    continue;
                                }
                                match event.method.as_str() {
                                    "item/agentMessage/delta" => {
                                        let item_id = params.get("itemId").and_then(|v| v.as_str()).unwrap_or("");
                                        if item_id.is_empty() {
                                            continue;
                                        }
                                        if !assistant_announced {
                                            assistant_announced = true;
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: assistant_message_id.clone(),
                                                role: "assistant".to_string(),
                                                selection_hint: None,
                                            }));
                                        }
                                        if let Some(delta) = params.get("delta").and_then(|v| v.as_str()) {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
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
                                        if !assistant_announced {
                                            assistant_announced = true;
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: assistant_message_id.clone(),
                                                role: "assistant".to_string(),
                                                selection_hint: None,
                                            }));
                                        }
                                        if let Some(delta) = params.get("delta").and_then(|v| v.as_str()) {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
                                                part_id: item_id.to_string(),
                                                part_type: "reasoning".to_string(),
                                                field: "text".to_string(),
                                                delta: delta.to_string(),
                                            }));
                                        }
                                    }
                                    "item/commandExecution/outputDelta"
                                    | "item/commandExecution/terminalInteraction"
                                    | "item/fileChange/outputDelta"
                                    | "item/mcpToolCall/progress" => {
                                        let Some((item_id, field, payload)) =
                                            CodexAppServerAgent::extract_tool_output_delta(
                                                event.method.as_str(),
                                                &params,
                                            ) else {
                                                continue;
                                            };
                                        if !assistant_announced {
                                            assistant_announced = true;
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: assistant_message_id.clone(),
                                                role: "assistant".to_string(),
                                                selection_hint: None,
                                            }));
                                        }
                                        let _ = tx.send(Ok(AiEvent::PartDelta {
                                            message_id: assistant_message_id.clone(),
                                            part_id: item_id,
                                            part_type: "tool".to_string(),
                                            field,
                                            delta: payload,
                                        }));
                                    }
                                    "item/plan/delta" => {
                                        let item_id = params
                                            .get("itemId")
                                            .or_else(|| params.get("item_id"))
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("");
                                        if item_id.is_empty() {
                                            continue;
                                        }
                                        if !assistant_announced {
                                            assistant_announced = true;
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: assistant_message_id.clone(),
                                                role: "assistant".to_string(),
                                                selection_hint: None,
                                            }));
                                        }
                                        if let Some(delta) = params.get("delta").and_then(|v| v.as_str()) {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
                                                part_id: item_id.to_string(),
                                                part_type: "text".to_string(),
                                                field: "text".to_string(),
                                                delta: delta.to_string(),
                                            }));
                                        }
                                    }
                                    "turn/plan/updated" => {
                                        let part_id = format!("{}-plan-summary", assistant_message_id);
                                        if !assistant_announced {
                                            assistant_announced = true;
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: assistant_message_id.clone(),
                                                role: "assistant".to_string(),
                                                selection_hint: None,
                                            }));
                                        }
                                        let _ = tx.send(Ok(AiEvent::PartUpdated {
                                            message_id: assistant_message_id.clone(),
                                            part: AiPart::new_text(
                                                part_id,
                                                CodexAppServerAgent::render_turn_plan_update(&params),
                                            ),
                                        }));
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
                                        if !assistant_announced {
                                            assistant_announced = true;
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: assistant_message_id.clone(),
                                                role: "assistant".to_string(),
                                                selection_hint: None,
                                            }));
                                        }
                                        let status = if event.method == "item/started" {
                                            "running"
                                        } else {
                                            "completed"
                                        };
                                        if let Some(part) = CodexAppServerAgent::map_item_to_part(item, status) {
                                            let _ = tx.send(Ok(AiEvent::PartUpdated {
                                                message_id: assistant_message_id.clone(),
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
                                        if Self::should_ignore_error_notification(&params) {
                                            info!(
                                                "Codex transient stream warning ignored: session_id={}, turn_id={}, message={}",
                                                session_id, turn_id, message
                                            );
                                            continue;
                                        }
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
                                        // 获取真实用户消息内容
                                        let real_user_text = match client.thread_read(&session_id, true).await {
                                            Ok(thread_data) => {
                                                let found = thread_data
                                                    .get("thread")
                                                    .and_then(|v| v.get("turns"))
                                                    .and_then(|v| v.as_array())
                                                    .and_then(|turns| {
                                                        turns.iter().find(|t| {
                                                            t.get("id")
                                                                .and_then(|v| v.as_str())
                                                                .unwrap_or_default()
                                                                == turn_id
                                                        })
                                                    })
                                                    .and_then(|turn| turn.get("items"))
                                                    .and_then(|v| v.as_array())
                                                    .and_then(|items| {
                                                        items.iter().find(|item| {
                                                            item.get("type")
                                                                .and_then(|v| v.as_str())
                                                                .unwrap_or_default()
                                                                .eq_ignore_ascii_case("usermessage")
                                                        })
                                                    })
                                                    .map(|item| Self::parse_user_text(item));
                                                found.unwrap_or_else(|| original_text.clone())
                                            }
                                            Err(e) => {
                                                warn!("Failed to fetch real user message from thread_read: {}", e);
                                                original_text.clone()
                                            }
                                        };
                                        let _ = tx.send(Ok(AiEvent::PartUpdated {
                                            message_id: user_message_id.clone(),
                                            part: AiPart::new_text(format!("{}-text", user_message_id), real_user_text),
                                        }));
                                        let _ = tx.send(Ok(AiEvent::Done { stop_reason: None }));
                                        active_turns.lock().await.remove(&session_id);
                                        break;
                                    }
                                    _ => {
                                        if let Some((_message_id, part_id, part_type, delta)) =
                                            CodexAppServerAgent::extract_generic_text_delta(
                                                event.method.as_str(),
                                                &params,
                                            )
                                        {
                                            if !assistant_announced {
                                                assistant_announced = true;
                                                let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                    message_id: assistant_message_id.clone(),
                                                    role: "assistant".to_string(),
                                                    selection_hint: None,
                                                }));
                                            }
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
                                                part_id,
                                                part_type,
                                                field: "text".to_string(),
                                                delta,
                                            }));
                                        }
                                    }
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
                                let thread_id = CodexAppServerAgent::first_string_by_pointers(
                                    &params,
                                    &["/threadId", "/thread_id", "/sessionId", "/session_id"],
                                )
                                .unwrap_or_default();
                                let request_turn_id = CodexAppServerAgent::first_string_by_pointers(
                                    &params,
                                    &["/turnId", "/turn_id"],
                                )
                                .unwrap_or_default();
                                if thread_id != session_id {
                                    continue;
                                }
                                if !request_turn_id.is_empty()
                                    && request_turn_id != turn_id
                                    && !CodexAppServerAgent::method_in(
                                        req.method.as_str(),
                                        &[
                                            "item/tool/requestUserInput",
                                            "item/tool/request_user_input",
                                            "tool/requestUserInput",
                                            "tool/request_user_input",
                                            "item/commandExecution/requestApproval",
                                            "item/command_execution/request_approval",
                                            "item/fileChange/requestApproval",
                                            "item/file_change/request_approval",
                                        ],
                                    )
                                {
                                    continue;
                                }
                                let request_key = CodexAppServerAgent::request_id_key(&req.id);
                                debug!(
                                    "Codex server request: method={}, request_key={}, thread_id={}, turn_id={}, params={}",
                                    req.method,
                                    request_key,
                                    thread_id,
                                    request_turn_id,
                                    params
                                );
                                if let Some((question, question_ids)) = CodexAppServerAgent::build_question_from_request(&req.method, &request_key, &params) {
                                    let (question_message_id, question_part) =
                                        CodexAppServerAgent::build_question_prompt_part(&question);
                                    let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                        message_id: question_message_id.clone(),
                                        role: "assistant".to_string(),
                                        selection_hint: None,
                                    }));
                                    let _ = tx.send(Ok(AiEvent::PartUpdated {
                                        message_id: question_message_id.clone(),
                                        part: question_part,
                                    }));
                                    let pending = PendingApproval {
                                        id: req.id,
                                        method: req.method.clone(),
                                        question_ids,
                                        session_id: question.session_id.clone(),
                                        tool_message_id: Some(question_message_id),
                                    };
                                    approvals.lock().await.insert(
                                        request_key.clone(),
                                        pending,
                                    );
                                    let _ = tx.send(Ok(AiEvent::QuestionAsked { request: question }));
                                } else {
                                    if CodexAppServerAgent::method_in(
                                        req.method.as_str(),
                                        &[
                                            "item/tool/requestUserInput",
                                            "item/tool/request_user_input",
                                            "tool/requestUserInput",
                                            "tool/request_user_input",
                                        ],
                                    ) {
                                        warn!(
                                            "Codex request_user_input parse failed: request_key={}, params={}",
                                            request_key, params
                                        );
                                    }
                                    warn!(
                                        "Codex approval request ignored: method={}, request_key={}",
                                        req.method, request_key
                                    );
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

    pub(super) fn provider_from_models(models: Vec<CodexModelInfo>) -> Vec<AiProviderInfo> {
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
                variants: Self::model_variants(&m),
            })
            .collect::<Vec<_>>();
        vec![AiProviderInfo {
            id: "codex".to_string(),
            name: "Codex".to_string(),
            models: mapped,
        }]
    }
}
