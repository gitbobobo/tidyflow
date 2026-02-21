use tracing::info;

use crate::server::context::ConnectionMeta;
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;

pub(in crate::server::ws) async fn cleanup_remote_subscriptions(
    conn_meta: &ConnectionMeta,
    remote_sub_registry: &SharedRemoteSubRegistry,
) {
    if !conn_meta.is_remote {
        return;
    }

    if conn_meta.token_id.is_some() {
        info!(
            conn_id = %conn_meta.conn_id,
            subscriber_id = %conn_meta.remote_subscriber_id(),
            "Remote WebSocket disconnected; keeping remote terminal subscriptions"
        );
        return;
    }

    let mut reg = remote_sub_registry.lock().await;
    reg.unsubscribe_all(&conn_meta.conn_id);
}
