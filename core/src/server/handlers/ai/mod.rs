use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::ws::WebSocket;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::StreamExt;

use tracing::info;

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

pub async fn handle_ai_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    if try_handle_ai_chat_start(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_chat_send(client_msg, socket, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_chat_abort(client_msg, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_session_list(client_msg, socket, ai_state).await? {
        return Ok(true);
    }
    if try_handle_ai_session_delete(client_msg, ai_state).await? {
        return Ok(true);
    }
    Ok(false)
}

/// 创建 AI 代理实例（当前默认使用 OpenCode）
fn create_agent(workspace_root: PathBuf) -> Arc<dyn AiAgent> {
    let manager = OpenCodeManager::new(workspace_root);
    Arc::new(OpenCodeAgent::new(Arc::new(manager)))
}

async fn try_handle_ai_chat_start(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AIChatStart {
        project_name,
        title,
    } = msg
    else {
        return Ok(false);
    };

    let workspace_root = if let Some(ref proj_name) = project_name {
        let state = app_state.read().await;
        let project = state
            .get_project(proj_name)
            .ok_or_else(|| format!("Project '{}' not found", proj_name))?;
        project.root_path.clone()
    } else {
        PathBuf::from(std::env::temp_dir())
    };

    let title = title.clone().unwrap_or_else(|| "New Chat".to_string());

    // 通过工厂函数创建代理（未来可根据配置选择不同后端）
    let agent = create_agent(workspace_root);
    info!("AIChatStart: starting agent...");
    agent.start().await?;
    info!(
        "AIChatStart: agent started, creating session '{}'...",
        title
    );

    let session = agent.create_session(&title).await?;
    info!("AIChatStart: session created, id={}", session.id);

    {
        let mut ai = ai_state.lock().await;
        ai.agents.insert(session.id.clone(), agent);
        ai.sessions.insert(session.id.clone(), session.clone());
    }

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISessionStarted {
            session_id: session.id.clone(),
            title: session.title.clone(),
        },
    )
    .await?;
    info!(
        "AIChatStart: sent AISessionStarted, session_id={}",
        session.id
    );

    Ok(true)
}

async fn try_handle_ai_chat_send(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AIChatSend {
        session_id,
        message,
        file_refs,
    } = msg
    else {
        return Ok(false);
    };

    info!(
        "AIChatSend: session_id={}, message_len={}",
        session_id,
        message.len()
    );

    let agent = {
        let ai = ai_state.lock().await;
        ai.agents
            .get(session_id)
            .ok_or_else(|| format!("Session '{}' not found", session_id))?
            .clone()
    };

    let session_id = session_id.clone();
    let mut accumulated_text = String::new();
    let mut accumulated_thinking = String::new();
    let ai_state_clone = ai_state.clone();
    let session_id_for_abort = session_id.clone();
    let mut aborted = false;

    // 通过 trait 获取通用事件流
    info!("AIChatSend: calling agent.send_message...");
    let mut stream = agent
        .send_message(&session_id, message, file_refs.clone())
        .await?;
    info!("AIChatSend: got event stream, entering loop...");

    let (abort_tx, mut abort_rx) = mpsc::channel::<()>(1);
    {
        let mut ai = ai_state_clone.lock().await;
        ai.active_streams
            .insert(session_id_for_abort.clone(), abort_tx);
    }

    loop {
        tokio::select! {
            _ = abort_rx.recv() => {
                info!("AIChatSend: aborted");
                aborted = true;
                send_message(
                    socket,
                    &crate::server::protocol::ServerMessage::AIChatText {
                        session_id: session_id.clone(),
                        text: accumulated_text.clone(),
                        delta: None,
                        done: true,
                    },
                ).await?;
                send_message(
                    socket,
                    &crate::server::protocol::ServerMessage::AIChatThinking {
                        session_id: session_id.clone(),
                        text: accumulated_thinking.clone(),
                        delta: None,
                        done: true,
                    },
                ).await?;
                break;
            }
            event = stream.next() => {
                match event {
                    Some(Ok(ai_event)) => {
                        info!("AIChatSend: event={:?}", std::mem::discriminant(&ai_event));
                        match ai_event {
                            AiEvent::TextDelta { text } => {
                                accumulated_text.push_str(&text);
                                send_message(
                                    socket,
                                    &crate::server::protocol::ServerMessage::AIChatText {
                                        session_id: session_id.clone(),
                                        text: accumulated_text.clone(),
                                        delta: Some(text),
                                        done: false,
                                    },
                                ).await?;
                            }
                            AiEvent::ThinkingDelta { text } => {
                                accumulated_thinking.push_str(&text);
                                send_message(
                                    socket,
                                    &crate::server::protocol::ServerMessage::AIChatThinking {
                                        session_id: session_id.clone(),
                                        text: accumulated_thinking.clone(),
                                        delta: Some(text),
                                        done: false,
                                    },
                                ).await?;
                            }
                            AiEvent::ToolUse { tool, input } => {
                                send_message(
                                    socket,
                                    &crate::server::protocol::ServerMessage::AIChatTool {
                                        session_id: session_id.clone(),
                                        tool,
                                        input,
                                        output: None,
                                    },
                                ).await?;
                            }
                            AiEvent::Error { message } => {
                                send_message(
                                    socket,
                                    &crate::server::protocol::ServerMessage::AIChatError {
                                        session_id: session_id.clone(),
                                        error: message,
                                    },
                                ).await?;
                            }
                            AiEvent::Done => {
                                break;
                            }
                        }
                    }
                    Some(Err(e)) => {
                        info!("AIChatSend: stream error: {}", e);
                        send_message(
                            socket,
                            &crate::server::protocol::ServerMessage::AIChatError {
                                session_id: session_id.clone(),
                                error: e,
                            },
                        ).await?;
                        break;
                    }
                    None => {
                        info!("AIChatSend: stream ended (None)");
                        break;
                    }
                }
            }
        }
    }

    {
        let mut ai = ai_state_clone.lock().await;
        ai.active_streams.remove(&session_id_for_abort);
    }

    if aborted {
        return Ok(true);
    }

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AIChatText {
            session_id: session_id.clone(),
            text: accumulated_text,
            delta: None,
            done: true,
        },
    )
    .await?;
    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AIChatThinking {
            session_id,
            text: accumulated_thinking,
            delta: None,
            done: true,
        },
    )
    .await?;

    Ok(true)
}

