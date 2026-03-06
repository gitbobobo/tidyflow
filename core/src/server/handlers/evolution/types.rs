use std::collections::{HashMap, HashSet};

use crate::server::protocol::{
    EvolutionHandoffInfo, EvolutionSchedulerInfo, EvolutionSessionExecutionEntry,
    EvolutionStageProfileInfo, EvolutionWorkspaceItem,
};

pub(super) struct EvolutionState {
    pub(super) activation_state: String,
    pub(super) max_parallel_workspaces: u32,
    pub(super) seq_by_workspace: HashMap<String, u64>,
    pub(super) workspaces: HashMap<String, WorkspaceRunState>,
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
    pub(super) cycle_handoff: EvolutionHandoffInfo,
    pub(super) selected_direction_type: Option<String>,
    pub(super) direction_candidate_scores: Vec<serde_json::Value>,
    pub(super) direction_final_reason: Option<String>,
    pub(super) current_stage: String,
    pub(super) global_loop_round: u32,
    pub(super) loop_round_limit: u32,
    pub(super) verify_iteration: u32,
    pub(super) verify_iteration_limit: u32,
    pub(super) backlog_contract_version: u32,
    pub(super) created_at: String,
    pub(super) stop_requested: bool,
    pub(super) llm_defined_acceptance_criteria: Vec<serde_json::Value>,
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
