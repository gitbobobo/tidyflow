use std::collections::{HashMap, HashSet, VecDeque};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::server::protocol::{
    EvolutionSchedulerInfo, EvolutionSessionExecutionEntry, EvolutionStageProfileInfo,
    EvolutionWorkspaceItem,
};

// ──────────────────────────────────────────────────
// Evolution 恢复模型（Core 权威源）
// ──────────────────────────────────────────────────

/// 失败诊断码：单一权威分类枚举
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum EvolutionFailureDiagnosisCode {
    /// API 速率限制（429 等）
    RateLimit,
    /// 瞬态会话错误（网络超时、连接重置等）
    TransientSession,
    /// 产物契约违规（schema 版本不匹配、必需字段缺失）
    ArtifactContractViolation,
    /// 阶段执行超时
    StageTimeout,
    /// 门禁阻断（verify 重试耗尽、gate decision blocked）
    GateBlocked,
    /// 需要人工干预的阻断
    HumanBlocker,
    /// 未知系统错误
    UnknownSystem,
}

impl EvolutionFailureDiagnosisCode {
    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            Self::RateLimit => "rate_limit",
            Self::TransientSession => "transient_session",
            Self::ArtifactContractViolation => "artifact_contract_violation",
            Self::StageTimeout => "stage_timeout",
            Self::GateBlocked => "gate_blocked",
            Self::HumanBlocker => "human_blocker",
            Self::UnknownSystem => "unknown_system",
        }
    }
}

/// 恢复策略
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum EvolutionRecoveryStrategy {
    /// 等待速率限制解除
    WaitRateLimit,
    /// 重试当前阶段（指数退避）
    RetryStage,
    /// 工作区降级冷却
    DeferWorkspace,
    /// 无自动恢复策略
    None,
}

impl EvolutionRecoveryStrategy {
    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            Self::WaitRateLimit => "wait_rate_limit",
            Self::RetryStage => "retry_stage",
            Self::DeferWorkspace => "defer_workspace",
            Self::None => "none",
        }
    }
}

/// 恢复阶段
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum EvolutionRecoveryPhase {
    /// 正在自动恢复中
    Recovering,
    /// 已降级，冷却期内
    Degraded,
    /// 恢复失败，需要手动干预或系统观察
    Failed,
}

impl EvolutionRecoveryPhase {
    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            Self::Recovering => "recovering",
            Self::Degraded => "degraded",
            Self::Failed => "failed",
        }
    }
}

/// Core 权威恢复状态对象
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct EvolutionRecoveryInfo {
    /// 当前恢复阶段
    pub(crate) phase: EvolutionRecoveryPhase,
    /// 执行的恢复策略
    pub(crate) strategy: EvolutionRecoveryStrategy,
    /// 失败诊断码
    pub(crate) diagnosis_code: EvolutionFailureDiagnosisCode,
    /// 诊断摘要（人类可读）
    pub(crate) diagnosis_summary: String,
    /// 预计恢复时间（RFC3339），用于 wait_rate_limit / retry_stage
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) resume_at: Option<String>,
    /// 当前重试次数
    pub(crate) retry_count: u32,
    /// 重试上限
    pub(crate) retry_limit: u32,
    /// 降级冷却截止时间（RFC3339），用于 defer_workspace
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) degraded_until: Option<String>,
    /// 最后更新时间（RFC3339）
    pub(crate) updated_at: String,
}

impl EvolutionRecoveryInfo {
    /// 当前恢复是否仍在冷却/等待中
    pub(crate) fn is_active_cooldown(&self) -> bool {
        let now = Utc::now();
        if let Some(ref resume_at) = self.resume_at {
            if let Ok(t) = DateTime::parse_from_rfc3339(resume_at) {
                if t.with_timezone(&Utc) > now {
                    return true;
                }
            }
        }
        if let Some(ref degraded_until) = self.degraded_until {
            if let Ok(t) = DateTime::parse_from_rfc3339(degraded_until) {
                if t.with_timezone(&Utc) > now {
                    return true;
                }
            }
        }
        false
    }

