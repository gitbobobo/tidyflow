use std::sync::atomic::{AtomicU64, Ordering};

tokio::task_local! {
    static CURRENT_REQUEST_ID: Option<String>;
}

static SERVER_ENVELOPE_SEQ: AtomicU64 = AtomicU64::new(0);

pub(in crate::server::ws) async fn with_request_id<F, T>(request_id: Option<String>, fut: F) -> T
where
    F: std::future::Future<Output = T>,
{
    CURRENT_REQUEST_ID.scope(request_id, fut).await
}

pub(in crate::server::ws) fn current_request_id() -> Option<String> {
    CURRENT_REQUEST_ID.try_with(|id| id.clone()).ok().flatten()
}

pub(in crate::server::ws) fn next_server_envelope_seq() -> u64 {
    SERVER_ENVELOPE_SEQ.fetch_add(1, Ordering::Relaxed) + 1
}
