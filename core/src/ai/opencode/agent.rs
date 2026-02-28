use super::http_client::OpenCodeClient;
use super::protocol::MessageEnvelope;
use super::stream_mapping::map_opencode_hub_stream;
use super::{selection_hint, usage};
use crate::ai::context_usage::AiSessionContextUsage;

// ============================================================================
// OpenCodeAgent: 实现通用 AiAgent trait（单 serve + directory 路由）
// ============================================================================

use crate::ai::event_hub::OpenCodeEventHub;
use crate::ai::session_status::AiSessionStatus;
use crate::ai::{
    AiAgent, AiAgentInfo, AiAudioPart, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiSession, AiSlashCommand, OpenCodeManager,
};
use async_trait::async_trait;
use std::sync::Arc;

/// OpenCode 后端的 AiAgent 实现
///
/// 封装 OpenCodeManager（进程管理）+ OpenCodeClient（HTTP 通信），
/// 将 OpenCode 特有的 SSE 事件转换为通用 AiEvent。
pub struct OpenCodeAgent {
    manager: Arc<OpenCodeManager>,
    hub: Arc<OpenCodeEventHub>,
}

impl OpenCodeAgent {
    pub fn new(manager: Arc<OpenCodeManager>) -> Self {
        let hub = Arc::new(OpenCodeEventHub::new(manager.clone()));
        Self { manager, hub }
    }

    async fn verify_session_directory(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let session = client
            .get_session(directory, session_id)
            .await
            .map_err(|e| format!("Failed to fetch session info: {}", e))?;

        let expected = directory.trim_end_matches('/');
        let actual = session
            .directory
            .as_deref()
            .unwrap_or("")
            .trim_end_matches('/');

        if actual.is_empty() {
            return Err(format!(
                "Session '{}' missing directory; cannot verify workspace isolation",
                session_id
            ));
        }
        if actual != expected {
            return Err(format!(
                "Session '{}' does not belong to current workspace directory (expected='{}', actual='{}')",
                session_id, expected, actual
            ));
        }
        Ok(())
    }
}

#[async_trait]
impl AiAgent for OpenCodeAgent {
    async fn start(&self) -> Result<(), String> {
        self.manager.ensure_server_running().await?;
        self.hub.ensure_started().await?;
        Ok(())
    }

