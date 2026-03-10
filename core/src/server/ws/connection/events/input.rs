use crate::server::ws::OutboundTx as WebSocket;
use tracing::{trace, warn};

use crate::server::context::{ConnectionMeta, HandlerContext};
use crate::server::protocol::ServerMessage;

use super::common::emit_message;

pub(in crate::server::ws) async fn handle_binary_client_message(
    data: &[u8],
    socket: &WebSocket,
    handler_ctx: &HandlerContext,
    watcher: &std::sync::Arc<tokio::sync::Mutex<crate::server::watcher::WorkspaceWatcher>>,
    conn_meta: &ConnectionMeta,
) {
    trace!("Received binary client message: {} bytes", data.len());
    let client_message_type = crate::server::ws::dispatch::probe_client_message_type(data);
    if let Err(e) =
        crate::server::ws::dispatch::handle_client_message(data, socket, handler_ctx, watcher).await
    {
        warn!(
            "Error handling client message: conn_id={}, message_type={}, error={}",
            conn_meta.conn_id, client_message_type, e
        );
        emit_message(
            socket,
            &ServerMessage::Error {
                code: "message_error".to_string(),
                message: e,
                project: None,
                workspace: None,
                session_id: None,
                cycle_id: None,
            },
            &format!(
                "Failed to send error message: conn_id={}, message_type={}",
                conn_meta.conn_id, client_message_type
            ),
        )
        .await;
    }
}
