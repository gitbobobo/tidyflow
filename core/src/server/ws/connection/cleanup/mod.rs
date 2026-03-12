use crate::server::handlers::ai::SharedAIState;
use tracing::info;

use std::collections::HashMap;
use std::sync::Arc;

use crate::server::context::{ConnectionMeta, HandlerContext, TermSubscription};
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;

mod remote;
mod terminal;

/// 连接关闭时的统一清理入口（单一编排驱动）。
///
/// 职责：
/// - 按 `conn_id` 回收 AI 会话订阅（不跨连接串用）
/// - 按 `conn_id` 回收终端订阅（stale 状态终端归属当前连接）
/// - 远程（iOS/移动端）连接携带稳定 `subscriber_id` 时保留终端订阅，支持同一设备跨重连恢复
///
/// 约束：
/// - 本函数是 WebSocket 断开时的唯一合法清理路径，`handle_socket` 在 loop 结束后必须调用。
/// - 不得在各 action handler 中直接清理订阅状态；所有清理必须通过此入口。
/// - 恢复订阅与上下文的责任在客户端，服务端仅保证旧连接状态不泄漏到新连接。
pub(in crate::server::ws) async fn cleanup_on_disconnect(
    subscribed_terms: &Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
    conn_meta: &ConnectionMeta,
    remote_sub_registry: &SharedRemoteSubRegistry,
    _handler_ctx: &HandlerContext,
    ai_state: &SharedAIState,
) {
    let conn_id = &conn_meta.conn_id;
    info!(conn_id = %conn_id, "Starting connection-level cleanup on disconnect");
    terminal::cleanup_terminal_subscriptions(subscribed_terms, conn_id).await;
    remote::cleanup_remote_subscriptions(conn_meta, remote_sub_registry).await;
    cleanup_ai_session_subscriptions(ai_state, conn_id).await;
    info!(conn_id = %conn_id, "Connection-level cleanup completed");
}

async fn cleanup_ai_session_subscriptions(ai_state: &SharedAIState, conn_id: &str) {
    let mut ai = ai_state.lock().await;
    let removed = ai.unsubscribe_all_sessions_for_connection(conn_id);
    if removed > 0 {
        info!(
            conn_id = %conn_id,
            session_count = removed,
            "Cleaned up AI session subscriptions for connection"
        );
    }
}
