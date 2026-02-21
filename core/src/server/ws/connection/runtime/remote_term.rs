use crate::server::context::ConnectionMeta;
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::ws::connection::shared_types::RemoteTermRx;

pub(in crate::server::ws) async fn build_remote_term_rx(
    conn_meta: &ConnectionMeta,
    remote_sub_registry: &SharedRemoteSubRegistry,
) -> Option<RemoteTermRx> {
    if !conn_meta.is_remote {
        Some(remote_sub_registry.lock().await.subscribe_events())
    } else {
        None
    }
}
