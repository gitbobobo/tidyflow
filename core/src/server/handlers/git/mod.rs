use crate::server::ws::OutboundTx as WebSocket;

use crate::server::context::{HandlerContext, SharedAppState};
use crate::server::protocol::ClientMessage;

pub(crate) mod branch_commit;
mod history;
mod integration;
pub(crate) mod query;
mod route;
mod sequencer;
mod stage_ops;
mod stash;
mod status_diff;

/// 处理 Git 相关的客户端消息
pub async fn handle_git_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
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

    route::handle_standard_git_routes(client_msg, socket, app_state, ctx).await
}
