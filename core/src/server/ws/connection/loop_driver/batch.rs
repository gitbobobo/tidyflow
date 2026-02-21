use std::collections::HashMap;

use axum::extract::ws::WebSocket;
use tracing::error;

use crate::server::protocol::ServerMessage;

use super::LoopControl;

const MAX_BATCH_SIZE: usize = 256 * 1024;

pub(super) fn collect_batched_output(
    first_term_id: String,
    first_output: Vec<u8>,
    agg_rx: &mut tokio::sync::mpsc::Receiver<(String, Vec<u8>)>,
) -> (HashMap<String, Vec<u8>>, usize) {
    let mut batched: HashMap<String, Vec<u8>> = HashMap::new();
    let mut total = first_output.len();
    batched.entry(first_term_id).or_default().extend(first_output);

    while total < MAX_BATCH_SIZE {
        match agg_rx.try_recv() {
            Ok((id, data)) => {
                total += data.len();
                batched.entry(id).or_default().extend(data);
            }
            Err(_) => break,
        }
    }
    (batched, total)
}

pub(super) async fn forward_batched_output(
    socket: &mut WebSocket,
    batched: HashMap<String, Vec<u8>>,
) -> LoopControl {
    for (id, data) in batched {
        let msg = ServerMessage::Output {
            data,
            term_id: Some(id),
        };
        if let Err(e) = crate::server::ws::send_message(socket, &msg).await {
            error!("Failed to send output message: {}", e);
            return LoopControl::Break;
        }
    }
    LoopControl::Continue
}
