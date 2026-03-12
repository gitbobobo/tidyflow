use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::{info, trace, warn};

use super::SharedAIState;
use crate::ai::session_status::AiSessionStatus;
use crate::ai::{
    AiAgent, AiSessionSelectionHint, ClaudeCodeAgent, CodexAppServerAgent, CodexAppServerManager,
    CopilotAcpAgent, KimiAcpAgent, OpenCodeAgent, OpenCodeManager,
};
use crate::server::context::{SharedAppState, TaskBroadcastEvent, TaskBroadcastTx};
use crate::server::protocol::ServerMessage;

pub(crate) const IDLE_DISPOSE_TTL_MS: i64 = 15 * 60 * 1000;
pub(crate) const MAINTENANCE_INTERVAL_SECS: u64 = 60;
pub(crate) const PRELOAD_AI_TOOLS: [&str; 5] =
    ["opencode", "codex", "copilot", "kimi", "claude_code"];
// 经验值：macOS URLSession WebSocket 在超大单帧下更容易被客户端主动 reset。
// 这里对 ai_session_messages 做保守上限，优先保证“详情可打开”。
pub(crate) const MAX_AI_SESSION_MESSAGES_PAYLOAD_BYTES: usize = 900_000;
pub(crate) const MAX_AI_SESSION_UPDATE_PAYLOAD_BYTES: usize = 850_000;
pub(crate) const AI_STREAM_SNAPSHOT_TERMINAL_TTL_MS: i64 = 2 * 60 * 1000;
pub(crate) const AI_STREAM_SNAPSHOT_STALE_TTL_MS: i64 = 30 * 60 * 1000;

fn should_broadcast_stream_message(_msg: &ServerMessage, _broadcast_depth: usize) -> bool {
    // 协议已硬切到 ai_session_messages_update，不再保留旧增量事件节流分支。
    true
}

fn should_cleanup_stream_snapshot(snapshot: &AiStreamSnapshot, now: i64) -> bool {
    let terminal_expired = snapshot
        .terminal_at_ms
        .map(|terminal_at| now.saturating_sub(terminal_at) > AI_STREAM_SNAPSHOT_TERMINAL_TTL_MS)
        .unwrap_or(false);
    let stale_expired =
        now.saturating_sub(snapshot.last_updated_ms) > AI_STREAM_SNAPSHOT_STALE_TTL_MS;
    terminal_expired || stale_expired
}

#[derive(Default)]
pub(crate) struct StreamEmitState {
    pub(crate) direct_channel_closed: bool,
    direct_send_failed_logged: bool,
    broadcast_target_conn_ids: Option<Arc<HashSet<String>>>,
}

impl StreamEmitState {
    pub(crate) fn set_broadcast_targets(&mut self, targets: HashSet<String>) {
        self.broadcast_target_conn_ids = Some(Arc::new(targets));
    }
}

pub(crate) fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[derive(Clone)]
pub(crate) struct AiStreamSnapshot {
    pub(crate) messages: Vec<crate::server::protocol::ai::MessageInfo>,
    pub(crate) selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
    pub(crate) is_streaming: bool,
    pub(crate) cache_revision: u64,
    pub(crate) last_updated_ms: i64,
    pub(crate) terminal_at_ms: Option<i64>,
    message_index_by_id: HashMap<String, usize>,
    part_index_by_id: HashMap<String, (usize, usize)>,
}

impl AiStreamSnapshot {
    pub(crate) fn seeded(
        messages: Vec<crate::server::protocol::ai::MessageInfo>,
        selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
        is_streaming: bool,
    ) -> Self {
        let mut snapshot = Self {
            messages,
            selection_hint,
            is_streaming,
            cache_revision: 0,
            last_updated_ms: now_ms(),
            terminal_at_ms: if is_streaming { None } else { Some(now_ms()) },
            message_index_by_id: HashMap::new(),
            part_index_by_id: HashMap::new(),
        };
        snapshot.rebuild_indexes();
        snapshot
    }

    pub(crate) fn cache_revision(&self) -> u64 {
        self.cache_revision
    }

    pub(crate) fn touch_activity(&mut self, is_streaming: bool) -> u64 {
        let now = now_ms();
        self.cache_revision = self.cache_revision.saturating_add(1);
        self.last_updated_ms = now;
        self.is_streaming = is_streaming;
        self.terminal_at_ms = if is_streaming { None } else { Some(now) };
        self.cache_revision
    }

    pub(crate) fn apply_cache_op(
        &mut self,
        op: &crate::server::protocol::ai::AiSessionCacheOpInfo,
        selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
    ) -> u64 {
        match op {
            crate::server::protocol::ai::AiSessionCacheOpInfo::MessageUpdated {
                message_id,
                role,
            } => {
                self.ensure_message(message_id, role);
            }
            crate::server::protocol::ai::AiSessionCacheOpInfo::PartUpdated { message_id, part } => {
                let existing_role = self
                    .message_index_by_id
                    .get(message_id)
                    .and_then(|idx| self.messages.get(*idx))
                    .map(|message| message.role.clone())
                    .unwrap_or_else(|| "assistant".to_string());
                let msg_idx = self.ensure_message(message_id, &existing_role);
                if let Some((part_msg_idx, part_idx)) = self.part_index_by_id.get(&part.id).copied()
                {
                    if part_msg_idx == msg_idx && part_idx < self.messages[msg_idx].parts.len() {
                        self.messages[msg_idx].parts[part_idx] = part.clone();
                    } else {
                        self.part_index_by_id.remove(&part.id);
                        self.messages[msg_idx].parts.push(part.clone());
                        let new_part_idx = self.messages[msg_idx].parts.len().saturating_sub(1);
                        self.part_index_by_id
                            .insert(part.id.clone(), (msg_idx, new_part_idx));
                    }
                } else {
                    self.messages[msg_idx].parts.push(part.clone());
                    let new_part_idx = self.messages[msg_idx].parts.len().saturating_sub(1);
                    self.part_index_by_id
                        .insert(part.id.clone(), (msg_idx, new_part_idx));
                }
            }
            crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id,
                part_id,
                part_type,
                field,
                delta,
            } => {
                let existing_role = self
                    .message_index_by_id
                    .get(message_id)
                    .and_then(|idx| self.messages.get(*idx))
                    .map(|message| message.role.clone())
                    .unwrap_or_else(|| "assistant".to_string());
                let msg_idx = self.ensure_message(message_id, &existing_role);
                let (part_msg_idx, part_idx) = self.ensure_part(msg_idx, part_id, part_type);
                if part_msg_idx < self.messages.len()
                    && part_idx < self.messages[part_msg_idx].parts.len()
                {
                    let part = &mut self.messages[part_msg_idx].parts[part_idx];
                    if field == "text" {
                        let text = part.text.get_or_insert_with(String::new);
                        text.push_str(delta);
                    } else if part.part_type == "tool" {
                        Self::append_tool_delta(part, field, delta);
                    } else {
                        let text = part.text.get_or_insert_with(String::new);
                        text.push_str(delta);
                    }
                }
            }
        }

        if selection_hint.is_some() {
            self.selection_hint = selection_hint;
        }
        self.touch_activity(true)
    }

    pub(crate) fn part_clone(
        &self,
        message_id: &str,
        part_id: &str,
    ) -> Option<crate::server::protocol::ai::PartInfo> {
        let message_idx = *self.message_index_by_id.get(message_id)?;
        let part_idx = self
            .part_index_by_id
            .get(part_id)
            .and_then(|(msg_idx, part_idx)| {
                if *msg_idx == message_idx {
                    Some(*part_idx)
                } else {
                    None
                }
            })?;
        self.messages
            .get(message_idx)
            .and_then(|message| message.parts.get(part_idx))
            .cloned()
    }

    fn rebuild_indexes(&mut self) {
        self.message_index_by_id.clear();
        self.part_index_by_id.clear();
        for (msg_idx, message) in self.messages.iter().enumerate() {
            self.message_index_by_id.insert(message.id.clone(), msg_idx);
            for (part_idx, part) in message.parts.iter().enumerate() {
                self.part_index_by_id
                    .insert(part.id.clone(), (msg_idx, part_idx));
            }
        }
    }

    fn ensure_message(&mut self, message_id: &str, role: &str) -> usize {
        if let Some(idx) = self.message_index_by_id.get(message_id).copied() {
            if idx < self.messages.len() {
                self.messages[idx].role = role.to_string();
                return idx;
            }
            self.message_index_by_id.remove(message_id);
        }
        self.messages
            .push(crate::server::protocol::ai::MessageInfo {
                id: message_id.to_string(),
                role: role.to_string(),
                created_at: None,
                agent: None,
                model_provider_id: None,
                model_id: None,
                parts: Vec::new(),
            });
        let idx = self.messages.len().saturating_sub(1);
        self.message_index_by_id.insert(message_id.to_string(), idx);
        idx
    }

    fn ensure_part(&mut self, msg_idx: usize, part_id: &str, part_type: &str) -> (usize, usize) {
        if let Some((part_msg_idx, part_idx)) = self.part_index_by_id.get(part_id).copied() {
            if part_msg_idx < self.messages.len()
                && part_idx < self.messages[part_msg_idx].parts.len()
            {
                return (part_msg_idx, part_idx);
            }
            self.part_index_by_id.remove(part_id);
        }

        if msg_idx >= self.messages.len() {
            return (msg_idx, 0);
        }

        self.messages[msg_idx]
            .parts
            .push(crate::server::protocol::ai::PartInfo {
                id: part_id.to_string(),
                part_type: part_type.to_string(),
                text: None,
                mime: None,
                filename: None,
                url: None,
                synthetic: None,
                ignored: None,
                source: None,
                tool_name: None,
                tool_call_id: None,
                tool_kind: None,
                tool_view: Some(crate::server::protocol::ai::ToolView {
                    status: "running".to_string(),
                    display_title: "unknown".to_string(),
                    status_text: "running".to_string(),
                    summary: None,
                    header_command_summary: None,
                    duration_ms: None,
                    sections: Vec::new(),
                    locations: Vec::new(),
                    question: None,
                    linked_session: None,
                }),
            });
        let part_idx = self.messages[msg_idx].parts.len().saturating_sub(1);
        self.part_index_by_id
            .insert(part_id.to_string(), (msg_idx, part_idx));
        (msg_idx, part_idx)
    }

    fn append_tool_delta(
        part: &mut crate::server::protocol::ai::PartInfo,
        field: &str,
        delta: &str,
    ) {
        let tool_view =
            part.tool_view
                .get_or_insert_with(|| crate::server::protocol::ai::ToolView {
                    status: "running".to_string(),
                    display_title: "unknown".to_string(),
                    status_text: "running".to_string(),
                    summary: None,
                    header_command_summary: None,
                    duration_ms: None,
                    sections: Vec::new(),
                    locations: Vec::new(),
                    question: None,
                    linked_session: None,
                });
        let section_title = if field == "progress" {
            "progress"
        } else {
            "output"
        };
        let style = if field == "progress" {
            crate::server::protocol::ai::ToolViewSectionStyle::Text
        } else {
            crate::server::protocol::ai::ToolViewSectionStyle::Code
        };

        if let Some(section) = tool_view
            .sections
            .iter_mut()
            .find(|section| section.title.eq_ignore_ascii_case(section_title))
        {
            if field == "progress" && !section.content.is_empty() {
                section.content.push('\n');
            }
            section.content.push_str(delta);
            return;
        }

        tool_view
            .sections
            .push(crate::server::protocol::ai::ToolViewSection {
                id: if field == "progress" {
                    "generic-progress".to_string()
                } else {
                    "generic-output".to_string()
                },
                title: section_title.to_string(),
                content: delta.to_string(),
                style,
                language: if field == "progress" {
                    None
                } else {
                    Some("text".to_string())
                },
                copyable: true,
                collapsed_by_default: false,
            });
    }
}

