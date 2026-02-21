use axum::extract::ws::WebSocket;

use crate::application::settings::get_client_settings_message;
use crate::server::context::SharedAppState;
use crate::server::protocol::ClientMessage;
use crate::server::ws::send_message;

pub async fn handle_query_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::GetClientSettings => {
            let msg = get_client_settings_message(app_state).await;
            send_message(socket, &msg).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
