use axum::extract::ws::WebSocket;

use crate::server::context::SharedAppState;
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

mod mutate;
mod query;
mod read_write;

/// 处理文件相关的客户端消息
pub async fn handle_file_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    dispatch_handlers!(
        query::handle_query_message(client_msg, socket, app_state),
        read_write::handle_read_write_message(client_msg, socket, app_state),
        mutate::handle_mutate_message(client_msg, socket, app_state),
    );

    Ok(false)
}