/// 创建 AI 代理实例（单 opencode serve child + x-opencode-directory 路由）
pub(crate) fn create_agent(tool: &str) -> Result<Arc<dyn AiAgent>, String> {
    match tool {
        "opencode" => {
            let manager = OpenCodeManager::new(std::env::temp_dir());
            Ok(Arc::new(OpenCodeAgent::new(Arc::new(manager))))
        }
        "codex" => {
            // 需求：AI 聊天中的 codex 默认使用不受限权限模式。
            let manager = CodexAppServerManager::new_with_command(
                std::env::temp_dir(),
                "codex",
                vec![
                    "-c".to_string(),
                    "sandbox_mode=\"danger-full-access\"".to_string(),
                    "-c".to_string(),
                    "approval_policy=\"never\"".to_string(),
                    "app-server".to_string(),
                ],
                "Codex app-server",
            );
            Ok(Arc::new(CodexAppServerAgent::new(Arc::new(manager))))
        }
        "copilot" => {
            // 需求：AI 聊天中的 copilot 默认使用不受限权限模式（与 codex / claude 一致）。
            let manager = CodexAppServerManager::new_with_command_and_protocol(
                std::env::temp_dir(),
                "copilot",
                vec!["--acp".to_string(), "--allow-all".to_string()],
                "Copilot ACP server",
                Some(1),
            );
            Ok(Arc::new(CopilotAcpAgent::new_copilot(Arc::new(manager))))
        }
        "kimi" => {
            let manager = CodexAppServerManager::new_with_command_and_protocol(
                std::env::temp_dir(),
                "kimi",
                // Kimi ACP 使用标准启动参数；会话级 `/yolo` 由适配器在首次发言前自动注入。
                vec!["acp".to_string()],
                "Kimi ACP server",
                Some(1),
            );
            Ok(Arc::new(KimiAcpAgent::new_kimi(Arc::new(manager))))
        }
        "claude_code" => Ok(Arc::new(ClaudeCodeAgent::new())),
        other => Err(format!("Unsupported AI tool: {}", other)),
    }
}

pub(crate) fn normalize_ai_tool(tool: &str) -> Result<String, String> {
    let normalized = tool.trim().to_lowercase();
    match normalized.as_str() {
        "opencode" | "codex" | "copilot" | "kimi" | "claude_code" => Ok(normalized),
        "kimi-code" => Ok("kimi".to_string()),
        "claude-code" | "claudecode" => Ok("claude_code".to_string()),
        _ => Err(format!("Unsupported AI tool: {}", tool)),
    }
}

pub(crate) fn tool_directory_key(tool: &str, directory: &str) -> String {
    format!("{}::{}", tool, directory)
}

pub(crate) fn stream_key(tool: &str, directory: &str, session_id: &str) -> String {
    format!("{}::{}::{}", tool, directory, session_id)
}

pub(crate) fn map_ai_selection_hint_to_wire(
    hint: crate::ai::AiSessionSelectionHint,
) -> crate::server::protocol::ai::SessionSelectionHint {
    crate::server::protocol::ai::SessionSelectionHint {
        agent: hint.agent,
        model_provider_id: hint.model_provider_id,
        model_id: hint.model_id,
        config_options: hint.config_options,
    }
}

pub(crate) fn map_ai_message_for_wire(
    message: crate::ai::AiMessage,
) -> crate::server::protocol::ai::MessageInfo {
    crate::server::protocol::ai::MessageInfo {
        id: message.id,
        role: message.role,
        created_at: message.created_at,
        agent: message.agent,
        model_provider_id: message.model_provider_id,
        model_id: message.model_id,
        parts: message
            .parts
            .into_iter()
            .map(normalize_part_for_wire)
            .collect::<Vec<_>>(),
    }
}

pub(crate) fn map_ai_messages_for_wire(
    messages: Vec<crate::ai::AiMessage>,
) -> Vec<crate::server::protocol::ai::MessageInfo> {
    messages
        .into_iter()
        .map(map_ai_message_for_wire)
        .collect::<Vec<_>>()
}

pub(crate) fn split_utf8_text_by_max_bytes(input: &str, max_bytes: usize) -> Vec<String> {
    if input.is_empty() || max_bytes == 0 {
        return vec![input.to_string()];
    }
    if input.len() <= max_bytes {
        return vec![input.to_string()];
    }

    let mut chunks: Vec<String> = Vec::new();
    let mut start = 0usize;
    while start < input.len() {
        let mut end = (start + max_bytes).min(input.len());
        while end > start && !input.is_char_boundary(end) {
            end = end.saturating_sub(1);
        }
        if end == start {
            end = input.len();
        }
        chunks.push(input[start..end].to_string());
        start = end;
    }
    if chunks.is_empty() {
        chunks.push(input.to_string());
    }
    chunks
}

pub(crate) async fn seed_stream_snapshot(
    ai_state: &SharedAIState,
    stream_key: &str,
    messages: Vec<crate::server::protocol::ai::MessageInfo>,
    selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
    is_streaming: bool,
) {
    let mut ai = ai_state.lock().await;
    ai.stream_snapshots.insert(
        stream_key.to_string(),
        AiStreamSnapshot::seeded(messages, selection_hint, is_streaming),
    );
}

pub(crate) async fn get_stream_snapshot(
    ai_state: &SharedAIState,
    stream_key: &str,
) -> Option<AiStreamSnapshot> {
    let ai = ai_state.lock().await;
    ai.stream_snapshots.get(stream_key).cloned()
}

pub(crate) async fn remove_stream_snapshot(ai_state: &SharedAIState, stream_key: &str) -> bool {
    let mut ai = ai_state.lock().await;
    ai.stream_snapshots.remove(stream_key).is_some()
}

pub(crate) async fn apply_stream_snapshot_cache_op(
    ai_state: &SharedAIState,
    stream_key: &str,
    op: &crate::server::protocol::ai::AiSessionCacheOpInfo,
    selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
) -> AiStreamSnapshot {
    let mut ai = ai_state.lock().await;
    let snapshot = ai
        .stream_snapshots
        .entry(stream_key.to_string())
        .or_insert_with(|| AiStreamSnapshot::seeded(Vec::new(), None, true));
    snapshot.apply_cache_op(op, selection_hint);
    snapshot.clone()
}

pub(crate) fn emit_ops_for_cache_op(
    snapshot: &AiStreamSnapshot,
    op: &crate::server::protocol::ai::AiSessionCacheOpInfo,
) -> Vec<crate::server::protocol::ai::AiSessionCacheOpInfo> {
    match op {
        crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
            message_id,
            part_id,
            part_type,
            field,
            ..
        } if part_type == "tool" && field != "output" && field != "progress" => snapshot
            .part_clone(message_id, part_id)
            .map(|part| {
                vec![
                    crate::server::protocol::ai::AiSessionCacheOpInfo::PartUpdated {
                        message_id: message_id.clone(),
                        part,
                    },
                ]
            })
            .unwrap_or_else(|| vec![op.clone()]),
        _ => vec![op.clone()],
    }
}

pub(crate) async fn mark_stream_snapshot_terminal(
    ai_state: &SharedAIState,
    stream_key: &str,
    selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
) -> Option<AiStreamSnapshot> {
    let mut ai = ai_state.lock().await;
    let snapshot = ai.stream_snapshots.get_mut(stream_key)?;
    if selection_hint.is_some() {
        snapshot.selection_hint = selection_hint;
    }
    snapshot.touch_activity(false);
    Some(snapshot.clone())
}

pub(crate) fn ai_session_messages_update_encoded_len(
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
    from_revision: u64,
    to_revision: u64,
    is_streaming: bool,
    selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
    messages: Option<Vec<crate::server::protocol::ai::MessageInfo>>,
    ops: Option<Vec<crate::server::protocol::ai::AiSessionCacheOpInfo>>,
) -> Result<usize, String> {
    let payload = crate::server::protocol::ServerMessage::AISessionMessagesUpdate {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool: ai_tool.to_string(),
        session_id: session_id.to_string(),
        from_revision,
        to_revision,
        is_streaming,
        selection_hint,
        messages,
        ops,
    };
    rmp_serde::to_vec_named(&payload)
        .map(|buf| buf.len())
        .map_err(|e| format!("encode ai_session_messages_update failed: {}", e))
}

pub(crate) fn build_ai_session_messages_update(
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
    from_revision: u64,
    snapshot: &AiStreamSnapshot,
    ops: Option<Vec<crate::server::protocol::ai::AiSessionCacheOpInfo>>,
    allow_snapshot_messages_fallback: bool,
) -> crate::server::protocol::ServerMessage {
    if let Some(ref ops_payload) = ops {
        let ops_size = ai_session_messages_update_encoded_len(
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            from_revision,
            snapshot.cache_revision(),
            snapshot.is_streaming,
            snapshot.selection_hint.clone(),
            None,
            Some(ops_payload.clone()),
        );
        if let Ok(size) = ops_size {
            if size <= MAX_AI_SESSION_UPDATE_PAYLOAD_BYTES {
                return crate::server::protocol::ServerMessage::AISessionMessagesUpdate {
                    project_name: project_name.to_string(),
                    workspace_name: workspace_name.to_string(),
                    ai_tool: ai_tool.to_string(),
                    session_id: session_id.to_string(),
                    from_revision,
                    to_revision: snapshot.cache_revision(),
                    is_streaming: snapshot.is_streaming,
                    selection_hint: snapshot.selection_hint.clone(),
                    messages: None,
                    ops: Some(ops_payload.clone()),
                };
            }
            warn!(
                "ai_session_messages_update ops payload too large, fallback without ops: session_id={}, cache_revision={}, payload_bytes={}, limit_bytes={}",
                session_id,
                snapshot.cache_revision(),
                size,
                MAX_AI_SESSION_UPDATE_PAYLOAD_BYTES
            );
        } else if let Err(err) = ops_size {
            warn!(
                "ai_session_messages_update ops payload encode failed, fallback without ops: session_id={}, cache_revision={}, error={}",
                session_id,
                snapshot.cache_revision(),
                err
            );
        }
    }

    if allow_snapshot_messages_fallback {
        let full_messages = Some(snapshot.messages.clone());
        if let Ok(size) = ai_session_messages_update_encoded_len(
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            from_revision,
            snapshot.cache_revision(),
            snapshot.is_streaming,
            snapshot.selection_hint.clone(),
            full_messages.clone(),
            None,
        ) {
            if size <= MAX_AI_SESSION_UPDATE_PAYLOAD_BYTES {
                return crate::server::protocol::ServerMessage::AISessionMessagesUpdate {
                    project_name: project_name.to_string(),
                    workspace_name: workspace_name.to_string(),
                    ai_tool: ai_tool.to_string(),
                    session_id: session_id.to_string(),
                    from_revision,
                    to_revision: snapshot.cache_revision(),
                    is_streaming: snapshot.is_streaming,
                    selection_hint: snapshot.selection_hint.clone(),
                    messages: full_messages,
                    ops: None,
                };
            }
        }
    }

    crate::server::protocol::ServerMessage::AISessionMessagesUpdate {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool: ai_tool.to_string(),
        session_id: session_id.to_string(),
        from_revision,
        to_revision: snapshot.cache_revision(),
        is_streaming: snapshot.is_streaming,
        selection_hint: snapshot.selection_hint.clone(),
        messages: None,
        ops: None,
    }
}

pub(crate) async fn ai_session_subscriber_conn_ids(
    ai_state: &SharedAIState,
    session_key: &str,
    origin_conn_id: &str,
) -> HashSet<String> {
    let ai = ai_state.lock().await;
    let targets = ai
        .session_subscribers_by_key
        .get(session_key)
        .into_iter()
        .flat_map(|conn_ids| conn_ids.iter())
        .filter(|conn_id| conn_id.as_str() != origin_conn_id)
        .cloned()
        .collect::<HashSet<_>>();
    crate::server::perf::record_ai_subscriber_fanout(targets.len());
    targets
}

pub(crate) async fn emit_server_message(
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
    msg: ServerMessage,
) -> bool {
    let mut state = StreamEmitState::default();
    emit_server_message_with_state(
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
        msg,
        &mut state,
    )
    .await
}

pub(crate) async fn emit_server_message_with_state(
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
    msg: ServerMessage,
    emit_state: &mut StreamEmitState,
) -> bool {
    let mut delivered = false;
    let broadcast_depth = task_broadcast_tx.len();
    let should_broadcast = should_broadcast_stream_message(&msg, broadcast_depth);

    if !emit_state.direct_channel_closed {
        if let Err(e) = output_tx.send(msg.clone()).await {
            if !emit_state.direct_send_failed_logged {
                warn!("AI stream: failed to enqueue server message: {}", e);
                emit_state.direct_send_failed_logged = true;
            } else {
                trace!("AI stream: skip direct enqueue after channel closed: {}", e);
            }
            emit_state.direct_channel_closed = true;
        } else {
            delivered = true;
        }
    }

    if should_broadcast {
        let sent = crate::server::context::send_task_broadcast_event(
            task_broadcast_tx,
            TaskBroadcastEvent {
                origin_conn_id: origin_conn_id.to_string(),
                message: msg,
                target_conn_ids: emit_state.broadcast_target_conn_ids.clone(),
                skip_when_single_receiver: true,
            },
        );
        if sent {
            delivered = true;
        } else {
            trace!("AI stream: skip or failed to broadcast server message");
        }
    } else {
        trace!("AI stream: skip broadcast for high-frequency delta update");
    }

    delivered
}