    /// 转换为协议 DTO
    pub(crate) fn to_dto(&self) -> crate::server::protocol::EvolutionRecoveryDTO {
        crate::server::protocol::EvolutionRecoveryDTO {
            phase: self.phase.as_str().to_string(),
            strategy: self.strategy.as_str().to_string(),
            diagnosis_code: self.diagnosis_code.as_str().to_string(),
            diagnosis_summary: Some(self.diagnosis_summary.clone()),
            resume_at: self.resume_at.clone(),
            retry_count: self.retry_count,
            retry_limit: self.retry_limit,
            degraded_until: self.degraded_until.clone(),
            updated_at: self.updated_at.clone(),
        }
    }
}

/// 失败分类器：单一权威实现，根据错误文本判定诊断码
pub(crate) fn classify_failure(error_text: &str) -> EvolutionFailureDiagnosisCode {
    // 优先检查人工阻断
    if error_text.starts_with("evo_human_blocking_required") {
        return EvolutionFailureDiagnosisCode::HumanBlocker;
    }

    // 速率限制
    if is_rate_limit_error(error_text) {
        return EvolutionFailureDiagnosisCode::RateLimit;
    }

    // 阶段超时
    if error_text.contains("evo_stage_timeout") {
        return EvolutionFailureDiagnosisCode::StageTimeout;
    }

    // 产物契约违规
    if error_text.contains("evo_stage_output_invalid")
        || error_text.contains("evo_llm_output_unparseable")
        || error_text.contains("evo_boundary_empty_project")
        || error_text.contains("evo_boundary_workspace_missing")
        || error_text.contains("schema_version")
    {
        return EvolutionFailureDiagnosisCode::ArtifactContractViolation;
    }

    // 门禁阻断
    if error_text.contains("evo_gate_decision_blocked")
        || error_text.contains("verify_exhausted")
        || error_text.contains("evo_retry_exhausted")
        || error_text.contains("evo_round_limit_exceeded")
    {
        return EvolutionFailureDiagnosisCode::GateBlocked;
    }

    // 瞬态会话错误
    if is_transient_session_error(error_text) {
        return EvolutionFailureDiagnosisCode::TransientSession;
    }

    EvolutionFailureDiagnosisCode::UnknownSystem
}

/// 速率限制错误判定（从 manager_worker 收敛）
fn is_rate_limit_error(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    (lower.contains("429")
        && (lower.contains("rate limit")
            || lower.contains("too many requests")
            || lower.contains("quota")
            || lower.contains("reset")
            || lower.contains("retry")))
        || text.contains("限额")
        || text.contains("频率限制")
        || text.contains("请求过多")
        || text.contains("速率限制")
}

/// 瞬态会话错误判定（从 manager_worker 收敛）
fn is_transient_session_error(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    // 排除确定性失败
    if lower.contains("context window")
        || lower.contains("evo_stage_output_invalid")
        || lower.contains("evo_llm_output_unparseable")
        || lower.contains("evo_boundary_empty_project")
        || lower.contains("evo_boundary_workspace_missing")
    {
        return false;
    }
    lower.contains("stage stream error: unknown error")
        || lower.contains("stage stream timeout")
        || lower.contains("stdout closed")
        || lower.contains("request timeout")
        || lower.contains("connection reset")
        || lower.contains("connection aborted")
        || lower.contains("broken pipe")
        || lower.contains("transport error")
        || lower.contains("network error")
        || lower.contains("service unavailable")
        || lower.contains("pre-flight check")
        || lower.contains("connection refused")
        || lower.contains("agent not available")
        || lower.contains("evo_boundary_cycle_dir_missing")
        || text.contains("连接超时")
        || text.contains("连接重置")
        || text.contains("连接中断")
        || text.contains("网络错误")
        || text.contains("服务不可用")
        || text.contains("AI服务不可用")
        || text.contains("无法连接")
}

pub(super) struct EvolutionState {
    pub(super) activation_state: String,
    pub(super) max_parallel_workspaces: u32,
    pub(super) seq_by_workspace: HashMap<String, u64>,
    pub(super) workspaces: HashMap<String, WorkspaceRunState>,
    pub(super) project_coordination: HashMap<String, ProjectCoordinationState>,
    pub(super) adaptive: AdaptiveSchedulingState,
}

