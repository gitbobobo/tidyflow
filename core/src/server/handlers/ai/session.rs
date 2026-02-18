use crate::ai::session_status::{AiSessionStatus, AiSessionStatusMeta};
use axum::extract::ws::WebSocket;
use tracing::{info, warn};

use crate::server::context::SharedAppState;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

use super::utils::*;
use super::SharedAIState;

pub(super) async fn try_handle_ai_session_list(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionList {
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

    info!(
        "AISessionList: project={}, workspace={}, ai_tool={}, directory={}",
        project_name, workspace_name, ai_tool, directory
    );

    let sessions = agent.list_sessions(&directory).await?;
    if ai_tool == "opencode" {
        if let Some(invalid) = sessions.iter().find(|s| !s.id.starts_with("ses")) {
            warn!(
                "AISessionList: opencode session id format unexpected, project={}, workspace={}, session_id={}, possible_cross_tool_mismatch=true",
                project_name, workspace_name, invalid.id
            );
        }
    }
    info!(
        "AISessionList: project={}, workspace={}, ai_tool={}, sessions_count={}",
        project_name,
        workspace_name,
        ai_tool,
        sessions.len()
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

pub(super) async fn try_handle_ai_session_messages(
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
        "AISessionMessages: project={}, workspace={}, ai_tool={}, session_id={}, limit={:?}, directory={}",
        project_name, workspace_name, ai_tool, session_id, limit, directory
    );
    if ai_tool == "opencode" && !session_id.starts_with("ses") {
        warn!(
            "AISessionMessages: opencode session id format unexpected, project={}, workspace={}, session_id={}, possible_cross_tool_mismatch=true",
            project_name, workspace_name, session_id
        );
    }

    let mut messages: Vec<crate::server::protocol::ai::MessageInfo> = agent
        .list_messages(&directory, session_id, *limit)
        .await
        .map_err(|e| {
            warn!(
                "AISessionMessages failed: project={}, workspace={}, ai_tool={}, session_id={}, limit={:?}, error={}",
                project_name, workspace_name, ai_tool, session_id, limit, e
            );
            e
        })?
        .into_iter()
        .map(|m| crate::server::protocol::ai::MessageInfo {
            id: m.id,
            role: m.role,
            created_at: m.created_at,
            parts: m
                .parts
                .into_iter()
                .map(normalize_part_for_wire)
                .collect(),
        })
        .collect();
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
    let selection_hint = merge_session_selection_hint(adapter_hint, inferred_hint);
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
        messages.clone(),
        selection_hint.clone(),
    )?;
    let mut dropped_count = 0usize;
    while payload_bytes > MAX_AI_SESSION_MESSAGES_PAYLOAD_BYTES && messages.len() > 1 {
        messages.remove(0);
        dropped_count += 1;
        payload_bytes = ai_session_messages_encoded_len(
            project_name,
            workspace_name,
            &ai_tool,
            session_id,
            messages.clone(),
            selection_hint.clone(),
        )?;
    }
    if dropped_count > 0 {
        warn!(
            "AISessionMessages payload truncated: project={}, workspace={}, ai_tool={}, session_id={}, dropped_count={}, remaining_count={}, payload_bytes={}, max_payload_bytes={}",
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            dropped_count,
            messages.len(),
            payload_bytes,
            MAX_AI_SESSION_MESSAGES_PAYLOAD_BYTES
        );
    }
    let (parts_count, text_bytes) = ai_session_messages_stats(&messages);
    info!(
        "AISessionMessages: project={}, workspace={}, ai_tool={}, session_id={}, messages_count={}, parts_count={}, text_bytes={}, payload_bytes={}, has_selection_hint={}",
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        messages.len(),
        parts_count,
        text_bytes,
        payload_bytes,
        selection_hint.is_some()
    );

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISessionMessages {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            session_id: session_id.clone(),
            messages,
            selection_hint,
        },
    )
    .await?;

    Ok(true)
}

pub(super) async fn try_handle_ai_session_delete(
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

pub(super) async fn try_handle_ai_session_status(
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
            status: status_to_info(&status),
        },
    )
    .await?;

    Ok(true)
}

pub(super) async fn try_handle_ai_provider_list(
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

pub(super) async fn try_handle_ai_agent_list(
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
pub(super) async fn try_handle_ai_slash_commands(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISlashCommands {
        project_name,
        workspace_name,
        ai_tool,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    // 验证工作空间存在，并作为 /command 的目录路由依据
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;

    use crate::server::protocol::ai::SlashCommandInfo;
    use std::collections::BTreeMap;

    // 内置兜底命令：按当前产品约定，仅保留 /new 本地命令。
    let mut command_map: BTreeMap<String, SlashCommandInfo> = BTreeMap::new();
    for cmd in [SlashCommandInfo {
        name: "new".to_string(),
        description: "新建会话".to_string(),
        action: "client".to_string(),
    }] {
        command_map.insert(cmd.name.clone(), cmd);
    }

    // 动态命令来源：OpenCode /command（与 CLI 实际可用命令保持一致）
    if let Ok(agent) = ensure_agent(ai_state, &ai_tool).await {
        ensure_maintenance(ai_state).await;
        if let Ok(dynamic_commands) = agent.list_slash_commands(&directory).await {
            for cmd in dynamic_commands {
                let info = SlashCommandInfo {
                    name: cmd.name,
                    description: cmd.description,
                    action: cmd.action,
                };
                command_map.insert(info.name.clone(), info);
            }
        }
    }

    let commands: Vec<SlashCommandInfo> = command_map.into_values().collect();

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISlashCommandsResult {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            commands,
        },
    )
    .await?;

    Ok(true)
}
