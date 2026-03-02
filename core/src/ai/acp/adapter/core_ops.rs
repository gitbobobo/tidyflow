use super::*;

impl AcpAgent {
    pub(super) fn now_ms() -> i64 {
        Utc::now().timestamp_millis()
    }

    pub(super) fn normalized_title(raw: Option<&str>) -> Option<String> {
        cache::normalized_title(raw)
    }

    pub(super) async fn upsert_cached_session_in_map(
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

    pub(super) async fn append_cached_message_in_map(
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

    pub(super) async fn replace_cached_messages_in_map(
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

    pub(super) async fn upsert_cached_session(
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

    pub(super) async fn append_cached_message(
        &self,
        directory: &str,
        session_id: &str,
        message: AiMessage,
    ) {
        Self::append_cached_message_in_map(&self.cached_sessions, directory, session_id, message)
            .await;
    }

    pub(super) async fn replace_cached_messages(
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

    pub(super) async fn cached_messages_for_session(
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

    pub(super) async fn cached_sessions_for_directory(&self, directory: &str) -> Vec<AiSession> {
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

    pub(super) fn merge_sessions(remote: Vec<AiSession>, cached: Vec<AiSession>) -> Vec<AiSession> {
        cache::merge_sessions(remote, cached)
    }

    pub(super) fn build_cached_user_message(message_id: String, text: String) -> AiMessage {
        cache::build_cached_user_message(message_id, text, Self::now_ms())
    }

    pub(super) fn extract_plan_entries(update: &Value) -> Option<Vec<AcpPlanEntry>> {
        plan::extract_plan_entries(update)
    }

    pub(super) fn is_plan_update(session_update: &str) -> bool {
        plan::is_plan_update(session_update)
    }

    pub(super) fn apply_plan_update(
        current: &mut Option<AcpPlanSnapshot>,
        history: &mut Vec<AcpPlanSnapshot>,
        revision: &mut u64,
        entries: Vec<AcpPlanEntry>,
    ) -> AcpPlanSnapshot {
        plan::apply_plan_update(
            current,
            history,
            revision,
            entries,
            Self::PLAN_HISTORY_LIMIT,
            Self::now_ms(),
        )
    }

    pub(super) fn build_plan_part(
        message_id: &str,
        current: &AcpPlanSnapshot,
        history: &[AcpPlanSnapshot],
    ) -> AiPart {
        plan::build_plan_part(message_id, current, history)
    }

    pub(super) fn flush_plan_snapshot_for_history(
        messages: &mut Vec<AiMessage>,
        message_id_prefix: &str,
        next_message_index: &mut u64,
        plan_current: &mut Option<AcpPlanSnapshot>,
        plan_history: &mut Vec<AcpPlanSnapshot>,
    ) {
        plan::flush_plan_snapshot_for_history(
            messages,
            message_id_prefix,
            next_message_index,
            plan_current,
            plan_history,
            Self::now_ms(),
        )
    }

    pub(super) fn build_cached_assistant_message(
        message_id: String,
        reasoning_text: String,
        answer_text: String,
        plan_current: Option<AcpPlanSnapshot>,
        plan_history: Vec<AcpPlanSnapshot>,
    ) -> Option<AiMessage> {
        cache::build_cached_assistant_message(
            message_id,
            reasoning_text,
            answer_text,
            plan_current,
            plan_history,
            Self::now_ms(),
        )
    }

    pub(super) async fn cache_metadata(&self, directory: &str, metadata: AcpSessionMetadata) {
        self.metadata_by_directory
            .lock()
            .await
            .insert(Self::normalize_directory(directory), metadata);
    }

    pub(super) async fn cache_session_metadata(
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

    pub(super) async fn metadata_for_session(
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

    pub(super) async fn metadata_for_directory(&self, directory: &str) -> AcpSessionMetadata {
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

    pub(super) async fn list_sessions_for_directory(
        &self,
        directory: &str,
        max_pages: usize,
    ) -> Result<Vec<AcpSessionSummary>, String> {
        self.client.ensure_started().await?;
        let expected = Self::normalize_directory(directory);
        let mut sessions = Vec::new();
        let mut cursor: Option<String> = None;

        for _ in 0..max_pages {
            let (page, next_cursor) = self.client.session_list_page(directory, cursor.as_deref()).await?;
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

    pub(super) fn normalize_mode_name(raw: &str) -> String {
        metadata_state::normalize_mode_name(raw)
    }

    pub(super) fn normalize_non_empty_token(raw: &str) -> Option<String> {
        metadata_state::normalize_non_empty_token(raw)
    }

    pub(super) fn is_set_mode_unsupported(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("-32601")
            || normalized.contains("method not found")
            || normalized.contains("unknown method")
            || normalized.contains("not supported")
    }

    pub(super) fn is_set_config_option_unsupported(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("-32601")
            || normalized.contains("method not found")
            || normalized.contains("unknown method")
            || normalized.contains("not supported")
            || normalized.contains("set_config_option")
    }

    pub(super) fn is_rpc_method_unsupported(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("-32601")
            || normalized.contains("method not found")
            || normalized.contains("unknown method")
            || normalized.contains("not supported")
            || normalized.contains("unsupported")
    }

    pub(super) fn status_is_terminal(status: &str) -> bool {
        tool_call::status_is_terminal(status)
    }

    pub(super) fn log_unknown_content_type(tool_id: &str, context: &str, content_type: &str) {
        let count = UNKNOWN_CONTENT_TYPE_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
        warn!(
            "{}: unknown ACP content type in {}, type={}, count={}",
            tool_id, context, content_type, count
        );
    }

    pub(super) fn log_missing_tool_call_id(tool_id: &str, context: &str) {
        let count = TOOL_CALL_UPDATE_MISSING_ID_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
        warn!(
            "{}: tool_call_update missing toolCallId in {}, fallback to random part id, count={}",
            tool_id, context, count
        );
    }

    pub(super) fn log_follow_along_failure(tool_id: &str, operation: &str, detail: &str) {
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

    pub(super) fn parse_tool_call_update_event(
        update: &Value,
        session_update: &str,
    ) -> Option<ParsedToolCallUpdate> {
        tool_call::parse_tool_call_update_event(update, session_update)
    }

    pub(super) fn merge_tool_state(
        previous: Option<&Value>,
        parsed: &ParsedToolCallUpdate,
    ) -> Value {
        tool_call::merge_tool_state(previous, parsed)
    }

    pub(super) fn normalize_current_mode_update(raw: &str) -> bool {
        metadata_state::normalize_current_mode_update(raw)
    }

    pub(super) fn is_config_option_update(raw: &str) -> bool {
        metadata_state::is_config_option_update(raw)
    }

    pub(super) fn is_config_options_update(raw: &str) -> bool {
        metadata_state::is_config_options_update(raw)
    }

    pub(super) fn is_available_commands_update(raw: &str) -> bool {
        metadata_state::is_available_commands_update(raw)
    }

    pub(super) fn extract_available_command_hint(value: &Value) -> Option<String> {
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

    pub(super) fn parse_available_command(
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

    pub(super) fn looks_like_available_command(value: &Value) -> bool {
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

    pub(super) fn extract_available_commands(update: &Value) -> Vec<AiSlashCommand> {
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

    pub(super) fn extract_config_option_updates(update: &Value) -> Vec<(String, Value)> {
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

    pub(super) async fn cache_available_commands(
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

    pub(super) async fn slash_commands_for(
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

    pub(super) fn extract_current_mode_id(update: &Value) -> Option<String> {
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

    pub(super) fn apply_current_mode_to_metadata(metadata: &mut AcpSessionMetadata, mode_id: &str) {
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
            metadata.modes.push(crate::ai::acp::client::AcpModeInfo {
                id: resolved_mode_id.clone(),
                name: resolved_mode_id,
                description: None,
            });
        }
    }

    pub(super) async fn apply_current_mode_to_caches(
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

    pub(super) fn apply_current_model_to_metadata(
        metadata: &mut AcpSessionMetadata,
        model_id: &str,
    ) {
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
            metadata.models.push(crate::ai::acp::client::AcpModelInfo {
                id: resolved_model_id.clone(),
                name: resolved_model_id,
                supports_image_input: true,
            });
        }
    }

    pub(super) fn normalized_category(category: Option<&str>, option_id: &str) -> String {
        if let Some(category) = category.map(|it| it.trim().to_lowercase()) {
            if !category.is_empty() {
                return category;
            }
        }
        option_id.trim().to_lowercase()
    }

    pub(super) fn value_to_string(value: &Value) -> Option<String> {
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

    pub(super) fn resolve_choice_string(
        option: &AcpConfigOptionInfo,
        value: &Value,
    ) -> Option<String> {
        if let Some(raw) = Self::value_to_string(value) {
            return Some(raw);
        }
        option
            .options
            .iter()
            .find_map(|choice| Self::value_to_string(&choice.value))
    }

    pub(super) fn resolve_mode_id_from_option(
        option: &AcpConfigOptionInfo,
        value: &Value,
    ) -> Option<String> {
        let candidate = Self::resolve_choice_string(option, value)?;
        if !candidate.is_empty() {
            return Some(candidate);
        }
        None
    }

    pub(super) fn resolve_model_id_from_option(
        option: &AcpConfigOptionInfo,
        value: &Value,
    ) -> Option<String> {
        let candidate = Self::resolve_choice_string(option, value)?;
        if let Some((_, suffix)) = candidate.split_once('/') {
            let trimmed = suffix.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
        Some(candidate)
    }

    pub(super) fn apply_config_value_to_metadata(
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

    pub(super) async fn apply_config_value_to_caches(
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

    pub(super) fn session_config_values(
        metadata: &AcpSessionMetadata,
    ) -> Option<HashMap<String, Value>> {
        if metadata.config_values.is_empty() {
            return None;
        }
        Some(metadata.config_values.clone())
    }

    pub(super) fn resolve_mode_id(
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

    pub(super) fn current_agent_name(metadata: &AcpSessionMetadata) -> Option<String> {
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

    pub(super) fn map_config_option_choice(
        choice: &crate::ai::acp::client::AcpConfigOptionChoice,
    ) -> AiSessionConfigOptionChoice {
        AiSessionConfigOptionChoice {
            value: choice.value.clone(),
            label: choice.label.clone(),
            description: choice.description.clone(),
        }
    }

    pub(super) fn map_config_option_group(
        group: &crate::ai::acp::client::AcpConfigOptionGroup,
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

    pub(super) fn map_config_option(option: &AcpConfigOptionInfo) -> AiSessionConfigOption {
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

    pub(super) fn map_config_options(
        options: &[AcpConfigOptionInfo],
    ) -> Vec<AiSessionConfigOption> {
        options
            .iter()
            .map(Self::map_config_option)
            .collect::<Vec<_>>()
    }

    pub(super) fn selection_hint_from_metadata(
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

    pub(super) fn compose_prompt_parts(
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
        prompt_builder::compose_prompt_parts(
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
            Self::EMBED_TEXT_LIMIT_BYTES,
            Self::EMBED_BLOB_LIMIT_BYTES,
        )
    }

    pub(super) fn is_session_not_found(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("session") && normalized.contains("not found")
    }

    pub(super) fn is_session_already_loaded(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("session")
            && normalized.contains("already")
            && normalized.contains("loaded")
    }

    pub(super) fn resolve_permission_option_id(
        pending: &PendingPermission,
        answers: &[Vec<String>],
    ) -> Option<String> {
        permissions::resolve_permission_option_id(pending, answers)
    }

    pub(super) fn build_question_from_permission_request(
        request_id: &Value,
        params: &Value,
    ) -> Option<(AiQuestionRequest, Vec<PermissionOption>)> {
        permissions::build_question_from_permission_request(request_id, params)
    }

    pub(super) fn extract_update(event: &Value) -> Option<(String, String, String)> {
        stream_mapping::extract_update(event)
    }

    pub(super) fn map_content_to_non_text_parts(
        message_id: &str,
        content: &serde_json::Map<String, Value>,
    ) -> Vec<AiPart> {
        stream_mapping::map_content_to_non_text_parts(message_id, content)
    }

    pub(super) fn role_for_session_update(session_update: &str) -> &'static str {
        stream_mapping::role_for_session_update(session_update)
    }

    pub(super) fn push_structured_parts_message(
        messages: &mut Vec<AiMessage>,
        message_id_prefix: &str,
        role: &str,
        parts: Vec<AiPart>,
    ) {
        stream_mapping::push_structured_parts_message(messages, message_id_prefix, role, parts)
    }

    pub(super) fn map_update_to_output(session_update: &str) -> Option<(&'static str, bool)> {
        stream_mapping::map_update_to_output(session_update)
    }

    pub(super) fn normalized_update_token(raw: &str) -> String {
        stream_mapping::normalized_update_token(raw)
    }

    pub(super) fn is_terminal_update(session_update: &str, content_type: &str) -> bool {
        stream_mapping::is_terminal_update(session_update, content_type)
    }

    pub(super) fn is_error_update(session_update: &str, content_type: &str) -> bool {
        stream_mapping::is_error_update(session_update, content_type)
    }

    pub(super) fn parse_prompt_stop_reason(result: &Value) -> Result<String, String> {
        stream_mapping::parse_prompt_stop_reason(result)
    }

    pub(super) async fn reject_pending_permissions_for_session(
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

    pub(super) fn select_sessions_for_directory(
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

    pub(super) fn push_chunk_message(
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

    pub(super) async fn collect_loaded_messages(
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
                    if let Some(parsed) =
                        Self::parse_tool_call_update_event(update, &session_update)
                    {
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
                        let tool_state =
                            Self::merge_tool_state(history_tool_states.get(&part_id), &parsed);
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
                    if let Some(content) = update.get("content").and_then(|v| v.as_object()) {
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

    pub(super) async fn apply_config_overrides_before_send(
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