pub(crate) async fn emit_server_message_with_targets(
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
    target_conn_ids: HashSet<String>,
    msg: ServerMessage,
) -> bool {
    let mut state = StreamEmitState::default();
    state.set_broadcast_targets(target_conn_ids);
    emit_server_message_with_state(
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
        msg,
        &mut state,
    )
    .await
}

pub(crate) async fn cleanup_stream_state(
    ai_state: &SharedAIState,
    abort_key: &str,
    tool: &str,
    directory: &str,
) {
    let mut ai = ai_state.lock().await;
    ai.active_streams.remove(abort_key);
    let dir_key = tool_directory_key(tool, directory);
    let active = ai
        .directory_active_streams
        .entry(dir_key.clone())
        .or_insert(0);
    *active = active.saturating_sub(1);
    ai.directory_last_used_ms.insert(dir_key, now_ms());
}

pub(crate) async fn resolve_directory(
    app_state: &SharedAppState,
    project_name: &str,
    workspace_name: &str,
) -> Result<String, String> {
    // 与其他 handler 对齐：`default` 工作空间应解析为项目根目录。
    let ws = crate::server::context::resolve_workspace(app_state, project_name, workspace_name)
        .await
        .map_err(|e| e.to_string())?;
    Ok(ws.root_path.to_string_lossy().to_string())
}

pub(crate) fn ai_session_messages_encoded_len(
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
    before_message_id: Option<String>,
    messages: Vec<crate::server::protocol::ai::MessageInfo>,
    has_more: bool,
    next_before_message_id: Option<String>,
    selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
    truncated: Option<bool>,
) -> Result<usize, String> {
    let payload = crate::server::protocol::ServerMessage::AISessionMessages {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool: ai_tool.to_string(),
        session_id: session_id.to_string(),
        before_message_id,
        messages,
        has_more,
        next_before_message_id,
        selection_hint,
        truncated,
    };
    rmp_serde::to_vec_named(&payload)
        .map(|buf| buf.len())
        .map_err(|e| format!("encode ai_session_messages failed: {}", e))
}

pub(crate) fn ai_session_messages_stats(
    messages: &[crate::server::protocol::ai::MessageInfo],
) -> (usize, usize) {
    let mut parts_count = 0usize;
    let mut text_bytes = 0usize;
    for message in messages {
        parts_count += message.parts.len();
        text_bytes += message
            .parts
            .iter()
            .filter_map(|part| part.text.as_ref())
            .map(|text| text.len())
            .sum::<usize>();
    }
    (parts_count, text_bytes)
}

pub(crate) fn canonical_meta_key(raw: &str) -> String {
    raw.chars()
        .filter(|ch| *ch != '_' && *ch != '-')
        .flat_map(|ch| ch.to_lowercase())
        .collect::<String>()
}

pub(crate) fn json_value_to_trimmed_string(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        serde_json::Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

pub(crate) fn find_scalar_by_keys(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
    let target = keys
        .iter()
        .map(|key| canonical_meta_key(key))
        .collect::<Vec<_>>();
    let mut stack = vec![value];
    let mut visited = 0usize;
    const MAX_VISITS: usize = 400;

    while let Some(node) = stack.pop() {
        if visited >= MAX_VISITS {
            break;
        }
        visited += 1;
        match node {
            serde_json::Value::Object(map) => {
                for (k, v) in map {
                    let canonical = canonical_meta_key(k);
                    if target.iter().any(|key| key == &canonical) {
                        if let Some(found) = json_value_to_trimmed_string(v) {
                            return Some(found);
                        }
                    }
                    if matches!(
                        v,
                        serde_json::Value::Object(_) | serde_json::Value::Array(_)
                    ) {
                        stack.push(v);
                    }
                }
            }
            serde_json::Value::Array(arr) => {
                for item in arr {
                    if matches!(
                        item,
                        serde_json::Value::Object(_) | serde_json::Value::Array(_)
                    ) {
                        stack.push(item);
                    }
                }
            }
            _ => {}
        }
    }

    None
}

pub(crate) fn find_object_by_keys(
    value: &serde_json::Value,
    keys: &[&str],
) -> Option<serde_json::Map<String, serde_json::Value>> {
    let target = keys
        .iter()
        .map(|key| canonical_meta_key(key))
        .collect::<Vec<_>>();
    let mut stack = vec![value];
    let mut visited = 0usize;
    const MAX_VISITS: usize = 400;

    while let Some(node) = stack.pop() {
        if visited >= MAX_VISITS {
            break;
        }
        visited += 1;
        match node {
            serde_json::Value::Object(map) => {
                for (k, v) in map {
                    let canonical = canonical_meta_key(k);
                    if target.iter().any(|key| key == &canonical) {
                        if let Some(found) = v.as_object() {
                            return Some(found.clone());
                        }
                    }
                    if matches!(
                        v,
                        serde_json::Value::Object(_) | serde_json::Value::Array(_)
                    ) {
                        stack.push(v);
                    }
                }
            }
            serde_json::Value::Array(arr) => {
                for item in arr {
                    if matches!(
                        item,
                        serde_json::Value::Object(_) | serde_json::Value::Array(_)
                    ) {
                        stack.push(item);
                    }
                }
            }
            _ => {}
        }
    }

    None
}

pub(crate) fn normalize_agent_hint(raw: &str) -> Option<String> {
    let normalized = raw.trim().to_lowercase();
    if normalized.is_empty() {
        return None;
    }
    if normalized.contains("#plan") {
        return Some("plan".to_string());
    }
    if normalized.contains("#agent") {
        return Some("agent".to_string());
    }
    Some(normalized)
}

pub(crate) fn normalize_optional_token(raw: Option<String>) -> Option<String> {
    let token = raw?;
    let trimmed = token.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

pub(crate) fn infer_hint_from_json(value: &serde_json::Value) -> AiSessionSelectionHint {
    let mut hint = AiSessionSelectionHint::default();

    // mode/agent 只采纳语义清晰的键，避免误把通用 `mode` 字段识别为 agent。
    let agent_keys = [
        "agent",
        "agent_name",
        "selected_agent",
        "current_agent",
        "collaboration_mode",
        "current_mode_id",
        "mode_id",
    ];
    if let Some(agent) = find_scalar_by_keys(value, &agent_keys) {
        hint.agent = normalize_agent_hint(&agent);
    }

    let provider_keys = [
        "model_provider_id",
        "model_provider",
        "modelProvider",
        "provider_id",
        "providerID",
        "modelProviderID",
    ];
    hint.model_provider_id = normalize_optional_token(find_scalar_by_keys(value, &provider_keys));

    let model_keys = [
        "model_id",
        "modelID",
        "selected_model",
        "current_model_id",
        "model",
    ];
    hint.model_id = normalize_optional_token(find_scalar_by_keys(value, &model_keys));
    hint.config_options = find_object_by_keys(
        value,
        &[
            "config_options",
            "configOptions",
            "session_config_options",
            "sessionConfigOptions",
        ],
    )
    .and_then(|items| {
        let map = items
            .into_iter()
            .filter(|(k, _)| !k.trim().is_empty())
            .collect::<HashMap<_, _>>();
        if map.is_empty() {
            None
        } else {
            Some(map)
        }
    });

    hint
}

pub(crate) fn merge_session_selection_hint(
    preferred: AiSessionSelectionHint,
    fallback: AiSessionSelectionHint,
) -> Option<crate::server::protocol::ai::SessionSelectionHint> {
    let agent = preferred
        .agent
        .or(fallback.agent)
        .and_then(|v| normalize_agent_hint(&v));
    let model_provider_id = preferred
        .model_provider_id
        .or(fallback.model_provider_id)
        .and_then(|v| normalize_optional_token(Some(v)));
    let model_id = preferred
        .model_id
        .or(fallback.model_id)
        .and_then(|v| normalize_optional_token(Some(v)));
    let config_options = match (preferred.config_options, fallback.config_options) {
        (Some(mut preferred_map), Some(fallback_map)) => {
            for (key, value) in fallback_map {
                preferred_map.entry(key).or_insert(value);
            }
            if preferred_map.is_empty() {
                None
            } else {
                Some(preferred_map)
            }
        }
        (Some(preferred_map), None) => {
            if preferred_map.is_empty() {
                None
            } else {
                Some(preferred_map)
            }
        }
        (None, Some(fallback_map)) => {
            if fallback_map.is_empty() {
                None
            } else {
                Some(fallback_map)
            }
        }
        (None, None) => None,
    };

    if agent.is_none()
        && model_provider_id.is_none()
        && model_id.is_none()
        && config_options.is_none()
    {
        None
    } else {
        Some(crate::server::protocol::ai::SessionSelectionHint {
            agent,
            model_provider_id,
            model_id,
            config_options,
        })
    }
}

pub(crate) fn infer_selection_hint_from_messages(
    messages: &[crate::server::protocol::ai::MessageInfo],
) -> AiSessionSelectionHint {
    let mut resolved = AiSessionSelectionHint::default();

    for message in messages
        .iter()
        .rev()
        .filter(|m| m.role.eq_ignore_ascii_case("user"))
    {
        if resolved.agent.is_none() {
            resolved.agent = message.agent.clone();
        }
        if resolved.model_provider_id.is_none() {
            resolved.model_provider_id = message.model_provider_id.clone();
        }
        if resolved.model_id.is_none() {
            resolved.model_id = message.model_id.clone();
        }
        if resolved.agent.is_some() && resolved.model_id.is_some() {
            return resolved;
        }
    }

    for message in messages.iter().rev() {
        if resolved.agent.is_none() {
            resolved.agent = message.agent.clone();
        }
        if resolved.model_provider_id.is_none() {
            resolved.model_provider_id = message.model_provider_id.clone();
        }
        if resolved.model_id.is_none() {
            resolved.model_id = message.model_id.clone();
        }
        if resolved.agent.is_some() && resolved.model_id.is_some() {
            return resolved;
        }
    }

    for message in messages.iter().rev() {
        for part in message.parts.iter().rev() {
            let mut candidates: Vec<&serde_json::Value> = Vec::new();
            if let Some(source) = part.source.as_ref() {
                candidates.push(source);
            }
            for candidate in candidates {
                let hint = infer_hint_from_json(candidate);
                if resolved.agent.is_none() {
                    resolved.agent = hint.agent;
                }
                if resolved.model_provider_id.is_none() {
                    resolved.model_provider_id = hint.model_provider_id;
                }
                if resolved.model_id.is_none() {
                    resolved.model_id = hint.model_id;
                }
                if resolved.agent.is_some() && resolved.model_id.is_some() {
                    return resolved;
                }
            }
        }
    }
    resolved
}

pub(crate) async fn ensure_agent(
    ai_state: &SharedAIState,
    tool: &str,
) -> Result<Arc<dyn AiAgent>, String> {
    let agent = {
        let mut ai = ai_state.lock().await;
        if !ai.agents.contains_key(tool) {
            ai.agents.insert(tool.to_string(), create_agent(tool)?);
        }
        ai.agents.get(tool).unwrap().clone()
    };

    // start() 幂等：内部会 health check，失败才 spawn；event hub 也会 ensure_started。
    agent.start().await?;
    Ok(agent)
}

pub(crate) async fn preload_agents_on_startup(ai_state: &SharedAIState) {
    ensure_maintenance(ai_state).await;

    for tool in PRELOAD_AI_TOOLS {
        match ensure_agent(ai_state, tool).await {
            Ok(_) => info!("AI startup preload succeeded: tool={}", tool),
            Err(e) => warn!("AI startup preload failed: tool={}, error={}", tool, e),
        }
    }
}

pub(crate) async fn shutdown_agents(ai_state: &SharedAIState) {
    let agents = {
        let mut ai = ai_state.lock().await;
        let drained = ai.agents.drain().collect::<Vec<_>>();
        ai.active_streams.clear();
        ai.stream_snapshots.clear();
        ai.directory_active_streams.clear();
        ai.directory_last_used_ms.clear();
        drained
    };

    if agents.is_empty() {
        info!("AI shutdown: no agents to stop");
        return;
    }

    for (tool, agent) in agents {
        match tokio::time::timeout(std::time::Duration::from_secs(8), agent.stop()).await {
            Ok(Ok(())) => info!("AI shutdown: stopped agent tool={}", tool),
            Ok(Err(e)) => warn!(
                "AI shutdown: failed to stop agent tool={}, error={}",
                tool, e
            ),
            Err(_) => warn!("AI shutdown: stop timeout tool={}", tool),
        }
    }
}

pub(crate) async fn ensure_maintenance(ai_state: &SharedAIState) {
    let should_start = {
        let mut ai = ai_state.lock().await;
        if ai.maintenance_started {
            false
        } else {
            ai.maintenance_started = true;
            true
        }
    };
    if !should_start {
        return;
    }

    let ai_state = ai_state.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(MAINTENANCE_INTERVAL_SECS)).await;

            let now = now_ms();
            let idle_keys: Vec<String> = {
                let ai = ai_state.lock().await;
                ai.directory_last_used_ms
                    .iter()
                    .filter_map(|(key, last_used)| {
                        let active = ai.directory_active_streams.get(key).cloned().unwrap_or(0);
                        if active == 0 && now.saturating_sub(*last_used) > IDLE_DISPOSE_TTL_MS {
                            Some(key.clone())
                        } else {
                            None
                        }
                    })
                    .collect()
            };
            let stale_snapshot_keys: Vec<String> = {
                let ai = ai_state.lock().await;
                ai.stream_snapshots
                    .iter()
                    .filter_map(|(key, snapshot)| {
                        if should_cleanup_stream_snapshot(snapshot, now) {
                            Some(key.clone())
                        } else {
                            None
                        }
                    })
                    .collect()
            };

            for key in idle_keys {
                let mut parts = key.splitn(2, "::");
                let Some(tool) = parts.next() else { continue };
                let Some(dir) = parts.next() else { continue };

                let agent = {
                    let ai = ai_state.lock().await;
                    ai.agents.get(tool).cloned()
                };
                if let Some(agent) = agent {
                    match agent.dispose_instance(dir).await {
                        Ok(_) => {
                            let mut ai = ai_state.lock().await;
                            // dispose 后更新时间戳，避免立即重复 dispose
                            ai.directory_last_used_ms.insert(key.clone(), now_ms());
                        }
                        Err(e) => warn!("AI maintenance: dispose_instance failed: {}", e),
                    }
                }
            }

            if !stale_snapshot_keys.is_empty() {
                let mut ai = ai_state.lock().await;
                for key in stale_snapshot_keys {
                    ai.stream_snapshots.remove(&key);
                }
            }
        }
    });
}

