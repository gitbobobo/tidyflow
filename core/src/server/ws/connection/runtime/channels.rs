use crate::server::protocol::ServerMessage;
use crate::server::watcher::WatchEvent;

use super::types::RuntimeChannels;

pub(in crate::server::ws) fn build_runtime_channels() -> RuntimeChannels {
    let (agg_tx, agg_rx) = tokio::sync::mpsc::channel::<(String, Vec<u8>)>(256);
    let (tx_watch, rx_watch) = tokio::sync::mpsc::channel::<WatchEvent>(100);
    let (cmd_output_tx, cmd_output_rx) = tokio::sync::mpsc::channel::<ServerMessage>(256);
    RuntimeChannels {
        agg_tx,
        agg_rx,
        tx_watch,
        rx_watch,
        cmd_output_tx,
        cmd_output_rx,
    }
}
