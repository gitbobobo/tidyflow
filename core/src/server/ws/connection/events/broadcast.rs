use crate::server::ws::OutboundTx as WebSocket;
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
    socket: &WebSocket,
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
    socket: &WebSocket,
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

    /// 验证旧连接 ID 在重连后不会命中新连接的目标过滤。
    /// 模拟场景：广播目标只指定新 conn_id，旧 conn_id 被排除。
    #[test]
    fn old_connection_excluded_via_target_filter() {
        let mut targets = HashSet::new();
        targets.insert("new-conn".to_string());
        let event = TaskBroadcastEvent {
            origin_conn_id: "origin".to_string(),
            message: ServerMessage::Pong,
            target_conn_ids: Some(Arc::new(targets)),
            skip_when_single_receiver: false,
        };
        assert!(
            !is_task_broadcast_target_match(&event, "old-conn"),
            "旧连接 ID 不应命中目标过滤"
        );
        assert!(
            is_task_broadcast_target_match(&event, "new-conn"),
            "新连接 ID 应命中目标过滤"
        );
    }

    /// 验证 origin 过滤与 target 过滤在同一连接上的交互。
    /// origin_conn_id 即使在 target_conn_ids 中，也会被 handle_task_broadcast_event
    /// 的 origin 过滤先拦截（此处只测试 target_match 函数本身的行为）。
    #[test]
    fn target_match_does_not_consider_origin() {
        let mut targets = HashSet::new();
        targets.insert("conn-A".to_string());
        let event = TaskBroadcastEvent {
            origin_conn_id: "conn-A".to_string(),
            message: ServerMessage::Pong,
            target_conn_ids: Some(Arc::new(targets)),
            skip_when_single_receiver: false,
        };
        // target_match 只看 target_conn_ids，origin 过滤由调用方处理
        assert!(is_task_broadcast_target_match(&event, "conn-A"));
    }

    /// 验证空目标集合拒绝所有连接。
    #[test]
    fn empty_target_set_rejects_all() {
        let targets: HashSet<String> = HashSet::new();
        let event = TaskBroadcastEvent {
            origin_conn_id: "origin".to_string(),
            message: ServerMessage::Pong,
            target_conn_ids: Some(Arc::new(targets)),
            skip_when_single_receiver: false,
        };
        assert!(!is_task_broadcast_target_match(&event, "conn-1"));
        assert!(!is_task_broadcast_target_match(&event, "conn-2"));
    }
}
