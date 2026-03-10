use std::collections::{HashMap, HashSet};

use crate::server::protocol::{
    EvolutionSchedulerInfo, EvolutionSessionExecutionEntry, EvolutionStageProfileInfo,
    EvolutionWorkspaceItem,
};

pub(super) struct EvolutionState {
    pub(super) activation_state: String,
    pub(super) max_parallel_workspaces: u32,
    pub(super) seq_by_workspace: HashMap<String, u64>,
    pub(super) workspaces: HashMap<String, WorkspaceRunState>,
    /// 自适应调度状态
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
}

#[derive(Clone)]
pub(super) struct StageSession {
    pub(super) ai_tool: String,
    pub(super) session_id: String,
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

/// 自适应调度决策记录
///
/// 记录调度器基于分析结果做出的每次调优动作，
/// 包含原因、作用范围和安全边界，用于审计和回退。
#[derive(Clone, Debug)]
pub(super) struct AdaptiveDecision {
    /// 决策类型
    pub(super) kind: AdaptiveDecisionKind,
    /// 机器可读原因
    pub(super) reason: String,
    /// 决策前的值
    pub(super) previous_value: i64,
    /// 决策后的值
    pub(super) new_value: i64,
    /// 安全下限
    pub(super) safe_lower_bound: i64,
    /// 安全上限
    pub(super) safe_upper_bound: i64,
    /// 决策时间（RFC3339）
    pub(super) decided_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum AdaptiveDecisionKind {
    /// 调整并发上限
    ConcurrencyAdjusted,
    /// 工作区降级（暂停）
    WorkspaceDegraded,
    /// 延迟排队（速率限制退避）
    QueueDeferred,
    /// 重试退避调整
    BackoffAdjusted,
    /// 回退到保守默认值
    FallbackToDefault,
}

/// 自适应调度状态（挂在 EvolutionState 上）
#[derive(Clone, Debug, Default)]
pub(super) struct AdaptiveSchedulingState {
    /// 最近一次生效的并发上限（自适应调整后的值）
    pub(super) effective_max_parallel: Option<u32>,
    /// 最近的决策历史（最多保留 20 条）
    pub(super) recent_decisions: Vec<AdaptiveDecision>,
    /// 被降级暂停的工作区键列表
    pub(super) degraded_workspaces: HashSet<String>,
    /// 延迟排队的工作区键及其恢复时间（RFC3339）
    pub(super) deferred_workspaces: HashMap<String, String>,
}

impl AdaptiveSchedulingState {
    pub(super) fn record_decision(&mut self, decision: AdaptiveDecision) {
        self.recent_decisions.push(decision);
        if self.recent_decisions.len() > 20 {
            self.recent_decisions.remove(0);
        }
    }
}
