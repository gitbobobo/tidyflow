use chrono::Utc;
use uuid::Uuid;

use crate::server::context::{HandlerContext, TaskBroadcastEvent};
use crate::server::protocol::ServerMessage;

use super::stage::{active_agents, build_agents};
use super::EvolutionManager;

impl EvolutionManager {
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
            loop_round_limit,
            verify_iteration,
            verify_limit,
            stage_statuses,
            stage_tool_call_counts,
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
                entry.loop_round_limit,
                entry.verify_iteration,
                entry.verify_iteration_limit,
                entry.stage_statuses.clone(),
                entry.stage_tool_call_counts.clone(),
            )
        };

        let agents = build_agents(&stage_statuses, &stage_tool_call_counts);

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
                loop_round_limit,
                verify_iteration,
                verify_iteration_limit: verify_limit,
                agents,
                active_agents: active_agents(&stage_statuses),
            },
        )
        .await;
    }

    pub(super) async fn broadcast_scheduler(&self, ctx: &HandlerContext) {
        let snapshot = self.build_snapshot(ctx).await;
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
        let _ = crate::server::context::send_task_broadcast_event(
            &ctx.task_broadcast_tx,
            TaskBroadcastEvent {
                origin_conn_id: "evolution_orchestrator".to_string(),
                message,
                target_conn_ids: None,
                skip_when_single_receiver: false,
            },
        );
    }
}
