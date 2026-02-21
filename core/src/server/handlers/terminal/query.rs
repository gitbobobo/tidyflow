use axum::extract::ws::WebSocket;
use tracing::info;

use crate::application::terminal as terminal_app;
use crate::server::context::HandlerContext;
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub async fn handle_query_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::TermList => {
            let (msg, terminal_count, remote_count) = terminal_app::term_list_message(
                &ctx.terminal_registry,
                &ctx.remote_sub_registry,
                &ctx.conn_meta,
            )
            .await;
            info!(
                total_terminals = terminal_count,
                remote_subscriber_count = remote_count,
                conn_id = %ctx.conn_meta.conn_id,
                is_remote = ctx.conn_meta.is_remote,
                "TermList response: {} terminals, {} remote subscribers",
                terminal_count,
                remote_count
            );

            send_message(socket, &msg).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
