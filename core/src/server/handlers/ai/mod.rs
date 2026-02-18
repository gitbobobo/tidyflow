use std::sync::Arc;

use axum::extract::ws::WebSocket;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::StreamExt;
use tracing::{info, warn};

use crate::ai::session_status::{AiSessionStateStore, AiSessionStatus, AiSessionStatusMeta};
use crate::ai::{
    AiAgent, AiEvent, AiSessionSelectionHint, CodexAppServerAgent, CodexAppServerManager,
    CopilotAcpAgent, OpenCodeAgent, OpenCodeManager,
};
use crate::server::context::{SharedAppState, TaskBroadcastEvent, TaskBroadcastTx};
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub mod ai_state;
#[cfg(test)]
mod ai_test;
pub mod file_ref;

pub use ai_state::AIState;

pub type SharedAIState = Arc<Mutex<AIState>>;

const IDLE_DISPOSE_TTL_MS: i64 = 15 * 60 * 1000;
const MAINTENANCE_INTERVAL_SECS: u64 = 60;
// 经验值：macOS URLSession WebSocket 在超大单帧下更容易被客户端主动 reset。
// 这里对 ai_session_messages 做保守上限，优先保证“详情可打开”。
const MAX_AI_SESSION_MESSAGES_PAYLOAD_BYTES: usize = 900_000;

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// 创建 AI 代理实例（单 opencode serve child + x-opencode-directory 路由）
fn create_agent(tool: &str) -> Result<Arc<dyn AiAgent>, String> {
    match tool {
        "opencode" => {
            let manager = OpenCodeManager::new(std::env::temp_dir());
            Ok(Arc::new(OpenCodeAgent::new(Arc::new(manager))))
        }
        "codex" => {
            let manager = CodexAppServerManager::new(std::env::temp_dir());
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
            Ok(Arc::new(CopilotAcpAgent::new(Arc::new(manager))))
        }
        other => Err(format!("Unsupported AI tool: {}", other)),
    }
}

fn normalize_ai_tool(tool: &str) -> Result<String, String> {
    let normalized = tool.trim().to_lowercase();
    match normalized.as_str() {
        "opencode" | "codex" | "copilot" => Ok(normalized),
        _ => Err(format!("Unsupported AI tool: {}", tool)),
    }
}

fn tool_directory_key(tool: &str, directory: &str) -> String {
    format!("{}::{}", tool, directory)
}

fn stream_key(tool: &str, directory: &str, session_id: &str) -> String {
    format!("{}::{}::{}", tool, directory, session_id)
}

async fn emit_server_message(output_tx: &mpsc::Sender<ServerMessage>, msg: ServerMessage) -> bool {
    if let Err(e) = output_tx.send(msg).await {
        warn!("AI stream: failed to enqueue server message: {}", e);
        return false;
    }
    true
}

