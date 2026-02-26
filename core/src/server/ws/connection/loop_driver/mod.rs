use axum::extract::ws::WebSocket;
use tracing::{debug, info, trace};

use crate::server::context::{ConnectionMeta, HandlerContext, SharedAppState};
use crate::server::protocol::ServerMessage;
use crate::server::watcher::{WatchEvent, WorkspaceWatcher};
use crate::server::ws::connection::shared_types::{RemoteTermRx, TaskBroadcastRx};

mod batch;
mod channels;
mod socket;

pub(in crate::server::ws) struct SocketDeps<'a> {
    pub socket: &'a mut WebSocket,
    pub conn_meta: &'a ConnectionMeta,
    pub handler_ctx: &'a HandlerContext,
    pub watcher: &'a std::sync::Arc<tokio::sync::Mutex<WorkspaceWatcher>>,
    pub app_state: &'a SharedAppState,
}

pub(in crate::server::ws) struct ChannelDeps<'a> {
    pub agg_rx: &'a mut tokio::sync::mpsc::Receiver<(String, Vec<u8>)>,
    pub rx_watch: &'a mut tokio::sync::mpsc::Receiver<WatchEvent>,
    pub cmd_output_rx: &'a mut tokio::sync::mpsc::Receiver<ServerMessage>,
    pub task_broadcast_rx: &'a mut TaskBroadcastRx,
    pub remote_term_rx: &'a mut Option<RemoteTermRx>,
}

pub(in crate::server::ws) struct LoopDeps<'a> {
    pub socket: SocketDeps<'a>,
    pub channels: ChannelDeps<'a>,
}

pub(super) enum LoopControl {
    Continue,
    Break,
}

pub(in crate::server::ws) async fn run_main_loop(deps: &mut LoopDeps<'_>) {
    let socket = &mut *deps.socket.socket;
    let conn_meta = deps.socket.conn_meta;
    let handler_ctx = deps.socket.handler_ctx;
    let watcher = deps.socket.watcher;
    let app_state = deps.socket.app_state;
    let agg_rx = &mut *deps.channels.agg_rx;
    let rx_watch = &mut *deps.channels.rx_watch;
    let cmd_output_rx = &mut *deps.channels.cmd_output_rx;
    let task_broadcast_rx = &mut *deps.channels.task_broadcast_rx;
    let remote_term_rx = &mut *deps.channels.remote_term_rx;

    info!("Entering main WebSocket loop");
    crate::util::flush_logs();
    let mut loop_count: u64 = 0;
    let mut last_log_time = std::time::Instant::now();

    loop {
        loop_count += 1;
        let tick_started = std::time::Instant::now();

        if loop_count == 1 {
            debug!("First loop iteration, about to call tokio::select!");
            crate::util::flush_logs();
        } else if last_log_time.elapsed().as_secs() >= 5 {
            trace!("Main loop still running, iteration {}", loop_count);
            crate::util::flush_logs();
            last_log_time = std::time::Instant::now();
        }

        tokio::select! {
            msg_result = socket.recv() => {
                if let LoopControl::Break = socket::handle_socket_recv_result(
                    msg_result,
                    socket,
                    handler_ctx,
                    watcher,
                    conn_meta,
                )
                .await {
                    break;
                }
            }

            Some((term_id, output)) = agg_rx.recv() => {
                let (batched, total) = batch::collect_batched_output(term_id, output, agg_rx);

                trace!("Batched PTY output: {} terminals, {} bytes total", batched.len(), total);

                if let LoopControl::Break = batch::forward_batched_output(socket, batched).await {
                    break;
                }
            }

            Some(watch_event) = rx_watch.recv() => {
                channels::handle_watch_channel_event(watch_event, socket, app_state, handler_ctx).await;
            }

            Some(msg) = cmd_output_rx.recv() => {
                channels::handle_cmd_output_event(msg, socket).await;
            }

            result = task_broadcast_rx.recv() => {
                crate::server::perf::record_task_broadcast_queue_depth(task_broadcast_rx.len() as u64);
                channels::handle_task_broadcast_channel_event(result, socket, conn_meta).await;
            }

            result = channels::recv_remote_term_event(remote_term_rx) => {
                channels::handle_remote_term_channel_event(result, socket, conn_meta).await;
            }

            else => {
                debug!("All channels closed, exiting");
                break;
            }
        }

        crate::server::perf::record_ws_outbound_loop_tick(tick_started.elapsed().as_millis() as u64);
    }
}
