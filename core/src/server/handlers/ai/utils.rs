use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

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
const AI_STREAM_BROADCAST_SUMMARY_INTERVAL_LOW: Duration = Duration::from_millis(250);
const AI_STREAM_BROADCAST_SUMMARY_INTERVAL_MEDIUM: Duration = Duration::from_millis(500);
const AI_STREAM_BROADCAST_SUMMARY_INTERVAL_HIGH: Duration = Duration::from_millis(1000);
const AI_STREAM_BROADCAST_SUMMARY_INTERVAL_HIGHEST: Duration = Duration::from_millis(1500);

fn parse_env_bool(name: &str, default: bool) -> bool {
    match std::env::var(name) {
        Ok(raw) => match raw.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => true,
            "0" | "false" | "no" | "off" => false,
            _ => default,
        },
        Err(_) => default,
    }
}

fn perf_active_only_delta_broadcast_enabled() -> bool {
    parse_env_bool("PERF_ACTIVE_ONLY_DELTA_BROADCAST", true)
}

fn session_summary_broadcast_gate() -> &'static Mutex<HashMap<String, Instant>> {
    static GATE: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
    GATE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn summary_broadcast_interval_by_depth(depth: usize) -> Duration {
    if depth < 128 {
        AI_STREAM_BROADCAST_SUMMARY_INTERVAL_LOW
    } else if depth < 256 {
        AI_STREAM_BROADCAST_SUMMARY_INTERVAL_MEDIUM
    } else if depth < 512 {
        AI_STREAM_BROADCAST_SUMMARY_INTERVAL_HIGH
    } else {
        AI_STREAM_BROADCAST_SUMMARY_INTERVAL_HIGHEST
    }
}

fn allow_summary_broadcast(session_id: &str, interval: Duration) -> bool {
    let now = Instant::now();
    let mut gate = session_summary_broadcast_gate()
        .lock()
        .expect("summary broadcast gate poisoned");

    if let Some(last) = gate.get(session_id) {
        if now.duration_since(*last) < interval {
            return false;
        }
    }
    gate.insert(session_id.to_string(), now);

    if gate.len() > 4096 {
        gate.retain(|_, ts| now.duration_since(*ts) <= Duration::from_secs(600));
    }
    true
}