async fn cleanup_stream_state(
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

async fn resolve_directory(
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

fn ai_session_messages_encoded_len(
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

fn ai_session_messages_stats(
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

fn canonical_meta_key(raw: &str) -> String {
    raw.chars()
        .filter(|ch| *ch != '_' && *ch != '-')
        .flat_map(|ch| ch.to_lowercase())
        .collect::<String>()
}

fn json_value_to_trimmed_string(value: &serde_json::Value) -> Option<String> {
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

fn find_scalar_by_keys(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
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

fn normalize_agent_hint(raw: &str) -> Option<String> {
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

fn normalize_optional_token(raw: Option<String>) -> Option<String> {
    let token = raw?;
    let trimmed = token.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn infer_hint_from_json(value: &serde_json::Value) -> AiSessionSelectionHint {
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

fn merge_session_selection_hint(
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

fn infer_selection_hint_from_messages(
    messages: &[crate::server::protocol::ai::MessageInfo],
) -> AiSessionSelectionHint {
    let mut resolved = AiSessionSelectionHint::default();
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

async fn ensure_agent(ai_state: &SharedAIState, tool: &str) -> Result<Arc<dyn AiAgent>, String> {
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

async fn ensure_maintenance(ai_state: &SharedAIState) {
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

fn status_to_info(status: &AiSessionStatus) -> crate::server::protocol::ai::AiSessionStatusInfo {
    crate::server::protocol::ai::AiSessionStatusInfo {
        status: status.status_str().to_string(),
        error_message: status.error_message(),
    }
}

/// 将 AiPart 转换为协议层 PartInfo，并对 tool 类型做兜底规范化：
/// - 确保 tool_state 至少有 status 字段
/// - 确保 tool_name 不为 None
fn normalize_part_for_wire(part: crate::ai::AiPart) -> crate::server::protocol::ai::PartInfo {
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

async fn ensure_status_push_initialized(ai_state: &SharedAIState, tx: &TaskBroadcastTx) {
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
            },
        };

        let _ = tx.send(TaskBroadcastEvent {
            // 状态更新希望所有连接都收到（包括触发变更的连接）。
            origin_conn_id: "".to_string(),
            message: msg,
        });
    }));
}

pub async fn handle_ai_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
) -> Result<bool, String> {
    ensure_status_push_initialized(ai_state, task_broadcast_tx).await;

    if try_handle_ai_chat_start(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_chat_send(client_msg, app_state, ai_state, output_tx).await? {
        return Ok(true);
    }
    if try_handle_ai_chat_command(client_msg, app_state, ai_state, output_tx).await? {
        return Ok(true);
    }
    if try_handle_ai_chat_abort(client_msg, app_state, ai_state, output_tx).await? {
        return Ok(true);
    }
    if try_handle_ai_question_reply(client_msg, app_state, ai_state, output_tx).await? {
        return Ok(true);
    }
    if try_handle_ai_question_reject(client_msg, app_state, ai_state, output_tx).await? {
        return Ok(true);
    }
    if try_handle_ai_session_list(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_session_messages(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_session_delete(client_msg, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_session_status(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_provider_list(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_agent_list(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_slash_commands(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    Ok(false)
}

async fn try_handle_ai_chat_start(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AIChatStart {
        project_name,
        workspace_name,
        ai_tool,
        title,
    } = msg
    else {
        return Ok(false);
    };
    let ai_tool = normalize_ai_tool(ai_tool)?;

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    let title = title.clone().unwrap_or_else(|| "New Chat".to_string());
    info!(
        "AIChatStart: project={}, workspace={}, directory={}, title={}",
        project_name, workspace_name, directory, title
    );

    let session = agent.create_session(&directory, &title).await?;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISessionStartedV2 {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            ai_tool,
            session_id: session.id,
            title: session.title,
            updated_at: session.updated_at,
        },
    )
    .await?;

    Ok(true)
}

async fn try_handle_ai_chat_send(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
) -> Result<bool, String> {
    let (
        project_name,
        workspace_name,
        session_id,
        message,
        file_refs,
        image_parts,
        model,
        agent_name,
        ai_tool,
    ) = match msg {
        ClientMessage::AIChatSend {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            message,
            file_refs,
            image_parts,
            model,
            agent,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            message.clone(),
            file_refs.clone(),
            image_parts.clone(),
            model.clone(),
            agent.clone(),
            ai_tool.clone(),
        ),
        _ => return Ok(false),
    };
    let ai_tool = normalize_ai_tool(&ai_tool)?;

    let directory = resolve_directory(app_state, &project_name, &workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    let status_store: Arc<AiSessionStateStore> = {
        let guard = ai_state.lock().await;
        guard.session_statuses.clone()
    };
    let status_meta = AiSessionStatusMeta {
        project_name: project_name.clone(),
        workspace_name: workspace_name.clone(),
        ai_tool: ai_tool.clone(),
        directory: directory.clone(),
        session_id: session_id.clone(),
    };
    status_store.set_status_with_meta(status_meta.clone(), AiSessionStatus::Busy);

    info!(
        "AIChatSend: project={}, workspace={}, session_id={}, message_len={}",
        project_name,
        workspace_name,
        session_id,
        message.len()
    );

    // 将协议层 ImagePart/ModelSelection 转为 AI 层类型，并在服务端统一规范化图片格式。
    let ai_image_parts_raw: Option<Vec<crate::ai::AiImagePart>> =
        image_parts.as_ref().map(|parts| {
            parts
                .iter()
                .map(|p| crate::ai::AiImagePart {
                    filename: p.filename.clone(),
                    mime: p.mime.clone(),
                    data: p.data.clone(),
                })
                .collect()
        });
    if let Some(parts) = ai_image_parts_raw.as_ref() {
        info!(
            "AIChatSend image parts received: count={}, items={}",
            parts.len(),
            summarize_ai_image_parts(parts)
        );
    }
    let ai_image_parts = match normalize_ai_image_parts(ai_image_parts_raw).await {
        Ok(parts) => parts,
        Err(e) => {
            let _ = emit_server_message(
                output_tx,
                ServerMessage::AIChatErrorV2 {
                    project_name: project_name.clone(),
                    workspace_name: workspace_name.clone(),
                    ai_tool: ai_tool.clone(),
                    session_id: session_id.clone(),
                    error: e,
                },
            )
            .await;
            return Ok(true);
        }
    };
    if let Some(parts) = ai_image_parts.as_ref() {
        info!(
            "AIChatSend image parts normalized: count={}, items={}",
            parts.len(),
            summarize_ai_image_parts(parts)
        );
    }
    let ai_model = model.as_ref().map(|m| crate::ai::AiModelSelection {
        provider_id: m.provider_id.clone(),
        model_id: m.model_id.clone(),
    });

    let (abort_tx, mut abort_rx) = mpsc::channel::<()>(1);
    let abort_key = stream_key(&ai_tool, &directory, &session_id);
    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.active_streams.insert(abort_key.clone(), abort_tx);
        ai.directory_last_used_ms.insert(dir_key.clone(), now_ms());
        let active = ai.directory_active_streams.entry(dir_key).or_insert(0);
        *active += 1;
    }

    let output_tx = output_tx.clone();
    let ai_state_cloned = ai_state.clone();
    let status_store_cloned = status_store.clone();
    let status_meta_cloned = status_meta.clone();
    tokio::spawn(async move {
        let mut stream = match agent
            .send_message(
                &directory,
                &session_id,
                &message,
                file_refs.clone(),
                ai_image_parts,
                ai_model,
                agent_name.clone(),
            )
            .await
        {
            Ok(stream) => stream,
            Err(e) => {
                warn!(
                    "AIChatSend: send_message failed, project={}, workspace={}, session_id={}, error={}",
                    project_name, workspace_name, session_id, e
                );
                status_store_cloned.set_status_with_meta(
                    status_meta_cloned.clone(),
                    AiSessionStatus::Error { message: e.clone() },
                );
                let _ = emit_server_message(
                    &output_tx,
                    ServerMessage::AIChatErrorV2 {
                        project_name: project_name.clone(),
                        workspace_name: workspace_name.clone(),
                        ai_tool: ai_tool.clone(),
                        session_id: session_id.clone(),
                        error: e,
                    },
                )
                .await;
                cleanup_stream_state(&ai_state_cloned, &abort_key, &ai_tool, &directory).await;
                return;
            }
        };

        loop {
            tokio::select! {
                _ = abort_rx.recv() => {
                    info!("AIChatSend: abort signal received, session_id={}", session_id);
                    if let Err(e) = agent.abort_session(&directory, &session_id).await {
                        warn!(
                            "AIChatSend: abort_session failed, project={}, workspace={}, session_id={}, error={}",
                            project_name, workspace_name, session_id, e
                        );
                    }
                    let _ = emit_server_message(
                        &output_tx,
                        ServerMessage::AIChatDone {
                            project_name: project_name.clone(),
                            workspace_name: workspace_name.clone(),
                            ai_tool: ai_tool.clone(),
                            session_id: session_id.clone(),
                        },
                    )
                    .await;
                    status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), AiSessionStatus::Idle);
                    break;
                }
                event = stream.next() => {
                    match event {
                        Some(Ok(ai_event)) => {
                            let keep_running = match ai_event {
                                AiEvent::MessageUpdated { message_id, role } => {
                                    emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatMessageUpdated {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            message_id,
                                            role,
                                        },
                                    )
                                    .await
                                }
                                AiEvent::PartUpdated { message_id, part } => {
                                    emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatPartUpdated {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            message_id,
                                            part: normalize_part_for_wire(part),
                                        },
                                    )
                                    .await
                                }
                                AiEvent::PartDelta { message_id, part_id, part_type, field, delta } => {
                                    emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatPartDelta {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            message_id,
                                            part_id,
                                            part_type,
                                            field,
                                            delta,
                                        },
                                    )
                                    .await
                                }
                                AiEvent::QuestionAsked { request } => {
                                    emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIQuestionAsked {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            request: crate::server::protocol::ai::QuestionRequestInfo {
                                                id: request.id,
                                                session_id: request.session_id,
                                                questions: request
                                                    .questions
                                                    .into_iter()
                                                    .map(|q| crate::server::protocol::ai::QuestionInfo {
                                                        question: q.question,
                                                        header: q.header,
                                                        options: q
                                                            .options
                                                            .into_iter()
                                                            .map(|opt| crate::server::protocol::ai::QuestionOptionInfo {
                                                                label: opt.label,
                                                                description: opt.description,
                                                            })
                                                            .collect(),
                                                        multiple: q.multiple,
                                                        custom: q.custom,
                                                    })
                                                    .collect(),
                                                tool_message_id: request.tool_message_id,
                                                tool_call_id: request.tool_call_id,
                                            },
                                        },
                                    )
                                    .await
                                }
                                AiEvent::QuestionCleared { request_id, .. } => {
                                    emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIQuestionCleared {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            request_id,
                                        },
                                    )
                                    .await
                                }
                                AiEvent::Error { message } => {
                                    status_store_cloned.set_status_with_meta(
                                        status_meta_cloned.clone(),
                                        AiSessionStatus::Error { message: message.clone() },
                                    );
                                    let _ = emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatErrorV2 {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            error: message,
                                        },
                                    )
                                    .await;
                                    false
                                }
                                AiEvent::Done => {
                                    status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), AiSessionStatus::Idle);
                                    let _ = emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatDone {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                        },
                                    )
                                    .await;
                                    false
                                }
                            };
                            if !keep_running {
                                break;
                            }
                        }
                        Some(Err(e)) => {
                            status_store_cloned.set_status_with_meta(
                                status_meta_cloned.clone(),
                                AiSessionStatus::Error { message: e.clone() },
                            );
                            let _ = emit_server_message(
                                &output_tx,
                                ServerMessage::AIChatErrorV2 {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                    error: e,
                                },
                            )
                            .await;
                            break;
                        }
                        None => {
                            // Hub 断开等情况下可能出现 None，确保收敛
                            status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), AiSessionStatus::Idle);
                            let _ = emit_server_message(
                                &output_tx,
                                ServerMessage::AIChatDone {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                },
                            )
                            .await;
                            break;
                        }
                    }
                }
            }
        }

        cleanup_stream_state(&ai_state_cloned, &abort_key, &ai_tool, &directory).await;
    });

    Ok(true)
}

async fn try_handle_ai_chat_command(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
) -> Result<bool, String> {
    let (
        project_name,
        workspace_name,
        session_id,
        command,
        arguments,
        file_refs,
        image_parts,
        model,
        agent_name,
        ai_tool,
    ) = match msg {
        ClientMessage::AIChatCommand {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            command,
            arguments,
            file_refs,
            image_parts,
            model,
            agent,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            command.clone(),
            arguments.clone(),
            file_refs.clone(),
            image_parts.clone(),
            model.clone(),
            agent.clone(),
            ai_tool.clone(),
        ),
        _ => return Ok(false),
    };
    let ai_tool = normalize_ai_tool(&ai_tool)?;

    let directory = resolve_directory(app_state, &project_name, &workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    let status_store: Arc<AiSessionStateStore> = {
        let guard = ai_state.lock().await;
        guard.session_statuses.clone()
    };
    let status_meta = AiSessionStatusMeta {
        project_name: project_name.clone(),
        workspace_name: workspace_name.clone(),
        ai_tool: ai_tool.clone(),
        directory: directory.clone(),
        session_id: session_id.clone(),
    };
    status_store.set_status_with_meta(status_meta.clone(), AiSessionStatus::Busy);

    info!(
        "AIChatCommand: project={}, workspace={}, session_id={}, command={}, arguments_len={}",
        project_name,
        workspace_name,
        session_id,
        command,
        arguments.len()
    );

    let ai_image_parts_raw: Option<Vec<crate::ai::AiImagePart>> =
        image_parts.as_ref().map(|parts| {
            parts
                .iter()
                .map(|p| crate::ai::AiImagePart {
                    filename: p.filename.clone(),
                    mime: p.mime.clone(),
                    data: p.data.clone(),
                })
                .collect()
        });
    if let Some(parts) = ai_image_parts_raw.as_ref() {
        info!(
            "AIChatCommand image parts received: count={}, items={}",
            parts.len(),
            summarize_ai_image_parts(parts)
        );
    }
    let ai_image_parts = match normalize_ai_image_parts(ai_image_parts_raw).await {
        Ok(parts) => parts,
        Err(e) => {
            let _ = emit_server_message(
                output_tx,
                ServerMessage::AIChatErrorV2 {
                    project_name: project_name.clone(),
                    workspace_name: workspace_name.clone(),
                    ai_tool: ai_tool.clone(),
                    session_id: session_id.clone(),
                    error: e,
                },
            )
            .await;
            return Ok(true);
        }
    };
    if let Some(parts) = ai_image_parts.as_ref() {
        info!(
            "AIChatCommand image parts normalized: count={}, items={}",
            parts.len(),
            summarize_ai_image_parts(parts)
        );
    }
    let ai_model = model.as_ref().map(|m| crate::ai::AiModelSelection {
        provider_id: m.provider_id.clone(),
        model_id: m.model_id.clone(),
    });

    let (abort_tx, mut abort_rx) = mpsc::channel::<()>(1);
    let abort_key = stream_key(&ai_tool, &directory, &session_id);
    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.active_streams.insert(abort_key.clone(), abort_tx);
        ai.directory_last_used_ms.insert(dir_key.clone(), now_ms());
        let active = ai.directory_active_streams.entry(dir_key).or_insert(0);
        *active += 1;
    }

    let output_tx = output_tx.clone();
    let ai_state_cloned = ai_state.clone();
    let status_store_cloned = status_store.clone();
    let status_meta_cloned = status_meta.clone();
    tokio::spawn(async move {
        let mut stream = match agent
            .send_command(
                &directory,
                &session_id,
                &command,
                &arguments,
                file_refs.clone(),
                ai_image_parts,
                ai_model,
                agent_name.clone(),
            )
            .await
        {
            Ok(stream) => stream,
            Err(e) => {
                warn!(
                    "AIChatCommand: send_command failed, project={}, workspace={}, session_id={}, command={}, error={}",
                    project_name, workspace_name, session_id, command, e
                );
                status_store_cloned.set_status_with_meta(
                    status_meta_cloned.clone(),
                    AiSessionStatus::Error { message: e.clone() },
                );
                let _ = emit_server_message(
                    &output_tx,
                    ServerMessage::AIChatErrorV2 {
                        project_name: project_name.clone(),
                        workspace_name: workspace_name.clone(),
                        ai_tool: ai_tool.clone(),
                        session_id: session_id.clone(),
                        error: e,
                    },
                )
                .await;
                cleanup_stream_state(&ai_state_cloned, &abort_key, &ai_tool, &directory).await;
                return;
            }
        };

        loop {
            tokio::select! {
                _ = abort_rx.recv() => {
                    info!("AIChatCommand: abort signal received, session_id={}", session_id);
                    if let Err(e) = agent.abort_session(&directory, &session_id).await {
                        warn!(
                            "AIChatCommand: abort_session failed, project={}, workspace={}, session_id={}, error={}",
                            project_name, workspace_name, session_id, e
                        );
                    }
                    let _ = emit_server_message(
                        &output_tx,
                        ServerMessage::AIChatDone {
                            project_name: project_name.clone(),
                            workspace_name: workspace_name.clone(),
                            ai_tool: ai_tool.clone(),
                            session_id: session_id.clone(),
                        },
                    )
                    .await;
                    status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), AiSessionStatus::Idle);
                    break;
                }
                event = stream.next() => {
                    match event {
                        Some(Ok(ai_event)) => {
                            let keep_running = match ai_event {
                                AiEvent::MessageUpdated { message_id, role } => {
                                    emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatMessageUpdated {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            message_id,
                                            role,
                                        },
                                    )
                                    .await
                                }
                                AiEvent::PartUpdated { message_id, part } => {
                                    emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatPartUpdated {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            message_id,
                                            part: normalize_part_for_wire(part),
                                        },
                                    )
                                    .await
                                }
                                AiEvent::PartDelta { message_id, part_id, part_type, field, delta } => {
                                    emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatPartDelta {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            message_id,
                                            part_id,
                                            part_type,
                                            field,
                                            delta,
                                        },
                                    )
                                    .await
                                }
                                AiEvent::QuestionAsked { .. } | AiEvent::QuestionCleared { .. } => true,
                                AiEvent::Error { message } => {
                                    status_store_cloned.set_status_with_meta(
                                        status_meta_cloned.clone(),
                                        AiSessionStatus::Error { message: message.clone() },
                                    );
                                    let _ = emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatErrorV2 {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            error: message,
                                        },
                                    )
                                    .await;
                                    false
                                }
                                AiEvent::Done => {
                                    status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), AiSessionStatus::Idle);
                                    let _ = emit_server_message(
                                        &output_tx,
                                        ServerMessage::AIChatDone {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                        },
                                    )
                                    .await;
                                    false
                                }
                            };
                            if !keep_running {
                                break;
                            }
                        }
                        Some(Err(e)) => {
                            status_store_cloned.set_status_with_meta(
                                status_meta_cloned.clone(),
                                AiSessionStatus::Error { message: e.clone() },
                            );
                            let _ = emit_server_message(
                                &output_tx,
                                ServerMessage::AIChatErrorV2 {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                    error: e,
                                },
                            )
                            .await;
                            break;
                        }
                        None => {
                            status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), AiSessionStatus::Idle);
                            let _ = emit_server_message(
                                &output_tx,
                                ServerMessage::AIChatDone {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                },
                            )
                            .await;
                            break;
                        }
                    }
                }
            }
        }

        cleanup_stream_state(&ai_state_cloned, &abort_key, &ai_tool, &directory).await;
    });

    Ok(true)
}

