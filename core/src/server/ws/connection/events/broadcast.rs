use axum::extract::ws::WebSocket;
use std::sync::atomic::{AtomicU64, Ordering};
use tracing::{debug, info, warn};

use crate::server::context::{ConnectionMeta, TaskBroadcastEvent};
use crate::server::protocol::ServerMessage;
use crate::server::ws::connection::shared_types::{RemoteTermRecvResult, TaskBroadcastRecvResult};

use super::common::emit_message;

static TASK_BROADCAST_LAG_LOG_SAMPLE_COUNT: AtomicU64 = AtomicU64::new(0);

fn is_task_broadcast_target_match(event: &TaskBroadcastEvent, conn_id: &str) -> bool {
    event
        .target_conn_ids
        .as_ref()
        .map(|targets| targets.contains(conn_id))
        .unwrap_or(true)
}

pub(in crate::server::ws) async fn handle_task_broadcast_event(
    result: TaskBroadcastRecvResult,
    socket: &mut WebSocket,
    conn_meta: &ConnectionMeta,
) {
    match result {
        Ok(event) => {
            if event.origin_conn_id == conn_meta.conn_id {
                return;
            }

            if !is_task_broadcast_target_match(&event, &conn_meta.conn_id) {
                crate::server::perf::record_task_broadcast_filtered_target();
                return;
            }

            emit_message(
                socket,
                &event.message,
                "Failed to send broadcast task event",
            )
            .await;
        }
        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
            crate::server::perf::record_task_broadcast_lag(n);
            let sample_count =
                TASK_BROADCAST_LAG_LOG_SAMPLE_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
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

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::sync::Arc;

    use crate::server::context::TaskBroadcastEvent;
    use crate::server::protocol::ServerMessage;

    use super::is_task_broadcast_target_match;

    #[test]
    fn target_match_defaults_to_true_when_targets_absent() {
        let event = TaskBroadcastEvent {
            origin_conn_id: "origin".to_string(),
            message: ServerMessage::Pong,
            target_conn_ids: None,
            skip_when_single_receiver: false,
        };
        assert!(is_task_broadcast_target_match(&event, "conn-1"));
    }

    #[test]
    fn target_match_respects_target_set() {
        let mut targets = HashSet::new();
        targets.insert("conn-2".to_string());
        let event = TaskBroadcastEvent {
            origin_conn_id: "origin".to_string(),
            message: ServerMessage::Pong,
            target_conn_ids: Some(Arc::new(targets)),
            skip_when_single_receiver: false,
        };
        assert!(is_task_broadcast_target_match(&event, "conn-2"));
        assert!(!is_task_broadcast_target_match(&event, "conn-9"));
    }
}