fn should_broadcast_stream_message(msg: &ServerMessage, broadcast_depth: usize) -> bool {
    if !perf_active_only_delta_broadcast_enabled() {
        return true;
    }

    match msg {
        // 高频 token 增量只保留给当前活跃连接，避免广播通道被淹没。
        ServerMessage::AIChatPartDelta { .. } => false,
        // 其余连接只接收节流后的阶段性摘要更新。
        ServerMessage::AIChatPartUpdated { session_id, .. }
        | ServerMessage::AIChatMessageUpdated { session_id, .. } => {
            let interval = summary_broadcast_interval_by_depth(broadcast_depth);
            allow_summary_broadcast(session_id, interval)
        }
        _ => true,
    }
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
            let manager = CodexAppServerManager::new_with_command_and_protocol(
                std::env::temp_dir(),
                "copilot",
                vec!["--acp".to_string()],
                "Copilot ACP server",
                Some(1),
            );
            Ok(Arc::new(CopilotAcpAgent::new_copilot(Arc::new(manager))))
        }
        "kimi" => {
            let manager = CodexAppServerManager::new_with_command_and_protocol(
                std::env::temp_dir(),
                "kimi",
                // Kimi ACP 走全自动执行：`--yolo` 作为全局参数放在 `acp` 前，避免 verify 阶段被权限确认阻断。
                vec!["--yolo".to_string(), "acp".to_string()],
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

pub(crate) async fn ai_session_subscriber_conn_ids(
    ai_state: &SharedAIState,
    session_key: &str,
    origin_conn_id: &str,
) -> HashSet<String> {
    let ai = ai_state.lock().await;
    ai.session_subscriptions
        .iter()
        .filter_map(|(conn_id, keys)| {
            if conn_id == origin_conn_id || !keys.contains(session_key) {
                None
            } else {
                Some(conn_id.clone())
            }
        })
        .collect()
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
    messages: Vec<crate::server::protocol::ai::MessageInfo>,
    selection_hint: Option<crate::server::protocol::ai::SessionSelectionHint>,
) -> Result<usize, String> {
    let payload = crate::server::protocol::ServerMessage::AISessionMessages {
        project_name: project_name.to_string(),
        workspace_name: workspace_name.to_string(),
        ai_tool: ai_tool.to_string(),
        session_id: session_id.to_string(),
        messages,
        selection_hint,
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

    if agent.is_none() && model_provider_id.is_none() && model_id.is_none() {
        None
    } else {
        Some(crate::server::protocol::ai::SessionSelectionHint {
            agent,
            model_provider_id,
            model_id,
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
            if let Some(metadata) = part.tool_part_metadata.as_ref() {
                candidates.push(metadata);
            }
            if let Some(state) = part.tool_state.as_ref() {
                candidates.push(state);
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

/// 将 AiPart 转换为协议层 PartInfo，并对 tool 类型做兜底规范化：
/// - 确保 tool_state 至少有 status 字段
/// - 确保 tool_name 不为 None
pub(crate) fn normalize_part_for_wire(
    part: crate::ai::AiPart,
) -> crate::server::protocol::ai::PartInfo {
    let mut tool_name = part.tool_name;
    let mut tool_state = part.tool_state;

    if part.part_type == "tool" {
        // 确保 tool_name 不为 None
        if tool_name.as_deref().map_or(true, |n| n.is_empty()) {
            tool_name = Some("unknown".to_string());
        }
        // 确保 tool_state 至少有 status 字段
        match &mut tool_state {
            Some(state) if state.is_object() => {
                let obj = state.as_object_mut().unwrap();
                if !obj.contains_key("status") {
                    obj.insert("status".to_string(), serde_json::json!("completed"));
                }
            }
            Some(_) | None => {
                // tool_state 不是对象或为 None，包装为统一信封
                let original = tool_state.take();
                tool_state = Some(serde_json::json!({
                    "status": "completed",
                    "metadata": original,
                }));
            }
        }
    }

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
        tool_state,
        tool_part_metadata: part.tool_part_metadata,
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
    store.set_on_change(std::sync::Arc::new(move |change| {
        let Some(meta) = change.meta.clone() else {
            return;
        };

        // 避免在“首次初始化为 idle”时刷屏推送。
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

#[cfg(test)]
mod tests {
    use super::{
        infer_selection_hint_from_messages, normalize_ai_tool, should_broadcast_stream_message,
    };
    use crate::server::protocol::ServerMessage;
    use std::time::{SystemTime, UNIX_EPOCH};

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
                tool_state: None,
                tool_part_metadata: None,
            }],
        }];

        let hint = infer_selection_hint_from_messages(&messages);
        assert_eq!(hint.agent.as_deref(), Some("build"));
        assert_eq!(hint.model_provider_id.as_deref(), Some("openai"));
        assert_eq!(hint.model_id.as_deref(), Some("gpt-4.1"));
    }

    #[test]
    fn stream_delta_is_not_broadcast_when_perf_mode_enabled() {
        let msg = ServerMessage::AIChatPartDelta {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            ai_tool: "codex".to_string(),
            session_id: "session-delta".to_string(),
            message_id: "m1".to_string(),
            part_id: "part-1".to_string(),
            part_type: "text".to_string(),
            field: "text".to_string(),
            delta: "hello".to_string(),
        };

        assert!(!should_broadcast_stream_message(&msg, 0));
    }

    #[test]
    fn stream_done_is_always_broadcast() {
        let msg = ServerMessage::AIChatDone {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            ai_tool: "codex".to_string(),
            session_id: "session-done".to_string(),
            selection_hint: None,
        };

        assert!(should_broadcast_stream_message(&msg, 0));
    }

    #[test]
    fn stream_message_update_is_throttled_per_session() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let session_id = format!("session-throttle-{}", unique);

        let msg = ServerMessage::AIChatMessageUpdated {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            ai_tool: "codex".to_string(),
            session_id: session_id.clone(),
            message_id: "m1".to_string(),
            role: "assistant".to_string(),
            selection_hint: None,
        };
        let same_session_msg = ServerMessage::AIChatMessageUpdated {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            ai_tool: "codex".to_string(),
            session_id,
            message_id: "m1".to_string(),
            role: "assistant".to_string(),
            selection_hint: None,
        };

        assert!(should_broadcast_stream_message(&msg, 0));
        assert!(!should_broadcast_stream_message(&same_session_msg, 0));
    }

    #[test]
    fn stream_message_update_uses_longer_window_with_high_queue_depth() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let session_id = format!("session-throttle-depth-{}", unique);

        let msg = ServerMessage::AIChatMessageUpdated {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            ai_tool: "codex".to_string(),
            session_id: session_id.clone(),
            message_id: "m1".to_string(),
            role: "assistant".to_string(),
            selection_hint: None,
        };
        let same_session_msg = ServerMessage::AIChatMessageUpdated {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            ai_tool: "codex".to_string(),
            session_id,
            message_id: "m1".to_string(),
            role: "assistant".to_string(),
            selection_hint: None,
        };

        assert!(should_broadcast_stream_message(&msg, 600));
        assert!(!should_broadcast_stream_message(&same_session_msg, 600));
    }

    #[test]
    fn normalize_ai_tool_should_accept_kimi_aliases() {
        assert_eq!(normalize_ai_tool("kimi").as_deref(), Ok("kimi"));
        assert_eq!(normalize_ai_tool("KIMI-CODE").as_deref(), Ok("kimi"));
        assert!(normalize_ai_tool("kimi-agent").is_err());
    }
}

pub(crate) fn summarize_ai_image_parts(parts: &[crate::ai::AiImagePart]) -> String {
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
