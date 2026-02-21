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
) {
    terminal::cleanup_terminal_subscriptions(subscribed_terms).await;
    remote::cleanup_remote_subscriptions(conn_meta, remote_sub_registry).await;
    finalize::shutdown_lsp_and_log(handler_ctx).await;
}
