use tracing::info;

use crate::server::handlers::ai::SharedAIState;

use std::collections::HashMap;
use std::sync::Arc;

use crate::server::context::{ConnectionMeta, HandlerContext, TermSubscription};
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;

mod finalize;
mod remote;
mod terminal;

pub(in crate::server::ws) async fn cleanup_on_disconnect(
    subscribed_terms: &Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
    conn_meta: &ConnectionMeta,
    remote_sub_registry: &SharedRemoteSubRegistry,
    handler_ctx: &HandlerContext,
    ai_state: &SharedAIState,
) {
    let conn_id = &conn_meta.conn_id;
    terminal::cleanup_terminal_subscriptions(subscribed_terms).await;
    remote::cleanup_remote_subscriptions(conn_meta, remote_sub_registry).await;
    finalize::shutdown_lsp_and_log(handler_ctx).await;
    cleanup_ai_session_subscriptions(ai_state, conn_id).await;
}

async fn cleanup_ai_session_subscriptions(ai_state: &SharedAIState, conn_id: &str) {
    let mut ai = ai_state.lock().await;
    if ai.session_subscriptions.remove(conn_id).is_some() {
        info!("Cleaned up AI session subscriptions for connection {}", conn_id);
    }
}
