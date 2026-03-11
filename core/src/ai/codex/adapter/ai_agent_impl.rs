use super::*;
use async_trait::async_trait;

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
        audio_parts: Option<Vec<AiAudioPart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
    ) -> Result<AiEventStream, String> {
        self.client.ensure_started().await?;

        let effective_message = Self::append_audio_fallback_text(message, audio_parts.as_deref());
        let mut input = vec![CodexAppServerClient::text_input(&effective_message)];
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
        let outbound_hint = AiSessionSelectionHint {
            agent: collaboration_mode.clone(),
            model_provider_id: model_provider.clone(),
            model_id: model_id.clone(),
            config_options: None,
        };
        let turn_id = match self
            .client
            .turn_start(
                session_id,
                input.clone(),
                model_id.clone(),
                model_provider.clone(),
                collaboration_mode.clone(),
                None,
            )
            .await
        {
            Ok(turn_id) => turn_id,
            Err(err) if Self::is_thread_not_found_error(&err) => {
                let resume = self.client.thread_resume(directory, session_id).await?;
                if let Some(hint) = Self::selection_hint_from_thread_payload(&resume) {
                    self.selection_hints
                        .lock()
                        .await
                        .insert(session_id.to_string(), hint.clone());
                    info!(
                        "Codex session hint from thread/resume: session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
                        session_id, hint.agent, hint.model_provider_id, hint.model_id
                    );
                }
                self.client
                    .turn_start(
                        session_id,
                        input,
                        model_id,
                        model_provider,
                        collaboration_mode,
                        None,
                    )
                    .await?
            }
            Err(err) => return Err(err),
        };
        if outbound_hint.agent.is_some()
            || outbound_hint.model_provider_id.is_some()
            || outbound_hint.model_id.is_some()
            || outbound_hint.config_options.is_some()
        {
            self.selection_hints
                .lock()
                .await
                .insert(session_id.to_string(), outbound_hint);
        }
        self.active_turns
            .lock()
            .await
            .insert(session_id.to_string(), turn_id.clone());

        self.build_turn_stream(session_id.to_string(), turn_id, effective_message)
            .await
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        self.client.ensure_started().await?;
        let sessions = self.client.thread_list(directory, 500).await?;
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
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String> {
        self.client.ensure_started().await?;
        let response = self.client.thread_read(session_id, true).await?;
        if let Some(hint) = Self::selection_hint_from_thread_payload(&response) {
            self.selection_hints
                .lock()
                .await
                .insert(session_id.to_string(), hint.clone());
            info!(
                "Codex session hint from thread/read(history): session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
                session_id, hint.agent, hint.model_provider_id, hint.model_id
            );
        } else {
            debug!(
                "Codex thread/read(history) returned no selection hint: directory={}, session_id={}",
                directory, session_id
            );
        }
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
            messages.extend(Self::map_turn_items_to_messages(
                session_id,
                &turn_id,
                &items,
                &pending_request_id_by_item_id,
            ));
        }
        if let Some(limit) = limit {
            let keep = limit as usize;
            if keep == 0 {
                messages.clear();
            } else if messages.len() > keep {
                messages = messages.split_off(messages.len() - keep);
            }
        }
        Ok(messages)
    }

    async fn session_selection_hint(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionSelectionHint>, String> {
        if let Some(hint) = self.selection_hints.lock().await.get(session_id).cloned() {
            debug!(
                "Codex session hint cache hit: session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
                session_id, hint.agent, hint.model_provider_id, hint.model_id
            );
            return Ok(Some(hint));
        }
        self.client.ensure_started().await?;
        match self.client.thread_read(session_id, false).await {
            Ok(read_response) => {
                let hint = Self::selection_hint_from_thread_payload(&read_response);
                if let Some(ref value) = hint {
                    self.selection_hints
                        .lock()
                        .await
                        .insert(session_id.to_string(), value.clone());
                    info!(
                        "Codex session hint resolved by thread/read: session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
                        session_id, value.agent, value.model_provider_id, value.model_id
                    );
                } else {
                    debug!(
                        "Codex thread/read returned no selection hint: directory={}, session_id={}",
                        directory, session_id
                    );
                }
                Ok(hint)
            }
            Err(err) => {
                warn!(
                    "Codex thread/read for selection hint failed: directory={}, session_id={}, error={}",
                    directory, session_id, err
                );
                Ok(None)
            }
        }
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
            AiSessionStatus::Running
        } else {
            AiSessionStatus::Idle
        })
    }

    async fn get_session_context_usage(
        &self,
        _directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionContextUsage>, String> {
        if let Some(cached) = self
            .context_usage_by_session
            .lock()
            .await
            .get(session_id)
            .cloned()
        {
            return Ok(Some(cached));
        }

        let thread = self.client.thread_read(session_id, true).await?;
        let usage = AiSessionContextUsage {
            context_remaining_percent: extract_context_remaining_percent(&thread),
        };
        if usage.context_remaining_percent.is_some() {
            self.context_usage_by_session
                .lock()
                .await
                .insert(session_id.to_string(), usage.clone());
        }
        Ok(Some(usage))
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

    async fn list_slash_commands(
        &self,
        _directory: &str,
        _session_id: Option<&str>,
    ) -> Result<Vec<AiSlashCommand>, String> {
        Ok(vec![
            AiSlashCommand {
                name: "new".to_string(),
                description: "新建会话".to_string(),
                action: "client".to_string(),
                input_hint: None,
            },
            AiSlashCommand {
                name: "code".to_string(),
                description: "生成或修改代码".to_string(),
                action: "agent".to_string(),
                input_hint: Some("<任务描述>".to_string()),
            },
            AiSlashCommand {
                name: "explain".to_string(),
                description: "解释代码或概念".to_string(),
                action: "agent".to_string(),
                input_hint: Some("<代码或概念>".to_string()),
            },
            AiSlashCommand {
                name: "fix".to_string(),
                description: "修复错误或问题".to_string(),
                action: "agent".to_string(),
                input_hint: Some("<错误描述>".to_string()),
            },
            AiSlashCommand {
                name: "review".to_string(),
                description: "审查代码质量与风格".to_string(),
                action: "agent".to_string(),
                input_hint: Some("<代码片段或文件路径>".to_string()),
            },
            AiSlashCommand {
                name: "ask".to_string(),
                description: "向 Codex 提问".to_string(),
                action: "agent".to_string(),
                input_hint: Some("<问题>".to_string()),
            },
        ])
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

        let response = if Self::method_in(
            pending.method.as_str(),
            &[
                "item/commandExecution/requestApproval",
                "item/command_execution/request_approval",
            ],
        ) {
            let decision = answers
                .first()
                .and_then(|a| a.first())
                .map(|s| s.to_lowercase())
                .unwrap_or_else(|| "accept".to_string());
            serde_json::json!({ "decision": decision })
        } else if Self::method_in(
            pending.method.as_str(),
            &[
                "item/fileChange/requestApproval",
                "item/file_change/request_approval",
            ],
        ) {
            let decision = answers
                .first()
                .and_then(|a| a.first())
                .map(|s| s.to_lowercase())
                .unwrap_or_else(|| "accept".to_string());
            serde_json::json!({ "decision": decision })
        } else if Self::method_in(
            pending.method.as_str(),
            &[
                "item/tool/requestUserInput",
                "item/tool/request_user_input",
                "tool/requestUserInput",
                "tool/request_user_input",
            ],
        ) {
            let mut answer_map = serde_json::Map::new();
            for (idx, qid) in pending.question_ids.iter().enumerate() {
                let ans = answers.get(idx).cloned().unwrap_or_default();
                answer_map.insert(qid.clone(), serde_json::json!({ "answers": ans }));
            }
            if answer_map.is_empty() {
                serde_json::json!({ "answers": answers })
            } else {
                serde_json::json!({ "answers": answer_map })
            }
        } else {
            warn!(
                "Unsupported Codex request method in reply_question: {}",
                pending.method
            );
            serde_json::json!({})
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

        let response = if Self::method_in(
            pending.method.as_str(),
            &[
                "item/commandExecution/requestApproval",
                "item/command_execution/request_approval",
                "item/fileChange/requestApproval",
                "item/file_change/request_approval",
            ],
        ) {
            serde_json::json!({ "decision": "cancel" })
        } else if Self::method_in(
            pending.method.as_str(),
            &[
                "item/tool/requestUserInput",
                "item/tool/request_user_input",
                "tool/requestUserInput",
                "tool/request_user_input",
            ],
        ) {
            serde_json::json!({ "answers": {} })
        } else {
            serde_json::json!({})
        };
        self.client
            .send_approval_response(pending.id, response)
            .await
    }

    /// Codex 静态模型变体配置项，用于在未接收到动态配置时提供 reasoning_effort 选项。
    async fn list_session_config_options(
        &self,
        _directory: &str,
        _session_id: Option<&str>,
    ) -> Result<Vec<AiSessionConfigOption>, String> {
        Ok(vec![AiSessionConfigOption {
            option_id: "model_variant".to_string(),
            category: Some("model_variant".to_string()),
            name: "模型变体".to_string(),
            description: Some("控制 Codex 推理深度：low 快速，medium 均衡，high 深入".to_string()),
            current_value: None,
            options: vec![
                AiSessionConfigOptionChoice {
                    value: serde_json::json!("low"),
                    label: "low".to_string(),
                    description: None,
                },
                AiSessionConfigOptionChoice {
                    value: serde_json::json!("medium"),
                    label: "medium".to_string(),
                    description: None,
                },
                AiSessionConfigOptionChoice {
                    value: serde_json::json!("high"),
                    label: "high".to_string(),
                    description: None,
                },
            ],
            option_groups: vec![],
            raw: None,
        }])
    }

    /// 支持 config_overrides 的发送消息，提取 model_variant 并写入 reasoning_effort。
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
        self.client.ensure_started().await?;

        let effective_message = Self::append_audio_fallback_text(message, audio_parts.as_deref());
        let mut input = vec![CodexAppServerClient::text_input(&effective_message)];
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

        // 从 config_overrides 中提取 model_variant 作为 reasoning_effort
        let reasoning_effort = config_overrides.as_ref().and_then(|overrides| {
            overrides
                .get("model_variant")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_lowercase())
                .filter(|s| matches!(s.as_str(), "low" | "medium" | "high"))
        });

        let (model_id, model_provider) = Self::parse_model_selection(model);
        let collaboration_mode = Self::parse_collaboration_mode(agent.as_deref());
        // 将 config_overrides 中的 model_variant 回写到 outbound_hint，保证会话恢复后能复现
        let outbound_config_options = reasoning_effort.as_ref().map(|effort| {
            let mut map = HashMap::new();
            map.insert("model_variant".to_string(), serde_json::json!(effort));
            map
        });
        let outbound_hint = AiSessionSelectionHint {
            agent: collaboration_mode.clone(),
            model_provider_id: model_provider.clone(),
            model_id: model_id.clone(),
            config_options: outbound_config_options,
        };
        let turn_id = match self
            .client
            .turn_start(
                session_id,
                input.clone(),
                model_id.clone(),
                model_provider.clone(),
                collaboration_mode.clone(),
                reasoning_effort.clone(),
            )
            .await
        {
            Ok(turn_id) => turn_id,
            Err(err) if Self::is_thread_not_found_error(&err) => {
                let resume = self.client.thread_resume(directory, session_id).await?;
                if let Some(hint) = Self::selection_hint_from_thread_payload(&resume) {
                    self.selection_hints
                        .lock()
                        .await
                        .insert(session_id.to_string(), hint.clone());
                    info!(
                        "Codex session hint from thread/resume (with_config): session_id={}, agent={:?}",
                        session_id, hint.agent
                    );
                }
                self.client
                    .turn_start(
                        session_id,
                        input,
                        model_id,
                        model_provider,
                        collaboration_mode,
                        reasoning_effort,
                    )
                    .await?
            }
            Err(err) => return Err(err),
        };
        if outbound_hint.agent.is_some()
            || outbound_hint.model_provider_id.is_some()
            || outbound_hint.model_id.is_some()
        {
            self.selection_hints
                .lock()
                .await
                .insert(session_id.to_string(), outbound_hint);
        }
        self.active_turns
            .lock()
            .await
            .insert(session_id.to_string(), turn_id.clone());

        self.build_turn_stream(session_id.to_string(), turn_id, effective_message)
            .await
    }
}
