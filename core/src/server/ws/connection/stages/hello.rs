use axum::extract::ws::WebSocket;

use crate::server::protocol::{ServerMessage, PROTOCOL_VERSION};

pub(in crate::server::ws) async fn send_hello_message(
    socket: &mut WebSocket,
) -> Result<(), String> {
    let hello_msg = ServerMessage::Hello {
        version: PROTOCOL_VERSION,
        session_id: String::new(),
        shell: String::new(),
        capabilities: Some(crate::server::protocol::v1_capabilities()),
    };

    crate::server::ws::send_message(socket, &hello_msg).await
}