pub(crate) fn status_to_info(
    status: &AiSessionStatus,
    context_remaining_percent: Option<f64>,
) -> crate::server::protocol::ai::AiSessionStatusInfo {
    crate::server::protocol::ai::AiSessionStatusInfo {
        status: status.status_str().to_string(),
        error_message: status.error_message(),
        context_remaining_percent,
    }
}

fn normalized_status(raw: Option<&str>) -> &'static str {
    let token = raw.unwrap_or_default().trim().to_ascii_lowercase();
    match token.as_str() {
        "" => "unknown",
        "pending" => "pending",
        "awaiting_input" | "requires_input" | "in_progress" | "inprogress" => "running",
        "running" | "progress" => "running",
        "done" | "success" | "succeeded" | "completed" => "completed",
        "failed" | "failure" | "rejected" | "cancelled" | "canceled" | "error" => "error",
        other => {
            if other.contains("progress") {
                "running"
            } else {
                "unknown"
            }
        }
    }
}

fn tool_status_text(status: &str) -> String {
    status.to_string()
}

fn json_string(value: &serde_json::Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
}

fn parse_input_map(value: Option<&serde_json::Value>) -> HashMap<String, serde_json::Value> {
    match value {
        Some(serde_json::Value::Object(map)) => map.clone().into_iter().collect(),
        Some(serde_json::Value::String(text)) => serde_json::from_str::<serde_json::Value>(text)
            .ok()
            .and_then(|value| value.as_object().cloned())
            .map(|map| map.into_iter().collect())
            .unwrap_or_default(),
        _ => HashMap::new(),
    }
}

fn value_as_string(value: Option<&serde_json::Value>) -> Option<String> {
    match value {
        Some(serde_json::Value::String(text)) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        Some(serde_json::Value::Number(number)) => Some(number.to_string()),
        Some(serde_json::Value::Bool(value)) => Some(value.to_string()),
        _ => None,
    }
}

fn first_non_empty_input_string(
    input: &HashMap<String, serde_json::Value>,
    keys: &[&str],
) -> Option<String> {
    keys.iter()
        .find_map(|key| value_as_string(input.get(*key)))
}

fn first_non_empty_input_array_string(
    input: &HashMap<String, serde_json::Value>,
    keys: &[&str],
) -> Option<String> {
    keys.iter().find_map(|key| {
        input.get(*key).and_then(|value| match value {
            serde_json::Value::Array(items) => items.iter().find_map(|item| value_as_string(Some(item))),
            _ => None,
        })
    })
}

fn tool_content_display_title(
    tool_id: &str,
    input: &HashMap<String, serde_json::Value>,
) -> Option<String> {
    match tool_id {
        "read" | "edit" => first_non_empty_input_string(
            input,
            &["path", "file", "filePath", "file_path"],
        )
        .or_else(|| first_non_empty_input_array_string(input, &["paths", "files"])),
        "search" | "websearch" => {
            first_non_empty_input_string(input, &["pattern", "query", "search"])
        }
        _ => None,
    }
}

fn value_as_f64(value: Option<&serde_json::Value>) -> Option<f64> {
    match value {
        Some(serde_json::Value::Number(number)) => number.as_f64(),
        Some(serde_json::Value::String(text)) => text.parse::<f64>().ok(),
        _ => None,
    }
}

fn format_json_map(map: &HashMap<String, serde_json::Value>) -> Option<String> {
    if map.is_empty() {
        None
    } else {
        Some(json_string(&serde_json::Value::Object(
            map.clone().into_iter().collect(),
        )))
    }
}

fn tool_display_name(tool_id: &str) -> String {
    if tool_id.trim().is_empty() {
        "tool".to_string()
    } else {
        tool_id.to_string()
    }
}

fn tool_section(
    id: impl Into<String>,
    title: impl Into<String>,
    content: impl Into<String>,
    style: crate::server::protocol::ai::ToolViewSectionStyle,
    language: Option<&str>,
) -> crate::server::protocol::ai::ToolViewSection {
    crate::server::protocol::ai::ToolViewSection {
        id: id.into(),
        title: title.into(),
        content: content.into(),
        style,
        language: language.map(|it| it.to_string()),
        copyable: true,
        collapsed_by_default: false,
    }
}

fn progress_section(
    metadata: Option<&serde_json::Map<String, serde_json::Value>>,
    id_prefix: &str,
) -> Option<crate::server::protocol::ai::ToolViewSection> {
    let lines = metadata
        .and_then(|m| m.get("progress_lines"))
        .and_then(|value| value.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| value_as_string(Some(item)))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if lines.is_empty() {
        return None;
    }
    Some(tool_section(
        format!("{}-progress", id_prefix),
        "progress",
        lines.join("\n"),
        crate::server::protocol::ai::ToolViewSectionStyle::Text,
        None,
    ))
}

fn terminal_command_summary(input: &HashMap<String, serde_json::Value>) -> Option<String> {
    for key in ["command", "cmd", "script"] {
        if let Some(command) = value_as_string(input.get(key)) {
            return Some(command);
        }
    }
    None
}

fn extract_acp_content_text(value: &serde_json::Value) -> Option<String> {
    let items = value.as_array()?;
    let mut parts: Vec<String> = Vec::new();
    for item in items {
        let obj = item.as_object()?;
        if value_as_string(obj.get("type")).as_deref() != Some("content") {
            continue;
        }
        let Some(content) = obj.get("content").and_then(|value| value.as_object()) else {
            continue;
        };
        if value_as_string(content.get("type")).as_deref() != Some("text") {
            continue;
        }
        if let Some(text) = value_as_string(content.get("text")) {
            parts.push(text);
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join(""))
    }
}

fn build_unified_diff_from_snapshot(path: &str, old_text: Option<&str>, new_text: &str) -> String {
    let old_lines = old_text
        .unwrap_or_default()
        .lines()
        .map(|line| format!("-{}", line))
        .collect::<Vec<_>>();
    let new_lines = new_text
        .lines()
        .map(|line| format!("+{}", line))
        .collect::<Vec<_>>();
    let old_count = old_text.unwrap_or_default().lines().count().max(1);
    let new_count = new_text.lines().count().max(1);
    let mut lines = vec![
        format!("--- {}", path),
        format!("+++ {}", path),
        format!("@@ -1,{} +1,{} @@", old_count, new_count),
    ];
    lines.extend(old_lines);
    lines.extend(new_lines);
    lines.join("\n")
}

fn structured_content_to_tool_sections(
    value: Option<&serde_json::Value>,
) -> Vec<crate::server::protocol::ai::ToolViewSection> {
    let Some(items) = value.and_then(|value| value.as_array()) else {
        return Vec::new();
    };

    let mut sections = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let Some(obj) = item.as_object() else {
            continue;
        };
        let item_type = value_as_string(obj.get("type"))
            .map(|value| value.to_ascii_lowercase())
            .unwrap_or_default();
        match item_type.as_str() {
            "content" => {
                let Some(content) = obj.get("content").and_then(|value| value.as_object()) else {
                    continue;
                };
                let content_type = value_as_string(content.get("type"))
                    .map(|value| value.to_ascii_lowercase())
                    .unwrap_or_default();
                match content_type.as_str() {
                    "text" => {
                        if let Some(text) = value_as_string(content.get("text")) {
                            sections.push(tool_section(
                                format!("structured-content-{}", index),
                                "output",
                                text,
                                crate::server::protocol::ai::ToolViewSectionStyle::Text,
                                None,
                            ));
                        }
                    }
                    "markdown" | "md" => {
                        if let Some(text) = value_as_string(content.get("text"))
                            .or_else(|| value_as_string(content.get("markdown")))
                            .or_else(|| value_as_string(content.get("content")))
                        {
                            sections.push(tool_section(
                                format!("structured-markdown-{}", index),
                                "markdown",
                                text,
                                crate::server::protocol::ai::ToolViewSectionStyle::Markdown,
                                None,
                            ));
                        }
                    }
                    "resource" | "resource_link" => {
                        if let Some(text) = value_as_string(content.get("text"))
                            .or_else(|| value_as_string(content.get("uri")))
                            .or_else(|| value_as_string(content.get("name")))
                        {
                            sections.push(tool_section(
                                format!("structured-resource-{}", index),
                                "resource",
                                text,
                                crate::server::protocol::ai::ToolViewSectionStyle::Text,
                                None,
                            ));
                        }
                    }
                    _ => {
                        sections.push(tool_section(
                            format!("structured-content-raw-{}", index),
                            "output",
                            json_string(item),
                            crate::server::protocol::ai::ToolViewSectionStyle::Code,
                            Some("json"),
                        ));
                    }
                }
            }
            "diff" => {
                let path =
                    value_as_string(obj.get("path")).unwrap_or_else(|| "unknown".to_string());
                let new_text = value_as_string(obj.get("newText").or_else(|| obj.get("new_text")));
                if let Some(new_text) = new_text {
                    let old_text =
                        value_as_string(obj.get("oldText").or_else(|| obj.get("old_text")));
                    sections.push(tool_section(
                        format!("structured-diff-{}", index),
                        "diff",
                        build_unified_diff_from_snapshot(&path, old_text.as_deref(), &new_text),
                        crate::server::protocol::ai::ToolViewSectionStyle::Diff,
                        Some("diff"),
                    ));
                }
            }
            "terminal" => {
                if let Some(terminal_id) =
                    value_as_string(obj.get("terminalId").or_else(|| obj.get("terminal_id")))
                {
                    sections.push(tool_section(
                        format!("structured-terminal-{}", index),
                        "terminal",
                        format!("terminalId: {}", terminal_id),
                        crate::server::protocol::ai::ToolViewSectionStyle::Terminal,
                        Some("text"),
                    ));
                }
            }
            _ => {}
        }
    }

    sections
}

fn semantic_tool_id_for_view(tool_name: Option<&str>, tool_kind: Option<&str>) -> String {
    let normalized_kind = tool_kind
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty());
    if matches!(normalized_kind.as_deref(), Some("websearch")) {
        return "websearch".to_string();
    }
    if let Some(mapped) = crate::ai::acp::tool_call::tool_kind_semantic_id(tool_kind) {
        return mapped.to_string();
    }

    let normalized_name = tool_name
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    match normalized_name.as_str() {
        "bash" => "terminal".to_string(),
        "websearch" => "websearch".to_string(),
        "grep" | "glob" | "list" | "codesearch" | "webfetch" => "search".to_string(),
        other => other.to_string(),
    }
}

