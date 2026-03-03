use crate::ai::session_status::{AiSessionStatus, AiSessionStatusMeta};
use axum::extract::ws::WebSocket;
use tracing::{info, warn};

use crate::server::context::SharedAppState;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

use super::utils::*;
use super::SharedAIState;

fn map_session_config_options(
    options: Vec<crate::ai::AiSessionConfigOption>,
) -> Vec<crate::server::protocol::ai::SessionConfigOptionInfo> {
    options
        .into_iter()
        .map(
            |option| crate::server::protocol::ai::SessionConfigOptionInfo {
                option_id: option.option_id,
                category: option.category,
                name: option.name,
                description: option.description,
                current_value: option.current_value,
                options: option
                    .options
                    .into_iter()
                    .map(
                        |choice| crate::server::protocol::ai::SessionConfigOptionChoice {
                            value: choice.value,
                            label: choice.label,
                            description: choice.description,
                        },
                    )
                    .collect::<Vec<_>>(),
                option_groups: option
                    .option_groups
                    .into_iter()
                    .map(
                        |group| crate::server::protocol::ai::SessionConfigOptionGroup {
                            label: group.label,
                            options: group
                                .options
                                .into_iter()
                                .map(|choice| {
                                    crate::server::protocol::ai::SessionConfigOptionChoice {
                                        value: choice.value,
                                        label: choice.label,
                                        description: choice.description,
                                    }
                                })
                                .collect::<Vec<_>>(),
                        },
                    )
                    .collect::<Vec<_>>(),
                raw: option.raw,
            },
        )
        .collect::<Vec<_>>()
}

const AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE: usize = 50;
const AI_SESSION_MESSAGES_MAX_PAGE_SIZE: usize = 200;

#[derive(Debug, Clone)]
struct AiSessionMessagesPage {
    requested_before_message_id: Option<String>,
    applied_before_message_id: Option<String>,
    window_end: usize,
    messages: Vec<crate::server::protocol::ai::MessageInfo>,
    has_more: bool,
    next_before_message_id: Option<String>,
}

fn normalize_ai_session_messages_page_size(limit: Option<i64>) -> usize {
    match limit.unwrap_or(AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE as i64) {
        raw if raw <= 0 => AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE,
        raw => (raw as usize).min(AI_SESSION_MESSAGES_MAX_PAGE_SIZE),
    }
}

fn paginate_ai_session_messages(
    all_messages: &[crate::server::protocol::ai::MessageInfo],
    before_message_id: Option<&str>,
    page_size: usize,
) -> AiSessionMessagesPage {
    let requested_before_message_id = before_message_id
        .map(str::trim)
        .filter(|it| !it.is_empty())
        .map(|it| it.to_string());

    let total = all_messages.len();
    let (window_end, applied_before_message_id) =
        if let Some(before_id) = requested_before_message_id.as_deref() {
            if let Some(cursor_idx) = all_messages.iter().position(|it| it.id == before_id) {
                (cursor_idx, Some(before_id.to_string()))
            } else {
                (total, None)
            }
        } else {
            (total, None)
        };

    let window_start = window_end.saturating_sub(page_size.max(1));
    let messages = all_messages[window_start..window_end].to_vec();
    let has_more = window_start > 0;
    let next_before_message_id = if has_more {
        messages.first().map(|it| it.id.clone())
    } else {
        None
    };

    AiSessionMessagesPage {
        requested_before_message_id,
        applied_before_message_id,
        window_end,
        messages,
        has_more,
        next_before_message_id,
    }
}

fn recompute_ai_session_page_meta_after_truncate(
    all_messages: &[crate::server::protocol::ai::MessageInfo],
    page: &mut AiSessionMessagesPage,
) {
    if let Some(first) = page.messages.first() {
        if let Some(first_idx) = all_messages.iter().position(|it| it.id == first.id) {
            page.has_more = first_idx > 0;
            page.next_before_message_id = if page.has_more {
                Some(first.id.clone())
            } else {
                None
            };
            return;
        }
    }

    if page.window_end > 0 {
        // 当当前页被裁剪为空时，使用“窗口最后一条”作为翻页锚点，继续向更旧历史翻页。
        let fallback_idx = page.window_end.saturating_sub(1);
        page.has_more = fallback_idx > 0;
        page.next_before_message_id = if page.has_more {
            all_messages.get(fallback_idx).map(|it| it.id.clone())
        } else {
            None
        };
    } else {
        page.has_more = false;
        page.next_before_message_id = None;
    }
}

