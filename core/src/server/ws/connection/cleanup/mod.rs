use crate::server::handlers::ai::SharedAIState;
use tracing::info;

use std::collections::HashMap;
use std::sync::Arc;

use crate::server::context::{ConnectionMeta, HandlerContext, TermSubscription};
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;

mod remote;
mod terminal;

/// 连接关闭时的统一清理入口：按 conn_id 语义回收 AI、终端和远程订阅。
/// 确保旧连接不会在新连接建立后继续收到推送或残留脏状态。
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
    if let Some(keys) = ai.session_subscriptions.remove(conn_id) {
        info!(
            conn_id = %conn_id,
            session_count = keys.len(),
            "Cleaned up AI session subscriptions for connection"
        );
    }
}
