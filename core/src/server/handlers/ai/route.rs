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
        session::handle_ai_read_via_http_required(client_msg, socket),
        session::handle_ai_session_delete(client_msg, app_state, ai_state),
        session::handle_ai_session_set_config_option(client_msg, socket, app_state, ai_state),
        session::handle_ai_session_rename(client_msg, socket, app_state, ai_state),
        session::query_ai_session_search(client_msg, socket, app_state, ai_state),
        session::handle_ai_code_review(client_msg, socket, app_state, ai_state),
    );

    Ok(false)
}

pub(crate) async fn handle_subscription_routes(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    conn_id: &str,
) -> Result<bool, String> {
    dispatch_handlers!(
        session::handle_ai_session_subscribe(client_msg, socket, app_state, ai_state, conn_id),
        session::handle_ai_session_unsubscribe(client_msg, app_state, ai_state, conn_id),
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
            push_and_return(trace.clone(), "read_via_http_required", false),
            push_and_return(trace.clone(), "session_delete", false),
            push_and_return(trace.clone(), "session_set_config_option", false),
            push_and_return(trace.clone(), "session_set_config_option_2", true),
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
                "read_via_http_required",
                "session_delete",
                "session_set_config_option",
                "session_set_config_option_2"
            ]
        );
    }
}
