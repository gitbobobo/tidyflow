//! 健康域消息处理器（WI-002 / WI-003）
//!
//! 处理客户端健康上报（`health_report`）和修复动作请求（`health_repair`）。

use crate::server::ws::OutboundTx as WebSocket;

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

/// 处理健康域消息
///
/// 返回 `Ok(true)` 表示消息已处理，`Ok(false)` 表示不属于本处理器。
pub async fn handle_health_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::HealthReport {
            client_session_id,
            connectivity: _,
            incidents,
            context: _,
            reported_at: _,
        } => {
            // 将客户端上报的 incidents 注入健康注册表
            let registry = crate::server::health::global();
            if let Ok(mut reg) = registry.try_write() {
                reg.ingest_client_report(client_session_id, incidents.clone());
            }
            Ok(true)
        }

        ClientMessage::HealthRepair { request } => {
            // 执行修复动作并推送审计结果
            let audit = crate::server::health::execute_repair(
                request.clone(),
                "client_request",
                ctx.app_state.clone(),
            )
            .await;
            send_message(socket, &ServerMessage::HealthRepairResult { audit }).await?;
            Ok(true)
        }

        _ => Ok(false),
    }
}
