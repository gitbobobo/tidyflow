use axum::extract::ws::{Message, WebSocket};
use futures::SinkExt;
use tracing::debug;

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
/// 每连接统一出站队列容量
const OUTBOUND_QUEUE_CAPACITY: usize = 1024;

pub type OutboundTx = tokio::sync::mpsc::Sender<ServerMessage>;
pub(super) type OutboundRx = tokio::sync::mpsc::Receiver<ServerMessage>;

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

pub(super) fn create_outbound_channel() -> (OutboundTx, OutboundRx) {
    tokio::sync::mpsc::channel(OUTBOUND_QUEUE_CAPACITY)
}

fn record_outbound_queue_depth(outbound_tx: &OutboundTx) {
    let available = outbound_tx.capacity();
    let depth = OUTBOUND_QUEUE_CAPACITY.saturating_sub(available);
    crate::server::perf::record_ws_outbound_queue_depth(depth as u64);
}

/// 将服务端消息入队到每连接统一 outbound queue。
pub async fn send_message(outbound_tx: &OutboundTx, msg: &ServerMessage) -> Result<(), String> {
    record_outbound_queue_depth(outbound_tx);
    outbound_tx
        .send(msg.clone())
        .await
        .map_err(|_| "outbound queue closed".to_string())
}

async fn write_server_message(
    socket_tx: &mut futures::stream::SplitSink<WebSocket, Message>,
    msg: &ServerMessage,
) -> Result<(), String> {
    let encode_started = std::time::Instant::now();
    let bytes = transport::envelope::encode_server_message(msg)?;
    crate::server::perf::record_ws_encode_ms(encode_started.elapsed().as_millis() as u64);
    socket_tx
        .send(Message::Binary(bytes))
        .await
        .map_err(|e| e.to_string())
}

pub(super) async fn run_writer_loop(
    mut socket_tx: futures::stream::SplitSink<WebSocket, Message>,
    mut outbound_rx: OutboundRx,
    conn_id: String,
) -> bool {
    loop {
        let Some(msg) = outbound_rx.recv().await else {
            debug!(
                "Outbound queue closed, writer exiting (conn_id={})",
                conn_id
            );
            return true;
        };
        if let Err(e) = write_server_message(&mut socket_tx, &msg).await {
            tracing::error!(
                "Failed to write outbound message: conn_id={}, error={}",
                conn_id,
                e
            );
            return false;
        }
    }
}