async fn try_handle_ai_chat_abort(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
) -> Result<bool, String> {
    let (project_name, workspace_name, session_id, ai_tool) = match msg {
        ClientMessage::AIChatAbort {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            ai_tool.clone(),
        ),
        _ => return Ok(false),
    };
    let ai_tool = normalize_ai_tool(&ai_tool)?;

    let directory = resolve_directory(app_state, &project_name, &workspace_name).await?;
    let key = stream_key(&ai_tool, &directory, &session_id);
    info!(
        "AIChatAbort: project={}, workspace={}, session_id={}, key={}",
        project_name, workspace_name, session_id, key
    );

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    // best-effort：abort 代表前端应进入 idle（即使后端 abort 失败，也不应一直显示 busy）。
    {
        let store = {
            let guard = ai_state.lock().await;
            guard.session_statuses.clone()
        };
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: project_name.clone(),
                workspace_name: workspace_name.clone(),
                ai_tool: ai_tool.clone(),
                directory: directory.clone(),
                session_id: session_id.clone(),
            },
            AiSessionStatus::Idle,
        );
    }

    let abort_tx = {
        let ai = ai_state.lock().await;
        ai.active_streams.get(&key).cloned()
    };
    let mut should_emit_done_now = false;
    if let Some(tx) = abort_tx {
        info!("AIChatAbort: found active stream sender, sending abort signal");
        if tx.send(()).await.is_err() {
            should_emit_done_now = true;
        }
    } else {
        info!("AIChatAbort: no active stream sender found for key");
        should_emit_done_now = true;
    }

    // best-effort：并发触发后端 abort，避免阻塞 WS 主循环。
    let ai_state_cloned = ai_state.clone();
    let directory_cloned = directory.clone();
    let session_id_cloned = session_id.clone();
    let project_name_cloned = project_name.clone();
    let workspace_name_cloned = workspace_name.clone();
    let ai_tool_cloned = ai_tool.clone();
    tokio::spawn(async move {
        if let Ok(agent) = ensure_agent(&ai_state_cloned, &ai_tool_cloned).await {
            info!("AIChatAbort: calling agent.abort_session");
            if let Err(e) = agent
                .abort_session(&directory_cloned, &session_id_cloned)
                .await
            {
                warn!(
                    "AIChatAbort: abort_session failed, project={}, workspace={}, session_id={}, error={}",
                    project_name_cloned, workspace_name_cloned, session_id_cloned, e
                );
            }
        }
    });

    // 若没有可用流任务接收 abort 信号，主动下发 done 收敛前端状态。
    if should_emit_done_now {
        let _ = emit_server_message(
            output_tx,
            ServerMessage::AIChatDone {
                project_name,
                workspace_name,
                ai_tool,
                session_id,
            },
        )
        .await;
    }

    Ok(true)
}

