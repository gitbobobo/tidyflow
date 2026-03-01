use std::collections::{HashMap, HashSet};

use chrono::Utc;
use tracing::warn;
use uuid::Uuid;

use crate::server::context::HandlerContext;
use crate::server::handlers::ai::resolve_directory;
use crate::server::protocol::{EvolutionWorkspaceItem, ServerMessage};

use super::stage::{active_agents, build_agents};
use super::utils::workspace_key;
use super::{
    EvolutionManager, SnapshotResult, StartWorkspaceReq, WorkspaceRunState, DEFAULT_VERIFY_LIMIT,
    STAGES,
};

fn initial_global_loop_round() -> u32 {
    1
}

impl EvolutionManager {
    pub(super) async fn start_workspace(
        &self,
        req: StartWorkspaceReq,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let key = workspace_key(&req.project, &req.workspace);
        let workspace_root =
            resolve_directory(&ctx.app_state, &req.project, &req.workspace).await?;
        if self
            .emit_blocking_required_if_any(
                &req.project,
                &req.workspace,
                &workspace_root,
                "start",
                None,
                None,
                ctx,
            )
            .await?
        {
            return Ok(());
        }

        {
            let workers = self.workers.lock().await;
            if workers.contains_key(&key) {
                return Err(format!("evo_workspace_locked: {}", key));
            }
        }

        let stage_profiles = if req.stage_profiles.is_empty() {
            self.get_agent_profile(&req.project, &req.workspace, ctx)
                .await
        } else {
            super::profile::normalize_profiles(req.stage_profiles)?
        };
        let now = Utc::now();
        let cycle_id = now.format("%Y-%m-%dT%H-%M-%S-%3fZ").to_string();

        let mut stage_statuses = HashMap::new();
        let mut stage_tool_call_counts = HashMap::new();
        let mut stage_seen_tool_calls = HashMap::new();
        for stage in STAGES {
            stage_statuses.insert(stage.to_string(), "pending".to_string());
            stage_tool_call_counts.insert(stage.to_string(), 0);
            stage_seen_tool_calls.insert(stage.to_string(), HashSet::new());
        }

        let global_loop_round = {
            let mut state = self.state.lock().await;
            state.activation_state = "activated".to_string();
            if let Some(existing) = state.workspaces.get(&key) {
                let is_terminal = existing.status == "completed"
                    || existing.status == "failed_exhausted"
                    || existing.status == "failed_system";
                if !is_terminal {
                    return Err(format!("evo_workspace_locked: {}", key));
                }
            }
            let round = initial_global_loop_round();
            let now_rfc3339 = Utc::now().to_rfc3339();
            state.workspaces.insert(
                key.clone(),
                WorkspaceRunState {
                    project: req.project.clone(),
                    workspace: req.workspace.clone(),
                    workspace_root: workspace_root.clone(),
                    priority: req.priority,
                    status: "queued".to_string(),
                    cycle_id: cycle_id.clone(),
                    current_stage: "direction".to_string(),
                    global_loop_round: round,
                    loop_round_limit: req.loop_round_limit.max(1),
                    verify_iteration: 0,
                    verify_iteration_limit: DEFAULT_VERIFY_LIMIT,
                    created_at: now_rfc3339,
                    stop_requested: false,
                    llm_defined_acceptance_criteria: Vec::new(),
                    last_judge_result: None,
                    terminal_reason_code: None,
                    rate_limit_resume_at: None,
                    rate_limit_error_message: None,
                    stage_profiles,
                    stage_statuses,
                    stage_sessions: HashMap::new(),
                    stage_session_history: HashMap::new(),
                    stage_tool_call_counts,
                    stage_seen_tool_calls,
                },
            );
            round
        };

        if let Err(e) = self.persist_cycle_file(&key).await {
            warn!("persist cycle file failed: {}", e);
        }

        self.broadcast(
            ctx,
            ServerMessage::EvoWorkspaceStarted {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(&key).await,
                project: req.project.clone(),
                workspace: req.workspace.clone(),
                cycle_id: cycle_id.clone(),
                ts: Utc::now().to_rfc3339(),
                source: "user".to_string(),
                status: "queued".to_string(),
            },
        )
        .await;

        self.broadcast_scheduler(ctx).await;
        self.spawn_worker(key, global_loop_round, ctx.clone()).await;
        Ok(())
    }

    pub(super) async fn stop_workspace(
        &self,
        project: &str,
        workspace: &str,
        reason: Option<String>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let key = workspace_key(project, workspace);
        let (cycle_id, status) = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(&key) else {
                return Err(format!("evo_cycle_not_found: {}", key));
            };
            entry.stop_requested = true;
            (entry.cycle_id.clone(), entry.status.clone())
        };

