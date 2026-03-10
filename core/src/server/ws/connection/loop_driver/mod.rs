use tracing::{debug, info, trace};

use crate::server::context::{ConnectionMeta, HandlerContext, SharedAppState};
use crate::server::protocol::ServerMessage;
use crate::server::watcher::WatchEvent;
use crate::server::ws::connection::shared_types::{RemoteTermRx, TaskBroadcastRx};
use crate::server::ws::OutboundTx;

mod batch;
mod channels;
pub(super) mod socket;

pub(in crate::server::ws) struct EventLoopDeps {
    pub conn_meta: ConnectionMeta,
    pub handler_ctx: HandlerContext,
    pub app_state: SharedAppState,
    pub outbound_tx: OutboundTx,
    pub agg_rx: tokio::sync::mpsc::Receiver<(String, Vec<u8>)>,
    pub rx_watch: tokio::sync::mpsc::Receiver<WatchEvent>,
    pub cmd_output_rx: tokio::sync::mpsc::Receiver<ServerMessage>,
    pub task_broadcast_rx: TaskBroadcastRx,
    pub remote_term_rx: Option<RemoteTermRx>,
}

pub(super) enum LoopControl {
    Continue,
    Break,
}

pub(in crate::server::ws) async fn run_outbound_event_loop(mut deps: EventLoopDeps) {
    info!("Entering outbound event loop");
    crate::util::flush_logs();
    let mut loop_count: u64 = 0;
    let mut last_log_time = std::time::Instant::now();

    loop {
        loop_count += 1;
        let tick_started = std::time::Instant::now();
        let select_started = std::time::Instant::now();

        if loop_count == 1 {
            debug!("First outbound loop iteration, about to call tokio::select!");
            crate::util::flush_logs();
        } else if last_log_time.elapsed().as_secs() >= 5 {
            trace!("Outbound loop still running, iteration {}", loop_count);
            crate::util::flush_logs();
            last_log_time = std::time::Instant::now();
        }

        let (select_wait_ms, handle_ms, should_break) = tokio::select! {
            Some((term_id, output)) = deps.agg_rx.recv() => {
                let select_wait_ms = select_started.elapsed().as_millis() as u64;
                let handle_started = std::time::Instant::now();
                let (batched, total) = batch::collect_batched_output(term_id, output, &mut deps.agg_rx);
                let mut should_break = false;

                trace!("Batched PTY output: {} terminals, {} bytes total", batched.len(), total);

                if let LoopControl::Break = batch::forward_batched_output(&deps.outbound_tx, batched).await {
                    should_break = true;
                }
                let handle_ms = handle_started.elapsed().as_millis() as u64;
                (select_wait_ms, handle_ms, should_break)
            }

            Some(watch_event) = deps.rx_watch.recv() => {
                let select_wait_ms = select_started.elapsed().as_millis() as u64;
                let handle_started = std::time::Instant::now();
                channels::handle_watch_channel_event(
                    watch_event,
                    &deps.outbound_tx,
                    &deps.app_state,
                    &deps.handler_ctx
                ).await;
                let handle_ms = handle_started.elapsed().as_millis() as u64;
                (select_wait_ms, handle_ms, false)
            }

            Some(msg) = deps.cmd_output_rx.recv() => {
                let select_wait_ms = select_started.elapsed().as_millis() as u64;
                let handle_started = std::time::Instant::now();
                channels::handle_cmd_output_event(msg, &deps.outbound_tx).await;
                let handle_ms = handle_started.elapsed().as_millis() as u64;
                (select_wait_ms, handle_ms, false)
            }

            result = deps.task_broadcast_rx.recv() => {
                let select_wait_ms = select_started.elapsed().as_millis() as u64;
                let handle_started = std::time::Instant::now();
                crate::server::perf::record_task_broadcast_queue_depth(deps.task_broadcast_rx.len() as u64);
                channels::handle_task_broadcast_channel_event(result, &deps.outbound_tx, &deps.conn_meta).await;
                let handle_ms = handle_started.elapsed().as_millis() as u64;
                (select_wait_ms, handle_ms, false)
            }

            result = channels::recv_remote_term_event(&mut deps.remote_term_rx) => {
                let select_wait_ms = select_started.elapsed().as_millis() as u64;
                let handle_started = std::time::Instant::now();
                channels::handle_remote_term_channel_event(result, &deps.outbound_tx, &deps.conn_meta).await;
                let handle_ms = handle_started.elapsed().as_millis() as u64;
                (select_wait_ms, handle_ms, false)
            }

            else => {
                let select_wait_ms = select_started.elapsed().as_millis() as u64;
                debug!("All outbound channels closed, exiting");
                (select_wait_ms, 0, true)
            }
        };

        crate::server::perf::record_ws_outbound_select_wait(select_wait_ms);
        crate::server::perf::record_ws_outbound_handle(handle_ms);
        crate::server::perf::record_ws_outbound_loop_tick(tick_started.elapsed().as_millis() as u64);
        if should_break {
            break;
        }
    }
}