#[derive(Clone)]
pub(super) struct WorkspaceRunState {
    pub(super) project: String,
    pub(super) workspace: String,
    pub(super) workspace_root: String,
    pub(super) priority: i32,
    pub(super) status: String,
    pub(super) cycle_id: String,
    pub(super) cycle_title: Option<String>,
    pub(super) current_stage: String,
    pub(super) global_loop_round: u32,
    pub(super) loop_round_limit: u32,
    pub(super) verify_iteration: u32,
    pub(super) verify_iteration_limit: u32,
    pub(super) backlog_contract_version: u32,
    pub(super) created_at: String,
    pub(super) stop_requested: bool,
    pub(super) terminal_reason_code: Option<String>,
    pub(super) terminal_error_message: Option<String>,
    pub(super) rate_limit_resume_at: Option<String>,
    pub(super) rate_limit_error_message: Option<String>,
    /// Core 权威恢复状态对象（自愈闭环）
    pub(super) recovery: Option<EvolutionRecoveryInfo>,
    pub(super) stage_profiles: Vec<EvolutionStageProfileInfo>,
    pub(super) stage_statuses: HashMap<String, String>,
    pub(super) stage_sessions: HashMap<String, StageSession>,
    pub(super) stage_session_history: HashMap<String, Vec<StageSession>>,
    pub(super) stage_tool_call_counts: HashMap<String, u32>,
    pub(super) stage_seen_tool_calls: HashMap<String, HashSet<String>>,
    /// 各阶段可重试错误的重试次数（用于指数退避计算）
    pub(super) stage_retry_counts: HashMap<String, u32>,
    /// 会话级执行轨迹（同阶段可多次会话）
    pub(super) session_executions: Vec<EvolutionSessionExecutionEntry>,
    /// 各代理开始运行的 RFC3339 时间戳
    pub(super) stage_started_ats: HashMap<String, String>,
    /// 各代理运行耗时（毫秒），仅在完成后填充
    pub(super) stage_duration_ms: HashMap<String, u64>,
    /// 当前协作等待/占用状态，仅用于编排可视化与等待逻辑
    pub(super) coordination_state: Option<String>,
    /// 协作状态所属作用域：本地项目或节点网络
    pub(super) coordination_scope: Option<String>,
    /// 当前协作等待原因
    pub(super) coordination_reason: Option<String>,
    /// 造成当前等待或占用的对端节点 ID
    pub(super) coordination_peer_node_id: Option<String>,
    /// 造成当前等待或占用的对端节点名称
    pub(super) coordination_peer_node_name: Option<String>,
    /// 造成当前等待或占用的对端项目
    pub(super) coordination_peer_project: Option<String>,
    /// 造成当前等待或占用的对端工作区
    pub(super) coordination_peer_workspace: Option<String>,
    /// 当前工作区在项目级 integration FIFO 队列中的位置（从 0 开始）
    pub(super) coordination_queue_index: Option<u32>,
}

#[derive(Clone)]
pub(super) struct StageSession {
    pub(super) ai_tool: String,
    pub(super) session_id: String,
}

#[derive(Clone, Debug, Default)]
pub(super) struct ProjectCoordinationState {
    pub(super) direction_lock_owner: Option<String>,
    pub(super) integration_lock_owner: Option<String>,
    pub(super) pending_integration_queue: VecDeque<String>,
    pub(super) active_direction_summaries: HashMap<String, String>,
}

#[derive(Clone)]
pub(super) struct StartWorkspaceReq {
    pub(super) project: String,
    pub(super) workspace: String,
    pub(super) priority: i32,
    pub(super) loop_round_limit: u32,
    pub(super) stage_profiles: Vec<EvolutionStageProfileInfo>,
}

pub(super) struct SnapshotResult {
    pub(super) scheduler: EvolutionSchedulerInfo,
    pub(super) workspace_items: Vec<EvolutionWorkspaceItem>,
}

/// 自适应调度状态（挂在 EvolutionState 上）
#[derive(Clone, Debug, Default)]
pub(super) struct AdaptiveSchedulingState {
    /// 最近一次生效的并发上限（自适应调整后的值）
    pub(super) effective_max_parallel: Option<u32>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    #[test]
    fn classify_failure_rate_limit() {
        assert_eq!(
            classify_failure("429 rate limit exceeded"),
            EvolutionFailureDiagnosisCode::RateLimit
        );
    }

    #[test]
    fn classify_failure_transient_session() {
        assert_eq!(
            classify_failure("stage stream error: unknown error"),
            EvolutionFailureDiagnosisCode::TransientSession
        );
    }

    #[test]
    fn classify_failure_artifact_contract() {
        assert_eq!(
            classify_failure("evo_stage_output_invalid"),
            EvolutionFailureDiagnosisCode::ArtifactContractViolation
        );
    }