pub(super) async fn handle_ai_session_list(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionList {
        project_name,
        workspace_name,
        ai_tool,
        limit,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    info!(
        "AISessionList: project={}, workspace={}, ai_tool={}, directory={}",
        project_name, workspace_name, ai_tool, directory
    );

    let mut sessions = agent.list_sessions(&directory).await?;
    sessions.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    if ai_tool == "opencode" {
        if let Some(invalid) = sessions.iter().find(|s| !s.id.starts_with("ses")) {
            warn!(
                "AISessionList: opencode session id format unexpected, project={}, workspace={}, session_id={}, possible_cross_tool_mismatch=true",
                project_name, workspace_name, invalid.id
            );
        }
    }
    let total_sessions = sessions.len();
    if let Some(limit) = *limit {
        if limit > 0 {
            sessions.truncate(limit as usize);
        }
    }
    info!(
        "AISessionList: project={}, workspace={}, ai_tool={}, sessions_count={}, returned_count={}, limit={:?}",
        project_name,
        workspace_name,
        ai_tool,
        total_sessions,
        sessions.len(),
        limit
    );

    let sessions: Vec<_> = sessions
        .into_iter()
        .map(|s| crate::server::protocol::ai::SessionInfo {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            id: s.id,
            title: s.title,
            updated_at: s.updated_at,
        })
        .collect();

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISessionListV2 {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            sessions,
        },
    )
    .await?;

    Ok(true)
}

