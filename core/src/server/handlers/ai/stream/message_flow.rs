use std::sync::Arc;

use axum::extract::ws::WebSocket;
use tokio::sync::mpsc;
use tokio::time::{timeout, Duration};
use tokio_stream::StreamExt;
use tracing::{info, warn};

use crate::ai::session_status::{AiSessionStateStore, AiSessionStatus, AiSessionStatusMeta};
use crate::ai::{AiAgent, AiEvent};
use crate::server::context::{SharedAppState, TaskBroadcastTx};
use crate::server::protocol::ai::AiSessionOrigin;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

use super::super::utils::*;
use super::super::SharedAIState;

async fn resolve_selection_hint_for_done(
    agent: &Arc<dyn AiAgent>,
    directory: &str,
    session_id: &str,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
) -> Option<crate::server::protocol::ai::SessionSelectionHint> {
    let adapter_hint = match agent.session_selection_hint(directory, session_id).await {
        Ok(Some(adapter_hint)) => adapter_hint,
        Ok(None) => crate::ai::AiSessionSelectionHint::default(),
        Err(e) => {
            warn!(
                "AIChatDone selection hint lookup failed: project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                project_name, workspace_name, ai_tool, session_id, e
            );
            crate::ai::AiSessionSelectionHint::default()
        }
    };

    let inferred_hint = match agent.list_messages(directory, session_id, None).await {
        Ok(messages) => infer_selection_hint_from_messages(&map_ai_messages_for_wire(messages)),
        Err(e) => {
            warn!(
                "AIChatDone selection hint infer failed: project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                project_name, workspace_name, ai_tool, session_id, e
            );
            crate::ai::AiSessionSelectionHint::default()
        }
    };

    merge_session_selection_hint(adapter_hint, inferred_hint)
}

async fn resolve_selection_hint_for_done_with_timeout(
    agent: &Arc<dyn AiAgent>,
    directory: &str,
    session_id: &str,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
) -> Option<crate::server::protocol::ai::SessionSelectionHint> {
    const DONE_HINT_TIMEOUT_MS: u64 = 1500;
    match timeout(
        Duration::from_millis(DONE_HINT_TIMEOUT_MS),
        resolve_selection_hint_for_done(
            agent,
            directory,
            session_id,
            project_name,
            workspace_name,
            ai_tool,
        ),
    )
    .await
    {
        Ok(hint) => hint,
        Err(_) => {
            warn!(
                "AIChatDone selection hint resolve timeout: project={}, workspace={}, ai_tool={}, session_id={}, timeout_ms={}",
                project_name, workspace_name, ai_tool, session_id, DONE_HINT_TIMEOUT_MS
            );
            None
        }
    }
}

fn map_slash_command_for_wire(
    command: crate::ai::AiSlashCommand,
) -> crate::server::protocol::ai::SlashCommandInfo {
    crate::server::protocol::ai::SlashCommandInfo {
        name: command.name,
        description: command.description,
        action: command.action,
        input_hint: command.input_hint,
    }
}

fn map_slash_commands_for_wire(
    commands: Vec<crate::ai::AiSlashCommand>,
) -> Vec<crate::server::protocol::ai::SlashCommandInfo> {
    commands
        .into_iter()
        .map(map_slash_command_for_wire)
        .collect::<Vec<_>>()
}

fn build_slash_commands_update_message(
    project_name: String,
    workspace_name: String,
    ai_tool: String,
    session_id: String,
    commands: Vec<crate::ai::AiSlashCommand>,
) -> ServerMessage {
    ServerMessage::AISlashCommandsUpdate {
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        commands: map_slash_commands_for_wire(commands),
    }
}

const MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES: usize = 120_000;

fn build_part_updated_cache_ops(
    message_id: String,
    part: crate::server::protocol::ai::PartInfo,
) -> Vec<crate::server::protocol::ai::AiSessionCacheOpInfo> {
    if let Some(text) = part.text.clone() {
        if text.len() > MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES {
            let mut base_part = part.clone();
            base_part.text = None;
            let mut ops = vec![
                crate::server::protocol::ai::AiSessionCacheOpInfo::PartUpdated {
                    message_id: message_id.clone(),
                    part: base_part,
                },
            ];
            for chunk in split_utf8_text_by_max_bytes(&text, MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES) {
                ops.push(
                    crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                        message_id: message_id.clone(),
                        part_id: part.id.clone(),
                        part_type: part.part_type.clone(),
                        field: "text".to_string(),
                        delta: chunk,
                    },
                );
            }
            return ops;
        }
    }
    vec![crate::server::protocol::ai::AiSessionCacheOpInfo::PartUpdated { message_id, part }]
}

fn build_part_delta_cache_ops(
    message_id: String,
    part_id: String,
    part_type: String,
    field: String,
    delta: String,
) -> Vec<crate::server::protocol::ai::AiSessionCacheOpInfo> {
    if delta.len() <= MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES {
        return vec![
            crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id,
                part_id,
                part_type,
                field,
                delta,
            },
        ];
    }

    split_utf8_text_by_max_bytes(&delta, MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES)
        .into_iter()
        .map(
            |chunk| crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id: message_id.clone(),
                part_id: part_id.clone(),
                part_type: part_type.clone(),
                field: field.clone(),
                delta: chunk,
            },
        )
        .collect::<Vec<_>>()
}

async fn emit_ai_session_messages_update_with_ops(
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
    emit_state: &mut StreamEmitState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
    snapshot: &AiStreamSnapshot,
    ops: Option<Vec<crate::server::protocol::ai::AiSessionCacheOpInfo>>,
    allow_snapshot_messages_fallback: bool,
) {
    let update = build_ai_session_messages_update(
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        snapshot,
        ops,
        allow_snapshot_messages_fallback,
    );
    let _ = emit_server_message_with_state(
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
        update,
        emit_state,
    )
    .await;
}

