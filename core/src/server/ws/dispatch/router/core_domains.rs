use axum::extract::ws::WebSocket;

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub(super) async fn handle_system_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::Ping => {
            send_message(socket, &ServerMessage::Pong).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

pub(super) async fn handle_terminal_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    crate::server::handlers::terminal::handle_terminal_message(client_msg, socket, ctx).await
}

pub(super) async fn handle_git_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    crate::server::handlers::git::handle_git_message(client_msg, socket, &ctx.app_state, ctx).await
}

pub(super) async fn handle_project_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    crate::server::handlers::project::handle_project_message(client_msg, socket, ctx).await
}

pub(super) async fn handle_settings_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    crate::server::handlers::settings::handle_settings_message(client_msg, socket, ctx).await
}

pub(super) fn handle_log_domain(client_msg: &ClientMessage) -> Result<bool, String> {
    crate::server::handlers::log::handle_log_message(client_msg)
}

pub(super) async fn handle_ai_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    crate::server::handlers::ai::handle_ai_message(
        client_msg,
        socket,
        &ctx.app_state,
        &ctx.ai_state,
        &ctx.cmd_output_tx,
        &ctx.task_broadcast_tx,
        &ctx.conn_meta.conn_id,
    )
    .await
}

pub(super) async fn handle_evidence_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    crate::server::handlers::evidence::handle_evidence_message(client_msg, socket, ctx).await
}

pub(super) async fn handle_evolution_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    crate::server::handlers::evolution::handle_evolution_message(client_msg, socket, ctx).await
}
