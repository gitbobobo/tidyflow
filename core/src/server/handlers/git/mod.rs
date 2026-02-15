use axum::extract::ws::WebSocket;

use crate::server::context::{HandlerContext, SharedAppState};
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
    ctx: &HandlerContext,
) -> Result<bool, String> {
    // v1.37: AI 任务取消（优先匹配，避免被其他 handler 吞掉）
    if let ClientMessage::CancelAiTask {
        project,
        workspace,
        operation_type,
    } = client_msg
    {
        return branch_commit::handle_cancel_ai_task(
            project,
            workspace,
            operation_type,
            socket,
            ctx,
        )
        .await;
    }

    if status_diff::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if stage_ops::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if branch_commit::try_handle_git_message(client_msg, socket, app_state, ctx).await? {
        return Ok(true);
    }

    if integration::try_handle_git_message(client_msg, socket, app_state, ctx).await? {
        return Ok(true);
    }

    if history::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    Ok(false)
}
