use axum::extract::ws::WebSocket;

use crate::server::context::HandlerContext;
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

mod admin;
mod query;
mod runtime;

/// 处理项目和工作空间相关的客户端消息
///
/// 入口签名保持不变；按能力域顺序分发到子模块。
pub async fn handle_project_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    dispatch_handlers!(
        query::handle_query_message(client_msg, socket, ctx),
        admin::handle_admin_message(client_msg, socket, ctx),
        runtime::handle_runtime_message(client_msg, socket, ctx),
    );

    Ok(false)
}