        self.broadcast(
            ctx,
            ServerMessage::EvoWorkspaceStopped {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(&key).await,
                project: project.to_string(),
                workspace: workspace.to_string(),
                cycle_id,
                ts: Utc::now().to_rfc3339(),
                source: "user".to_string(),
                status,
                reason,
            },
        )
        .await;

        self.broadcast_scheduler(ctx).await;
        Ok(())
    }

    pub(super) async fn stop_all(&self, reason: Option<String>, ctx: &HandlerContext) {
        let keys = {
            let mut state = self.state.lock().await;
            let mut keys = Vec::new();
            for (key, entry) in state.workspaces.iter_mut() {
                entry.stop_requested = true;
                keys.push((
                    key.clone(),
                    entry.project.clone(),
                    entry.workspace.clone(),
                    entry.cycle_id.clone(),
                    entry.status.clone(),
                ));
            }
            keys
        };

        for (key, project, workspace, cycle_id, status) in keys {
            self.broadcast(
                ctx,
                ServerMessage::EvoWorkspaceStopped {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(&key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "user".to_string(),
                    status,
                    reason: reason.clone(),
                },
            )
            .await;
        }

        self.broadcast_scheduler(ctx).await;
    }

    pub(super) async fn resume_workspace(
        &self,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let key = workspace_key(project, workspace);
        {
            let workers = self.workers.lock().await;
            if workers.contains_key(&key) {
                return Ok(());
            }
        }

        let (cycle_id, current_stage, workspace_root) = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(&key) else {
                return Err(format!("evo_cycle_not_found: {}", key));
            };
            if entry.status != "interrupted" && entry.status != "stopped" {
                return Err(format!("evo_resume_not_allowed: {}", entry.status));
            }
            (
                entry.cycle_id.clone(),
                entry.current_stage.clone(),
                entry.workspace_root.clone(),
            )
        };
        if self
            .emit_blocking_required_if_any(
                project,
                workspace,
                &workspace_root,
                "resume",
                Some(&cycle_id),
                Some(&current_stage),
                ctx,
            )
            .await?
        {
            return Ok(());
        }

        {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(&key) else {
                return Err(format!("evo_cycle_not_found: {}", key));
            };
            entry.stop_requested = false;
            entry.status = "queued".to_string();
            entry.rate_limit_resume_at = None;
            entry.rate_limit_error_message = None;
        }

        self.broadcast(
            ctx,
            ServerMessage::EvoWorkspaceResumed {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(&key).await,
                project: project.to_string(),
                workspace: workspace.to_string(),
                cycle_id,
                ts: Utc::now().to_rfc3339(),
                source: "user".to_string(),
                status: "queued".to_string(),
            },
        )
        .await;

        self.broadcast_scheduler(ctx).await;
        self.spawn_worker(key, 0, ctx.clone()).await;
        Ok(())
    }

    pub(super) async fn open_stage_chat(
        &self,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
    ) -> Option<(String, String)> {
        let key = workspace_key(project, workspace);
        let state = self.state.lock().await;
        let entry = state.workspaces.get(&key)?;
        if entry.cycle_id != cycle_id {
            return None;
        }
        let session = entry.stage_sessions.get(stage)?.clone();
        Some((session.ai_tool, session.session_id))
    }

    pub(super) async fn build_snapshot(&self, _ctx: &HandlerContext) -> SnapshotResult {
        let state = self.state.lock().await;
        let running_count = state
            .workspaces
            .values()
            .filter(|w| w.status == "running")
            .count() as u32;
        let queued_count = state
            .workspaces
            .values()
            .filter(|w| w.status == "queued")
            .count() as u32;

        let mut workspace_items: Vec<EvolutionWorkspaceItem> = Vec::new();

        for w in state.workspaces.values() {
            let agents = build_agents(&w.stage_statuses, &w.stage_tool_call_counts);

            workspace_items.push(EvolutionWorkspaceItem {
                project: w.project.clone(),
                workspace: w.workspace.clone(),
                cycle_id: w.cycle_id.clone(),
                status: w.status.clone(),
                current_stage: w.current_stage.clone(),
                global_loop_round: w.global_loop_round,
                loop_round_limit: w.loop_round_limit,
                verify_iteration: w.verify_iteration,
                verify_iteration_limit: w.verify_iteration_limit,
                agents,
                active_agents: active_agents(&w.stage_statuses),
            });
        }

        workspace_items.sort_by(|a, b| {
            (a.project.clone(), a.workspace.clone()).cmp(&(b.project.clone(), b.workspace.clone()))
        });

        SnapshotResult {
            scheduler: crate::server::protocol::EvolutionSchedulerInfo {
                activation_state: state.activation_state.clone(),
                max_parallel_workspaces: state.max_parallel_workspaces,
                running_count,
                queued_count,
            },
            workspace_items,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::initial_global_loop_round;

    #[test]
    fn start_round_should_reset_to_one() {
        assert_eq!(initial_global_loop_round(), 1);
    }
}