fn is_web_search_tool(
    tool_name: Option<&str>,
    tool_kind: Option<&str>,
    input: &HashMap<String, serde_json::Value>,
) -> bool {
    let normalized_kind = tool_kind
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty());
    if matches!(normalized_kind.as_deref(), Some("websearch")) {
        return true;
    }

    let normalized_name = tool_name
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty());
    if matches!(normalized_name.as_deref(), Some("websearch")) {
        return true;
    }

    matches!(normalized_kind.as_deref(), Some("search"))
        && input
            .get("query")
            .and_then(|value| value_as_string(Some(value)))
            .is_some()
        && input
            .get("pattern")
            .and_then(|value| value_as_string(Some(value)))
            .is_none()
        && input
            .get("path")
            .and_then(|value| value_as_string(Some(value)))
            .is_none()
}

fn normalized_tool_kind_for_wire(
    tool_name: Option<&str>,
    tool_kind: Option<&str>,
    input: &HashMap<String, serde_json::Value>,
) -> Option<String> {
    if is_web_search_tool(tool_name, tool_kind, input) {
        return Some("websearch".to_string());
    }
    if let Some(mapped) = crate::ai::acp::tool_call::tool_kind_semantic_id(tool_kind) {
        return Some(mapped.to_string());
    }
    let semantic = semantic_tool_id_for_view(tool_name, tool_kind);
    if semantic == "unknown" {
        tool_kind.map(|value| value.to_string())
    } else {
        Some(semantic)
    }
}

fn extract_session_id_recursive(
    value: &serde_json::Value,
    keys: &HashSet<&'static str>,
) -> Option<String> {
    match value {
        serde_json::Value::Object(map) => {
            for (raw_key, nested) in map {
                let key = raw_key
                    .replace('-', "")
                    .replace('_', "")
                    .to_ascii_lowercase();
                if keys.contains(key.as_str()) {
                    if let Some(found) = value_as_string(Some(nested)) {
                        return Some(found);
                    }
                }
                if let Some(found) = extract_session_id_recursive(nested, keys) {
                    return Some(found);
                }
            }
            None
        }
        serde_json::Value::Array(items) => items
            .iter()
            .find_map(|item| extract_session_id_recursive(item, keys)),
        _ => None,
    }
}

