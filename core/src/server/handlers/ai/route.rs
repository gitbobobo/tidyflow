use axum::extract::ws::WebSocket;
use tokio::sync::mpsc;

use crate::server::context::{SharedAppState, TaskBroadcastTx};
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::{ClientMessage, ServerMessage};

use super::{session, stream, SharedAIState};

pub(crate) async fn handle_stream_routes(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
) -> Result<bool, String> {
    dispatch_handlers!(
        stream::try_handle_ai_chat_start(
            client_msg,
            socket,
            app_state,
            ai_state,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::try_handle_ai_chat_send(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::try_handle_ai_chat_command(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::try_handle_ai_chat_abort(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::try_handle_ai_question_reply(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::try_handle_ai_question_reject(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
    );

    Ok(false)
}

pub(crate) async fn handle_session_routes(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
) -> Result<bool, String> {
    dispatch_handlers!(
        session::try_handle_ai_session_list(client_msg, socket, app_state, ai_state),
        session::try_handle_ai_session_messages(client_msg, socket, app_state, ai_state),
        session::try_handle_ai_session_delete(client_msg, app_state, ai_state),
        session::try_handle_ai_session_status(client_msg, socket, app_state, ai_state),
        session::try_handle_ai_provider_list(client_msg, socket, app_state, ai_state),
        session::try_handle_ai_agent_list(client_msg, socket, app_state, ai_state),
        session::try_handle_ai_slash_commands(client_msg, socket, app_state, ai_state),
    );

    Ok(false)
}
