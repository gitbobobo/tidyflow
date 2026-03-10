use std::collections::HashMap;

use tracing::error;

use crate::server::protocol::{terminal::TerminalOutputBatchItem, ServerMessage};
use crate::server::ws::OutboundTx as WebSocket;

use super::LoopControl;

const MAX_BATCH_SIZE: usize = 256 * 1024;

pub(super) fn collect_batched_output(
    first_term_id: String,
    first_output: Vec<u8>,
    agg_rx: &mut tokio::sync::mpsc::Receiver<(String, Vec<u8>)>,
) -> (HashMap<String, Vec<u8>>, usize) {
    let mut batched: HashMap<String, Vec<u8>> = HashMap::new();
    let mut total = first_output.len();
    batched
        .entry(first_term_id)
        .or_default()
        .extend(first_output);

    let mut flush_reason = "channel_drain";
    while total < MAX_BATCH_SIZE {
        match agg_rx.try_recv() {
            Ok((id, data)) => {
                total += data.len();
                batched.entry(id).or_default().extend(data);
            }
            Err(_) => break,
        }
    }
    if total >= MAX_BATCH_SIZE {
        flush_reason = "size_limit";
    }
    crate::server::perf::record_ws_batch_flush(total, flush_reason);
    (batched, total)
}

pub(super) async fn forward_batched_output(
    socket: &WebSocket,
    batched: HashMap<String, Vec<u8>>,
) -> LoopControl {
    let items = batched
        .into_iter()
        .map(|(term_id, data)| TerminalOutputBatchItem { term_id, data })
        .collect::<Vec<_>>();
    let msg = ServerMessage::OutputBatch { items };
    if let Err(e) = crate::server::ws::send_message(socket, &msg).await {
        error!("Failed to send output batch message: {}", e);
        return LoopControl::Break;
    }
    LoopControl::Continue
}
