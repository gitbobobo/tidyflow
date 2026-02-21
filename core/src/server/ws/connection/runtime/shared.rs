use std::collections::HashMap;
use std::sync::Arc;

use crate::server::context::TermSubscription;
use crate::server::watcher::{WatchEvent, WorkspaceWatcher};

use super::types::RuntimeSharedState;

pub(in crate::server::ws) fn build_runtime_shared_state(
    tx_watch: tokio::sync::mpsc::Sender<WatchEvent>,
) -> RuntimeSharedState {
    let subscribed_terms: Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>> =
        Arc::new(tokio::sync::Mutex::new(HashMap::new()));
    let watcher = Arc::new(tokio::sync::Mutex::new(WorkspaceWatcher::new(tx_watch)));
    RuntimeSharedState {
        subscribed_terms,
        watcher,
    }
}