/// ai_chat_done 时持久化会话上下文快照，供重启恢复和跨工作区上下文复用
async fn save_done_context_snapshot(
    ai_state: &SharedAIState,
    snapshot: &crate::server::handlers::ai::utils::AiStreamSnapshot,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
) {
    let message_count = snapshot.messages.len() as u32;
    let context_summary = snapshot
        .messages
        .iter()
        .rev()
        .find(|m| m.role == "assistant")
        .and_then(|m| m.parts.first())
        .and_then(|p| p.text.as_ref())
        .map(|t| {
            let bytes = t.as_bytes();
            if bytes.len() <= 500 {
                t.clone()
            } else {
                String::from_utf8_lossy(&bytes[..500]).into_owned()
            }
        });
    let ctx_snapshot =
        crate::server::handlers::ai::session_index_store::AiSessionContextSnapshotStored {
            snapshot_at_ms: now_ms(),
            message_count,
            context_summary,
            selection_hint: snapshot.selection_hint.clone(),
            context_remaining_percent: None,
        };
    if let Err(e) = super::super::save_session_context_snapshot(
        ai_state,
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        &ctx_snapshot,
    )
    .await
    {
        warn!(
            "Failed to save context snapshot: project={}, workspace={}, ai_tool={}, session_id={}, error={}",
            project_name, workspace_name, ai_tool, session_id, e
        );
    }
}

async fn touch_session_index_updated_at_with_warn(
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
) {
    let updated_at_ms = now_ms();
    if let Err(e) = super::super::touch_session_index_updated_at(
        ai_state,
        project_name,
        workspace_name,
        ai_tool,
        session_id,
        updated_at_ms,
    )
    .await
    {
        warn!(
            "AI session index touch failed: project={}, workspace={}, ai_tool={}, session_id={}, updated_at_ms={}, error={}",
            project_name, workspace_name, ai_tool, session_id, updated_at_ms, e
        );
    }
}

pub(crate) async fn handle_ai_chat_start(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
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
    let created_at_ms = now_ms();
    if let Err(e) = super::super::record_session_index_created(
        ai_state,
        project_name,
        workspace_name,
        &ai_tool,
        &directory,
        &session.id,
        &session.title,
        created_at_ms,
        AiSessionOrigin::User,
    )
    .await
    {
        warn!(
            "AIChatStart: persist session index failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
            project_name, workspace_name, ai_tool, session.id, e
        );
        if let Err(delete_err) = agent.delete_session(&directory, &session.id).await {
            warn!(
                "AIChatStart: rollback delete_session failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                project_name, workspace_name, ai_tool, session.id, delete_err
            );
        }
        return Err(format!("failed to persist ai session index: {}", e));
    }

    let selection_hint = match agent.session_selection_hint(&directory, &session.id).await {
        Ok(hint) => hint.and_then(|adapter_hint| {
            merge_session_selection_hint(adapter_hint, crate::ai::AiSessionSelectionHint::default())
        }),
        Err(e) => {
            warn!(
                "AIChatStart selection hint lookup failed: project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                project_name,
                workspace_name,
                ai_tool,
                session.id,
                e
            );
            None
        }
    };

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    let msg = crate::server::protocol::ServerMessage::AISessionStartedV2 {
        project_name: project_name.clone(),
        workspace_name: workspace_name.clone(),
        ai_tool,
        session_id: session.id,
        title: session.title,
        updated_at: session.updated_at,
        session_origin: AiSessionOrigin::User,
        selection_hint,
    };
    send_message(socket, &msg).await?;
    let _ =
        crate::server::context::send_task_broadcast_message(task_broadcast_tx, origin_conn_id, msg);

    Ok(true)
}

