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
        stream::handle_ai_chat_start(
            client_msg,
            socket,
            app_state,
            ai_state,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::handle_ai_chat_send(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::handle_ai_chat_command(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::handle_ai_chat_abort(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::handle_ai_question_reply(
            client_msg,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        stream::handle_ai_question_reject(
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
        session::handle_ai_session_list(client_msg, socket, app_state, ai_state),
        session::handle_ai_session_messages(client_msg, socket, app_state, ai_state),
        session::handle_ai_session_delete(client_msg, app_state, ai_state),
        session::handle_ai_session_status(client_msg, socket, app_state, ai_state),
        session::handle_ai_provider_list(client_msg, socket, app_state, ai_state),
        session::handle_ai_agent_list(client_msg, socket, app_state, ai_state),
        session::handle_ai_slash_commands(client_msg, socket, app_state, ai_state),
    );

    Ok(false)
}

#[cfg(test)]
mod tests {
    use crate::server::handlers::dispatch_handlers;
    use std::sync::{Arc, Mutex};

    async fn push_and_return(
        trace: Arc<Mutex<Vec<&'static str>>>,
        label: &'static str,
        value: bool,
    ) -> Result<bool, String> {
        trace.lock().expect("lock trace").push(label);
        Ok(value)
    }

    async fn dispatch_like_ai_stream(trace: Arc<Mutex<Vec<&'static str>>>) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "chat_start", false),
            push_and_return(trace.clone(), "chat_send", false),
            push_and_return(trace.clone(), "chat_command", false),
            push_and_return(trace.clone(), "chat_abort", true),
            push_and_return(trace.clone(), "question_reply", true),
            push_and_return(trace.clone(), "question_reject", true),
        );
        Ok(false)
    }

    async fn dispatch_like_ai_session(
        trace: Arc<Mutex<Vec<&'static str>>>,
    ) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "session_list", false),
            push_and_return(trace.clone(), "session_messages", false),
            push_and_return(trace.clone(), "session_delete", false),
            push_and_return(trace.clone(), "session_status", false),
            push_and_return(trace.clone(), "provider_list", true),
            push_and_return(trace.clone(), "agent_list", true),
            push_and_return(trace.clone(), "slash_commands", true),
        );
        Ok(false)
    }

    #[tokio::test]
    async fn ai_stream_dispatch_order_short_circuit() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = dispatch_like_ai_stream(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(
            *trace.lock().expect("lock trace"),
            vec!["chat_start", "chat_send", "chat_command", "chat_abort"]
        );
    }

    #[tokio::test]
    async fn ai_session_dispatch_order_short_circuit() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = dispatch_like_ai_session(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(
            *trace.lock().expect("lock trace"),
            vec![
                "session_list",
                "session_messages",
                "session_delete",
                "session_status",
                "provider_list"
            ]
        );
    }
}
