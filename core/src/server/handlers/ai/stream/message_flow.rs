use std::sync::Arc;

use axum::extract::ws::WebSocket;
use tokio::sync::mpsc;
use tokio_stream::StreamExt;
use tracing::{info, warn};

use crate::ai::session_status::{AiSessionStateStore, AiSessionStatus, AiSessionStatusMeta};
use crate::ai::{AiAgent, AiEvent};
use crate::server::context::{SharedAppState, TaskBroadcastEvent, TaskBroadcastTx};
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

    let inferred_hint = match agent.list_messages(directory, session_id, Some(200)).await {
        Ok(messages) => {
            let wire_messages: Vec<crate::server::protocol::ai::MessageInfo> = messages
                .into_iter()
                .map(|m| crate::server::protocol::ai::MessageInfo {
                    id: m.id,
                    role: m.role,
                    created_at: m.created_at,
                    agent: m.agent,
                    model_provider_id: m.model_provider_id,
                    model_id: m.model_id,
                    parts: m.parts.into_iter().map(normalize_part_for_wire).collect(),
                })
                .collect();
            infer_selection_hint_from_messages(&wire_messages)
        }
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
        selection_hint,
    };
    send_message(socket, &msg).await?;
    let _ = task_broadcast_tx.send(TaskBroadcastEvent {
        origin_conn_id: origin_conn_id.to_string(),
        message: msg,
    });

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
                task_broadcast_tx,
                origin_conn_id,
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
    let task_broadcast_tx = task_broadcast_tx.clone();
    let origin_conn_id = origin_conn_id.to_string();
    let ai_state_cloned = ai_state.clone();
    let status_store_cloned = status_store.clone();
    let status_meta_cloned = status_meta.clone();
    tokio::spawn(async move {
        let task_broadcast_tx = &task_broadcast_tx;
        let origin_conn_id = origin_conn_id.as_str();
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
                    task_broadcast_tx,
                    origin_conn_id,
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
                        task_broadcast_tx,
                        origin_conn_id,
                        ServerMessage::AIChatDone {
                            project_name: project_name.clone(),
                            workspace_name: workspace_name.clone(),
                            ai_tool: ai_tool.clone(),
                            session_id: session_id.clone(),
                            selection_hint: None,
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
                                AiEvent::MessageUpdated {
                                    message_id,
                                    role,
                                    selection_hint,
                                } => {
                                    emit_server_message(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIChatMessageUpdated {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            message_id,
                                            role,
                                            selection_hint: selection_hint.map(|hint| {
                                                crate::server::protocol::ai::SessionSelectionHint {
                                                    agent: hint.agent,
                                                    model_provider_id: hint.model_provider_id,
                                                    model_id: hint.model_id,
                                                }
                                            }),
                                        },
                                    )
                                    .await
                                }
                                AiEvent::PartUpdated { message_id, part } => {
                                    emit_server_message(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
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
                                        task_broadcast_tx,
                                        origin_conn_id,
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
                                        task_broadcast_tx,
                                        origin_conn_id,
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
                                        task_broadcast_tx,
                                        origin_conn_id,
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
                                    let selection_hint = resolve_selection_hint_for_done(
                                        &agent,
                                        &directory,
                                        &session_id,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                    )
                                    .await;
                                    let _ = emit_server_message(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIChatDone {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            selection_hint,
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
                                task_broadcast_tx,
                                origin_conn_id,
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
                            let selection_hint = resolve_selection_hint_for_done(
                                &agent,
                                &directory,
                                &session_id,
                                &project_name,
                                &workspace_name,
                                &ai_tool,
                            )
                            .await;
                            let _ = emit_server_message(
                                &output_tx,
                                task_broadcast_tx,
                                origin_conn_id,
                                ServerMessage::AIChatDone {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                    selection_hint,
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
                task_broadcast_tx,
                origin_conn_id,
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
    let task_broadcast_tx = task_broadcast_tx.clone();
    let origin_conn_id = origin_conn_id.to_string();
    let ai_state_cloned = ai_state.clone();
    let status_store_cloned = status_store.clone();
    let status_meta_cloned = status_meta.clone();
    tokio::spawn(async move {
        let task_broadcast_tx = &task_broadcast_tx;
        let origin_conn_id = origin_conn_id.as_str();
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
                    task_broadcast_tx,
                    origin_conn_id,
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
                        task_broadcast_tx,
                        origin_conn_id,
                        ServerMessage::AIChatDone {
                            project_name: project_name.clone(),
                            workspace_name: workspace_name.clone(),
                            ai_tool: ai_tool.clone(),
                            session_id: session_id.clone(),
                            selection_hint: None,
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
                                AiEvent::MessageUpdated {
                                    message_id,
                                    role,
                                    selection_hint,
                                } => {
                                    emit_server_message(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIChatMessageUpdated {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            message_id,
                                            role,
                                            selection_hint: selection_hint.map(|hint| {
                                                crate::server::protocol::ai::SessionSelectionHint {
                                                    agent: hint.agent,
                                                    model_provider_id: hint.model_provider_id,
                                                    model_id: hint.model_id,
                                                }
                                            }),
                                        },
                                    )
                                    .await
                                }
                                AiEvent::PartUpdated { message_id, part } => {
                                    emit_server_message(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
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
                                        task_broadcast_tx,
                                        origin_conn_id,
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
                                        task_broadcast_tx,
                                        origin_conn_id,
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
                                    let selection_hint = resolve_selection_hint_for_done(
                                        &agent,
                                        &directory,
                                        &session_id,
                                        &project_name,
                                        &workspace_name,
                                        &ai_tool,
                                    )
                                    .await;
                                    let _ = emit_server_message(
                                        &output_tx,
                                        task_broadcast_tx,
                                        origin_conn_id,
                                        ServerMessage::AIChatDone {
                                            project_name: project_name.clone(),
                                            workspace_name: workspace_name.clone(),
                                            ai_tool: ai_tool.clone(),
                                            session_id: session_id.clone(),
                                            selection_hint,
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
                                task_broadcast_tx,
                                origin_conn_id,
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
                            let selection_hint = resolve_selection_hint_for_done(
                                &agent,
                                &directory,
                                &session_id,
                                &project_name,
                                &workspace_name,
                                &ai_tool,
                            )
                            .await;
                            let _ = emit_server_message(
                                &output_tx,
                                task_broadcast_tx,
                                origin_conn_id,
                                ServerMessage::AIChatDone {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    ai_tool: ai_tool.clone(),
                                    session_id: session_id.clone(),
                                    selection_hint,
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