fn build_tool_question(
    part: &crate::ai::AiPart,
    state_obj: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Option<crate::server::protocol::ai::ToolViewQuestion> {
    if !part
        .tool_name
        .as_deref()?
        .trim()
        .eq_ignore_ascii_case("question")
    {
        return None;
    }
    let questions_value = state_obj
        .and_then(|obj| obj.get("input"))
        .and_then(|value| value.as_object())
        .and_then(|input| input.get("questions"))
        .or_else(|| state_obj.and_then(|obj| obj.get("questions")))?;
    let prompt_items = questions_value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let dict = item.as_object()?;
                    let question = value_as_string(dict.get("question"))?;
                    let header = value_as_string(dict.get("header")).unwrap_or_default();
                    let options = dict
                        .get("options")
                        .and_then(|value| value.as_array())
                        .map(|options| {
                            options
                                .iter()
                                .filter_map(|option| {
                                    let dict = option.as_object()?;
                                    let label = value_as_string(dict.get("label"))?;
                                    Some(crate::server::protocol::ai::ToolViewQuestionOption {
                                        option_id: value_as_string(dict.get("option_id"))
                                            .or_else(|| value_as_string(dict.get("optionId"))),
                                        label,
                                        description: value_as_string(dict.get("description"))
                                            .unwrap_or_default(),
                                    })
                                })
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    Some(crate::server::protocol::ai::ToolViewQuestionPromptItem {
                        question,
                        header,
                        options,
                        multiple: dict
                            .get("multiple")
                            .and_then(|value| value.as_bool())
                            .unwrap_or(false),
                        custom: dict
                            .get("custom")
                            .and_then(|value| value.as_bool())
                            .unwrap_or(true),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if prompt_items.is_empty() {
        return None;
    }

    let request_id = state_obj
        .and_then(|obj| obj.get("request_id"))
        .and_then(|value| value_as_string(Some(value)))
        .or_else(|| {
            state_obj
                .and_then(|obj| obj.get("metadata"))
                .and_then(|value| value.as_object())
                .and_then(|metadata| metadata.get("request_id"))
                .and_then(|value| value_as_string(Some(value)))
        })
        .or_else(|| {
            part.tool_part_metadata
                .as_ref()
                .and_then(|value| value.as_object())
                .and_then(|metadata| metadata.get("request_id"))
                .and_then(|value| value_as_string(Some(value)))
        })
        .or_else(|| part.tool_call_id.clone())
        .or_else(|| Some(part.id.clone()))?;
    let tool_message_id = state_obj
        .and_then(|obj| obj.get("metadata"))
        .and_then(|value| value.as_object())
        .and_then(|metadata| metadata.get("tool_message_id"))
        .and_then(|value| value_as_string(Some(value)))
        .or_else(|| {
            part.tool_part_metadata
                .as_ref()
                .and_then(|value| value.as_object())
                .and_then(|metadata| metadata.get("tool_message_id"))
                .and_then(|value| value_as_string(Some(value)))
        })
        .or_else(|| Some(part.id.clone()));
    let answers = state_obj
        .and_then(|obj| obj.get("metadata"))
        .and_then(|value| value.as_object())
        .and_then(|metadata| metadata.get("answers"))
        .and_then(|value| value.as_array())
        .map(|groups| {
            groups
                .iter()
                .map(|group| {
                    group
                        .as_array()
                        .map(|values| {
                            values
                                .iter()
                                .filter_map(|value| value_as_string(Some(value)))
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default()
                })
                .collect::<Vec<_>>()
        });
    let interactive = matches!(
        normalized_status(
            state_obj
                .and_then(|obj| obj.get("status"))
                .and_then(|value| value.as_str())
        ),
        "pending" | "running" | "unknown"
    );
    Some(crate::server::protocol::ai::ToolViewQuestion {
        request_id,
        tool_message_id,
        prompt_items,
        interactive,
        answers,
    })
}

fn build_tool_linked_session(
    tool_id: &str,
    input: &HashMap<String, serde_json::Value>,
    metadata: Option<&serde_json::Map<String, serde_json::Value>>,
    part_metadata: Option<&serde_json::Map<String, serde_json::Value>>,
    output: Option<&str>,
) -> Option<crate::server::protocol::ai::ToolLinkedSession> {
    if tool_id != "task" && tool_id != "subagent_result" {
        return None;
    }
    let keys = HashSet::from([
        "sessionid",
        "session_id",
        "threadid",
        "thread_id",
        "conversationid",
        "conversation_id",
        "childsessionid",
        "child_session_id",
        "subsessionid",
        "sub_session_id",
        "subagentsessionid",
        "subagent_session_id",
        "agentsessionid",
        "agent_session_id",
    ]);
    let session_id = extract_session_id_recursive(
        &serde_json::Value::Object(input.clone().into_iter().collect()),
        &keys,
    )
    .or_else(|| {
        metadata.and_then(|map| {
            extract_session_id_recursive(&serde_json::Value::Object(map.clone()), &keys)
        })
    })
    .or_else(|| {
        part_metadata.and_then(|map| {
            extract_session_id_recursive(&serde_json::Value::Object(map.clone()), &keys)
        })
    })?;
    let agent_name = metadata
        .and_then(|map| map.get("agent"))
        .and_then(|value| value_as_string(Some(value)))
        .or_else(|| {
            part_metadata
                .and_then(|map| map.get("agent"))
                .and_then(|value| value_as_string(Some(value)))
        })
        .or_else(|| {
            input
                .get("agent")
                .and_then(|value| value_as_string(Some(value)))
        })
        .or_else(|| {
            input
                .get("subagent_type")
                .and_then(|value| value_as_string(Some(value)))
        })
        .or_else(|| {
            input
                .get("subagent")
                .and_then(|value| value_as_string(Some(value)))
        })
        .or_else(|| {
            output.and_then(|text| {
                text.lines().find_map(|line| {
                    let trimmed = line.trim();
                    trimmed
                        .strip_prefix("Agent:")
                        .or_else(|| trimmed.strip_prefix("agent:"))
                        .map(|token| token.trim().to_string())
                        .filter(|token| !token.is_empty())
                })
            })
        })
        .unwrap_or_else(|| "未知代理".to_string());
    let description = input
        .get("description")
        .and_then(|value| value_as_string(Some(value)))
        .or_else(|| {
            metadata
                .and_then(|map| map.get("description"))
                .and_then(|value| value_as_string(Some(value)))
        })
        .or_else(|| {
            part_metadata
                .and_then(|map| map.get("description"))
                .and_then(|value| value_as_string(Some(value)))
        })
        .unwrap_or_else(|| "子会话".to_string());
    Some(crate::server::protocol::ai::ToolLinkedSession {
        session_id,
        agent_name,
        description,
    })
}

fn build_tool_locations(
    items: Option<Vec<crate::ai::AiToolCallLocation>>,
) -> Vec<crate::server::protocol::ai::ToolViewLocation> {
    items
        .unwrap_or_default()
        .into_iter()
        .map(|item| crate::server::protocol::ai::ToolViewLocation {
            uri: item.uri,
            path: item.path,
            line: item.line,
            column: item.column,
            end_line: item.end_line,
            end_column: item.end_column,
            label: item.label,
        })
        .collect()
}

fn build_tool_summary(
    tool_id: &str,
    input: &HashMap<String, serde_json::Value>,
    metadata: Option<&serde_json::Map<String, serde_json::Value>>,
    output: Option<&str>,
) -> Option<String> {
    match tool_id {
        "search" | "list" | "codesearch" | "webfetch" | "websearch" => input
            .get("query")
            .and_then(|value| value_as_string(Some(value)))
            .or_else(|| {
                input
                    .get("pattern")
                    .and_then(|value| value_as_string(Some(value)))
            })
            .or_else(|| {
                input
                    .get("url")
                    .and_then(|value| value_as_string(Some(value)))
            })
            .or_else(|| {
                input
                    .get("path")
                    .and_then(|value| value_as_string(Some(value)))
            }),
        "grep" => metadata
            .and_then(|map| map.get("matches"))
            .and_then(|value| value_as_string(Some(value)))
            .map(|count| format!("Found {} match(es)", count))
            .or_else(|| {
                output.and_then(|text| text.lines().next().map(|line| line.trim().to_string()))
            }),
        "glob" => metadata
            .and_then(|map| map.get("files"))
            .and_then(|value| value_as_string(Some(value)))
            .map(|count| format!("Found {} file(s)", count))
            .or_else(|| {
                output.and_then(|text| text.lines().next().map(|line| line.trim().to_string()))
            }),
        _ => None,
    }
}

fn format_todo_summary(items: &[serde_json::Map<String, serde_json::Value>]) -> Option<String> {
    if items.is_empty() {
        return None;
    }
    let total = items.len();
    let completed = items
        .iter()
        .filter(|item| {
            value_as_string(item.get("status"))
                .map(|status| status.eq_ignore_ascii_case("completed"))
                .unwrap_or(false)
        })
        .count();
    let running = items
        .iter()
        .filter(|item| {
            value_as_string(item.get("status"))
                .map(|status| status.eq_ignore_ascii_case("in_progress"))
                .unwrap_or(false)
        })
        .count();
    let pending = items
        .iter()
        .filter(|item| {
            value_as_string(item.get("status"))
                .map(|status| status.eq_ignore_ascii_case("pending"))
                .unwrap_or(false)
        })
        .count();
    let mut parts = vec![format!("{} 项任务", total)];
    if completed > 0 {
        parts.push(format!("已完成 {}", completed));
    }
    if running > 0 {
        parts.push(format!("进行中 {}", running));
    }
    if pending > 0 {
        parts.push(format!("待处理 {}", pending));
    }
    Some(parts.join(" · "))
}

fn build_tool_sections(
    tool_id: &str,
    input: &HashMap<String, serde_json::Value>,
    structured_content: Option<&serde_json::Value>,
    raw: Option<&str>,
    output: Option<&str>,
    error: Option<&str>,
    metadata: Option<&serde_json::Map<String, serde_json::Value>>,
) -> (
    Vec<crate::server::protocol::ai::ToolViewSection>,
    Option<String>,
) {
    let mut sections = Vec::new();
    let mut summary = build_tool_summary(tool_id, input, metadata, output);
    let structured_sections = structured_content_to_tool_sections(structured_content);

    let add_json_section = |sections: &mut Vec<crate::server::protocol::ai::ToolViewSection>,
                            id: &str,
                            title: &str,
                            value: &HashMap<String, serde_json::Value>| {
        if let Some(text) = format_json_map(value) {
            sections.push(tool_section(
                id,
                title,
                text,
                crate::server::protocol::ai::ToolViewSectionStyle::Code,
                Some("json"),
            ));
        }
    };

    match tool_id {
        "read" | "subagent_result" | "contextcompaction" | "context_compaction" => {}
        "edit" | "write" | "apply_patch" | "multiedit" => {
            if !structured_sections.is_empty() {
                sections.extend(structured_sections.clone());
            } else if let Some(diff) = metadata
                .and_then(|map| map.get("diff"))
                .and_then(|value| value_as_string(Some(value)))
            {
                sections.push(tool_section(
                    "edit-diff",
                    "diff",
                    diff,
                    crate::server::protocol::ai::ToolViewSectionStyle::Diff,
                    Some("diff"),
                ));
            }
            if sections.is_empty() && !input.is_empty() {
                add_json_section(&mut sections, "edit-input", "input", input);
            }
            if let Some(diagnostics) = metadata
                .and_then(|map| map.get("diagnostics"))
                .map(json_string)
            {
                sections.push(tool_section(
                    "edit-diagnostics",
                    "diagnostics",
                    diagnostics,
                    crate::server::protocol::ai::ToolViewSectionStyle::Code,
                    Some("json"),
                ));
            }
        }
        "terminal" => {
            if let Some(command) = input
                .get("command")
                .or_else(|| input.get("cmd"))
                .or_else(|| input.get("script"))
                .and_then(|value| value_as_string(Some(value)))
            {
                sections.push(tool_section(
                    "bash-command",
                    "command",
                    command,
                    crate::server::protocol::ai::ToolViewSectionStyle::Code,
                    Some("bash"),
                ));
            }
            let mut remaining = input.clone();
            remaining.remove("command");
            remaining.remove("cmd");
            remaining.remove("script");
            remaining.remove("description");
            if !remaining.is_empty() {
                add_json_section(&mut sections, "bash-input", "input", &remaining);
            }
            if let Some(progress) = progress_section(metadata, "bash") {
                sections.push(progress);
            }
            if !structured_sections.is_empty() {
                sections.extend(structured_sections.clone());
            } else if let Some(output) = output {
                sections.push(tool_section(
                    "bash-output",
                    "output",
                    output,
                    crate::server::protocol::ai::ToolViewSectionStyle::Terminal,
                    Some("text"),
                ));
            }
        }
        "markdown" | "md" => {
            if let Some(output) = output {
                sections.push(tool_section(
                    "markdown-output",
                    "markdown",
                    output,
                    crate::server::protocol::ai::ToolViewSectionStyle::Markdown,
                    None,
                ));
            }
        }
        "diff" => {
            if let Some(output) = output {
                sections.push(tool_section(
                    "diff-output",
                    "diff",
                    output,
                    crate::server::protocol::ai::ToolViewSectionStyle::Diff,
                    Some("diff"),
                ));
            }
        }
        "question" => {
            if let Some(error) = error {
                sections.push(tool_section(
                    "question-error",
                    "error",
                    error,
                    crate::server::protocol::ai::ToolViewSectionStyle::Text,
                    None,
                ));
            }
        }
        "todowrite" | "todoread" => {
            let todo_items = metadata
                .and_then(|map| {
                    map.get("todos")
                        .or_else(|| map.get("items"))
                        .or_else(|| map.get("tasks"))
                })
                .and_then(|value| value.as_array())
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.as_object().cloned())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            if !todo_items.is_empty() {
                let lines = todo_items
                    .iter()
                    .map(|item| {
                        let content = value_as_string(item.get("content"))
                            .or_else(|| value_as_string(item.get("title")))
                            .unwrap_or_else(|| "未命名任务".to_string());
                        let status = value_as_string(item.get("status"))
                            .unwrap_or_else(|| "pending".to_string());
                        format!("[{}] {}", status, content)
                    })
                    .collect::<Vec<_>>();
                sections.push(tool_section(
                    "todo-items",
                    "todos",
                    lines.join("\n"),
                    crate::server::protocol::ai::ToolViewSectionStyle::Text,
                    None,
                ));
                summary = format_todo_summary(&todo_items).or(summary);
            } else {
                sections.push(tool_section(
                    "todo-empty",
                    "todos",
                    "暂无任务",
                    crate::server::protocol::ai::ToolViewSectionStyle::Text,
                    None,
                ));
            }
        }
        _ => {
            if !input.is_empty() {
                add_json_section(&mut sections, "generic-input", "input", input);
            }
            if let Some(progress) = progress_section(metadata, "generic") {
                sections.push(progress);
            }
            if !structured_sections.is_empty() {
                sections.extend(structured_sections.clone());
            } else if let Some(output) = output {
                sections.push(tool_section(
                    "generic-output",
                    "output",
                    output,
                    crate::server::protocol::ai::ToolViewSectionStyle::Code,
                    Some("text"),
                ));
            }
        }
    }

    if let Some(error) = error {
        sections.push(tool_section(
            format!("{}-error", tool_id),
            "error",
            error,
            crate::server::protocol::ai::ToolViewSectionStyle::Text,
            None,
        ));
    }

    if sections.is_empty() {
        if let Some(raw) = raw {
            sections.push(tool_section(
                "generic-raw",
                "raw",
                raw,
                crate::server::protocol::ai::ToolViewSectionStyle::Code,
                Some("text"),
            ));
        }
    }

    (sections, summary)
}

fn build_tool_view(part: &crate::ai::AiPart) -> Option<crate::server::protocol::ai::ToolView> {
    if part.part_type != "tool" {
        return None;
    }
    let state_obj = part.tool_state.as_ref().and_then(|value| value.as_object());
    let input = parse_input_map(state_obj.and_then(|obj| obj.get("input")));
    let tool_id =
        if is_web_search_tool(part.tool_name.as_deref(), part.tool_kind.as_deref(), &input) {
            "websearch".to_string()
        } else {
            semantic_tool_id_for_view(part.tool_name.as_deref(), part.tool_kind.as_deref())
        };
    let metadata = state_obj
        .and_then(|obj| obj.get("metadata"))
        .and_then(|value| value.as_object());
    let structured_content = state_obj.and_then(|obj| obj.get("content"));
    let output = state_obj
        .and_then(|obj| obj.get("output"))
        .and_then(|value| value_as_string(Some(value)))
        .or_else(|| {
            part.tool_raw_output
                .as_ref()
                .and_then(extract_acp_content_text)
        })
        .or_else(|| part.tool_raw_output.as_ref().map(json_string));
    let raw = state_obj
        .and_then(|obj| obj.get("raw"))
        .and_then(|value| value_as_string(Some(value)))
        .or_else(|| part.tool_raw_output.as_ref().map(json_string));
    let title = state_obj
        .and_then(|obj| obj.get("title"))
        .and_then(|value| value_as_string(Some(value)))
        .or_else(|| part.tool_title.clone());
    let error = state_obj
        .and_then(|obj| obj.get("error"))
        .and_then(|value| value_as_string(Some(value)));
    let status = normalized_status(
        state_obj
            .and_then(|obj| obj.get("status"))
            .and_then(|value| value.as_str()),
    );
    let duration_ms = state_obj
        .and_then(|obj| obj.get("time"))
        .and_then(|value| value.as_object())
        .and_then(|time| {
            let start = value_as_f64(time.get("start"))?;
            let end = value_as_f64(time.get("end"))?;
            Some((end - start).max(0.0))
        });
    let question = build_tool_question(part, state_obj);
    let part_metadata = part
        .tool_part_metadata
        .as_ref()
        .and_then(|value| value.as_object());
    let linked_session =
        build_tool_linked_session(&tool_id, &input, metadata, part_metadata, output.as_deref());
    let locations = build_tool_locations(part.tool_locations.clone());
    let (sections, summary) = build_tool_sections(
        &tool_id,
        &input,
        structured_content,
        raw.as_deref(),
        output.as_deref(),
        error.as_deref(),
        metadata,
    );
    let header_command_summary = if matches!(tool_id.as_str(), "terminal") {
        terminal_command_summary(&input)
    } else {
        None
    };
    let display_title = tool_content_display_title(&tool_id, &input).unwrap_or_else(|| {
        title.unwrap_or_else(|| {
            if matches!(tool_id.as_str(), "read" | "edit" | "terminal" | "switch_mode") {
                tool_display_name(&tool_id)
            } else {
                part.tool_kind
                    .clone()
                    .or_else(|| part.tool_name.clone())
                    .unwrap_or_else(|| tool_display_name(&tool_id))
            }
        })
    });

    Some(crate::server::protocol::ai::ToolView {
        status: status.to_string(),
        display_title,
        status_text: tool_status_text(status),
        summary,
        header_command_summary,
        duration_ms,
        sections,
        locations,
        question,
        linked_session,
    })
}

/// 将 AiPart 转换为协议层 PartInfo，并为 tool 类型生成结构化 tool_view。
pub(crate) fn normalize_part_for_wire(
    part: crate::ai::AiPart,
) -> crate::server::protocol::ai::PartInfo {
    let mut tool_name = part.tool_name.clone();
    if part.part_type == "tool"
        && tool_name
            .as_deref()
            .map_or(true, |name| name.trim().is_empty())
    {
        tool_name = Some("unknown".to_string());
    }
    let state_obj = part.tool_state.as_ref().and_then(|value| value.as_object());
    let input = parse_input_map(state_obj.and_then(|obj| obj.get("input")));
    let normalized_tool_kind =
        normalized_tool_kind_for_wire(part.tool_name.as_deref(), part.tool_kind.as_deref(), &input);
    let tool_view = build_tool_view(&part);

    crate::server::protocol::ai::PartInfo {
        id: part.id,
        part_type: part.part_type,
        text: part.text,
        mime: part.mime,
        filename: part.filename,
        url: part.url,
        synthetic: part.synthetic,
        ignored: part.ignored,
        source: part.source,
        tool_name,
        tool_call_id: part.tool_call_id,
        tool_kind: normalized_tool_kind,
        tool_view,
    }
}

pub(crate) async fn ensure_status_push_initialized(ai_state: &SharedAIState, tx: &TaskBroadcastTx) {
    let (store, should_init) = {
        let mut guard = ai_state.lock().await;
        if guard.status_push_initialized {
            (guard.session_statuses.clone(), false)
        } else {
            guard.status_push_initialized = true;
            (guard.session_statuses.clone(), true)
        }
    };

    if !should_init {
        return;
    }

    let tx = tx.clone();
    // Clone the Arc for use inside the coordinator snapshot closure
    let store_for_coordinator = store.clone();
    store.set_on_change(std::sync::Arc::new(move |change| {
        let Some(meta) = change.meta.clone() else {
            return;
        };

        // 避免在"首次初始化为 idle"时刷屏推送。
        if change.old_status.is_none() && matches!(change.new_status, AiSessionStatus::Idle) {
            return;
        }

        let msg = ServerMessage::AISessionStatusUpdate {
            project_name: meta.project_name.clone(),
            workspace_name: meta.workspace_name.clone(),
            ai_tool: meta.ai_tool.clone(),
            session_id: meta.session_id.clone(),
            status: crate::server::protocol::ai::AiSessionStatusInfo {
                status: change.new_status.status_str().to_string(),
                error_message: change.new_status.error_message(),
                context_remaining_percent: None,
            },
        };

        let _ = crate::server::context::send_task_broadcast_event(
            &tx,
            TaskBroadcastEvent {
                // 状态更新希望所有连接都收到（包括触发变更的连接）。
                origin_conn_id: "".to_string(),
                message: msg,
                target_conn_ids: None,
                skip_when_single_receiver: false,
            },
        );

        // 同步发送工作区级 Coordinator 聚合快照（低延迟增量更新）
        let ai_domain_state = crate::ai::session_status::aggregate_workspace_ai_domain_state(
            &store_for_coordinator,
            &meta.project_name,
            &meta.workspace_name,
        );
        let coordinator_msg = ServerMessage::CoordinatorSnapshot {
            project: meta.project_name.clone(),
            workspace: meta.workspace_name.clone(),
            ai: crate::server::protocol::CoordinatorAiDomainStateDto::from(&ai_domain_state),
            version: ai_domain_state.display_updated_at as u64,
            generated_at: chrono::Utc::now().to_rfc3339(),
        };
        let _ = crate::server::context::send_task_broadcast_event(
            &tx,
            TaskBroadcastEvent {
                origin_conn_id: "".to_string(),
                message: coordinator_msg,
                target_conn_ids: None,
                skip_when_single_receiver: false,
            },
        );
    }));
}

pub(crate) async fn normalize_ai_image_parts(
    image_parts: Option<Vec<crate::ai::AiImagePart>>,
) -> Result<Option<Vec<crate::ai::AiImagePart>>, String> {
    let Some(parts) = image_parts else {
        return Ok(None);
    };

    let mut normalized: Vec<crate::ai::AiImagePart> = Vec::with_capacity(parts.len());
    for mut part in parts {
        let declared_mime = normalize_mime(&part.mime);
        let detected_mime = detect_image_mime_from_bytes(&part.data);
        let mut effective_mime = detected_mime.map(|s| s.to_string()).unwrap_or_else(|| {
            if declared_mime.is_empty() {
                "application/octet-stream".to_string()
            } else {
                declared_mime.clone()
            }
        });

        if effective_mime == "image/jpg" {
            effective_mime = "image/jpeg".to_string();
        }

        let should_transcode = !matches!(
            effective_mime.as_str(),
            "image/jpeg" | "image/png" | "image/webp" | "image/gif"
        );

        if should_transcode {
            let converted = transcode_image_to_jpeg(&part.data, &effective_mime).await?;
            info!(
                "AI image transcoded on server: filename={}, from_mime={}, to_mime=image/jpeg",
                part.filename, effective_mime
            );
            part.data = converted;
            part.mime = "image/jpeg".to_string();
            part.filename = to_jpg_filename(&part.filename);
        } else {
            part.mime = effective_mime;
        }

        normalized.push(part);
    }

    Ok(Some(normalized))
}

pub(crate) fn normalize_ai_audio_parts(
    audio_parts: Option<Vec<crate::ai::AiAudioPart>>,
) -> Option<Vec<crate::ai::AiAudioPart>> {
    let parts = audio_parts?;
    if parts.is_empty() {
        return None;
    }
    let normalized = parts
        .into_iter()
        .map(|mut part| {
            let mime = normalize_mime(&part.mime);
            part.mime = if mime.is_empty() {
                "application/octet-stream".to_string()
            } else {
                mime
            };
            let filename = part.filename.trim().to_string();
            if filename.is_empty() {
                part.filename = "audio".to_string();
            }
            part
        })
        .collect::<Vec<_>>();
    Some(normalized)
}

#[cfg(test)]
mod tests {
    use super::{
        build_ai_session_messages_update, emit_ops_for_cache_op,
        infer_selection_hint_from_messages, normalize_ai_tool, normalize_part_for_wire,
        should_broadcast_stream_message, should_cleanup_stream_snapshot, AiStreamSnapshot,
        AI_STREAM_SNAPSHOT_STALE_TTL_MS, AI_STREAM_SNAPSHOT_TERMINAL_TTL_MS,
        MAX_AI_SESSION_UPDATE_PAYLOAD_BYTES,
    };
    use crate::server::protocol::ServerMessage;

    #[test]
    fn infer_selection_hint_prefers_last_user_message_metadata() {
        let messages = vec![
            crate::server::protocol::ai::MessageInfo {
                id: "m1".to_string(),
                role: "user".to_string(),
                created_at: None,
                agent: Some("build".to_string()),
                model_provider_id: Some("openai".to_string()),
                model_id: Some("gpt-4.1".to_string()),
                parts: vec![],
            },
            crate::server::protocol::ai::MessageInfo {
                id: "m2".to_string(),
                role: "user".to_string(),
                created_at: None,
                agent: Some("plan".to_string()),
                model_provider_id: Some("anthropic".to_string()),
                model_id: Some("claude-sonnet-4".to_string()),
                parts: vec![],
            },
        ];

        let hint = infer_selection_hint_from_messages(&messages);
        assert_eq!(hint.agent.as_deref(), Some("plan"));
        assert_eq!(hint.model_provider_id.as_deref(), Some("anthropic"));
        assert_eq!(hint.model_id.as_deref(), Some("claude-sonnet-4"));
    }

    #[test]
    fn infer_selection_hint_falls_back_to_part_source() {
        let messages = vec![crate::server::protocol::ai::MessageInfo {
            id: "m1".to_string(),
            role: "assistant".to_string(),
            created_at: None,
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: vec![crate::server::protocol::ai::PartInfo {
                id: "p1".to_string(),
                part_type: "text".to_string(),
                text: Some("x".to_string()),
                mime: None,
                filename: None,
                url: None,
                synthetic: None,
                ignored: None,
                source: Some(serde_json::json!({
                    "agent": "build",
                    "model_provider_id": "openai",
                    "model_id": "gpt-4.1"
                })),
                tool_name: None,
                tool_call_id: None,
                tool_kind: None,
                tool_view: None,
            }],
        }];

        let hint = infer_selection_hint_from_messages(&messages);
        assert_eq!(hint.agent.as_deref(), Some("build"));
        assert_eq!(hint.model_provider_id.as_deref(), Some("openai"));
        assert_eq!(hint.model_id.as_deref(), Some("gpt-4.1"));
    }

    #[test]
    fn stream_done_is_always_broadcast() {
        let msg = ServerMessage::AIChatDone {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            ai_tool: "codex".to_string(),
            session_id: "session-done".to_string(),
            selection_hint: None,
            stop_reason: None,
            route_decision: None,
            budget_status: None,
        };

        assert!(should_broadcast_stream_message(&msg, 0));
    }

    #[test]
    fn stream_session_update_is_always_broadcast() {
        let msg = ServerMessage::AISessionMessagesUpdate {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            ai_tool: "codex".to_string(),
            session_id: "s1".to_string(),
            from_revision: 0,
            to_revision: 1,
            is_streaming: true,
            selection_hint: None,
            messages: None,
            ops: Some(vec![
                crate::server::protocol::ai::AiSessionCacheOpInfo::MessageUpdated {
                    message_id: "m1".to_string(),
                    role: "assistant".to_string(),
                },
            ]),
        };

        assert!(should_broadcast_stream_message(&msg, 0));
    }

    #[test]
    fn normalize_ai_tool_should_accept_kimi_aliases() {
        assert_eq!(normalize_ai_tool("kimi").as_deref(), Ok("kimi"));
        assert_eq!(normalize_ai_tool("KIMI-CODE").as_deref(), Ok("kimi"));
        assert!(normalize_ai_tool("kimi-agent").is_err());
    }

    #[test]
    fn stream_snapshot_supports_unbounded_message_growth() {
        let mut snapshot = AiStreamSnapshot::seeded(Vec::new(), None, true);
        for idx in 0..320usize {
            let op = crate::server::protocol::ai::AiSessionCacheOpInfo::MessageUpdated {
                message_id: format!("m-{}", idx),
                role: "assistant".to_string(),
            };
            snapshot.apply_cache_op(&op, None);
        }
        assert_eq!(snapshot.messages.len(), 320);
    }

    #[test]
    fn stream_snapshot_cache_revision_is_monotonic() {
        let mut snapshot = AiStreamSnapshot::seeded(Vec::new(), None, true);
        let first = snapshot.apply_cache_op(
            &crate::server::protocol::ai::AiSessionCacheOpInfo::MessageUpdated {
                message_id: "m1".to_string(),
                role: "assistant".to_string(),
            },
            None,
        );
        let second = snapshot.apply_cache_op(
            &crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id: "m1".to_string(),
                part_id: "p1".to_string(),
                part_type: "text".to_string(),
                field: "text".to_string(),
                delta: "hello".to_string(),
            },
            None,
        );
        let third = snapshot.touch_activity(false);
        assert!(second > first);
        assert!(third > second);
    }

    #[test]
    fn stream_snapshot_part_updates_should_preserve_existing_user_role() {
        let mut snapshot = AiStreamSnapshot::seeded(Vec::new(), None, true);
        snapshot.apply_cache_op(
            &crate::server::protocol::ai::AiSessionCacheOpInfo::MessageUpdated {
                message_id: "user-1".to_string(),
                role: "user".to_string(),
            },
            None,
        );
        snapshot.apply_cache_op(
            &crate::server::protocol::ai::AiSessionCacheOpInfo::PartUpdated {
                message_id: "user-1".to_string(),
                part: crate::server::protocol::ai::PartInfo {
                    id: "user-1-text".to_string(),
                    part_type: "text".to_string(),
                    text: Some("阶段提示".to_string()),
                    mime: None,
                    filename: None,
                    url: None,
                    synthetic: None,
                    ignored: None,
                    source: None,
                    tool_name: None,
                    tool_call_id: None,
                    tool_kind: None,
                    tool_view: None,
                },
            },
            None,
        );
        assert_eq!(snapshot.messages.len(), 1);
        assert_eq!(snapshot.messages[0].role, "user");

        snapshot.apply_cache_op(
            &crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id: "user-1".to_string(),
                part_id: "user-1-text".to_string(),
                part_type: "text".to_string(),
                field: "text".to_string(),
                delta: "\n补充上下文".to_string(),
            },
            None,
        );
        assert_eq!(snapshot.messages[0].role, "user");
        assert_eq!(
            snapshot.messages[0].parts[0].text.as_deref(),
            Some("阶段提示\n补充上下文")
        );
    }

    #[test]
    fn stream_snapshot_cleanup_policy_matches_ttl() {
        let now = super::now_ms();
        let mut terminal_snapshot = AiStreamSnapshot::seeded(Vec::new(), None, false);
        terminal_snapshot.terminal_at_ms = Some(now - AI_STREAM_SNAPSHOT_TERMINAL_TTL_MS - 1);
        terminal_snapshot.last_updated_ms = now;
        assert!(should_cleanup_stream_snapshot(&terminal_snapshot, now));

        let mut stale_snapshot = AiStreamSnapshot::seeded(Vec::new(), None, true);
        stale_snapshot.terminal_at_ms = None;
        stale_snapshot.last_updated_ms = now - AI_STREAM_SNAPSHOT_STALE_TTL_MS - 1;
        assert!(should_cleanup_stream_snapshot(&stale_snapshot, now));

        let fresh_snapshot = AiStreamSnapshot::seeded(Vec::new(), None, true);
        assert!(!should_cleanup_stream_snapshot(&fresh_snapshot, now));
    }

    #[test]
    fn build_session_update_drops_oversized_ops_payload() {
        let snapshot = AiStreamSnapshot::seeded(
            vec![crate::server::protocol::ai::MessageInfo {
                id: "m1".to_string(),
                role: "assistant".to_string(),
                created_at: None,
                agent: None,
                model_provider_id: None,
                model_id: None,
                parts: vec![],
            }],
            None,
            true,
        );
        let oversized_op = crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
            message_id: "m1".to_string(),
            part_id: "p1".to_string(),
            part_type: "text".to_string(),
            field: "text".to_string(),
            delta: "x".repeat(MAX_AI_SESSION_UPDATE_PAYLOAD_BYTES),
        };

        let update = build_ai_session_messages_update(
            "p",
            "w",
            "codex",
            "s1",
            snapshot.cache_revision().saturating_sub(1),
            &snapshot,
            Some(vec![oversized_op]),
            false,
        );

        match update {
            crate::server::protocol::ServerMessage::AISessionMessagesUpdate {
                ops,
                messages,
                ..
            } => {
                assert!(ops.is_none());
                assert!(messages.is_none());
            }
            other => panic!("unexpected message variant: {:?}", other),
        }
    }

    #[test]
    fn normalize_part_for_wire_builds_structured_tool_view() {
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-1".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("bash".to_string()),
            tool_call_id: Some("call-1".to_string()),
            tool_kind: Some("terminal".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "in_progress",
                "title": "执行测试",
                "input": {
                    "command": "npm test"
                },
                "output": "running"
            })),
            tool_locations: Some(vec![crate::ai::AiToolCallLocation {
                uri: None,
                path: Some("src/main.ts".to_string()),
                line: Some(12),
                column: Some(4),
                end_line: Some(12),
                end_column: Some(22),
                label: Some("诊断".to_string()),
            }]),
            ..Default::default()
        });

        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(part.tool_kind.as_deref(), Some("terminal"));
        assert_eq!(tool_view.status, "running");
        assert_eq!(tool_view.display_title, "执行测试");
        assert_eq!(
            tool_view.header_command_summary.as_deref(),
            Some("npm test")
        );
        assert_eq!(tool_view.locations.len(), 1);
        assert_eq!(tool_view.locations[0].path.as_deref(), Some("src/main.ts"));
        assert!(tool_view
            .sections
            .iter()
            .any(|section| section.id == "bash-output" && section.content.contains("running")));
    }

    #[test]
    fn normalize_part_for_wire_prefers_acp_kind_and_structured_content() {
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-execute".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("executeCommand".to_string()),
            tool_call_id: Some("call-execute".to_string()),
            tool_kind: Some("execute".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "in_progress",
                "input": {
                    "command": "npm test"
                },
                "content": [
                    {
                        "type": "terminal",
                        "terminalId": "term_123"
                    },
                    {
                        "type": "diff",
                        "path": "/tmp/demo.txt",
                        "oldText": "before\n",
                        "newText": "after\n"
                    }
                ]
            })),
            ..Default::default()
        });

        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(part.tool_name.as_deref(), Some("executeCommand"));
        assert_eq!(part.tool_kind.as_deref(), Some("terminal"));
        assert_eq!(tool_view.display_title, "terminal");
        assert_eq!(
            tool_view.header_command_summary.as_deref(),
            Some("npm test")
        );
        assert!(tool_view.sections.iter().any(|section| {
            matches!(
                &section.style,
                crate::server::protocol::ai::ToolViewSectionStyle::Terminal
            ) && section.content.contains("term_123")
        }));
        assert!(tool_view.sections.iter().any(|section| {
            matches!(
                &section.style,
                crate::server::protocol::ai::ToolViewSectionStyle::Diff
            ) && section.content.contains("--- /tmp/demo.txt")
        }));
    }

    #[test]
    fn normalize_part_for_wire_promotes_web_search_to_dedicated_card_kind() {
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-web-search".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("search".to_string()),
            tool_kind: Some("search".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "completed",
                "input": {
                    "query": "https://moonshotai.github.io/kimi-cli/zh/customization/wire-mode.html"
                },
                "output": "[]"
            })),
            ..Default::default()
        });

        assert_eq!(part.tool_kind.as_deref(), Some("websearch"));
        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(
            tool_view.display_title,
            "https://moonshotai.github.io/kimi-cli/zh/customization/wire-mode.html"
        );
    }

    #[test]
    fn normalize_part_for_wire_read_title_prefers_target_path() {
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-read".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("read".to_string()),
            tool_kind: Some("read".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "completed",
                "title": "Viewing ../src/lib.rs",
                "input": {
                    "path": "/tmp/src/lib.rs"
                }
            })),
            ..Default::default()
        });

        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(tool_view.display_title, "/tmp/src/lib.rs");
    }

    #[test]
    fn normalize_part_for_wire_edit_title_prefers_target_path() {
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-edit".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("edit".to_string()),
            tool_kind: Some("edit".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "completed",
                "title": "Editing ../src/lib.rs",
                "input": {
                    "path": "/tmp/src/lib.rs",
                    "old_str": "before",
                    "new_str": "after"
                }
            })),
            ..Default::default()
        });

        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(tool_view.display_title, "/tmp/src/lib.rs");
    }

    #[test]
    fn normalize_part_for_wire_search_title_prefers_query_text() {
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-search".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("grep".to_string()),
            tool_kind: Some("search".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "completed",
                "title": "Searching for TODO",
                "input": {
                    "pattern": "TODO"
                }
            })),
            ..Default::default()
        });

        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(tool_view.display_title, "TODO");
    }

    #[test]
    fn normalize_part_for_wire_uses_raw_only_as_last_fallback() {
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-raw".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("terminal".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "running",
                "raw": "stderr only"
            })),
            ..Default::default()
        });

        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(tool_view.sections.len(), 1);
        assert_eq!(tool_view.sections[0].id, "generic-raw");
        assert_eq!(tool_view.sections[0].content, "stderr only");
    }

    #[test]
    fn normalize_part_for_wire_maps_kimi_glob_to_search_card_kind() {
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-glob".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("Glob".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "completed",
                "input": {
                    "pattern": ".tidyflow/evolution/**/*.jsonc"
                }
            })),
            ..Default::default()
        });

        assert_eq!(part.tool_kind.as_deref(), Some("search"));
        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(tool_view.display_title, ".tidyflow/evolution/**/*.jsonc");
    }

    #[test]
    fn normalize_part_for_wire_keeps_full_terminal_command_summary() {
        let command = "cd /Users/godbobo/work/projects/musiver && ./musiver-dev quality-gate --workspace main --show-details";
        let part = normalize_part_for_wire(crate::ai::AiPart {
            id: "tool-long-command".to_string(),
            part_type: "tool".to_string(),
            tool_name: Some("terminal".to_string()),
            tool_kind: Some("terminal".to_string()),
            tool_state: Some(serde_json::json!({
                "status": "completed",
                "input": {
                    "command": command
                }
            })),
            ..Default::default()
        });

        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(tool_view.header_command_summary.as_deref(), Some(command));
    }

    #[test]
    fn emit_ops_for_cache_op_keeps_tool_output_delta_incremental() {
        let mut snapshot = AiStreamSnapshot::seeded(
            vec![crate::server::protocol::ai::MessageInfo {
                id: "m1".to_string(),
                role: "assistant".to_string(),
                created_at: None,
                agent: None,
                model_provider_id: None,
                model_id: None,
                parts: vec![],
            }],
            None,
            true,
        );
        let op = crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
            message_id: "m1".to_string(),
            part_id: "tool-1".to_string(),
            part_type: "tool".to_string(),
            field: "output".to_string(),
            delta: "hello".to_string(),
        };

        snapshot.apply_cache_op(&op, None);
        let emitted = emit_ops_for_cache_op(&snapshot, &op);

        assert_eq!(emitted.len(), 1);
        match &emitted[0] {
            crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id,
                part_id,
                field,
                delta,
                ..
            } => {
                assert_eq!(message_id, "m1");
                assert_eq!(part_id, "tool-1");
                assert_eq!(field, "output");
                assert_eq!(delta, "hello");
            }
            other => panic!("unexpected emitted op: {:?}", other),
        }
    }

    #[test]
    fn append_tool_delta_reuses_existing_output_section_by_title() {
        let mut snapshot = AiStreamSnapshot::seeded(
            vec![crate::server::protocol::ai::MessageInfo {
                id: "m1".to_string(),
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
                    tool_name: Some("terminal".to_string()),
                    tool_call_id: None,
                    tool_kind: Some("terminal".to_string()),
                    tool_view: Some(crate::server::protocol::ai::ToolView {
                        status: "running".to_string(),
                        display_title: "terminal".to_string(),
                        status_text: "running".to_string(),
                        summary: None,
                        header_command_summary: Some("ls".to_string()),
                        duration_ms: None,
                        sections: vec![crate::server::protocol::ai::ToolViewSection {
                            id: "terminal-output".to_string(),
                            title: "output".to_string(),
                            content: "hello".to_string(),
                            style: crate::server::protocol::ai::ToolViewSectionStyle::Terminal,
                            language: Some("text".to_string()),
                            copyable: true,
                            collapsed_by_default: false,
                        }],
                        locations: Vec::new(),
                        question: None,
                        linked_session: None,
                    }),
                }],
            }],
            None,
            true,
        );

        snapshot.apply_cache_op(
            &crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id: "m1".to_string(),
                part_id: "tool-1".to_string(),
                part_type: "tool".to_string(),
                field: "output".to_string(),
                delta: " world".to_string(),
            },
            None,
        );

        let part = snapshot
            .part_clone("m1", "tool-1")
            .expect("tool part should exist");
        let tool_view = part.tool_view.expect("tool_view should exist");
        assert_eq!(tool_view.sections.len(), 1);
        assert_eq!(tool_view.sections[0].id, "terminal-output");
        assert_eq!(tool_view.sections[0].content, "hello world");
    }
}

