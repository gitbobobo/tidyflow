use axum::extract::ws::{Message, WebSocket};

use crate::server::protocol::ServerMessage;

mod connection;
mod dispatch;
mod http_api;
mod pairing;
mod request_scope;
mod server_runtime;
mod terminal;
mod transport;

/// 流控高水位（100KB）：未确认字节数超过此值时暂停转发
const FLOW_CONTROL_HIGH_WATER: u64 = 100 * 1024;
/// 入站 WS 帧大小上限（2MB）
const MAX_WS_FRAME_SIZE: usize = 2 * 1024 * 1024;
/// 入站 WS 消息大小上限（2MB）
const MAX_WS_MESSAGE_SIZE: usize = 2 * 1024 * 1024;

/// Run the WebSocket server on the specified port
pub async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    server_runtime::run_server(port).await
}

pub use terminal::{ack_terminal_output, subscribe_terminal, unsubscribe_terminal};

pub(super) async fn with_request_id<F, T>(request_id: Option<String>, fut: F) -> T
where
    F: std::future::Future<Output = T>,
{
    request_scope::with_request_id(request_id, fut).await
}

fn current_request_id() -> Option<String> {
    request_scope::current_request_id()
}

pub(super) fn next_server_envelope_seq() -> u64 {
    request_scope::next_server_envelope_seq()
}

/// Send a server message over WebSocket
pub async fn send_message(socket: &mut WebSocket, msg: &ServerMessage) -> Result<(), String> {
    let bytes = transport::envelope::encode_server_message(msg)?;
    socket
        .send(Message::Binary(bytes))
        .await
        .map_err(|e| e.to_string())
}
