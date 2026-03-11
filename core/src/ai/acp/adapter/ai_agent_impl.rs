use super::*;

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

        let mut metadata =
            if let Some(cached) = self.metadata_for_session(directory, session_id).await {
                cached
            } else {
                self.metadata_for_directory(directory).await
            };
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
        if let Some(target_mode_id) = mode_id.as_deref() {
            // `session_prompt` 直接携带的 mode 也应立即反映到本地缓存，
            // 否则后续 selection_hint / config_options 读取会短暂回退到旧默认值。
            Self::apply_current_mode_to_metadata(&mut metadata, target_mode_id);
        }
        if let Some(target_model_id) = model_id.as_deref() {
            // ACP 可能不会立刻回推 current_model_id；先以本次请求选择更新缓存，
            // 保持发送后的会话选择与输入栏展示一致。
            Self::apply_current_model_to_metadata(&mut metadata, target_model_id);
        }
        self.cache_metadata(directory, metadata.clone()).await;
        self.cache_session_metadata(directory, session_id, metadata.clone())
            .await;
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
            let mut current_chunk_part_type: Option<String> = None;
            let mut current_chunk_part_id: Option<String> = None;
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
                            Self::break_stream_chunk_part_sequence(
                                &mut current_chunk_part_type,
                                &mut current_chunk_part_id,
                            );
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

                        if let Some(parsed) =
                            Self::parse_tool_call_update_event(update, &session_update)
                        {
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

                            let tool_state =
                                Self::merge_tool_state(tool_states_by_part.get(&part_id), &parsed);
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

                            let tool_kind = parsed.tool_kind.as_deref();
                            if follow_along_supported
                                && crate::ai::acp::tool_call::tool_kind_is_terminal_like(tool_kind)
                            {
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
                            Self::break_stream_chunk_part_sequence(
                                &mut current_chunk_part_type,
                                &mut current_chunk_part_id,
                            );
                            continue;
                        }

                        if let Some(content) = update.get("content").and_then(|v| v.as_object()) {

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
                                    Self::break_stream_chunk_part_sequence(
                                        &mut current_chunk_part_type,
                                        &mut current_chunk_part_id,
                                    );
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
                                    Self::break_stream_chunk_part_sequence(
                                        &mut current_chunk_part_type,
                                        &mut current_chunk_part_id,
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
                        let part_id = Self::resolve_stream_chunk_part_id(
                            &assistant_message_id,
                            part_type,
                            &mut current_chunk_part_type,
                            &mut current_chunk_part_id,
                        );
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

        let mut merged_overrides = config_overrides.unwrap_or_default();
        if let Some(option_id) = Self::option_id_for_category(&metadata.config_options, "mode") {
            if let Some(selected_agent) = agent
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                merged_overrides.insert(option_id, serde_json::json!(selected_agent));
            }
        }
        if let Some(option_id) = Self::option_id_for_category(&metadata.config_options, "model") {
            if let Some(selected_model) = model.as_ref() {
                merged_overrides.insert(
                    option_id,
                    serde_json::json!(format!(
                        "{}/{}",
                        selected_model.provider_id, selected_model.model_id
                    )),
                );
            }
        }

        let (effective_model, effective_agent) = if !merged_overrides.is_empty() {
            self.apply_config_overrides_before_send(
                directory,
                session_id,
                &mut metadata,
                &merged_overrides,
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
        let value = Self::normalize_config_override_value(
            &metadata,
            option_meta.as_ref(),
            &category,
            value,
        );

        let set_result = if supports_set_config {
            match self
                .client
                .session_set_config_option(session_id, option_id, value.clone())
                .await
            {
                Ok(metadata_delta) => Ok(metadata_delta),
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
            Ok(metadata_delta) => {
                Self::merge_metadata_from_delta(&mut metadata, metadata_delta);
                Self::apply_config_value_to_metadata(&mut metadata, option_id, value.clone());
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
        let current_model_id = metadata.current_model_id.clone();
        let current_model_variants = metadata
            .config_options
            .iter()
            .find(|option| {
                Self::normalized_category(option.category.as_deref(), &option.option_id)
                    == "model_variant"
            })
            .map(Self::config_option_values)
            .unwrap_or_default();
        let mut models = metadata
            .models
            .into_iter()
            .map(|m| AiModelInfo {
                id: m.id.clone(),
                name: m.name,
                provider_id: provider_id.clone(),
                supports_image_input: m.supports_image_input,
                variants: if current_model_id
                    .as_ref()
                    .is_some_and(|current| current.eq_ignore_ascii_case(&m.id))
                {
                    current_model_variants.clone()
                } else {
                    vec![]
                },
            })
            .collect::<Vec<_>>();
        if models.is_empty() {
            models.push(AiModelInfo {
                id: "default".to_string(),
                name: "Default".to_string(),
                provider_id: provider_id.clone(),
                supports_image_input: true,
                variants: vec![],
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
