use axum::extract::ws::{Message, WebSocket};
use tracing::{error, info, trace, warn};

use crate::server::context::{ConnectionMeta, HandlerContext};
use crate::server::watcher::WorkspaceWatcher;

use super::LoopControl;

fn describe_socket_message(msg: &Message) -> String {
    match msg {
        Message::Text(t) => format!("Text({}...)", &t[..t.len().min(50)]),
        Message::Binary(b) => format!("Binary({} bytes)", b.len()),
        Message::Ping(_) => "Ping".to_string(),
        Message::Pong(_) => "Pong".to_string(),
        Message::Close(_) => "Close".to_string(),
    }
}

pub(super) async fn handle_socket_recv_result(
    msg_result: Option<Result<Message, axum::Error>>,
    socket: &mut WebSocket,
    handler_ctx: &HandlerContext,
    watcher: &std::sync::Arc<tokio::sync::Mutex<WorkspaceWatcher>>,
    conn_meta: &ConnectionMeta,
) -> LoopControl {
    trace!(
        "socket.recv() returned: {:?}",
        msg_result
            .as_ref()
            .map(|r| r.as_ref().map(describe_socket_message))
    );

    match msg_result {
        Some(Ok(Message::Binary(data))) => {
            super::super::events::handle_binary_client_message(
                &data,
                socket,
                handler_ctx,
                watcher,
                conn_meta,
            )
            .await;
            LoopControl::Continue
        }
        Some(Ok(Message::Close(_))) => {
            info!(
                "WebSocket connection closed by client (conn_id={})",
                conn_meta.conn_id
            );
            LoopControl::Break
        }
        Some(Ok(Message::Text(_))) => {
            warn!("Received deprecated text message, binary MessagePack expected");
            LoopControl::Continue
        }
        Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => LoopControl::Continue,
        Some(Err(e)) => {
            error!(
                "WebSocket error: conn_id={}, error={}",
                conn_meta.conn_id, e
            );
            LoopControl::Break
        }
        None => {
            info!(
                "WebSocket connection closed (recv returned None, conn_id={})",
                conn_meta.conn_id
            );
            LoopControl::Break
        }
    }
}
