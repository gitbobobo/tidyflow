use crate::ai::session_status::{AiSessionStatus, AiSessionStatusMeta};
use axum::extract::ws::WebSocket;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::ai::CompletionAgent;
use crate::server::context::SharedAppState;
use crate::server::protocol::ai::AiSessionOrigin;
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

async fn touch_directory_last_used(ai_state: &SharedAIState, ai_tool: &str, directory: &str) {
    let mut ai = ai_state.lock().await;
    let dir_key = tool_directory_key(ai_tool, directory);
    ai.directory_last_used_ms.insert(dir_key, now_ms());
}

#[derive(Debug, Clone)]
struct AiSessionMessagesPage {
    requested_before_message_id: Option<String>,
    applied_before_message_id: Option<String>,
    window_end: usize,
    messages: Vec<crate::server::protocol::ai::MessageInfo>,
    has_more: bool,
    next_before_message_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AiSessionMessagesSource {
    Snapshot,
    Agent,
    SnapshotEmptyFallbackAgent,
}

fn normalize_ai_session_messages_page_size(limit: Option<i64>) -> usize {
    match limit.unwrap_or(AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE as i64) {
        raw if raw <= 0 => AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE,
        raw => (raw as usize).min(AI_SESSION_MESSAGES_MAX_PAGE_SIZE),
    }
}

fn resolve_ai_session_messages_source(
    cached_snapshot: Option<&AiStreamSnapshot>,
    agent_messages: Option<Vec<crate::server::protocol::ai::MessageInfo>>,
) -> (
    Vec<crate::server::protocol::ai::MessageInfo>,
    AiSessionMessagesSource,
) {
    if let Some(snapshot) = cached_snapshot {
        if !snapshot.messages.is_empty() {
            return (snapshot.messages.clone(), AiSessionMessagesSource::Snapshot);
        }
    }

    if let Some(messages) = agent_messages {
        if cached_snapshot.is_some() {
            return (
                messages,
                AiSessionMessagesSource::SnapshotEmptyFallbackAgent,
            );
        }
        return (messages, AiSessionMessagesSource::Agent);
    }

    if let Some(snapshot) = cached_snapshot {
        return (snapshot.messages.clone(), AiSessionMessagesSource::Snapshot);
    }

    (Vec::new(), AiSessionMessagesSource::Agent)
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

fn clamp_text_for_history(text: &str, limit: usize) -> String {
    if limit == 0 || text.chars().count() <= limit {
        return text.to_string();
    }
    let head_count = limit.saturating_sub(180);
    let tail_count = 160usize.min(limit / 6);
    let head = text.chars().take(head_count).collect::<String>();
    let tail = if tail_count > 0 {
        text.chars()
            .rev()
            .take(tail_count)
            .collect::<String>()
            .chars()
            .rev()
            .collect::<String>()
    } else {
        String::new()
    };
    format!(
        "{}\n…（已为历史展示裁剪，原始长度 {} 字符）…\n{}",
        head,
        text.chars().count(),
        tail
    )
}

fn truncate_tool_view_sections_for_history(
    message: &mut crate::server::protocol::ai::MessageInfo,
) -> bool {
    let mut changed = false;
    for part in &mut message.parts {
        let Some(tool_view) = part.tool_view.as_mut() else {
            continue;
        };
        for section in &mut tool_view.sections {
            let limit = match section.style {
                crate::server::protocol::ai::ToolViewSectionStyle::Code
                | crate::server::protocol::ai::ToolViewSectionStyle::Diff
                | crate::server::protocol::ai::ToolViewSectionStyle::Terminal => 24_000,
                crate::server::protocol::ai::ToolViewSectionStyle::Markdown
                | crate::server::protocol::ai::ToolViewSectionStyle::Text => 8_000,
            };
            let clamped = clamp_text_for_history(&section.content, limit);
            if clamped != section.content {
                section.content = clamped;
                section.collapsed_by_default = true;
                changed = true;
            }
        }
    }
    changed
}

pub(super) async fn handle_ai_read_via_http_required(
    msg: &ClientMessage,
    socket: &mut WebSocket,
) -> Result<bool, String> {
    // 提取 action 名称与 project/workspace（用于多工作区归属提示）
    let (action, project, workspace) = match msg {
        ClientMessage::AISessionList {
            project_name,
            workspace_name,
            ..
        } => (
            Some("ai_session_list"),
            Some(project_name.clone()),
            Some(workspace_name.clone()),
        ),
        ClientMessage::AISessionMessages {
            project_name,
            workspace_name,
            ..
        } => (
            Some("ai_session_messages"),
            Some(project_name.clone()),
            Some(workspace_name.clone()),
        ),
        ClientMessage::AISessionStatus {
            project_name,
            workspace_name,
            ..
        } => (
            Some("ai_session_status"),
            Some(project_name.clone()),
            Some(workspace_name.clone()),
        ),
        ClientMessage::AIProviderList {
            project_name,
            workspace_name,
            ..
        } => (
            Some("ai_provider_list"),
            Some(project_name.clone()),
            Some(workspace_name.clone()),
        ),
        ClientMessage::AIAgentList {
            project_name,
            workspace_name,
            ..
        } => (
            Some("ai_agent_list"),
            Some(project_name.clone()),
            Some(workspace_name.clone()),
        ),
        ClientMessage::AISlashCommands {
            project_name,
            workspace_name,
            ..
        } => (
            Some("ai_slash_commands"),
            Some(project_name.clone()),
            Some(workspace_name.clone()),
        ),
        ClientMessage::AISessionConfigOptions {
            project_name,
            workspace_name,
            ..
        } => (
            Some("ai_session_config_options"),
            Some(project_name.clone()),
            Some(workspace_name.clone()),
        ),
        _ => (None, None, None),
    };
    let Some(action) = action else {
        return Ok(false);
    };

    send_message(
        socket,
        &ServerMessage::Error {
            code: "read_via_http_required".to_string(),
            message: format!(
                "{} must be fetched via HTTP API (/api/v1/projects/:project/workspaces/:workspace/ai/...)",
                action
            ),
            project,
            workspace,
            session_id: None,
            cycle_id: None,
        },
    )
    .await?;
    Ok(true)
}

pub(crate) async fn query_ai_session_list(
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    filter_ai_tool: Option<&str>,
    cursor: Option<&str>,
    limit: Option<u32>,
) -> Result<ServerMessage, String> {
    let filter_ai_tool = match filter_ai_tool {
        Some(ai_tool) => Some(normalize_ai_tool(ai_tool)?),
        None => None,
    };
    resolve_directory(app_state, project_name, workspace_name).await?;

    info!(
        "AISessionList(DB): project={}, workspace={}, filter_ai_tool={:?}, cursor_present={}",
        project_name,
        workspace_name,
        filter_ai_tool.as_deref(),
        cursor.is_some()
    );

    let page = super::list_session_index_page(
        ai_state,
        project_name,
        workspace_name,
        filter_ai_tool.as_deref(),
        cursor,
        limit,
    )
    .await?;
    let total_sessions = page.entries.len();

    info!(
        "AISessionList(DB): project={}, workspace={}, filter_ai_tool={:?}, returned_count={}, limit={:?}, has_more={}",
        project_name,
        workspace_name,
        filter_ai_tool.as_deref(),
        total_sessions,
        limit,
        page.has_more
    );

    let sessions: Vec<_> = page
        .entries
        .into_iter()
        .map(|s| crate::server::protocol::ai::SessionInfo {
            project_name: project_name.to_string(),
            workspace_name: workspace_name.to_string(),
            ai_tool: s.ai_tool,
            id: s.session_id,
            title: s.title,
            updated_at: s.updated_at_ms,
            session_origin: s.session_origin,
        })
        .collect();

    Ok(ServerMessage::AISessionListV2 {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        filter_ai_tool,
        sessions,
        has_more: page.has_more,
        next_cursor: page.next_cursor,
    })
}

pub(crate) async fn query_ai_session_messages(
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
    before_message_id: Option<String>,
    limit: Option<i64>,
) -> Result<ServerMessage, String> {
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;
    touch_directory_last_used(ai_state, &ai_tool, &directory).await;

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
    let cached_selection_hint = cached_snapshot
        .as_ref()
        .and_then(|snapshot| snapshot.selection_hint.clone());
    let should_load_agent_messages = cached_snapshot
        .as_ref()
        .map(|snapshot| snapshot.messages.is_empty())
        .unwrap_or(true);
    let agent_messages = if should_load_agent_messages {
        Some(
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
                .collect::<Vec<_>>(),
        )
    } else {
        None
    };
    let (all_messages, messages_source) =
        resolve_ai_session_messages_source(cached_snapshot.as_ref(), agent_messages);
    if matches!(
        messages_source,
        AiSessionMessagesSource::SnapshotEmptyFallbackAgent
    ) {
        warn!(
            "AISessionMessages live snapshot empty, fallback to adapter history: project={}, workspace={}, ai_tool={}, session_id={}",
            project_name, workspace_name, ai_tool, session_id
        );
    }
    let page_size = normalize_ai_session_messages_page_size(limit);
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

    let selection_hint = if matches!(messages_source, AiSessionMessagesSource::Snapshot) {
        if cached_selection_hint.is_some() {
            cached_selection_hint
        } else {
            let inferred_hint = infer_selection_hint_from_messages(&messages);
            merge_session_selection_hint(
                inferred_hint,
                crate::ai::AiSessionSelectionHint::default(),
            )
        }
    } else if cached_selection_hint.is_some() {
        cached_selection_hint
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
        let mut section_truncated = false;
        for message in &mut messages {
            section_truncated |= truncate_tool_view_sections_for_history(message);
        }
        if section_truncated {
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
            "AISessionMessages payload still exceeds limit after section truncate, fallback to empty messages: project={}, workspace={}, ai_tool={}, session_id={}, requested_before={:?}, applied_before={:?}, page_size={}, payload_bytes={}, limit_bytes={}",
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
        match messages_source {
            AiSessionMessagesSource::Snapshot => "snapshot",
            AiSessionMessagesSource::Agent => "agent",
            AiSessionMessagesSource::SnapshotEmptyFallbackAgent => "snapshot_empty_fallback_agent",
        },
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

    Ok(ServerMessage::AISessionMessages {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool,
        session_id: session_id.to_string(),
        before_message_id: page.applied_before_message_id.clone(),
        messages,
        has_more: page.has_more,
        next_before_message_id: page.next_before_message_id.clone(),
        selection_hint,
        truncated: if truncated { Some(true) } else { None },
    })
}

pub(crate) async fn query_ai_session_config_options(
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: Option<String>,
) -> Result<ServerMessage, String> {
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;
    touch_directory_last_used(ai_state, &ai_tool, &directory).await;

    let options = agent
        .list_session_config_options(&directory, session_id.as_deref())
        .await?;
    Ok(ServerMessage::AISessionConfigOptions {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool,
        session_id,
        options: map_session_config_options(options),
    })
}

pub(crate) async fn query_ai_session_status(
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
) -> Result<ServerMessage, String> {
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;
    touch_directory_last_used(ai_state, &ai_tool, &directory).await;

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

    store.set_status_with_meta(
        AiSessionStatusMeta {
            project_name: project_name.to_string(),
            workspace_name: workspace_name.to_string(),
            ai_tool: ai_tool.clone(),
            directory: directory.clone(),
            session_id: session_id.to_string(),
        },
        status.clone(),
    );

    Ok(ServerMessage::AISessionStatusResult {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool,
        session_id: session_id.to_string(),
        status: status_to_info(&status, context_remaining_percent),
    })
}

pub(crate) async fn query_ai_provider_list(
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
) -> Result<ServerMessage, String> {
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;
    touch_directory_last_used(ai_state, &ai_tool, &directory).await;

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

    Ok(ServerMessage::AIProviderListResult {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool,
        providers,
    })
}

pub(crate) async fn query_ai_agent_list(
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
) -> Result<ServerMessage, String> {
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;
    touch_directory_last_used(ai_state, &ai_tool, &directory).await;

    let agents = agent.list_agents(&directory).await?;
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

    Ok(ServerMessage::AIAgentListResult {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool,
        agents,
    })
}

pub(crate) async fn query_ai_slash_commands(
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: Option<String>,
) -> Result<ServerMessage, String> {
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;

    use crate::server::protocol::ai::SlashCommandInfo;
    use std::collections::BTreeMap;

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

    let local_new = SlashCommandInfo {
        name: "new".to_string(),
        description: "新建会话".to_string(),
        action: "client".to_string(),
        input_hint: None,
    };
    command_map.insert(local_new.name.clone(), local_new);

    let commands: Vec<SlashCommandInfo> = command_map.into_values().collect();

    Ok(ServerMessage::AISlashCommandsResult {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool,
        session_id,
        commands,
    })
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

    if let Err(e) = super::delete_session_index_entry(
        ai_state,
        project_name,
        workspace_name,
        &ai_tool,
        session_id,
    )
    .await
    {
        warn!(
            "AISessionDelete: remove index failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
            project_name, workspace_name, ai_tool, session_id, e
        );
    }

    let _ = agent.delete_session(&directory, session_id).await;

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
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
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

pub(super) async fn handle_ai_session_rename(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionRename {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        new_title,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    touch_directory_last_used(ai_state, &ai_tool, &directory).await;

    let now = now_ms();
    let store = {
        let guard = ai_state.lock().await;
        guard.session_index_store.clone()
    };
    let updated = store
        .update_title(
            project_name,
            workspace_name,
            &ai_tool,
            session_id,
            new_title,
            now,
        )
        .await
        .unwrap_or(false);

    if updated {
        send_message(
            socket,
            &ServerMessage::AISessionRenameResult {
                project_name: project_name.clone(),
                workspace_name: workspace_name.clone(),
                ai_tool: ai_tool.clone(),
                session_id: session_id.clone(),
                title: new_title.clone(),
                updated_at: now,
            },
        )
        .await?;
    }
    Ok(true)
}

pub(super) async fn query_ai_session_search(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionSearch {
        project_name,
        workspace_name,
        ai_tool,
        query,
        limit,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let _directory = resolve_directory(app_state, project_name, workspace_name).await?;
    ensure_agent(ai_state, &ai_tool).await?;

    let store = {
        let guard = ai_state.lock().await;
        guard.session_index_store.clone()
    };
    let entries = store
        .search(project_name, workspace_name, &ai_tool, query, *limit)
        .await
        .unwrap_or_default();

    let sessions: Vec<crate::server::protocol::ai::SessionInfo> = entries
        .into_iter()
        .map(|e| crate::server::protocol::ai::SessionInfo {
            project_name: e.project_name,
            workspace_name: e.workspace_name,
            ai_tool: e.ai_tool,
            id: e.session_id,
            title: e.title,
            updated_at: e.updated_at_ms,
            session_origin: e.session_origin,
        })
        .collect();

    send_message(
        socket,
        &ServerMessage::AISessionSearchResult {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool: ai_tool.clone(),
            query: query.clone(),
            sessions,
        },
    )
    .await?;
    Ok(true)
}

pub(super) async fn handle_ai_code_review(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AICodeReview {
        project_name,
        workspace_name,
        ai_tool,
        session_id: _provided_session_id,
        diff_text,
        file_paths,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    touch_directory_last_used(ai_state, &ai_tool, &directory).await;

    let session_title = "AI 代码审查";
    let session = match agent.create_session(&directory, session_title).await {
        Ok(s) => s,
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::AICodeReviewResult {
                    project_name: project_name.clone(),
                    workspace_name: workspace_name.clone(),
                    ai_tool: ai_tool.clone(),
                    session_id: String::new(),
                    review_text: None,
                    error: Some(format!("创建审查会话失败: {}", e)),
                },
            )
            .await?;
            return Ok(true);
        }
    };

    let now = now_ms();
    if let Err(e) = super::record_session_index_created(
        ai_state,
        project_name,
        workspace_name,
        &ai_tool,
        &directory,
        &session.id,
        session_title,
        now,
        AiSessionOrigin::User,
    )
    .await
    {
        warn!(
            "AICodeReview: persist session index failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
            project_name, workspace_name, ai_tool, session.id, e
        );
    }

    // 构建文件路径提示
    let paths_hint = if file_paths.is_empty() {
        String::new()
    } else {
        format!(
            "\n变更文件：\n{}",
            file_paths
                .iter()
                .map(|p| format!("- {}", p))
                .collect::<Vec<_>>()
                .join("\n")
        )
    };
    let _review_prompt = format!(
        "请对以下 Git diff 进行代码审查，指出潜在问题、改进建议和优点：{}\n\n```diff\n{}\n```",
        paths_hint, diff_text
    );

    // 返回会话 ID，前端订阅后发起第一条消息
    send_message(
        socket,
        &ServerMessage::AICodeReviewResult {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool: ai_tool.clone(),
            session_id: session.id.clone(),
            review_text: None,
            error: None,
        },
    )
    .await?;

    Ok(true)
}

/// 处理 AI 代码补全请求（流式推送分片到客户端）
pub(super) async fn handle_ai_code_completion(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AICodeCompletion {
        project_name,
        workspace_name,
        ai_tool,
        request,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;
    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;
    touch_directory_last_used(ai_state, &ai_tool, &directory).await;

    // 创建或复用一个独立的补全会话
    let session = match agent.create_session(&directory, "AI代码补全").await {
        Ok(s) => s,
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::AICodeCompletionDone {
                    project_name: project_name.clone(),
                    workspace_name: workspace_name.clone(),
                    ai_tool: ai_tool.clone(),
                    result: crate::server::protocol::ai::CodeCompletionResponse {
                        request_id: request.request_id.clone(),
                        completion_text: String::new(),
                        stop_reason: "error".to_string(),
                        error: Some(format!("创建补全会话失败: {}", e)),
                    },
                },
            )
            .await?;
            return Ok(true);
        }
    };

    // 使用 CompletionAgent 流式执行补全
    let completion_agent = CompletionAgent::new(Arc::clone(&agent));
    let (chunk_tx, mut chunk_rx) = mpsc::channel(32);

    let req_clone = request.clone();
    let directory_clone = directory.clone();
    let session_id = session.id.clone();
    tokio::spawn(async move {
        completion_agent
            .complete(&directory_clone, &session_id, &req_clone, chunk_tx)
            .await
    });

    // 将分片推送到 WebSocket
    while let Some(chunk_result) = chunk_rx.recv().await {
        match chunk_result {
            Ok(chunk) => {
                if let Err(e) = send_message(
                    socket,
                    &ServerMessage::AICodeCompletionChunk {
                        project_name: project_name.clone(),
                        workspace_name: workspace_name.clone(),
                        ai_tool: ai_tool.clone(),
                        chunk,
                    },
                )
                .await
                {
                    warn!(
                        "handle_ai_code_completion: failed to send chunk, request_id={}: {}",
                        request.request_id, e
                    );
                    return Ok(true);
                }
            }
            Err(err_msg) => {
                send_message(
                    socket,
                    &ServerMessage::AICodeCompletionDone {
                        project_name: project_name.clone(),
                        workspace_name: workspace_name.clone(),
                        ai_tool: ai_tool.clone(),
                        result: crate::server::protocol::ai::CodeCompletionResponse {
                            request_id: request.request_id.clone(),
                            completion_text: String::new(),
                            stop_reason: "error".to_string(),
                            error: Some(err_msg),
                        },
                    },
                )
                .await?;
                return Ok(true);
            }
        }
    }

    Ok(true)
}

/// HTTP 读取单个会话上下文快照
pub(crate) async fn query_ai_session_context_snapshot(
    _app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
) -> Result<ServerMessage, String> {
    let stored = super::get_session_context_snapshot(
        ai_state,
        project_name,
        workspace_name,
        ai_tool,
        session_id,
    )
    .await?;

    let snapshot = stored.map(|s| crate::server::protocol::ai::AiSessionContextSnapshot {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool: ai_tool.to_string(),
        session_id: session_id.to_string(),
        snapshot_at_ms: s.snapshot_at_ms,
        message_count: s.message_count,
        context_summary: s.context_summary,
        selection_hint: s.selection_hint,
        context_remaining_percent: s.context_remaining_percent,
    });

    Ok(ServerMessage::AISessionContextSnapshotResult {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool: ai_tool.to_string(),
        session_id: session_id.to_string(),
        snapshot,
    })
}

/// HTTP 读取跨工作区上下文快照列表（用于跨工作区上下文复用）
pub(crate) async fn query_ai_cross_context_snapshots(
    _app_state: &SharedAppState,
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    filter_ai_tool: Option<&str>,
) -> Result<ServerMessage, String> {
    let entries = super::list_session_context_snapshots(
        ai_state,
        project_name,
        workspace_name,
        filter_ai_tool,
    )
    .await?;

    let snapshots = entries
        .into_iter()
        .map(
            |(entry, stored)| crate::server::protocol::ai::AiSessionContextSnapshot {
                project_name: entry.project_name,
                workspace_name: entry.workspace_name,
                ai_tool: entry.ai_tool,
                session_id: entry.session_id,
                snapshot_at_ms: stored.snapshot_at_ms,
                message_count: stored.message_count,
                context_summary: stored.context_summary,
                selection_hint: stored.selection_hint,
                context_remaining_percent: stored.context_remaining_percent,
            },
        )
        .collect();

    Ok(ServerMessage::AICrossContextSnapshotsResult {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        snapshots,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::handlers::ai::{AIState, AiSessionIndexStore};
    use crate::server::protocol::ServerMessage;
    use crate::workspace::state::Project;
    use chrono::Utc;
    use std::collections::HashMap;
    use std::sync::Arc;

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

    // ACP 历史分页边界（WI-002）

    #[test]
    fn paginate_empty_session_returns_empty_no_more() {
        // ACP 新会话或历史为空时，should 返回 0 条消息，has_more=false
        let messages: Vec<crate::server::protocol::ai::MessageInfo> = vec![];
        let page =
            paginate_ai_session_messages(&messages, None, AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE);
        assert!(page.messages.is_empty());
        assert!(!page.has_more);
        assert_eq!(page.next_before_message_id, None);
    }

    #[test]
    fn paginate_exactly_default_page_size_returns_all_no_more() {
        // 恰好 50 条历史消息时，should 返回全部，has_more=false，无翻页游标
        let messages = build_messages(AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE);
        let page =
            paginate_ai_session_messages(&messages, None, AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE);
        assert_eq!(page.messages.len(), AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE);
        assert!(!page.has_more, "恰好 50 条时 has_more 应为 false");
        assert_eq!(
            page.next_before_message_id, None,
            "恰好 50 条时不应有翻页游标"
        );
    }

    #[test]
    fn paginate_one_more_than_default_page_size_sets_has_more() {
        // 51 条历史消息，默认页 50 条，should has_more=true 并给出翻页游标
        let messages = build_messages(AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE + 1);
        let page =
            paginate_ai_session_messages(&messages, None, AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE);
        assert_eq!(page.messages.len(), AI_SESSION_MESSAGES_DEFAULT_PAGE_SIZE);
        assert!(page.has_more, "51 条时 has_more 应为 true");
        assert_eq!(
            page.next_before_message_id.as_deref(),
            Some("msg_002"),
            "翻页游标应指向当前页第一条消息"
        );
    }

    #[test]
    fn truncate_tool_view_sections_for_history_preserves_card_shell() {
        let mut message = crate::server::protocol::ai::MessageInfo {
            id: "msg-1".to_string(),
            role: "assistant".to_string(),
            created_at: None,
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: vec![crate::server::protocol::ai::PartInfo {
                id: "tool-1".to_string(),
                part_type: "tool".to_string(),
                text: None,
                mime: None,
                filename: None,
                url: None,
                synthetic: None,
                ignored: None,
                source: None,
                tool_name: Some("bash".to_string()),
                tool_call_id: Some("call-1".to_string()),
                tool_kind: Some("terminal".to_string()),
                tool_view: Some(crate::server::protocol::ai::ToolView {
                    status: "running".to_string(),
                    display_title: "执行测试".to_string(),
                    status_text: "running".to_string(),
                    summary: Some("正在执行".to_string()),
                    header_command_summary: Some("npm test".to_string()),
                    duration_ms: None,
                    sections: vec![crate::server::protocol::ai::ToolViewSection {
                        id: "terminal-output".to_string(),
                        title: "output".to_string(),
                        content: "x".repeat(40_000),
                        style: crate::server::protocol::ai::ToolViewSectionStyle::Terminal,
                        language: None,
                        copyable: true,
                        collapsed_by_default: false,
                    }],
                    locations: vec![crate::server::protocol::ai::ToolViewLocation {
                        uri: None,
                        path: Some("src/main.ts".to_string()),
                        line: Some(1),
                        column: Some(1),
                        end_line: None,
                        end_column: None,
                        label: Some("入口".to_string()),
                    }],
                    question: None,
                    linked_session: None,
                }),
            }],
        };

        let changed = truncate_tool_view_sections_for_history(&mut message);
        let tool_view = message.parts[0]
            .tool_view
            .as_ref()
            .expect("tool_view should exist");
        let section = tool_view.sections.first().expect("section should exist");

        assert!(changed);
        assert_eq!(tool_view.display_title, "执行测试");
        assert_eq!(tool_view.status, "running");
        assert_eq!(tool_view.locations.len(), 1);
        assert!(section.content.contains("已为历史展示裁剪"));
        assert!(section.collapsed_by_default);
        assert!(section.content.chars().count() < 40_000);
    }

    #[test]
    fn resolve_messages_source_prefers_agent_when_live_snapshot_is_empty() {
        let cached_snapshot = AiStreamSnapshot::seeded(Vec::new(), None, true);
        let agent_messages = build_messages(3);
        let (messages, source) = resolve_ai_session_messages_source(
            Some(&cached_snapshot),
            Some(agent_messages.clone()),
        );

        assert_eq!(source, AiSessionMessagesSource::SnapshotEmptyFallbackAgent);
        assert_eq!(
            messages.iter().map(|it| it.id.as_str()).collect::<Vec<_>>(),
            agent_messages
                .iter()
                .map(|it| it.id.as_str())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn resolve_messages_source_prefers_snapshot_when_it_has_history() {
        let snapshot_messages = build_messages(2);
        let cached_snapshot = AiStreamSnapshot::seeded(snapshot_messages.clone(), None, true);
        let agent_messages = build_messages(4);
        let (messages, source) =
            resolve_ai_session_messages_source(Some(&cached_snapshot), Some(agent_messages));

        assert_eq!(source, AiSessionMessagesSource::Snapshot);
        assert_eq!(
            messages.iter().map(|it| it.id.as_str()).collect::<Vec<_>>(),
            snapshot_messages
                .iter()
                .map(|it| it.id.as_str())
                .collect::<Vec<_>>()
        );
    }

    fn build_test_app_state() -> SharedAppState {
        let mut app = crate::workspace::state::AppState::default();
        app.add_project(Project {
            name: "demo".to_string(),
            root_path: "/tmp/demo".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: HashMap::new(),
            commands: Vec::new(),
        });
        Arc::new(tokio::sync::RwLock::new(app))
    }

    fn build_test_ai_state_with_in_memory_index() -> SharedAIState {
        let mut ai = AIState::new();
        ai.session_index_store = Arc::new(
            AiSessionIndexStore::open_in_memory_for_test().expect("open in-memory index store"),
        );
        Arc::new(tokio::sync::Mutex::new(ai))
    }

    #[tokio::test]
    async fn query_ai_session_list_should_read_from_db_and_sort_by_updated_at() {
        let app_state = build_test_app_state();
        let ai_state = build_test_ai_state_with_in_memory_index();

        super::super::record_session_index_created(
            &ai_state,
            "demo",
            "default",
            "codex",
            "/tmp/demo",
            "s1",
            "会话 1",
            100,
            AiSessionOrigin::User,
        )
        .await
        .expect("record s1");
        super::super::record_session_index_created(
            &ai_state,
            "demo",
            "default",
            "codex",
            "/tmp/demo",
            "s2",
            "会话 2",
            200,
            AiSessionOrigin::User,
        )
        .await
        .expect("record s2");
        super::super::touch_session_index_updated_at(
            &ai_state, "demo", "default", "codex", "s1", 300,
        )
        .await
        .expect("touch s1");

        let resp = query_ai_session_list(
            &app_state,
            &ai_state,
            "demo",
            "default",
            Some("codex"),
            None,
            None,
        )
        .await
        .expect("query list");

        match resp {
            ServerMessage::AISessionListV2 {
                filter_ai_tool,
                sessions,
                has_more,
                next_cursor,
                ..
            } => {
                assert_eq!(filter_ai_tool.as_deref(), Some("codex"));
                assert_eq!(sessions.len(), 2);
                assert_eq!(sessions[0].ai_tool, "codex");
                assert_eq!(sessions[0].id, "s1");
                assert_eq!(sessions[0].updated_at, 300);
                assert_eq!(sessions[1].ai_tool, "codex");
                assert_eq!(sessions[1].id, "s2");
                assert_eq!(sessions[1].updated_at, 200);
                assert!(!has_more);
                assert_eq!(next_cursor, None);
            }
            _ => panic!("expected ai_session_list response"),
        }
    }

    #[tokio::test]
    async fn query_ai_session_list_should_keep_limit_semantics() {
        let app_state = build_test_app_state();
        let ai_state = build_test_ai_state_with_in_memory_index();

        super::super::record_session_index_created(
            &ai_state,
            "demo",
            "default",
            "codex",
            "/tmp/demo",
            "s1",
            "会话 1",
            100,
            AiSessionOrigin::User,
        )
        .await
        .expect("record s1");
        super::super::record_session_index_created(
            &ai_state,
            "demo",
            "default",
            "codex",
            "/tmp/demo",
            "s2",
            "会话 2",
            200,
            AiSessionOrigin::User,
        )
        .await
        .expect("record s2");
        super::super::record_session_index_created(
            &ai_state,
            "demo",
            "default",
            "opencode",
            "/tmp/demo",
            "s3",
            "会话 3",
            150,
            AiSessionOrigin::User,
        )
        .await
        .expect("record s3");

        let resp_limit_zero = query_ai_session_list(
            &app_state,
            &ai_state,
            "demo",
            "default",
            None,
            None,
            Some(0),
        )
        .await
        .expect("query list with limit 0");
        let resp_limit_one = query_ai_session_list(
            &app_state,
            &ai_state,
            "demo",
            "default",
            None,
            None,
            Some(1),
        )
        .await
        .expect("query list with limit 1");

        match resp_limit_zero {
            ServerMessage::AISessionListV2 {
                filter_ai_tool,
                sessions,
                has_more,
                ..
            } => {
                assert_eq!(filter_ai_tool, None);
                assert_eq!(sessions.len(), 3);
                assert!(!has_more);
            }
            _ => panic!("expected ai_session_list response"),
        }

        match resp_limit_one {
            ServerMessage::AISessionListV2 {
                sessions,
                has_more,
                next_cursor,
                ..
            } => {
                assert_eq!(sessions.len(), 1);
                assert_eq!(sessions[0].id, "s2");
                assert_eq!(sessions[0].ai_tool, "codex");
                assert!(has_more);
                assert!(next_cursor.is_some());
            }
            _ => panic!("expected ai_session_list response"),
        }
    }
}
