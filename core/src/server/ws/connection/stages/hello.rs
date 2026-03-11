use crate::server::protocol::{ServerMessage, PROTOCOL_VERSION};
use crate::server::ws::OutboundTx;

pub(in crate::server::ws) async fn send_hello_message(socket: &OutboundTx) -> Result<(), String> {
    let hello_msg = ServerMessage::Hello {
        version: PROTOCOL_VERSION,
        session_id: String::new(),
        shell: String::new(),
        capabilities: Some(crate::server::protocol::v1_capabilities()),
    };

    crate::server::ws::send_message(socket, &hello_msg).await
}
