use crate::server::ws::OutboundTx as WebSocket;
use tracing::error;

use crate::server::protocol::ServerMessage;

pub(in crate::server::ws) async fn emit_message(
    socket: &WebSocket,
    msg: &ServerMessage,
    error_context: &str,
) {
    if let Err(e) = crate::server::ws::send_message(socket, msg).await {
        error!("{}: {}", error_context, e);
    }
}