pub(super) async fn handle_ai_session_messages(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionMessages {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        before_message_id,
        limit,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    info!(
        "AISessionMessages: project={}, workspace={}, ai_tool={}, session_id={}, requested_before={:?}, limit={:?}, directory={}",
        project_name, workspace_name, ai_tool, session_id, before_message_id, limit, directory
    );
    if ai_tool == "opencode" && !session_id.starts_with("ses") {
        warn!(
            "AISessionMessages: opencode session id format unexpected, project={}, workspace={}, session_id={}, possible_cross_tool_mismatch=true",
            project_name, workspace_name, session_id
        );
    }

    let session_key = stream_key(&ai_tool, &directory, session_id);
    let cached_snapshot = get_stream_snapshot(ai_state, &session_key).await;
    let from_snapshot = cached_snapshot.is_some();
    let cached_selection_hint = cached_snapshot
        .as_ref()
        .and_then(|snapshot| snapshot.selection_hint.clone());
    let all_messages: Vec<crate::server::protocol::ai::MessageInfo> = if let Some(snapshot) =
        cached_snapshot
    {
        snapshot.messages
    } else {
        agent
                .list_messages(&directory, session_id, None)
                .await
                .map_err(|e| {
                    warn!(
                        "AISessionMessages failed: project={}, workspace={}, ai_tool={}, session_id={}, requested_before={:?}, limit={:?}, error={}",
                        project_name, workspace_name, ai_tool, session_id, before_message_id, limit, e
                    );
                    e
                })?
                .into_iter()
                .map(map_ai_message_for_wire)
                .collect()
    };
    let page_size = normalize_ai_session_messages_page_size(*limit);
    let mut page =
        paginate_ai_session_messages(&all_messages, before_message_id.as_deref(), page_size);
    if page.requested_before_message_id.is_some() && page.applied_before_message_id.is_none() {
        warn!(
            "AISessionMessages before_message_id not found, fallback to latest page: project={}, workspace={}, ai_tool={}, session_id={}, requested_before={:?}, page_size={}",
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            page.requested_before_message_id.as_deref(),
            page_size
        );
    }
    let mut messages = page.messages.clone();

    let selection_hint = if from_snapshot {
        if cached_selection_hint.is_some() {
            cached_selection_hint
        } else {
            let inferred_hint = infer_selection_hint_from_messages(&messages);
            merge_session_selection_hint(
                inferred_hint,
                crate::ai::AiSessionSelectionHint::default(),
            )
        }
    } else {
        let adapter_hint = agent
            .session_selection_hint(&directory, session_id)
            .await
            .map_err(|e| {
                warn!(
                    "AISessionMessages hint failed: project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                    project_name, workspace_name, ai_tool, session_id, e
                );
                e
            })
            .ok()
            .flatten()
            .unwrap_or_default();
        let inferred_hint = infer_selection_hint_from_messages(&messages);
        // 真实接口数据优先，消息元数据推断仅作兜底。
        merge_session_selection_hint(adapter_hint, inferred_hint)
    };
    if let Some(hint) = selection_hint.as_ref() {
        info!(
            "AISessionMessages selection_hint: project={}, workspace={}, ai_tool={}, session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            hint.agent,
            hint.model_provider_id,
            hint.model_id
        );
    } else {
        warn!(
            "AISessionMessages selection_hint empty: project={}, workspace={}, ai_tool={}, session_id={}",
            project_name, workspace_name, ai_tool, session_id
        );
    }
    let mut payload_bytes = ai_session_messages_encoded_len(
        project_name,
        workspace_name,
        &ai_tool,
        session_id,
        page.applied_before_message_id.clone(),
        messages.clone(),
        page.has_more,
        page.next_before_message_id.clone(),
        selection_hint.clone(),
        None,
    )?;
    let mut dropped_count = 0usize;
    let mut truncated = false;
    while payload_bytes > MAX_AI_SESSION_MESSAGES_PAYLOAD_BYTES && messages.len() > 1 {
        messages.remove(0);
        dropped_count += 1;
        truncated = true;
        page.messages = messages.clone();
        recompute_ai_session_page_meta_after_truncate(&all_messages, &mut page);
        payload_bytes = ai_session_messages_encoded_len(
            project_name,
            workspace_name,
            &ai_tool,
            session_id,
            page.applied_before_message_id.clone(),
            messages.clone(),
            page.has_more,
            page.next_before_message_id.clone(),
            selection_hint.clone(),
            Some(true),
        )?;
    }
    if payload_bytes > MAX_AI_SESSION_MESSAGES_PAYLOAD_BYTES {
        truncated = true;
        messages.clear();
        page.messages.clear();
        recompute_ai_session_page_meta_after_truncate(&all_messages, &mut page);
        payload_bytes = ai_session_messages_encoded_len(
            project_name,
            workspace_name,
            &ai_tool,
            session_id,
            page.applied_before_message_id.clone(),
            messages.clone(),
            page.has_more,
            page.next_before_message_id.clone(),
            selection_hint.clone(),
            Some(true),
        )?;
        warn!(
            "AISessionMessages payload still exceeds limit after page truncate, fallback to empty messages: project={}, workspace={}, ai_tool={}, session_id={}, requested_before={:?}, applied_before={:?}, page_size={}, payload_bytes={}, limit_bytes={}",
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            page.requested_before_message_id.as_deref(),
            page.applied_before_message_id.as_deref(),
            page_size,
            payload_bytes,
            MAX_AI_SESSION_MESSAGES_PAYLOAD_BYTES
        );
    }
    if dropped_count > 0 {
        warn!(
            "AISessionMessages payload truncated: project={}, workspace={}, ai_tool={}, session_id={}, requested_before={:?}, applied_before={:?}, page_size={}, dropped_count={}, remaining_count={}, has_more={}, next_before={:?}, payload_bytes={}, max_payload_bytes={}",
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            page.requested_before_message_id.as_deref(),
            page.applied_before_message_id.as_deref(),
            page_size,
            dropped_count,
            messages.len(),
            page.has_more,
            page.next_before_message_id.as_deref(),
            payload_bytes,
            MAX_AI_SESSION_MESSAGES_PAYLOAD_BYTES
        );
    }
    let (parts_count, text_bytes) = ai_session_messages_stats(&messages);
    info!(
        "AISessionMessages: project={}, workspace={}, ai_tool={}, session_id={}, source={}, requested_before={:?}, applied_before={:?}, page_size={}, has_more={}, next_before={:?}, messages_count={}, parts_count={}, text_bytes={}, payload_bytes={}, has_selection_hint={}, truncated={}",
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        if from_snapshot { "snapshot" } else { "agent" },
        page.requested_before_message_id.as_deref(),
        page.applied_before_message_id.as_deref(),
        page_size,
        page.has_more,
        page.next_before_message_id.as_deref(),
        messages.len(),
        parts_count,
        text_bytes,
        payload_bytes,
        selection_hint.is_some(),
        truncated
    );

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISessionMessages {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            session_id: session_id.clone(),
            before_message_id: page.applied_before_message_id.clone(),
            messages,
            has_more: page.has_more,
            next_before_message_id: page.next_before_message_id.clone(),
            selection_hint,
            truncated: if truncated { Some(true) } else { None },
        },
    )
    .await?;

    Ok(true)
}

