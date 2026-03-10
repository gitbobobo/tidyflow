use crate::server::ws::OutboundTx as WebSocket;
use tracing::debug;

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::{ack_terminal_output, send_message};

pub async fn handle_io_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::Input { data, term_id } => {
            debug!(
                "Input received: term_id={:?}, data_len={}",
                term_id,
                data.len()
            );

            let mut reg = ctx.terminal_registry.lock().await;
            let resolved_id = reg.resolve_term_id(term_id.as_deref());
            debug!(
                "Resolved term_id: {:?}, available_terms: {:?}",
                resolved_id,
                reg.term_ids()
            );

            if let Some(id) = resolved_id {
                debug!("Writing input to PTY: term_id={}", id);
                reg.write_input(&id, data)
                    .map_err(|e| format!("Write error: {}", e))?;
                debug!("Input written successfully");
            } else if term_id.is_some() {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!("Terminal '{}' not found", term_id.as_ref().unwrap()),
                        project: None,
                        workspace: None,
                        session_id: None,
                        cycle_id: None,
                    },
                )
                .await?;
            } else {
                debug!("No term_id provided and no default terminal");
            }
            Ok(true)
        }
        ClientMessage::Resize {
            cols,
            rows,
            term_id,
        } => {
            let reg = ctx.terminal_registry.lock().await;
            let resolved_id = reg.resolve_term_id(term_id.as_deref());

            if let Some(id) = resolved_id {
                reg.resize(&id, *cols, *rows)
                    .map_err(|e| format!("Resize error: {}", e))?;
            }
            Ok(true)
        }
        ClientMessage::TermOutputAck { term_id, bytes } => {
            ack_terminal_output(term_id, *bytes, &ctx.subscribed_terms).await;
            Ok(true)
        }
        _ => Ok(false),
    }
}