    #[test]
    fn classify_failure_stage_timeout() {
        assert_eq!(
            classify_failure("evo_stage_timeout exceeded"),
            EvolutionFailureDiagnosisCode::StageTimeout
        );
    }

    #[test]
    fn classify_failure_gate_blocked() {
        assert_eq!(
            classify_failure("evo_gate_decision_blocked"),
            EvolutionFailureDiagnosisCode::GateBlocked
        );
    }

    #[test]
    fn classify_failure_human_blocker() {
        assert_eq!(
            classify_failure("evo_human_blocking_required"),
            EvolutionFailureDiagnosisCode::HumanBlocker
        );
    }

    #[test]
    fn classify_failure_unknown_system_fallback() {
        assert_eq!(
            classify_failure("some random error text"),
            EvolutionFailureDiagnosisCode::UnknownSystem
        );
    }

    #[test]
    fn recovery_info_to_dto_roundtrip() {
        let info = EvolutionRecoveryInfo {
            phase: EvolutionRecoveryPhase::Recovering,
            strategy: EvolutionRecoveryStrategy::RetryStage,
            diagnosis_code: EvolutionFailureDiagnosisCode::TransientSession,
            diagnosis_summary: "网络超时".to_string(),
            resume_at: Some("2099-01-01T00:00:00Z".to_string()),
            retry_count: 2,
            retry_limit: 5,
            degraded_until: None,
            updated_at: "2099-01-01T00:00:00Z".to_string(),
        };
        let dto = info.to_dto();
        assert_eq!(dto.phase, "recovering");
        assert_eq!(dto.strategy, "retry_stage");
        assert_eq!(dto.diagnosis_code, "transient_session");
        assert_eq!(dto.diagnosis_summary.as_deref(), Some("网络超时"));
        assert_eq!(dto.resume_at.as_deref(), Some("2099-01-01T00:00:00Z"));
        assert_eq!(dto.retry_count, 2);
        assert_eq!(dto.retry_limit, 5);
        assert!(dto.degraded_until.is_none());
        assert_eq!(dto.updated_at, "2099-01-01T00:00:00Z");
    }

    #[test]
    fn recovery_info_active_cooldown_future_resume() {
        let future = (Utc::now() + chrono::Duration::hours(1))
            .to_rfc3339();
        let info = EvolutionRecoveryInfo {
            phase: EvolutionRecoveryPhase::Recovering,
            strategy: EvolutionRecoveryStrategy::WaitRateLimit,
            diagnosis_code: EvolutionFailureDiagnosisCode::RateLimit,
            diagnosis_summary: "rate limited".to_string(),
            resume_at: Some(future),
            retry_count: 0,
            retry_limit: 3,
            degraded_until: None,
            updated_at: Utc::now().to_rfc3339(),
        };
        assert!(info.is_active_cooldown());
    }

    #[test]
    fn recovery_info_active_cooldown_past_resume() {
        let past = (Utc::now() - chrono::Duration::hours(1))
            .to_rfc3339();
        let info = EvolutionRecoveryInfo {
            phase: EvolutionRecoveryPhase::Recovering,
            strategy: EvolutionRecoveryStrategy::WaitRateLimit,
            diagnosis_code: EvolutionFailureDiagnosisCode::RateLimit,
            diagnosis_summary: "rate limited".to_string(),
            resume_at: Some(past),
            retry_count: 0,
            retry_limit: 3,
            degraded_until: None,
            updated_at: Utc::now().to_rfc3339(),
        };
        assert!(!info.is_active_cooldown());
    }

    #[test]
    fn recovery_info_active_cooldown_degraded_until() {
        let future = (Utc::now() + chrono::Duration::hours(1))
            .to_rfc3339();
        let info = EvolutionRecoveryInfo {
            phase: EvolutionRecoveryPhase::Degraded,
            strategy: EvolutionRecoveryStrategy::DeferWorkspace,
            diagnosis_code: EvolutionFailureDiagnosisCode::GateBlocked,
            diagnosis_summary: "gate blocked".to_string(),
            resume_at: None,
            retry_count: 3,
            retry_limit: 3,
            degraded_until: Some(future),
            updated_at: Utc::now().to_rfc3339(),
        };
        assert!(info.is_active_cooldown());
    }
}