pub(crate) fn summarize_ai_image_parts(parts: &[crate::ai::AiImagePart]) -> String {
    parts
        .iter()
        .map(|p| format!("{}|{}|{}B", p.filename, p.mime, p.data.len()))
        .collect::<Vec<_>>()
        .join(", ")
}

pub(crate) fn summarize_ai_audio_parts(parts: &[crate::ai::AiAudioPart]) -> String {
    parts
        .iter()
        .map(|p| format!("{}|{}|{}B", p.filename, p.mime, p.data.len()))
        .collect::<Vec<_>>()
        .join(", ")
}

pub(crate) fn normalize_mime(mime: &str) -> String {
    mime.trim().to_ascii_lowercase()
}

pub(crate) fn detect_image_mime_from_bytes(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        return Some("image/png");
    }
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some("image/jpeg");
    }
    if bytes.starts_with(&[0x47, 0x49, 0x46, 0x38]) {
        return Some("image/gif");
    }
    if bytes.len() >= 12
        && bytes[0] == 0x52
        && bytes[1] == 0x49
        && bytes[2] == 0x46
        && bytes[3] == 0x46
        && bytes[8] == 0x57
        && bytes[9] == 0x45
        && bytes[10] == 0x42
        && bytes[11] == 0x50
    {
        return Some("image/webp");
    }
    if bytes.len() >= 12
        && bytes[4] == 0x66
        && bytes[5] == 0x74
        && bytes[6] == 0x79
        && bytes[7] == 0x70
    {
        let brand = String::from_utf8_lossy(&bytes[8..12]).to_ascii_lowercase();
        if brand.starts_with("hei") || brand.starts_with("hev") {
            return Some("image/heic");
        }
        if brand == "mif1" || brand == "msf1" {
            return Some("image/heif");
        }
        if brand == "avif" || brand == "avis" {
            return Some("image/avif");
        }
    }
    None
}

