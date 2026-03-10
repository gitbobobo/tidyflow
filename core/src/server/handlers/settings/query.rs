use crate::server::ws::OutboundTx as WebSocket;

use crate::application::settings::get_client_settings_message;
use crate::server::context::HandlerContext;
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub async fn handle_query_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::GetClientSettings => {
            let msg = get_client_settings_message(&ctx.app_state).await;
            send_message(socket, &msg).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
