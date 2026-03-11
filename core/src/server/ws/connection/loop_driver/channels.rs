use crate::server::context::{ConnectionMeta, HandlerContext, SharedAppState};
use crate::server::protocol::ServerMessage;
use crate::server::watcher::WatchEvent;
use crate::server::ws::connection::shared_types::{
    RemoteTermRecvResult, RemoteTermRx, TaskBroadcastRecvResult,
};
use crate::server::ws::OutboundTx as WebSocket;

pub(super) async fn handle_watch_channel_event(
    watch_event: WatchEvent,
    socket: &WebSocket,
    app_state: &SharedAppState,
    handler_ctx: &HandlerContext,
) {
    super::super::events::handle_watch_event(watch_event, socket, app_state, handler_ctx).await;
}

pub(super) async fn handle_cmd_output_event(msg: ServerMessage, socket: &WebSocket) {
    super::super::events::forward_command_output(msg, socket).await;
}

pub(super) async fn handle_task_broadcast_channel_event(
    result: TaskBroadcastRecvResult,
    socket: &WebSocket,
    conn_meta: &ConnectionMeta,
) {
    super::super::events::handle_task_broadcast_event(result, socket, conn_meta).await;
}

pub(super) async fn recv_remote_term_event(
    remote_term_rx: &mut Option<RemoteTermRx>,
) -> RemoteTermRecvResult {
    match remote_term_rx.as_mut() {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}

pub(super) async fn handle_remote_term_channel_event(
    result: RemoteTermRecvResult,
    socket: &WebSocket,
    conn_meta: &ConnectionMeta,
) {
    super::super::events::handle_remote_term_event(result, socket, conn_meta).await;
}