pub(super) async fn handle_ai_session_delete(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionDelete {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    // 先清理本地 active stream
    let key = stream_key(&ai_tool, &directory, session_id);
    {
        let mut ai = ai_state.lock().await;
        ai.active_streams.remove(&key);
    }
    let _ = remove_stream_snapshot(ai_state, &key).await;
    {
        let store = {
            let guard = ai_state.lock().await;
            guard.session_statuses.clone()
        };
        store.remove_status(&ai_tool, &directory, session_id);
    }

    let _ = agent.delete_session(&directory, session_id).await;

    Ok(true)
}

pub(super) async fn handle_ai_session_config_options(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionConfigOptions {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    let options = agent
        .list_session_config_options(&directory, session_id.as_deref())
        .await?;
    send_message(
        socket,
        &ServerMessage::AISessionConfigOptions {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            session_id: session_id.clone(),
            options: map_session_config_options(options),
        },
    )
    .await?;
    Ok(true)
}

pub(super) async fn handle_ai_session_set_config_option(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionSetConfigOption {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        option_id,
        value,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    agent
        .set_session_config_option(&directory, session_id, option_id, value.clone())
        .await?;
    let options = agent
        .list_session_config_options(&directory, Some(session_id.as_str()))
        .await
        .unwrap_or_default();
    send_message(
        socket,
        &ServerMessage::AISessionConfigOptions {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            session_id: Some(session_id.clone()),
            options: map_session_config_options(options),
        },
    )
    .await?;
    Ok(true)
}

pub(super) async fn handle_ai_session_status(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionStatus {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    let store = {
        let guard = ai_state.lock().await;
        guard.session_statuses.clone()
    };

    let mut status = store
        .get_status(&ai_tool, &directory, session_id)
        .unwrap_or(AiSessionStatus::Idle);

    if store.get_status(&ai_tool, &directory, session_id).is_none() {
        if let Ok(s) = agent.get_session_status(&directory, session_id).await {
            status = s;
        }
    }

    let context_remaining_percent = agent
        .get_session_context_usage(&directory, session_id)
        .await
        .ok()
        .flatten()
        .and_then(|usage| usage.context_remaining_percent);

    // 写入 meta，便于后续推送 update
    store.set_status_with_meta(
        AiSessionStatusMeta {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool: ai_tool.clone(),
            directory: directory.clone(),
            session_id: session_id.clone(),
        },
        status.clone(),
    );

    send_message(
        socket,
        &ServerMessage::AISessionStatusResult {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            session_id: session_id.clone(),
            status: status_to_info(&status, context_remaining_percent),
        },
    )
    .await?;

    Ok(true)
}

pub(super) async fn handle_ai_provider_list(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AIProviderList {
        project_name,
        workspace_name,
        ai_tool,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    let providers = agent.list_providers(&directory).await?;
    let providers: Vec<_> = providers
        .into_iter()
        .map(|p| crate::server::protocol::ai::ProviderInfo {
            id: p.id.clone(),
            name: p.name,
            models: p
                .models
                .into_iter()
                .map(|m| crate::server::protocol::ai::ModelInfo {
                    id: m.id,
                    name: m.name,
                    provider_id: m.provider_id,
                    supports_image_input: m.supports_image_input,
                })
                .collect(),
        })
        .collect();

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AIProviderListResult {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            providers,
        },
    )
    .await?;

    Ok(true)
}

pub(super) async fn handle_ai_agent_list(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AIAgentList {
        project_name,
        workspace_name,
        ai_tool,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    let agents = agent.list_agents(&directory).await?;
    // 返回 primary 和 all 模式的 agent，subagent/hidden 等不展示
    let agents: Vec<_> = agents
        .into_iter()
        .filter(|a| matches!(a.mode.as_deref(), Some("primary") | Some("all")))
        .map(|a| crate::server::protocol::ai::AgentInfo {
            name: a.name,
            description: a.description,
            mode: a.mode,
            color: a.color,
            default_provider_id: a.default_provider_id,
            default_model_id: a.default_model_id,
        })
        .collect();

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AIAgentListResult {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            agents,
        },
    )
    .await?;

    Ok(true)
}

/// 返回 AI 聊天可用的斜杠命令列表
/// 命令分为 client（前端本地执行）和 agent（发送给 AI 代理）两类
pub(super) async fn handle_ai_slash_commands(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISlashCommands {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    // 验证工作空间存在，并作为 /command 的目录路由依据
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;

    use crate::server::protocol::ai::SlashCommandInfo;
    use std::collections::BTreeMap;

    // 动态命令来源：后端代理（ACP/OpenCode 等）
    let mut command_map: BTreeMap<String, SlashCommandInfo> = BTreeMap::new();
    if let Ok(agent) = ensure_agent(ai_state, &ai_tool).await {
        ensure_maintenance(ai_state).await;
        if let Ok(dynamic_commands) = agent
            .list_slash_commands(&directory, session_id.as_deref())
            .await
        {
            for cmd in dynamic_commands {
                let info = SlashCommandInfo {
                    name: cmd.name,
                    description: cmd.description,
                    action: cmd.action,
                    input_hint: cmd.input_hint,
                };
                command_map.insert(info.name.clone(), info);
            }
        }
    }

    // 内置兜底命令：按当前产品约定，仅保留 /new 本地命令，且优先本地语义。
    let local_new = SlashCommandInfo {
        name: "new".to_string(),
        description: "新建会话".to_string(),
        action: "client".to_string(),
        input_hint: None,
    };
    command_map.insert(local_new.name.clone(), local_new);

    let commands: Vec<SlashCommandInfo> = command_map.into_values().collect();

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISlashCommandsResult {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            session_id: session_id.clone(),
            commands,
        },
    )
    .await?;

    Ok(true)
}

pub(super) async fn handle_ai_session_subscribe(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    conn_id: &str,
) -> Result<bool, String> {
    let ClientMessage::AISessionSubscribe {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let key = stream_key(&ai_tool, &directory, session_id);

    {
        let mut ai = ai_state.lock().await;
        ai.session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert(key.clone());
    }

    send_message(
        socket,
        &ServerMessage::AISessionSubscribeAck {
            session_id: session_id.clone(),
            session_key: key,
        },
    )
    .await?;

    Ok(true)
}

pub(super) async fn handle_ai_session_unsubscribe(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    conn_id: &str,
) -> Result<bool, String> {
    let ClientMessage::AISessionUnsubscribe {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let key = stream_key(&ai_tool, &directory, session_id);

    {
        let mut ai = ai_state.lock().await;
        if let Some(keys) = ai.session_subscriptions.get_mut(conn_id) {
            keys.remove(&key);
            if keys.is_empty() {
                ai.session_subscriptions.remove(conn_id);
            }
        }
    }

    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_messages(count: usize) -> Vec<crate::server::protocol::ai::MessageInfo> {
        (1..=count)
            .map(|idx| crate::server::protocol::ai::MessageInfo {
                id: format!("msg_{:03}", idx),
                role: "assistant".to_string(),
                created_at: None,
                agent: None,
                model_provider_id: None,
                model_id: None,
                parts: vec![],
            })
            .collect()
    }

    #[test]
    fn normalize_page_size_with_default_and_max_limit() {
        assert_eq!(
            normalize_ai_session_messages_page_size(None),
            AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE
        );
        assert_eq!(
            normalize_ai_session_messages_page_size(Some(0)),
            AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE
        );
        assert_eq!(
            normalize_ai_session_messages_page_size(Some(-42)),
            AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE
        );
        assert_eq!(normalize_ai_session_messages_page_size(Some(12)), 12);
        assert_eq!(
            normalize_ai_session_messages_page_size(Some(999)),
            AI_SESSION_MESSAGES_MAX_PAGE_SIZE
        );
    }

    #[test]
    fn paginate_without_before_returns_latest_page() {
        let messages = build_messages(120);
        let page = paginate_ai_session_messages(&messages, None, 50);
        assert_eq!(page.messages.len(), 50);
        assert_eq!(
            page.messages.first().map(|it| it.id.as_str()),
            Some("msg_071")
        );
        assert_eq!(
            page.messages.last().map(|it| it.id.as_str()),
            Some("msg_120")
        );
        assert_eq!(page.applied_before_message_id, None);
        assert!(page.has_more);
        assert_eq!(page.next_before_message_id.as_deref(), Some("msg_071"));
    }

    #[test]
    fn paginate_with_before_returns_older_page_without_anchor() {
        let messages = build_messages(120);
        let page = paginate_ai_session_messages(&messages, Some("msg_071"), 20);
        assert_eq!(page.messages.len(), 20);
        assert_eq!(
            page.messages.first().map(|it| it.id.as_str()),
            Some("msg_051")
        );
        assert_eq!(
            page.messages.last().map(|it| it.id.as_str()),
            Some("msg_070")
        );
        assert_eq!(page.applied_before_message_id.as_deref(), Some("msg_071"));
        assert!(page.has_more);
        assert_eq!(page.next_before_message_id.as_deref(), Some("msg_051"));
    }

    #[test]
    fn paginate_with_invalid_before_falls_back_to_latest_page() {
        let messages = build_messages(80);
        let page = paginate_ai_session_messages(&messages, Some("msg_not_found"), 50);
        assert_eq!(page.messages.len(), 50);
        assert_eq!(
            page.messages.first().map(|it| it.id.as_str()),
            Some("msg_031")
        );
        assert_eq!(
            page.messages.last().map(|it| it.id.as_str()),
            Some("msg_080")
        );
        assert_eq!(
            page.requested_before_message_id.as_deref(),
            Some("msg_not_found")
        );
        assert_eq!(page.applied_before_message_id, None);
        assert!(page.has_more);
        assert_eq!(page.next_before_message_id.as_deref(), Some("msg_031"));
    }

    #[test]
    fn recompute_meta_after_truncate_keeps_pagination_progress() {
        let messages = build_messages(10);
        let mut page = paginate_ai_session_messages(&messages, None, 5);
        assert_eq!(
            page.messages.first().map(|it| it.id.as_str()),
            Some("msg_006")
        );
        assert_eq!(page.next_before_message_id.as_deref(), Some("msg_006"));

        page.messages.remove(0);
        recompute_ai_session_page_meta_after_truncate(&messages, &mut page);
        assert_eq!(
            page.messages.first().map(|it| it.id.as_str()),
            Some("msg_007")
        );
        assert!(page.has_more);
        assert_eq!(page.next_before_message_id.as_deref(), Some("msg_007"));

        page.messages.clear();
        recompute_ai_session_page_meta_after_truncate(&messages, &mut page);
        assert!(page.has_more);
        assert_eq!(page.next_before_message_id.as_deref(), Some("msg_010"));
    }
}