async fn try_handle_ai_chat_abort(
    msg: &ClientMessage,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AIChatAbort { session_id } = msg else {
        return Ok(false);
    };

    let ai = ai_state.lock().await;
    if let Some(abort_tx) = ai.active_streams.get(session_id) {
        let _ = abort_tx.send(()).await;
    }

    Ok(true)
}

async fn try_handle_ai_session_list(
    msg: &ClientMessage,
    socket: &mut WebSocket,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionList { .. } = msg else {
        return Ok(false);
    };

    let ai = ai_state.lock().await;
    let sessions: Vec<_> = ai
        .sessions
        .values()
        .map(|s| crate::server::protocol::ai::SessionInfo {
            id: s.id.clone(),
            title: s.title.clone(),
            updated_at: s.updated_at,
        })
        .collect();

    send_message(
        socket,
        &crate::server::protocol::ServerMessage::AISessionList { sessions },
    )
    .await?;

    Ok(true)
}

async fn try_handle_ai_session_delete(
    msg: &ClientMessage,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    let ClientMessage::AISessionDelete { session_id } = msg else {
        return Ok(false);
    };

    let session_id = session_id.clone();

    let agent = {
        let mut ai = ai_state.lock().await;
        ai.sessions.remove(&session_id);
        ai.active_streams.remove(&session_id);
        ai.agents.remove(&session_id)
    };

    if let Some(agent) = agent {
        let _ = agent.stop().await;
    }

    Ok(true)
}
