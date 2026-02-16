use std::sync::Arc;

use axum::extract::ws::WebSocket;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::StreamExt;
use tracing::{info, warn};

use crate::ai::{AiAgent, AiEvent, OpenCodeAgent, OpenCodeManager};
use crate::server::context::SharedAppState;
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub mod ai_state;
#[cfg(test)]
mod ai_test;
pub mod file_ref;

pub use ai_state::AIState;

pub type SharedAIState = Arc<Mutex<AIState>>;

const IDLE_DISPOSE_TTL_MS: i64 = 15 * 60 * 1000;
const MAINTENANCE_INTERVAL_SECS: u64 = 60;

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// 创建 AI 代理实例（单 opencode serve child + x-opencode-directory 路由）
fn create_agent() -> Arc<dyn AiAgent> {
    let manager = OpenCodeManager::new(std::env::temp_dir());
    Arc::new(OpenCodeAgent::new(Arc::new(manager)))
}

fn stream_key(directory: &str, session_id: &str) -> String {
    format!("{}::{}", directory, session_id)
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

async fn ensure_agent(ai_state: &SharedAIState) -> Result<Arc<dyn AiAgent>, String> {
    let agent = {
        let mut ai = ai_state.lock().await;
        if ai.agent.is_none() {
            ai.agent = Some(create_agent());
        }
        ai.agent.as_ref().unwrap().clone()
    };

    // start() 幂等：内部会 health check，失败才 spawn；event hub 也会 ensure_started。
    agent.start().await?;
    Ok(agent)
}

async fn ensure_maintenance(ai_state: &SharedAIState, agent: Arc<dyn AiAgent>) {
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
            let idle_dirs: Vec<String> = {
                let ai = ai_state.lock().await;
                ai.directory_last_used_ms
                    .iter()
                    .filter_map(|(dir, last_used)| {
                        let active = ai.directory_active_streams.get(dir).cloned().unwrap_or(0);
                        if active == 0 && now.saturating_sub(*last_used) > IDLE_DISPOSE_TTL_MS {
                            Some(dir.clone())
                        } else {
                            None
                        }
                    })
                    .collect()
            };

            for dir in idle_dirs {
                match agent.dispose_instance(&dir).await {
                    Ok(_) => {
                        let mut ai = ai_state.lock().await;
                        // dispose 后更新时间戳，避免立即重复 dispose
                        ai.directory_last_used_ms.insert(dir, now_ms());
                    }
                    Err(e) => warn!("AI maintenance: dispose_instance failed: {}", e),
                }
            }
        }
    });
}

pub async fn handle_ai_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    if try_handle_ai_chat_start(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_chat_send(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_chat_abort(client_msg, app_state, ai_state).await? {
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
        title,
    } = msg
    else {
        return Ok(false);
    };

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state).await?;
    ensure_maintenance(ai_state, agent.clone()).await;

    let title = title.clone().unwrap_or_else(|| "New Chat".to_string());
    info!(
        "AIChatStart: project={}, workspace={}, directory={}, title={}",
        project_name, workspace_name, directory, title
    );

    let session = agent.create_session(&directory, &title).await?;

    {
        let mut ai = ai_state.lock().await;
        ai.directory_last_used_ms.insert(directory.clone(), now_ms());
    }

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISessionStartedV2 {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
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
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AIChatSend {
        project_name,
        workspace_name,
        session_id,
        message,
        file_refs,
    } = msg
    else {
        return Ok(false);
    };

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state).await?;
    ensure_maintenance(ai_state, agent.clone()).await;

    info!(
        "AIChatSend: project={}, workspace={}, session_id={}, message_len={}",
        project_name,
        workspace_name,
        session_id,
        message.len()
    );

    let mut stream = match agent
        .send_message(&directory, session_id, message, file_refs.clone())
        .await
    {
        Ok(stream) => stream,
        Err(e) => {
            warn!(
                "AIChatSend: send_message failed, project={}, workspace={}, session_id={}, error={}",
                project_name, workspace_name, session_id, e
            );
            send_message(
                socket,
                &crate::server::protocol::ServerMessage::AIChatErrorV2 {
                    project_name: project_name.clone(),
                    workspace_name: workspace_name.clone(),
                    session_id: session_id.clone(),
                    error: e,
                },
            )
            .await?;
            return Ok(true);
        }
    };

    let (abort_tx, mut abort_rx) = mpsc::channel::<()>(1);
    let abort_key = stream_key(&directory, session_id);
    {
        let mut ai = ai_state.lock().await;
        ai.active_streams.insert(abort_key.clone(), abort_tx);
        ai.directory_last_used_ms.insert(directory.clone(), now_ms());
        let active = ai.directory_active_streams.entry(directory.clone()).or_insert(0);
        *active += 1;
    }

    let mut aborted = false;
    loop {
        tokio::select! {
            _ = abort_rx.recv() => {
                aborted = true;
                let _ = agent.abort_session(&directory, session_id).await;
                send_message(socket, &crate::server::protocol::ServerMessage::AIChatDone {
                    project_name: project_name.clone(),
                    workspace_name: workspace_name.clone(),
                    session_id: session_id.clone(),
                }).await?;
                break;
            }
            event = stream.next() => {
                match event {
                    Some(Ok(ai_event)) => {
                        match ai_event {
                            AiEvent::MessageUpdated { message_id, role } => {
                                send_message(socket, &crate::server::protocol::ServerMessage::AIChatMessageUpdated {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    session_id: session_id.clone(),
                                    message_id,
                                    role,
                                }).await?;
                            }
                            AiEvent::PartUpdated { message_id, part } => {
                                send_message(socket, &crate::server::protocol::ServerMessage::AIChatPartUpdated {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    session_id: session_id.clone(),
                                    message_id,
                                    part: crate::server::protocol::ai::PartInfo {
                                        id: part.id,
                                        part_type: part.part_type,
                                        text: part.text,
                                        tool_name: part.tool_name,
                                        tool_state: part.tool_state,
                                    }
                                }).await?;
                            }
                            AiEvent::PartDelta { message_id, part_id, part_type, field, delta } => {
                                send_message(socket, &crate::server::protocol::ServerMessage::AIChatPartDelta {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    session_id: session_id.clone(),
                                    message_id,
                                    part_id,
                                    part_type,
                                    field,
                                    delta,
                                }).await?;
                            }
                            AiEvent::Error { message } => {
                                send_message(socket, &crate::server::protocol::ServerMessage::AIChatErrorV2 {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    session_id: session_id.clone(),
                                    error: message,
                                }).await?;
                                break;
                            }
                            AiEvent::Done => {
                                send_message(socket, &crate::server::protocol::ServerMessage::AIChatDone {
                                    project_name: project_name.clone(),
                                    workspace_name: workspace_name.clone(),
                                    session_id: session_id.clone(),
                                }).await?;
                                break;
                            }
                        }
                    }
                    Some(Err(e)) => {
                        send_message(socket, &crate::server::protocol::ServerMessage::AIChatErrorV2 {
                            project_name: project_name.clone(),
                            workspace_name: workspace_name.clone(),
                            session_id: session_id.clone(),
                            error: e,
                        }).await?;
                        break;
                    }
                    None => {
                        // Hub 断开等情况下可能出现 None，确保收敛
                        send_message(socket, &crate::server::protocol::ServerMessage::AIChatDone {
                            project_name: project_name.clone(),
                            workspace_name: workspace_name.clone(),
                            session_id: session_id.clone(),
                        }).await?;
                        break;
                    }
                }
            }
        }
    }

    {
        let mut ai = ai_state.lock().await;
        ai.active_streams.remove(&abort_key);
        let active = ai.directory_active_streams.entry(directory.clone()).or_insert(0);
        *active = active.saturating_sub(1);
        ai.directory_last_used_ms.insert(directory.clone(), now_ms());
    }

    if aborted {
        return Ok(true);
    }

    Ok(true)
}

