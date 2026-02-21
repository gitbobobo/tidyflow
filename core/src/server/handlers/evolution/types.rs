use std::collections::HashMap;

use crate::server::protocol::{
    EvolutionSchedulerInfo, EvolutionStageProfileInfo, EvolutionWorkspaceItem,
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
    pub(super) current_stage: String,
    pub(super) global_loop_round: u32,
    pub(super) auto_loop_enabled: bool,
    pub(super) verify_iteration: u32,
    pub(super) verify_iteration_limit: u32,
    pub(super) stop_requested: bool,
    pub(super) stage_profiles: Vec<EvolutionStageProfileInfo>,
    pub(super) stage_statuses: HashMap<String, String>,
    pub(super) stage_sessions: HashMap<String, StageSession>,
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
    pub(super) max_verify_iterations: u32,
    pub(super) auto_loop_enabled: bool,
    pub(super) stage_profiles: Vec<EvolutionStageProfileInfo>,
}

pub(super) struct SnapshotResult {
    pub(super) scheduler: EvolutionSchedulerInfo,
    pub(super) workspace_items: Vec<EvolutionWorkspaceItem>,
}
