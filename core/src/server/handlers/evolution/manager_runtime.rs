use chrono::Utc;
use uuid::Uuid;

use crate::server::context::{HandlerContext, TaskBroadcastEvent};
use crate::server::protocol::ServerMessage;

use super::stage::{active_agents, build_agents};
use super::{EvolutionManager, StageSession};

impl EvolutionManager {
    pub(super) async fn set_stage_status(&self, key: &str, stage: &str, status: &str) {
        let mut state = self.state.lock().await;
        if let Some(entry) = state.workspaces.get_mut(key) {
            entry
                .stage_statuses
                .insert(stage.to_string(), status.to_string());
        }
    }

    pub(super) async fn set_stage_session(
        &self,
        key: &str,
        stage: &str,
        ai_tool: &str,
        session_id: &str,
    ) {
        let mut state = self.state.lock().await;
        if let Some(entry) = state.workspaces.get_mut(key) {
            entry.stage_sessions.insert(
                stage.to_string(),
                StageSession {
                    ai_tool: ai_tool.to_string(),
                    session_id: session_id.to_string(),
                },
            );
        }
    }

    pub(super) async fn next_seq(&self, key: &str) -> u64 {
        let mut state = self.state.lock().await;
        let seq = state.seq_by_workspace.entry(key.to_string()).or_insert(0);
        *seq += 1;
        *seq
    }

    pub(super) async fn broadcast_cycle_update(
        &self,
        key: &str,
        ctx: &HandlerContext,
        source: &str,
    ) {
        let (
            project,
            workspace,
            cycle_id,
            status,
            current_stage,
            round,
            verify_iteration,
            verify_limit,
            stage_statuses,
        ) = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return;
            };
            (
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
                entry.status.clone(),
                entry.current_stage.clone(),
                entry.global_loop_round,
                entry.verify_iteration,
                entry.verify_iteration_limit,
                entry.stage_statuses.clone(),
            )
        };

        self.broadcast(
            ctx,
            ServerMessage::EvoCycleUpdated {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(key).await,
                project,
                workspace,
                cycle_id,
                ts: Utc::now().to_rfc3339(),
                source: source.to_string(),
                status,
                current_stage,
                global_loop_round: round,
                verify_iteration,
                verify_iteration_limit: verify_limit,
                agents: build_agents(&stage_statuses),
                active_agents: active_agents(&stage_statuses),
            },
        )
        .await;
    }

    pub(super) async fn broadcast_scheduler(&self, ctx: &HandlerContext) {
        let snapshot = self.build_snapshot().await;
        self.broadcast(
            ctx,
            ServerMessage::EvoSchedulerUpdated {
                activation_state: snapshot.scheduler.activation_state,
                max_parallel_workspaces: snapshot.scheduler.max_parallel_workspaces,
                running_count: snapshot.scheduler.running_count,
                queued_count: snapshot.scheduler.queued_count,
            },
        )
        .await;
    }

    pub(super) async fn broadcast(&self, ctx: &HandlerContext, message: ServerMessage) {
        let _ = ctx.task_broadcast_tx.send(TaskBroadcastEvent {
            origin_conn_id: "evolution_orchestrator".to_string(),
            message,
        });
    }

    pub(super) async fn can_run_with_priority(&self, key: &str) -> bool {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return false;
        };
        let current_priority = entry.priority;
        !state.workspaces.iter().any(|(other_key, other)| {
            other_key != key
                && !other.stop_requested
                && (other.status == "queued" || other.status == "running")
                && other.priority > current_priority
        })
    }
}