    async fn stop(&self) -> Result<(), String> {
        self.manager.stop_server().await
    }

    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let session = client
            .create_session(directory, title)
            .await
            .map_err(|e| format!("Failed to create session: {}", e))?;
        let updated_at = session.effective_updated_at();
        Ok(AiSession {
            id: session.id,
            title: session.title,
            updated_at,
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
        // 会话隔离：防止跨工作空间误用 session_id
        self.verify_session_directory(directory, session_id).await?;

        let client = OpenCodeClient::from_manager(&self.manager);

        // 1. 先订阅 Hub（避免丢首包）
        let rx = self.hub.subscribe();

        // 2. 异步发送消息（立即返回）
        client
            .send_message_async(
                directory,
                session_id,
                message,
                file_refs,
                image_parts,
                audio_parts,
                model,
                agent,
            )
            .await
            .map_err(|e| format!("Failed to send message: {}", e))?;

        Ok(map_opencode_hub_stream(rx, directory, session_id))
    }

    async fn send_command(
        &self,
        directory: &str,
        session_id: &str,
        command: &str,
        arguments: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        audio_parts: Option<Vec<AiAudioPart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
    ) -> Result<AiEventStream, String> {
        // 会话隔离：防止跨工作空间误用 session_id
        self.verify_session_directory(directory, session_id).await?;

        let rx = self.hub.subscribe();
        let directory_owned = directory.to_string();
        let session_id_owned = session_id.to_string();
        let command_owned = command.to_string();
        let arguments_owned = arguments.to_string();
        let manager = self.manager.clone();

        let (local_tx, local_rx) =
            tokio::sync::mpsc::unbounded_channel::<Result<AiEvent, String>>();

        tokio::spawn(async move {
            let client = OpenCodeClient::from_manager(&manager);
            if let Err(e) = client
                .send_command_async(
                    &directory_owned,
                    &session_id_owned,
                    &command_owned,
                    &arguments_owned,
                    file_refs,
                    image_parts,
                    audio_parts,
                    model,
                    agent,
                )
                .await
            {
                let _ = local_tx.send(Err(format!("Failed to send command: {}", e)));
            }
        });

        let hub_stream = map_opencode_hub_stream(rx, directory, session_id);
        let local_stream = tokio_stream::wrappers::UnboundedReceiverStream::new(local_rx);
        let merged = tokio_stream::StreamExt::merge(hub_stream, local_stream);
        Ok(Box::pin(merged))
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let sessions = client
            .list_sessions(directory)
            .await
            .map_err(|e| format!("Failed to list sessions: {}", e))?;
        let expected = directory.trim_end_matches('/');
        Ok(sessions
            .into_iter()
            .filter(|s| {
                s.directory
                    .as_deref()
                    .map(|d| d.trim_end_matches('/') == expected)
                    .unwrap_or(false)
            })
            .map(|s| AiSession {
                updated_at: s.effective_updated_at(),
                id: s.id,
                title: s.title,
            })
            .collect())
    }

    async fn delete_session(&self, directory: &str, session_id: &str) -> Result<(), String> {
        self.verify_session_directory(directory, session_id).await?;
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .delete_session(directory, session_id)
            .await
            .map_err(|e| format!("Failed to delete session: {}", e))?;
        Ok(())
    }

    async fn list_messages(
        &self,
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String> {
        self.verify_session_directory(directory, session_id).await?;
        let client = OpenCodeClient::from_manager(&self.manager);
        let raw = client
            .list_messages(directory, session_id, limit)
            .await
            .map_err(|e| format!("Failed to list messages: {}", e))?;

        let messages = raw
            .into_iter()
            .map(|m| {
                let MessageEnvelope { info, parts } = m;
                let info_source = selection_hint::message_info_selection_source(&info);
                AiMessage {
                    id: info.id,
                    role: info.role,
                    created_at: info.created_at,
                    agent: selection_hint::normalize_optional_token(
                        info.agent.clone().or(info.mode.clone()),
                    ),
                    model_provider_id: selection_hint::normalize_optional_token(
                        info.model
                            .as_ref()
                            .and_then(|m| m.provider_id.clone())
                            .or_else(|| info.provider_id.clone()),
                    ),
                    model_id: selection_hint::normalize_optional_token(
                        info.model
                            .as_ref()
                            .and_then(|m| m.model_id.clone())
                            .or_else(|| info.model_id.clone()),
                    ),
                    parts: parts
                        .into_iter()
                        .map(|p| AiPart {
                            id: p.id,
                            part_type: p.part_type,
                            text: p.text,
                            mime: p.mime,
                            filename: p.filename,
                            url: p.url,
                            synthetic: p.synthetic,
                            ignored: p.ignored,
                            source: selection_hint::merge_part_source_with_message_info(
                                p.source,
                                info_source.as_ref(),
                            ),
                            tool_name: p.name.or(p.tool),
                            tool_call_id: p.call_id,
                            tool_kind: None,
                            tool_title: None,
                            tool_raw_input: None,
                            tool_raw_output: None,
                            tool_locations: None,
                            tool_state: p.state,
                            tool_part_metadata: p.metadata,
                        })
                        .collect(),
                }
            })
            .collect();
        Ok(messages)
    }

    async fn session_selection_hint(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<crate::ai::AiSessionSelectionHint>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let session = client
            .get_session(directory, session_id)
            .await
            .map_err(|e| format!("Failed to fetch session info for selection hint: {}", e))?;
        let expected = directory.trim_end_matches('/');
        let actual = session
            .directory
            .as_deref()
            .unwrap_or("")
            .trim_end_matches('/');
        if !actual.is_empty() && actual != expected {
            return Ok(None);
        }
        let hint = selection_hint::selection_hint_from_session(&session);
        if hint.is_none() {
            tracing::debug!(
                "OpenCode session_selection_hint empty from /session: directory={}, session_id={}, session_extra_keys={:?}",
                directory,
                session_id,
                session.extra.keys().collect::<Vec<_>>()
            );
        }
        Ok(hint)
    }

    async fn abort_session(&self, directory: &str, session_id: &str) -> Result<(), String> {
        self.verify_session_directory(directory, session_id).await?;
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .abort_session(directory, session_id)
            .await
            .map_err(|e| format!("Failed to abort session: {}", e))?;
        Ok(())
    }

    async fn dispose_instance(&self, directory: &str) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .dispose_instance(directory)
            .await
            .map_err(|e| format!("Failed to dispose instance: {}", e))?;
        Ok(())
    }

    async fn get_session_status(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<AiSessionStatus, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let map = client
            .get_session_statuses(directory)
            .await
            .map_err(|e| format!("Failed to get session status: {}", e))?;

        let raw = map
            .get(session_id)
            .map(|item| item.status_type.trim().to_lowercase())
            .unwrap_or_else(|| "idle".to_string());

        let status = match raw.as_str() {
            "idle" => AiSessionStatus::Idle,
            // OpenCode 可能返回 busy/retry 等，统一映射为 busy
            "busy" | "retry" | "running" => AiSessionStatus::Busy,
            other => {
                // 未知状态不视为 error，避免误伤；倾向认为仍在进行中。
                tracing::debug!("Unknown OpenCode session status type: {}", other);
                AiSessionStatus::Busy
            }
        };

        Ok(status)
    }

    async fn get_session_context_usage(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionContextUsage>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let map = client
            .get_session_statuses(directory)
            .await
            .map_err(|e| format!("Failed to get session status for context usage: {}", e))?;
        let percent = map
            .get(session_id)
            .and_then(|item| item.context_remaining_percent());
        if percent.is_some() {
            return Ok(Some(AiSessionContextUsage {
                context_remaining_percent: percent,
            }));
        }

        let messages = client
            .list_messages(directory, session_id, Some(32))
            .await
            .map_err(|e| format!("Failed to list messages for context usage: {}", e))?;
        let latest_usage = usage::latest_assistant_usage(&messages);

        let computed_percent = if let Some((total_tokens, provider_id, model_id)) = latest_usage {
            let providers = client
                .list_providers(directory)
                .await
                .map_err(|e| format!("Failed to list providers for context usage: {}", e))?;
            let context_window = usage::resolve_context_window(
                &providers,
                provider_id.as_deref(),
                model_id.as_deref(),
            );
            context_window.and_then(|window| usage::compute_remaining_percent(total_tokens, window))
        } else {
            None
        };

        Ok(Some(AiSessionContextUsage {
            context_remaining_percent: computed_percent,
        }))
    }

    async fn list_providers(&self, directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let providers = client
            .list_providers(directory)
            .await
            .map_err(|e| format!("Failed to list providers: {}", e))?;
        Ok(providers
            .into_iter()
            .map(|p| {
                let pid = p.id.clone();
                AiProviderInfo {
                    id: p.id.clone(),
                    name: if p.name.is_empty() {
                        p.id.clone()
                    } else {
                        p.name.clone()
                    },
                    models: p
                        .models_vec()
                        .into_iter()
                        .filter(|m| m.status.as_deref() != Some("disabled"))
                        .map(|m| AiModelInfo {
                            supports_image_input: m.supports_image_input(),
                            id: m.id.clone(),
                            name: if m.name.is_empty() {
                                m.id.clone()
                            } else {
                                m.name
                            },
                            provider_id: if m.provider_id.is_empty() {
                                pid.clone()
                            } else {
                                m.provider_id
                            },
                        })
                        .collect(),
                }
            })
            .filter(|p: &AiProviderInfo| !p.models.is_empty())
            .collect())
    }

    async fn list_agents(&self, directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let agents = client
            .list_agents(directory)
            .await
            .map_err(|e| format!("Failed to list agents: {}", e))?;
        Ok(agents
            .into_iter()
            // 排除 hidden agent（compaction/title/summary 等内部 agent）
            .filter(|a| !a.hidden.unwrap_or(false))
            .map(|a| AiAgentInfo {
                name: a.name,
                description: a.description,
                mode: a.mode,
                color: a.color,
                default_provider_id: a.model.as_ref().map(|m| m.provider_id.clone()),
                default_model_id: a.model.as_ref().map(|m| m.model_id.clone()),
            })
            .collect())
    }

    async fn list_slash_commands(
        &self,
        directory: &str,
        _session_id: Option<&str>,
    ) -> Result<Vec<AiSlashCommand>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let commands = client
            .list_commands(directory)
            .await
            .map_err(|e| format!("Failed to list commands: {}", e))?;

        Ok(commands
            .into_iter()
            .filter(|c| !c.name.trim().is_empty())
            .map(|c| {
                let _source = c.source;
                AiSlashCommand {
                    name: c.name,
                    description: c.description.unwrap_or_default(),
                    // OpenCode /command 返回的是可在会话内执行的命令，
                    // 前端按 agent 命令处理（写入 `/xxx` 后发送）。
                    action: "agent".to_string(),
                    input_hint: None,
                }
            })
            .collect())
    }

    async fn reply_question(
        &self,
        directory: &str,
        request_id: &str,
        answers: Vec<Vec<String>>,
    ) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .reply_question(directory, request_id, answers)
            .await
            .map_err(|e| format!("Failed to reply question: {}", e))
    }

    async fn reject_question(&self, directory: &str, request_id: &str) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .reject_question(directory, request_id)
            .await
            .map_err(|e| format!("Failed to reject question: {}", e))
    }
}
