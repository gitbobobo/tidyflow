use axum::extract::ws::WebSocket;

use crate::server::context::SharedAppState;
use crate::server::protocol::ClientMessage;

mod branch_commit;
mod history;
mod integration;
mod stage_ops;
mod status_diff;

/// 处理 Git 相关的客户端消息
pub async fn handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    if status_diff::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if stage_ops::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if branch_commit::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if integration::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if history::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    Ok(false)
}