async fn try_handle_ai_chat_abort(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AIChatAbort {
        project_name,
        workspace_name,
        session_id,
    } = msg
    else {
        return Ok(false);
    };

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let key = stream_key(&directory, session_id);

    {
        let mut ai = ai_state.lock().await;
        ai.directory_last_used_ms.insert(directory.clone(), now_ms());
    }

    let abort_tx = {
        let ai = ai_state.lock().await;
        ai.active_streams.get(&key).cloned()
    };
    if let Some(tx) = abort_tx {
        let _ = tx.send(()).await;
    }

    // best-effort：触发后端 abort（不影响本地 done 收敛）
    if let Ok(agent) = ensure_agent(ai_state).await {
        let _ = agent.abort_session(&directory, session_id).await;
    }

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
    } = msg
    else {
        return Ok(false);
    };

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state).await?;
    ensure_maintenance(ai_state, agent.clone()).await;

    {
        let mut ai = ai_state.lock().await;
        ai.directory_last_used_ms.insert(directory.clone(), now_ms());
    }

    let sessions = agent.list_sessions(&directory).await?;
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
        session_id,
        limit,
    } = msg
    else {
        return Ok(false);
    };

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state).await?;
    ensure_maintenance(ai_state, agent.clone()).await;

    {
        let mut ai = ai_state.lock().await;
        ai.directory_last_used_ms.insert(directory.clone(), now_ms());
    }

    let messages = agent
        .list_messages(&directory, session_id, *limit)
        .await?
        .into_iter()
        .map(|m| crate::server::protocol::ai::MessageInfo {
            id: m.id,
            role: m.role,
            created_at: m.created_at,
            parts: m
                .parts
                .into_iter()
                .map(|p| crate::server::protocol::ai::PartInfo {
                    id: p.id,
                    part_type: p.part_type,
                    text: p.text,
                    tool_name: p.tool_name,
                    tool_state: p.tool_state,
                })
                .collect(),
        })
        .collect();

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISessionMessages {
            project_name: project_name.clone(),
            workspace_name: workspace_name.clone(),
            session_id: session_id.clone(),
            messages,
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
        session_id,
    } = msg
    else {
        return Ok(false);
    };

    let directory = resolve_directory(app_state, project_name, workspace_name).await?;
    let agent = ensure_agent(ai_state).await?;
    ensure_maintenance(ai_state, agent.clone()).await;

    {
        let mut ai = ai_state.lock().await;
        ai.directory_last_used_ms.insert(directory.clone(), now_ms());
    }

    // 先清理本地 active stream
    let key = stream_key(&directory, session_id);
    {
        let mut ai = ai_state.lock().await;
        ai.active_streams.remove(&key);
    }

    let _ = agent.delete_session(&directory, session_id).await;

    Ok(true)
}
