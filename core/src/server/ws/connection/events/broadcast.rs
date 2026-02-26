use axum::extract::ws::WebSocket;
use tracing::{debug, info, warn};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::server::context::ConnectionMeta;
use crate::server::protocol::ServerMessage;
use crate::server::ws::connection::shared_types::{RemoteTermRecvResult, TaskBroadcastRecvResult};

use super::common::emit_message;

static TASK_BROADCAST_LAG_LOG_SAMPLE_COUNT: AtomicU64 = AtomicU64::new(0);

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
            crate::server::perf::record_task_broadcast_lag(n);
            let sample_count = TASK_BROADCAST_LAG_LOG_SAMPLE_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
            if n >= 512 || sample_count % 20 == 1 {
                warn!(
                    "Task broadcast lagged by {} messages (sample_count={})",
                    n, sample_count
                );
            } else {
                debug!(
                    "Task broadcast lagged by {} messages (sampled, sample_count={})",
                    n, sample_count
                );
            }
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
