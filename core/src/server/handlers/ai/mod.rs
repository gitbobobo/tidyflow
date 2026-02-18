use std::sync::Arc;

use axum::extract::ws::WebSocket;
use tokio::sync::{mpsc, Mutex};

use crate::server::context::{SharedAppState, TaskBroadcastTx};
use crate::server::protocol::{ClientMessage, ServerMessage};

pub mod ai_state;
#[cfg(test)]
mod ai_test;
pub mod file_ref;

mod session;
mod stream;
mod utils;

pub use ai_state::AIState;

pub type SharedAIState = Arc<Mutex<AIState>>;

pub async fn handle_ai_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
) -> Result<bool, String> {
    utils::ensure_status_push_initialized(ai_state, task_broadcast_tx).await;

    if stream::try_handle_ai_chat_start(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if stream::try_handle_ai_chat_send(
        client_msg,
        app_state,
        ai_state,
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
    )
    .await?
    {
        return Ok(true);
    }
    if stream::try_handle_ai_chat_command(
        client_msg,
        app_state,
        ai_state,
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
    )
    .await?
    {
        return Ok(true);
    }
    if stream::try_handle_ai_chat_abort(
        client_msg,
        app_state,
        ai_state,
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
    )
    .await?
    {
        return Ok(true);
    }
    if stream::try_handle_ai_question_reply(
        client_msg,
        app_state,
        ai_state,
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
    )
    .await?
    {
        return Ok(true);
    }
    if stream::try_handle_ai_question_reject(
        client_msg,
        app_state,
        ai_state,
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
    )
    .await?
    {
        return Ok(true);
    }
    if session::try_handle_ai_session_list(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if session::try_handle_ai_session_messages(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if session::try_handle_ai_session_delete(client_msg, app_state, ai_state).await? {
        return Ok(true);
    }
    if session::try_handle_ai_session_status(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if session::try_handle_ai_provider_list(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if session::try_handle_ai_agent_list(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    if session::try_handle_ai_slash_commands(client_msg, socket, app_state, ai_state).await? {
        return Ok(true);
    }
    Ok(false)
}
