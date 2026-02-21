use axum::extract::ws::WebSocket;

use crate::server::context::{HandlerContext, SharedAppState};
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

use super::{branch_commit, history, integration, stage_ops, status_diff};

/// 标准 Git 消息路由（按既有顺序短路匹配）。
pub async fn handle_standard_git_routes(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    dispatch_handlers!(
        status_diff::handle_message(client_msg, socket, app_state),
        stage_ops::handle_message(client_msg, socket, app_state),
        branch_commit::handle_message(client_msg, socket, app_state, ctx),
        integration::handle_message(client_msg, socket, app_state, ctx),
        history::handle_message(client_msg, socket, app_state),
    );

    Ok(false)
}
