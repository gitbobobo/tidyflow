//! 健康域消息处理器（WI-002 / WI-003）
//!
//! 处理客户端健康上报（`health_report`）和修复动作请求（`health_repair`）。
//! WI-002: 新增门禁裁决查询支持。

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
            client_performance_report,
        } => {
            // 将客户端上报的 incidents 注入健康注册表
            let registry = crate::server::health::global();
            if let Ok(mut reg) = registry.try_write() {
                reg.ingest_client_report(client_session_id, incidents.clone());
            }
            // 将客户端性能上报写入全局性能注册表（WI-001）
            if let Some(report) = client_performance_report {
                crate::server::perf::record_client_performance_report(report.clone());
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

/// 查询指定 project/workspace/cycle_id 的门禁裁决
///
/// 供 HTTP API 和 Evolution 内部调用，裁决结果按维度隔离。
pub fn query_gate_decision(
    project: &str,
    workspace: &str,
    cycle_id: &str,
    retry_count: u32,
) -> crate::server::protocol::health::GateDecision {
    crate::server::health::evaluate_gate_decision(project, workspace, cycle_id, retry_count)
}

/// 查询指定工作区的智能演化分析摘要
///
/// 聚合门禁裁决、观测聚合、预测异常和调度建议，
/// 输出按 `(project, workspace, cycle_id)` 隔离的统一分析结果。
pub fn query_analysis_summary(
    project: &str,
    workspace: &str,
    cycle_id: &str,
    retry_count: u32,
) -> crate::server::protocol::health::EvolutionAnalysisSummary {
    let gate =
        crate::server::health::evaluate_gate_decision(project, workspace, cycle_id, retry_count);
    let aggregates =
        crate::server::perf::build_observation_aggregates(&std::collections::HashMap::new());
    let anomalies = crate::server::perf::build_predictive_anomalies(&aggregates);
    let recommendations = crate::server::perf::build_scheduling_recommendations(&aggregates, 4, 0);
    crate::server::perf::build_analysis_summary(
        project,
        workspace,
        cycle_id,
        Some(&gate),
        &aggregates,
        &anomalies,
        &recommendations,
    )
}