async fn try_handle_ai_question_reply(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
) -> Result<bool, String> {
    let (project_name, workspace_name, session_id, request_id, answers, ai_tool) = match msg {
        ClientMessage::AIQuestionReply {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
            answers,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            request_id.clone(),
            answers.clone(),
            ai_tool.clone(),
        ),
        _ => return Ok(false),
    };
    let ai_tool = normalize_ai_tool(&ai_tool)?;

    let directory = resolve_directory(app_state, &project_name, &workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    info!(
        "AIQuestionReply: project={}, workspace={}, session_id={}, request_id={}, answers_count={}",
        project_name,
        workspace_name,
        session_id,
        request_id,
        answers.len()
    );

    agent
        .reply_question(&directory, &request_id, answers)
        .await
        .map_err(|e| {
            format!(
                "AIQuestionReply failed: project={}, workspace={}, session_id={}, request_id={}, error={}",
                project_name, workspace_name, session_id, request_id, e
            )
        })?;

    let _ = emit_server_message(
        output_tx,
        ServerMessage::AIQuestionCleared {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
        },
    )
    .await;

    Ok(true)
}

async fn try_handle_ai_question_reject(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
) -> Result<bool, String> {
    let (project_name, workspace_name, session_id, request_id, ai_tool) = match msg {
        ClientMessage::AIQuestionReject {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            request_id.clone(),
            ai_tool.clone(),
        ),
        _ => return Ok(false),
    };
    let ai_tool = normalize_ai_tool(&ai_tool)?;

    let directory = resolve_directory(app_state, &project_name, &workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    info!(
        "AIQuestionReject: project={}, workspace={}, session_id={}, request_id={}",
        project_name, workspace_name, session_id, request_id
    );

    agent
        .reject_question(&directory, &request_id)
        .await
        .map_err(|e| {
            format!(
                "AIQuestionReject failed: project={}, workspace={}, session_id={}, request_id={}, error={}",
                project_name, workspace_name, session_id, request_id, e
            )
        })?;

    let _ = emit_server_message(
        output_tx,
        ServerMessage::AIQuestionCleared {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
        },
    )
    .await;

    Ok(true)
}

async fn try_handle_ai_session_list(
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

async fn try_handle_ai_session_messages(
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

async fn try_handle_ai_session_delete(
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

async fn try_handle_ai_session_status(
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

async fn try_handle_ai_provider_list(
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

async fn try_handle_ai_agent_list(
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
async fn try_handle_ai_slash_commands(
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

async fn normalize_ai_image_parts(
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

fn summarize_ai_image_parts(parts: &[crate::ai::AiImagePart]) -> String {
    parts
        .iter()
        .map(|p| format!("{}|{}|{}B", p.filename, p.mime, p.data.len()))
        .collect::<Vec<_>>()
        .join(", ")
}

fn normalize_mime(mime: &str) -> String {
    mime.trim().to_ascii_lowercase()
}

fn detect_image_mime_from_bytes(bytes: &[u8]) -> Option<&'static str> {
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
