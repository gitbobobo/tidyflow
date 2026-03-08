use std::collections::HashMap;
use std::sync::Arc;

use tracing::info;

use crate::server::context::TermSubscription;

pub(in crate::server::ws) async fn cleanup_terminal_subscriptions(
    subscribed_terms: &Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
    conn_id: &str,
) {
    let mut subs = subscribed_terms.lock().await;
    let count = subs.len();
    for (term_id, (handle, _fc, flow_gate)) in subs.drain() {
        info!(conn_id = %conn_id, term_id = %term_id, "Unsubscribing from terminal on WS disconnect");
        handle.abort();
        flow_gate.remove_subscriber();
    }
    if count > 0 {
        info!(conn_id = %conn_id, count = count, "Terminal subscriptions cleaned up");
    }
}