fn to_jpg_filename(filename: &str) -> String {
    use std::path::Path;

    let stem = Path::new(filename)
        .file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("image");
    format!("{}.jpg", stem)
}

async fn transcode_image_to_jpeg(data: &[u8], source_mime: &str) -> Result<Vec<u8>, String> {
    match transcode_with_image_crate(data).await {
        Ok(bytes) => Ok(bytes),
        Err(image_err) => match transcode_with_sips(data, source_mime).await {
            Ok(bytes) => Ok(bytes),
            Err(sips_err) => Err(format!(
                "图片转 JPEG 失败（mime={}）：{}；{}",
                source_mime, image_err, sips_err
            )),
        },
    }
}

async fn transcode_with_image_crate(data: &[u8]) -> Result<Vec<u8>, String> {
    let input = data.to_vec();
    tokio::task::spawn_blocking(move || {
        use image::ImageReader;
        use std::io::Cursor;

        let reader = ImageReader::new(Cursor::new(input))
            .with_guessed_format()
            .map_err(|e| format!("无法识别图片格式: {}", e))?;
        let img = reader
            .decode()
            .map_err(|e| format!("图片解码失败: {}", e))?;

        let mut out = Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Jpeg)
            .map_err(|e| format!("JPEG 编码失败: {}", e))?;
        Ok(out.into_inner())
    })
    .await
    .map_err(|e| format!("图片转码任务失败: {}", e))?
}

#[cfg(target_os = "macos")]
async fn transcode_with_sips(data: &[u8], source_mime: &str) -> Result<Vec<u8>, String> {
    let input_ext = match source_mime {
        "image/heic" => "heic",
        "image/heif" => "heif",
        "image/avif" => "avif",
        "image/gif" => "gif",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/jpeg" => "jpg",
        _ => "img",
    };

    let id = uuid::Uuid::new_v4().to_string();
    let in_path = std::env::temp_dir().join(format!("tidyflow_ai_{}.{}", id, input_ext));
    let out_path = std::env::temp_dir().join(format!("tidyflow_ai_{}.jpg", id));

    tokio::fs::write(&in_path, data)
        .await
        .map_err(|e| format!("写入临时图片失败: {}", e))?;

    let output = tokio::process::Command::new("sips")
        .arg("-s")
        .arg("format")
        .arg("jpeg")
        .arg(&in_path)
        .arg("--out")
        .arg(&out_path)
        .output()
        .await
        .map_err(|e| format!("调用 sips 失败: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let _ = tokio::fs::remove_file(&in_path).await;
        let _ = tokio::fs::remove_file(&out_path).await;
        return Err(format!("sips 转码失败: {}", stderr.trim()));
    }

    let result = tokio::fs::read(&out_path)
        .await
        .map_err(|e| format!("读取转码结果失败: {}", e));

    let _ = tokio::fs::remove_file(&in_path).await;
    let _ = tokio::fs::remove_file(&out_path).await;

    result
}

#[cfg(not(target_os = "macos"))]
async fn transcode_with_sips(_data: &[u8], _source_mime: &str) -> Result<Vec<u8>, String> {
    Err("当前平台未启用 sips 图片转码".to_string())
}

// ============================================================================
// 代码语言检测工具函数（WI-005）
// ============================================================================

/// 从文件路径推断编程语言（基于扩展名）
#[allow(dead_code)]
pub(crate) fn detect_language_from_path(
    path: &str,
) -> crate::server::protocol::ai::CodeCompletionLanguage {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    crate::server::protocol::ai::CodeCompletionLanguage::from_extension(ext)
}
