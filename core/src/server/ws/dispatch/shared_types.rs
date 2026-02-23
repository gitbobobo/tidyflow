use tokio::sync::Mutex;

use crate::server::watcher::WorkspaceWatcher;

pub(in crate::server::ws::dispatch) type DispatchWatcher = std::sync::Arc<Mutex<WorkspaceWatcher>>;
