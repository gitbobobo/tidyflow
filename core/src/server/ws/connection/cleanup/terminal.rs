use std::collections::HashMap;
use std::sync::Arc;

use tracing::info;

use crate::server::context::TermSubscription;

pub(in crate::server::ws) async fn cleanup_terminal_subscriptions(
    subscribed_terms: &Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
) {
    let mut subs = subscribed_terms.lock().await;
    for (term_id, (handle, _fc, flow_gate)) in subs.drain() {
        info!("Unsubscribing from terminal {} on WS disconnect", term_id);
        handle.abort();
        flow_gate.remove_subscriber();
    }
}
