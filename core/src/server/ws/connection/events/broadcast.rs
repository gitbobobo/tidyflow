use axum::extract::ws::WebSocket;
use tracing::{debug, info, warn};

use crate::server::context::ConnectionMeta;
use crate::server::protocol::ServerMessage;
use crate::server::ws::connection::shared_types::{RemoteTermRecvResult, TaskBroadcastRecvResult};

use super::common::emit_message;

pub(in crate::server::ws) async fn handle_task_broadcast_event(
    result: TaskBroadcastRecvResult,
    socket: &mut WebSocket,
    conn_meta: &ConnectionMeta,
) {
    match result {
        Ok(event) => {
            if event.origin_conn_id != conn_meta.conn_id {
                emit_message(
                    socket,
                    &event.message,
                    "Failed to send broadcast task event",
                )
                .await;
            }
        }
        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
            warn!("Task broadcast lagged by {} messages", n);
        }
        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
            debug!("Task broadcast channel closed");
        }
    }
}

pub(in crate::server::ws) async fn handle_remote_term_event(
    result: RemoteTermRecvResult,
    socket: &mut WebSocket,
    conn_meta: &ConnectionMeta,
) {
    match result {
        Ok(_event) => {
            info!(
                "Received RemoteTermEvent::Changed, sending remote_term_changed to local conn {}",
                conn_meta.conn_id
            );
            emit_message(
                socket,
                &ServerMessage::RemoteTermChanged,
                "Failed to send remote_term_changed",
            )
            .await;
        }
        Err(e) => {
            warn!("remote_term_rx recv error (lagged?): {:?}", e);
        }
    }
}
