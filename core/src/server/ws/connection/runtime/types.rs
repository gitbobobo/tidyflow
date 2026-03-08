use std::collections::HashMap;
use std::sync::Arc;

use crate::server::context::{HandlerContext, SharedAppState, TermSubscription};
use crate::server::protocol::ServerMessage;
use crate::server::watcher::{WatchEvent, WorkspaceWatcher};
use crate::server::ws::connection::shared_types::{RemoteTermRx, TaskBroadcastRx};

pub(in crate::server::ws) struct RuntimeChannels {
    pub(in crate::server::ws) agg_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    pub(in crate::server::ws) agg_rx: tokio::sync::mpsc::Receiver<(String, Vec<u8>)>,
    pub(in crate::server::ws) tx_watch: tokio::sync::mpsc::Sender<WatchEvent>,
    pub(in crate::server::ws) rx_watch: tokio::sync::mpsc::Receiver<WatchEvent>,
    pub(in crate::server::ws) cmd_output_tx: tokio::sync::mpsc::Sender<ServerMessage>,
    pub(in crate::server::ws) cmd_output_rx: tokio::sync::mpsc::Receiver<ServerMessage>,
}

pub(in crate::server::ws) struct RuntimeSharedState {
    pub(in crate::server::ws) subscribed_terms:
        Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
    pub(in crate::server::ws) watcher: Arc<tokio::sync::Mutex<WorkspaceWatcher>>,
}

/// 每个 WebSocket 连接独占一个 SocketRuntime 实例。
/// 连接关闭时，cleanup_on_disconnect 按 conn_id 回收 subscribed_terms、
/// AI session subscriptions 和 remote subscriptions，确保旧连接的订阅
/// 不会泄漏到新连接，也不会在重连后产生重复事件。
pub(in crate::server::ws) struct SocketRuntime {
    pub app_state: SharedAppState,
    pub subscribed_terms: Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
    pub watcher: Arc<tokio::sync::Mutex<WorkspaceWatcher>>,
    pub handler_ctx: HandlerContext,
    pub agg_rx: tokio::sync::mpsc::Receiver<(String, Vec<u8>)>,
    pub rx_watch: tokio::sync::mpsc::Receiver<WatchEvent>,
    pub cmd_output_rx: tokio::sync::mpsc::Receiver<ServerMessage>,
    pub task_broadcast_rx: TaskBroadcastRx,
    pub remote_term_rx: Option<RemoteTermRx>,
}