pub(crate) async fn handle_ai_chat_send(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
) -> Result<bool, String> {
    let (
        project_name,
        workspace_name,
        session_id,
        message,
        file_refs,
        image_parts,
        audio_parts,
        model,
        agent_name,
        config_overrides,
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
            audio_parts,
            model,
            agent,
            config_overrides,
            project_mentions: _,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            message.clone(),
            file_refs.clone(),
            image_parts.clone(),
            audio_parts.clone(),
            model.clone(),
            agent.clone(),
            config_overrides.clone(),
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
    status_store.set_status_with_meta(status_meta.clone(), AiSessionStatus::Running);

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
                task_broadcast_tx,
                origin_conn_id,
                ServerMessage::AIChatErrorV2 {
                    project_name: project_name.clone(),
                    workspace_name: workspace_name.clone(),
                    ai_tool: ai_tool.clone(),
                    session_id: session_id.clone(),
                    error: e,
                    route_decision: None,
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
    let ai_audio_parts_raw: Option<Vec<crate::ai::AiAudioPart>> =
        audio_parts.as_ref().map(|parts| {
            parts
                .iter()
                .map(|p| crate::ai::AiAudioPart {
                    filename: p.filename.clone(),
                    mime: p.mime.clone(),
                    data: p.data.clone(),
                })
                .collect()
        });
    if let Some(parts) = ai_audio_parts_raw.as_ref() {
        info!(
            "AIChatSend audio parts received: count={}, items={}",
            parts.len(),
            summarize_ai_audio_parts(parts)
        );
    }
    let ai_audio_parts = normalize_ai_audio_parts(ai_audio_parts_raw);
    if let Some(parts) = ai_audio_parts.as_ref() {
        info!(
            "AIChatSend audio parts normalized: count={}, items={}",
            parts.len(),
            summarize_ai_audio_parts(parts)
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
    let task_broadcast_tx = task_broadcast_tx.clone();
    let origin_conn_id = origin_conn_id.to_string();
    let ai_state_cloned = ai_state.clone();
    let status_store_cloned = status_store.clone();
    let status_meta_cloned = status_meta.clone();
    tokio::spawn(async move {
        let task_broadcast_tx = &task_broadcast_tx;
        let origin_conn_id = origin_conn_id.as_str();
        let mut emit_state = StreamEmitState::default();
        let target_conn_ids =
            ai_session_subscriber_conn_ids(&ai_state_cloned, &abort_key, origin_conn_id).await;
        emit_state.set_broadcast_targets(target_conn_ids);
        let _ = emit_server_message_with_state(
            &output_tx,
            task_broadcast_tx,
            origin_conn_id,
            ServerMessage::AIChatPending {
                project_name: project_name.clone(),
                workspace_name: workspace_name.clone(),
                ai_tool: ai_tool.clone(),
                session_id: session_id.clone(),
            },
            &mut emit_state,
        )
        .await;
        let seed_messages = match agent.list_messages(&directory, &session_id, None).await {
            Ok(messages) => map_ai_messages_for_wire(messages),
            Err(e) => {
                warn!(
                    "AIChatSend: seed snapshot list_messages failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                    project_name, workspace_name, ai_tool, session_id, e
                );
                Vec::new()
            }
        };
        let seed_selection_hint = match agent.session_selection_hint(&directory, &session_id).await
        {
            Ok(Some(hint)) => Some(map_ai_selection_hint_to_wire(hint)),
            Ok(None) => None,
            Err(e) => {
                warn!(
                    "AIChatSend: seed snapshot selection_hint failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                    project_name, workspace_name, ai_tool, session_id, e
                );
                None
            }
        };
        seed_stream_snapshot(
            &ai_state_cloned,
            &abort_key,
            seed_messages,
            seed_selection_hint,
            true,
        )
        .await;

        let mut stream = match agent
            .send_message_with_config(
                &directory,
                &session_id,
                &message,
                file_refs.clone(),
                ai_image_parts,
                ai_audio_parts,
                ai_model,
                agent_name.clone(),
                config_overrides.clone(),
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
                    AiSessionStatus::Failure { message: e.clone() },
                );
                if let Some(snapshot) =
                    mark_stream_snapshot_terminal(&ai_state_cloned, &abort_key, None).await
                {
                    emit_ai_session_messages_update_with_ops(
                        &output_tx,
                        task_broadcast_tx,
                        origin_conn_id,
                        &mut emit_state,
                        &project_name,
                        &workspace_name,
                        &ai_tool,
                        &session_id,
                        &snapshot,
                        None,
                        true,
                    )
                    .await;
                }
                let _ = emit_server_message_with_state(
                    &output_tx,
                    task_broadcast_tx,
                    origin_conn_id,
                    ServerMessage::AIChatErrorV2 {
                        project_name: project_name.clone(),
                        workspace_name: workspace_name.clone(),
                        ai_tool: ai_tool.clone(),
                        session_id: session_id.clone(),
                        error: e,
                        route_decision: None,
                    },
                    &mut emit_state,
                )
                .await;
                touch_session_index_updated_at_with_warn(
                    &ai_state_cloned,
                    &project_name,
                    &workspace_name,
                    &ai_tool,
                    &session_id,
                )
                .await;
                cleanup_stream_state(&ai_state_cloned, &abort_key, &ai_tool, &directory).await;
                return;
            }
        };

        let mut abort_forwarded = false;
        loop {
            tokio::select! {
                abort_signal = abort_rx.recv(), if !abort_forwarded => {
                    if abort_signal.is_none() {
                        continue;
                    }
                    abort_forwarded = true;
                    info!(
                        "AIChatSend: abort signal received, session_id={}, waiting adapter terminal event",
                        session_id
                    );
                    continue;
                }
                event = stream.next() => {
                    match event {
                        Some(Ok(ai_event)) => {
                            let keep_running = match ai_event {
                                AiEvent::MessageUpdated {
                                    message_id,
                                    role,
                                    selection_hint,
                                } => {
                                    let wire_hint = selection_hint.map(map_ai_selection_hint_to_wire);
                                    let op = crate::server::protocol::ai::AiSessionCacheOpInfo::MessageUpdated {
                                        message_id,
                                        role,
                                    };
                                    let snapshot = apply_stream_snapshot_cache_op(
                                        &ai_state_cloned,
                                        &abort_key,
                                        &op,
                                        wire_hint,
                                    )
                                    .await;
                                    emit_ai_session_messages_update_with_ops(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        &mut emit_state,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                        &session_id,
                                        &snapshot,
                                        Some(vec![op]),
                                        false,
                                    )
                                    .await;
                                    true
                                }
                                AiEvent::PartUpdated { message_id, part } => {
                                    let ops = build_part_updated_cache_ops(message_id, normalize_part_for_wire(part));
                                    for op in ops {
                                        let snapshot = apply_stream_snapshot_cache_op(
                                            &ai_state_cloned,
                                            &abort_key,
                                            &op,
                                            None,
                                        )
                                        .await;
                                        let emit_ops = emit_ops_for_cache_op(&snapshot, &op);
                                        emit_ai_session_messages_update_with_ops(
                                            &output_tx,
                                            task_broadcast_tx,
                                            origin_conn_id,
                                            &mut emit_state,
                                            &project_name,
                                            &workspace_name,
                                            &ai_tool,
                                            &session_id,
                                            &snapshot,
                                            Some(emit_ops),
                                            false,
                                        )
                                        .await;
                                    }
                                    true
                                }
                                AiEvent::PartDelta { message_id, part_id, part_type, field, delta } => {
                                    let ops = build_part_delta_cache_ops(message_id, part_id, part_type, field, delta);
                                    for op in ops {
                                        let snapshot = apply_stream_snapshot_cache_op(
                                            &ai_state_cloned,
                                            &abort_key,
                                            &op,
                                            None,
                                        )
                                        .await;
                                        let emit_ops = emit_ops_for_cache_op(&snapshot, &op);
                                        emit_ai_session_messages_update_with_ops(
                                            &output_tx,
                                            task_broadcast_tx,
                                            origin_conn_id,
                                            &mut emit_state,
                                            &project_name,
                                            &workspace_name,
                                            &ai_tool,
                                            &session_id,
                                            &snapshot,
                                            Some(emit_ops),
                                            false,
                                        )
                                        .await;
                                    }
                                    true
                                }
                                AiEvent::QuestionAsked { request } => {
                                    // 设置等待用户输入状态
                                    status_store_cloned.set_status_with_meta(
                                        status_meta_cloned.clone(),
                                        AiSessionStatus::AwaitingInput,
                                    );
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
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
                                                                option_id: opt.option_id,
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
                                        &mut emit_state,
                                    )
                                    .await;
                                    true
                                }
                                AiEvent::QuestionCleared { request_id, .. } => {
                                    // 恢复执行状态
                                    status_store_cloned.set_status_with_meta(
                                        status_meta_cloned.clone(),
                                        AiSessionStatus::Running,
                                    );
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIQuestionCleared {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            request_id,
                                        },
                                        &mut emit_state,
                                    )
                                    .await;
                                    true
                                }
                                AiEvent::SessionConfigOptionsUpdated {
                                    options,
                                    ..
                                } => {
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AISessionConfigOptions {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: Some(session_id.clone()),
                                            options: options
                                                .into_iter()
                                                .map(|option| crate::server::protocol::ai::SessionConfigOptionInfo {
                                                    option_id: option.option_id,
                                                    category: option.category,
                                                    name: option.name,
                                                    description: option.description,
                                                    current_value: option.current_value,
                                                    options: option
                                                        .options
                                                        .into_iter()
                                                        .map(|choice| crate::server::protocol::ai::SessionConfigOptionChoice {
                                                            value: choice.value,
                                                            label: choice.label,
                                                            description: choice.description,
                                                        })
                                                        .collect::<Vec<_>>(),
                                                    option_groups: option
                                                        .option_groups
                                                        .into_iter()
                                                        .map(|group| crate::server::protocol::ai::SessionConfigOptionGroup {
                                                            label: group.label,
                                                            options: group
                                                                .options
                                                                .into_iter()
                                                                .map(|choice| crate::server::protocol::ai::SessionConfigOptionChoice {
                                                                    value: choice.value,
                                                                    label: choice.label,
                                                                    description: choice.description,
                                                                })
                                                                .collect::<Vec<_>>(),
                                                        })
                                                        .collect::<Vec<_>>(),
                                                    raw: option.raw,
                                                })
                                                .collect::<Vec<_>>(),
                                        },
                                        &mut emit_state,
                                    )
                                    .await;
                                    true
                                }
                                AiEvent::SlashCommandsUpdated {
                                    session_id: event_session_id,
                                    commands,
                                } => {
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        build_slash_commands_update_message(
                                            project_name.clone(),
                                            workspace_name.clone(),
                                            ai_tool.clone(),
                                            event_session_id,
                                            commands,
                                        ),
                                        &mut emit_state,
                                    )
                                    .await;
                                    true
                                }
                                AiEvent::Error { message } => {
                                    warn!(
                                        "AIChatSend: stream event error, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                                        project_name, workspace_name, ai_tool, session_id, message
                                    );
                                    status_store_cloned.set_status_with_meta(
                                        status_meta_cloned.clone(),
                                        AiSessionStatus::Failure { message: message.clone() },
                                    );
                                    if let Some(snapshot) =
                                        mark_stream_snapshot_terminal(&ai_state_cloned, &abort_key, None).await
                                    {
                                        emit_ai_session_messages_update_with_ops(
                                            &output_tx,
                                            task_broadcast_tx,
                                            origin_conn_id,
                                            &mut emit_state,
                                            &project_name,
                                            &workspace_name,
                                            &ai_tool,
                                            &session_id,
                                            &snapshot,
                                            None,
                                            true,
                                        )
                                        .await;
                                    }
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIChatErrorV2 {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            error: message,
                route_decision: None,
                                        },
                                        &mut emit_state,
                                    )
                                    .await;
                                    touch_session_index_updated_at_with_warn(
                                        &ai_state_cloned,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                        &session_id,
                                    )
                                    .await;
                                    false
                                }
                                AiEvent::Done { stop_reason } => {
                                    // 根据 stop_reason 设置终态
                                    let final_status = match stop_reason.as_deref() {
                                        Some("cancel" | "cancelled" | "abort" | "aborted") => {
                                            AiSessionStatus::Cancelled
                                        }
                                        Some("error" | "failure") => {
                                            AiSessionStatus::Failure {
                                                message: "Task failed".to_string(),
                                            }
                                        }
                                        _ => AiSessionStatus::Success,
                                    };
                                    status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), final_status);
                                    let selection_hint = resolve_selection_hint_for_done_with_timeout(
                                        &agent,
                                        &directory,
                                        &session_id,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                    )
                                    .await;
                                    if let Some(snapshot) = mark_stream_snapshot_terminal(
                                        &ai_state_cloned,
                                        &abort_key,
                                        selection_hint.clone(),
                                    )
                                    .await {
                                        emit_ai_session_messages_update_with_ops(
                                            &output_tx,
                                            task_broadcast_tx,
                                            origin_conn_id,
                                            &mut emit_state,
                                            &project_name,
                                            &workspace_name,
                                            &ai_tool,
                                            &session_id,
                                            &snapshot,
                                            None,
                                            true,
                                        )
                                        .await;
                                        save_done_context_snapshot(&ai_state_cloned, &snapshot, &project_name, &workspace_name, &ai_tool, &session_id).await;
                                    }
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIChatDone {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            selection_hint,
                                            stop_reason,
                                route_decision: None,
                                budget_status: None,
                                        },
                                        &mut emit_state,
                                    )
                                    .await;
                                    touch_session_index_updated_at_with_warn(
                                        &ai_state_cloned,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                        &session_id,
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
                            warn!(
                                "AIChatSend: stream failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                                project_name, workspace_name, ai_tool, session_id, e
                            );
                            status_store_cloned.set_status_with_meta(
                                status_meta_cloned.clone(),
                                AiSessionStatus::Failure { message: e.clone() },
                            );
                            if let Some(snapshot) = mark_stream_snapshot_terminal(&ai_state_cloned, &abort_key, None).await {
                                emit_ai_session_messages_update_with_ops(
                                    &output_tx,
                                    task_broadcast_tx,
                                    origin_conn_id,
                                    &mut emit_state,
                                    &project_name,
                                    &workspace_name,
                                    &ai_tool,
                                    &session_id,
                                    &snapshot,
                                    None,
                                    true,
                                )
                                .await;
                            }
                            let _ = emit_server_message_with_state(
                                &output_tx,
                                task_broadcast_tx,
                                origin_conn_id,
                                ServerMessage::AIChatErrorV2 {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                    error: e,
                route_decision: None,
                                },
                                &mut emit_state,
                            )
                            .await;
                            touch_session_index_updated_at_with_warn(
                                &ai_state_cloned,
                                &project_name,
                                &workspace_name,
                                &ai_tool,
                                &session_id,
                            )
                            .await;
                            break;
                        }
                        None => {
                            // Hub 断开等情况下可能出现 None，确保收敛
                            status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), AiSessionStatus::Idle);
                            let selection_hint = resolve_selection_hint_for_done_with_timeout(
                                &agent,
                                &directory,
                                &session_id,
                                &project_name,
                                &workspace_name,
                                &ai_tool,
                            )
                            .await;
                            if let Some(snapshot) = mark_stream_snapshot_terminal(
                                &ai_state_cloned,
                                &abort_key,
                                selection_hint.clone(),
                            )
                            .await {
                                emit_ai_session_messages_update_with_ops(
                                    &output_tx,
                                    task_broadcast_tx,
                                    origin_conn_id,
                                    &mut emit_state,
                                    &project_name,
                                    &workspace_name,
                                    &ai_tool,
                                    &session_id,
                                    &snapshot,
                                    None,
                                    true,
                                )
                                .await;
                                save_done_context_snapshot(&ai_state_cloned, &snapshot, &project_name, &workspace_name, &ai_tool, &session_id).await;
                            }
                            let _ = emit_server_message_with_state(
                                &output_tx,
                                task_broadcast_tx,
                                origin_conn_id,
                                ServerMessage::AIChatDone {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                    selection_hint,
                                    stop_reason: None,
                                    route_decision: None,
                                    budget_status: None,
                                },
                                &mut emit_state,
                            )
                            .await;
                            touch_session_index_updated_at_with_warn(
                                &ai_state_cloned,
                                &project_name,
                                &workspace_name,
                                &ai_tool,
                                &session_id,
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

pub(crate) async fn handle_ai_chat_command(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
) -> Result<bool, String> {
    let (
        project_name,
        workspace_name,
        session_id,
        command,
        arguments,
        file_refs,
        image_parts,
        audio_parts,
        model,
        agent_name,
        config_overrides,
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
            audio_parts,
            model,
            agent,
            config_overrides,
            project_mentions: _,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            command.clone(),
            arguments.clone(),
            file_refs.clone(),
            image_parts.clone(),
            audio_parts.clone(),
            model.clone(),
            agent.clone(),
            config_overrides.clone(),
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
    status_store.set_status_with_meta(status_meta.clone(), AiSessionStatus::Running);

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
                task_broadcast_tx,
                origin_conn_id,
                ServerMessage::AIChatErrorV2 {
                    project_name: project_name.clone(),
                    workspace_name: workspace_name.clone(),
                    ai_tool: ai_tool.clone(),
                    session_id: session_id.clone(),
                    error: e,
                    route_decision: None,
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
    let ai_audio_parts_raw: Option<Vec<crate::ai::AiAudioPart>> =
        audio_parts.as_ref().map(|parts| {
            parts
                .iter()
                .map(|p| crate::ai::AiAudioPart {
                    filename: p.filename.clone(),
                    mime: p.mime.clone(),
                    data: p.data.clone(),
                })
                .collect()
        });
    if let Some(parts) = ai_audio_parts_raw.as_ref() {
        info!(
            "AIChatCommand audio parts received: count={}, items={}",
            parts.len(),
            summarize_ai_audio_parts(parts)
        );
    }
    let ai_audio_parts = normalize_ai_audio_parts(ai_audio_parts_raw);
    if let Some(parts) = ai_audio_parts.as_ref() {
        info!(
            "AIChatCommand audio parts normalized: count={}, items={}",
            parts.len(),
            summarize_ai_audio_parts(parts)
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
    let task_broadcast_tx = task_broadcast_tx.clone();
    let origin_conn_id = origin_conn_id.to_string();
    let ai_state_cloned = ai_state.clone();
    let status_store_cloned = status_store.clone();
    let status_meta_cloned = status_meta.clone();
    tokio::spawn(async move {
        let task_broadcast_tx = &task_broadcast_tx;
        let origin_conn_id = origin_conn_id.as_str();
        let mut emit_state = StreamEmitState::default();
        let target_conn_ids =
            ai_session_subscriber_conn_ids(&ai_state_cloned, &abort_key, origin_conn_id).await;
        emit_state.set_broadcast_targets(target_conn_ids);
        let command_message = if arguments.trim().is_empty() {
            format!("/{}", command.trim())
        } else {
            format!("/{} {}", command.trim(), arguments.trim())
        };
        let seed_messages = match agent.list_messages(&directory, &session_id, None).await {
            Ok(messages) => map_ai_messages_for_wire(messages),
            Err(e) => {
                warn!(
                    "AIChatCommand: seed snapshot list_messages failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                    project_name, workspace_name, ai_tool, session_id, e
                );
                Vec::new()
            }
        };
        let seed_selection_hint = match agent.session_selection_hint(&directory, &session_id).await
        {
            Ok(Some(hint)) => Some(map_ai_selection_hint_to_wire(hint)),
            Ok(None) => None,
            Err(e) => {
                warn!(
                    "AIChatCommand: seed snapshot selection_hint failed, project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                    project_name, workspace_name, ai_tool, session_id, e
                );
                None
            }
        };
        seed_stream_snapshot(
            &ai_state_cloned,
            &abort_key,
            seed_messages,
            seed_selection_hint,
            true,
        )
        .await;

        let mut stream = match agent
            .send_message_with_config(
                &directory,
                &session_id,
                &command_message,
                file_refs.clone(),
                ai_image_parts,
                ai_audio_parts,
                ai_model,
                agent_name.clone(),
                config_overrides.clone(),
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
                    AiSessionStatus::Failure { message: e.clone() },
                );
                if let Some(snapshot) =
                    mark_stream_snapshot_terminal(&ai_state_cloned, &abort_key, None).await
                {
                    emit_ai_session_messages_update_with_ops(
                        &output_tx,
                        task_broadcast_tx,
                        origin_conn_id,
                        &mut emit_state,
                        &project_name,
                        &workspace_name,
                        &ai_tool,
                        &session_id,
                        &snapshot,
                        None,
                        true,
                    )
                    .await;
                }
                let _ = emit_server_message_with_state(
                    &output_tx,
                    task_broadcast_tx,
                    origin_conn_id,
                    ServerMessage::AIChatErrorV2 {
                        project_name: project_name.clone(),
                        workspace_name: workspace_name.clone(),
                        ai_tool: ai_tool.clone(),
                        session_id: session_id.clone(),
                        error: e,
                        route_decision: None,
                    },
                    &mut emit_state,
                )
                .await;
                touch_session_index_updated_at_with_warn(
                    &ai_state_cloned,
                    &project_name,
                    &workspace_name,
                    &ai_tool,
                    &session_id,
                )
                .await;
                cleanup_stream_state(&ai_state_cloned, &abort_key, &ai_tool, &directory).await;
                return;
            }
        };

        let mut abort_forwarded = false;
        loop {
            tokio::select! {
                abort_signal = abort_rx.recv(), if !abort_forwarded => {
                    if abort_signal.is_none() {
                        continue;
                    }
                    abort_forwarded = true;
                    info!(
                        "AIChatCommand: abort signal received, session_id={}, waiting adapter terminal event",
                        session_id
                    );
                    continue;
                }
                event = stream.next() => {
                    match event {
                        Some(Ok(ai_event)) => {
                            let keep_running = match ai_event {
                                AiEvent::MessageUpdated {
                                    message_id,
                                    role,
                                    selection_hint,
                                } => {
                                    let wire_hint = selection_hint.map(map_ai_selection_hint_to_wire);
                                    let op = crate::server::protocol::ai::AiSessionCacheOpInfo::MessageUpdated {
                                        message_id,
                                        role,
                                    };
                                    let snapshot = apply_stream_snapshot_cache_op(
                                        &ai_state_cloned,
                                        &abort_key,
                                        &op,
                                        wire_hint,
                                    )
                                    .await;
                                    emit_ai_session_messages_update_with_ops(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        &mut emit_state,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                        &session_id,
                                        &snapshot,
                                        Some(vec![op]),
                                        false,
                                    )
                                    .await;
                                    true
                                }
                                AiEvent::PartUpdated { message_id, part } => {
                                    let ops = build_part_updated_cache_ops(message_id, normalize_part_for_wire(part));
                                    for op in ops {
                                        let snapshot = apply_stream_snapshot_cache_op(
                                            &ai_state_cloned,
                                            &abort_key,
                                            &op,
                                            None,
                                        )
                                        .await;
                                        let emit_ops = emit_ops_for_cache_op(&snapshot, &op);
                                        emit_ai_session_messages_update_with_ops(
                                            &output_tx,
                                            task_broadcast_tx,
                                            origin_conn_id,
                                            &mut emit_state,
                                            &project_name,
                                            &workspace_name,
                                            &ai_tool,
                                            &session_id,
                                            &snapshot,
                                            Some(emit_ops),
                                            false,
                                        )
                                        .await;
                                    }
                                    true
                                }
                                AiEvent::PartDelta { message_id, part_id, part_type, field, delta } => {
                                    let ops = build_part_delta_cache_ops(message_id, part_id, part_type, field, delta);
                                    for op in ops {
                                        let snapshot = apply_stream_snapshot_cache_op(
                                            &ai_state_cloned,
                                            &abort_key,
                                            &op,
                                            None,
                                        )
                                        .await;
                                        let emit_ops = emit_ops_for_cache_op(&snapshot, &op);
                                        emit_ai_session_messages_update_with_ops(
                                            &output_tx,
                                            task_broadcast_tx,
                                            origin_conn_id,
                                            &mut emit_state,
                                            &project_name,
                                            &workspace_name,
                                            &ai_tool,
                                            &session_id,
                                            &snapshot,
                                            Some(emit_ops),
                                            false,
                                        )
                                        .await;
                                    }
                                    true
                                }
                                AiEvent::QuestionAsked { .. } | AiEvent::QuestionCleared { .. } => true,
                                AiEvent::SessionConfigOptionsUpdated { options, .. } => {
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AISessionConfigOptions {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: Some(session_id.clone()),
                                            options: options
                                                .into_iter()
                                                .map(|option| crate::server::protocol::ai::SessionConfigOptionInfo {
                                                    option_id: option.option_id,
                                                    category: option.category,
                                                    name: option.name,
                                                    description: option.description,
                                                    current_value: option.current_value,
                                                    options: option
                                                        .options
                                                        .into_iter()
                                                        .map(|choice| crate::server::protocol::ai::SessionConfigOptionChoice {
                                                            value: choice.value,
                                                            label: choice.label,
                                                            description: choice.description,
                                                        })
                                                        .collect::<Vec<_>>(),
                                                    option_groups: option
                                                        .option_groups
                                                        .into_iter()
                                                        .map(|group| crate::server::protocol::ai::SessionConfigOptionGroup {
                                                            label: group.label,
                                                            options: group
                                                                .options
                                                                .into_iter()
                                                                .map(|choice| crate::server::protocol::ai::SessionConfigOptionChoice {
                                                                    value: choice.value,
                                                                    label: choice.label,
                                                                    description: choice.description,
                                                                })
                                                                .collect::<Vec<_>>(),
                                                        })
                                                        .collect::<Vec<_>>(),
                                                    raw: option.raw,
                                                })
                                                .collect::<Vec<_>>(),
                                        },
                                        &mut emit_state,
                                    )
                                    .await;
                                    true
                                }
                                AiEvent::SlashCommandsUpdated {
                                    session_id: event_session_id,
                                    commands,
                                } => {
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        build_slash_commands_update_message(
                                            project_name.clone(),
                                            workspace_name.clone(),
                                            ai_tool.clone(),
                                            event_session_id,
                                            commands,
                                        ),
                                        &mut emit_state,
                                    )
                                    .await;
                                    true
                                }
                                AiEvent::Error { message } => {
                                    status_store_cloned.set_status_with_meta(
                                        status_meta_cloned.clone(),
                                        AiSessionStatus::Failure { message: message.clone() },
                                    );
                                    if let Some(snapshot) =
                                        mark_stream_snapshot_terminal(&ai_state_cloned, &abort_key, None).await
                                    {
                                        emit_ai_session_messages_update_with_ops(
                                            &output_tx,
                                            task_broadcast_tx,
                                            origin_conn_id,
                                            &mut emit_state,
                                            &project_name,
                                            &workspace_name,
                                            &ai_tool,
                                            &session_id,
                                            &snapshot,
                                            None,
                                            true,
                                        )
                                        .await;
                                    }
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIChatErrorV2 {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            error: message,
                route_decision: None,
                                        },
                                        &mut emit_state,
                                    )
                                    .await;
                                    touch_session_index_updated_at_with_warn(
                                        &ai_state_cloned,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                        &session_id,
                                    )
                                    .await;
                                    false
                                }
                                AiEvent::Done { stop_reason } => {
                                    // 根据 stop_reason 设置终态
                                    let final_status = match stop_reason.as_deref() {
                                        Some("cancel" | "cancelled" | "abort" | "aborted") => {
                                            AiSessionStatus::Cancelled
                                        }
                                        Some("error" | "failure") => {
                                            AiSessionStatus::Failure {
                                                message: "Task failed".to_string(),
                                            }
                                        }
                                        _ => AiSessionStatus::Success,
                                    };
                                    status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), final_status);
                                    let selection_hint = resolve_selection_hint_for_done_with_timeout(
                                        &agent,
                                        &directory,
                                        &session_id,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                    )
                                    .await;
                                    if let Some(snapshot) = mark_stream_snapshot_terminal(
                                        &ai_state_cloned,
                                        &abort_key,
                                        selection_hint.clone(),
                                    )
                                    .await {
                                        emit_ai_session_messages_update_with_ops(
                                            &output_tx,
                                            task_broadcast_tx,
                                            origin_conn_id,
                                            &mut emit_state,
                                            &project_name,
                                            &workspace_name,
                                            &ai_tool,
                                            &session_id,
                                            &snapshot,
                                            None,
                                            true,
                                        )
                                        .await;
                                        save_done_context_snapshot(&ai_state_cloned, &snapshot, &project_name, &workspace_name, &ai_tool, &session_id).await;
                                    }
                                    let _ = emit_server_message_with_state(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIChatDone {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            selection_hint,
                                            stop_reason,
                                route_decision: None,
                                budget_status: None,
                                        },
                                        &mut emit_state,
                                    )
                                    .await;
                                    touch_session_index_updated_at_with_warn(
                                        &ai_state_cloned,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                        &session_id,
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
                                AiSessionStatus::Failure { message: e.clone() },
                            );
                            if let Some(snapshot) = mark_stream_snapshot_terminal(&ai_state_cloned, &abort_key, None).await {
                                emit_ai_session_messages_update_with_ops(
                                    &output_tx,
                                    task_broadcast_tx,
                                    origin_conn_id,
                                    &mut emit_state,
                                    &project_name,
                                    &workspace_name,
                                    &ai_tool,
                                    &session_id,
                                    &snapshot,
                                    None,
                                    true,
                                )
                                .await;
                            }
                            let _ = emit_server_message_with_state(
                                &output_tx,
                                task_broadcast_tx,
                                origin_conn_id,
                                ServerMessage::AIChatErrorV2 {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                    error: e,
                route_decision: None,
                                },
                                &mut emit_state,
                            )
                            .await;
                            touch_session_index_updated_at_with_warn(
                                &ai_state_cloned,
                                &project_name,
                                &workspace_name,
                                &ai_tool,
                                &session_id,
                            )
                            .await;
                            break;
                        }
                        None => {
                            status_store_cloned.set_status_with_meta(status_meta_cloned.clone(), AiSessionStatus::Idle);
                            let selection_hint = resolve_selection_hint_for_done_with_timeout(
                                &agent,
                                &directory,
                                &session_id,
                                &project_name,
                                &workspace_name,
                                &ai_tool,
                            )
                            .await;
                            if let Some(snapshot) = mark_stream_snapshot_terminal(
                                &ai_state_cloned,
                                &abort_key,
                                selection_hint.clone(),
                            )
                            .await {
                                emit_ai_session_messages_update_with_ops(
                                    &output_tx,
                                    task_broadcast_tx,
                                    origin_conn_id,
                                    &mut emit_state,
                                    &project_name,
                                    &workspace_name,
                                    &ai_tool,
                                    &session_id,
                                    &snapshot,
                                    None,
                                    true,
                                )
                                .await;
                                save_done_context_snapshot(&ai_state_cloned, &snapshot, &project_name, &workspace_name, &ai_tool, &session_id).await;
                            }
                            let _ = emit_server_message_with_state(
                                &output_tx,
                                task_broadcast_tx,
                                origin_conn_id,
                                ServerMessage::AIChatDone {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                    selection_hint,
                                    stop_reason: None,
                                    route_decision: None,
                                    budget_status: None,
                                },
                                &mut emit_state,
                            )
                            .await;
                            touch_session_index_updated_at_with_warn(
                                &ai_state_cloned,
                                &project_name,
                                &workspace_name,
                                &ai_tool,
                                &session_id,
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

#[cfg(test)]
mod tests {
    use super::{build_slash_commands_update_message, map_slash_commands_for_wire};
    use crate::ai::AiSlashCommand;
    use crate::server::protocol::ServerMessage;

    #[test]
    fn map_slash_commands_for_wire_should_keep_input_hint() {
        let mapped = map_slash_commands_for_wire(vec![
            AiSlashCommand {
                name: "build".to_string(),
                description: "构建项目".to_string(),
                action: "agent".to_string(),
                input_hint: Some("--release".to_string()),
            },
            AiSlashCommand {
                name: "new".to_string(),
                description: "新建会话".to_string(),
                action: "client".to_string(),
                input_hint: None,
            },
        ]);

        assert_eq!(mapped.len(), 2);
        assert_eq!(mapped[0].name, "build");
        assert_eq!(mapped[0].input_hint.as_deref(), Some("--release"));
        assert_eq!(mapped[1].name, "new");
        assert_eq!(mapped[1].input_hint, None);
    }

    #[test]
    fn build_slash_commands_update_message_should_map_event_payload() {
        let message = build_slash_commands_update_message(
            "tidyflow".to_string(),
            "default".to_string(),
            "codex".to_string(),
            "session-1".to_string(),
            vec![AiSlashCommand {
                name: "build".to_string(),
                description: "构建项目".to_string(),
                action: "agent".to_string(),
                input_hint: Some("--release".to_string()),
            }],
        );

        match message {
            ServerMessage::AISlashCommandsUpdate {
                project_name,
                workspace_name,
                ai_tool,
                session_id,
                commands,
            } => {
                assert_eq!(project_name, "tidyflow");
                assert_eq!(workspace_name, "default");
                assert_eq!(ai_tool, "codex");
                assert_eq!(session_id, "session-1");
                assert_eq!(commands.len(), 1);
                assert_eq!(commands[0].name, "build");
                assert_eq!(commands[0].input_hint.as_deref(), Some("--release"));
            }
            _ => panic!("expected ai_slash_commands_update message"),
        }
    }

    /// 验证 AISlashCommandsUpdate 消息中 project_name/workspace_name 完整保留，
    /// 客户端依赖这两个字段做多工作区 AI 会话流隔离，防止不同工作区的 slash 命令互相污染。
    #[test]
    fn slash_commands_update_preserves_workspace_boundary_fields() {
        let msg_a = build_slash_commands_update_message(
            "proj-a".to_string(),
            "main".to_string(),
            "claude_code".to_string(),
            "sess-a".to_string(),
            vec![],
        );
        let msg_b = build_slash_commands_update_message(
            "proj-b".to_string(),
            "feature".to_string(),
            "claude_code".to_string(),
            "sess-b".to_string(),
            vec![],
        );

        // 两个不同工作区的消息应各自携带独立的 project/workspace 标识，不混用
        match (&msg_a, &msg_b) {
            (
                ServerMessage::AISlashCommandsUpdate {
                    project_name: pa,
                    workspace_name: wa,
                    session_id: sa,
                    ..
                },
                ServerMessage::AISlashCommandsUpdate {
                    project_name: pb,
                    workspace_name: wb,
                    session_id: sb,
                    ..
                },
            ) => {
                assert_ne!(pa, pb, "不同工作区消息的 project_name 不应相同");
                assert_ne!(wa, wb, "不同工作区消息的 workspace_name 不应相同");
                assert_ne!(sa, sb, "不同工作区消息的 session_id 不应相同");
                // 复合键唯一性：客户端用 "<project>:<workspace>:<session_id>" 隔离 AI 流事件
                let key_a = format!("{}:{}:{}", pa, wa, sa);
                let key_b = format!("{}:{}:{}", pb, wb, sb);
                assert_ne!(key_a, key_b, "不同工作区的 AI 流复合键必须唯一");
            }
            _ => panic!("两个消息均应为 AISlashCommandsUpdate"),
        }
    }

    /// 验证同一 project 下不同 workspace 的 AI 流消息产生不同复合键，
    /// 防止多工作区场景下流式事件路由到错误的客户端状态。
    #[test]
    fn same_project_different_workspace_ai_stream_keys_are_distinct() {
        let pairs = [
            ("proj", "main", "sess-1"),
            ("proj", "feature-a", "sess-2"),
            ("proj", "feature-b", "sess-3"),
        ];

        let keys: std::collections::HashSet<String> = pairs
            .iter()
            .map(|(p, w, s)| format!("{}:{}:{}", p, w, s))
            .collect();

        assert_eq!(
            keys.len(),
            pairs.len(),
            "同一 project 下不同 workspace/session 的 AI 流复合键必须唯一，防止流式事件串台"
        );
    }
}
