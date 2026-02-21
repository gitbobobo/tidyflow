use axum::extract::ws::WebSocket;

use crate::server::context::HandlerContext;
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

mod clipboard;
mod io;
mod lifecycle;
mod query;

/// 处理终端相关的客户端消息
///
/// 入口签名保持不变，按能力域顺序分发。
pub async fn handle_terminal_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    dispatch_handlers!(
        io::handle_io_message(client_msg, socket, ctx),
        lifecycle::handle_lifecycle_message(client_msg, socket, ctx),
        query::handle_query_message(client_msg, socket, ctx),
        clipboard::handle_clipboard_message(client_msg, socket, ctx),
    );

    Ok(false)
}
