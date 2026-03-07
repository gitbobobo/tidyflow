use chrono::Utc;
use uuid::Uuid;

use crate::server::context::{HandlerContext, TaskBroadcastEvent};
use crate::server::protocol::ServerMessage;

use super::stage::build_agents;
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
            title,
            status,
            current_stage,
            round,
            loop_round_limit,
            verify_iteration,
            verify_limit,
            stage_statuses,
            stage_tool_call_counts,
            session_executions,
            stage_started_ats,
            stage_duration_ms,
            terminal_reason_code,
            terminal_error_message,
            rate_limit_error_message,
        ) = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return;
            };
            (
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
                entry.cycle_title.clone(),
                entry.status.clone(),
                entry.current_stage.clone(),
                entry.global_loop_round,
                entry.loop_round_limit,
                entry.verify_iteration,
                entry.verify_iteration_limit,
                entry.stage_statuses.clone(),
                entry.stage_tool_call_counts.clone(),
                entry.session_executions.clone(),
                entry.stage_started_ats.clone(),
                entry.stage_duration_ms.clone(),
                entry.terminal_reason_code.clone(),
                entry.terminal_error_message.clone(),
                entry.rate_limit_error_message.clone(),
            )
        };

        let agents = build_agents(
            &stage_statuses,
            &stage_tool_call_counts,
            &stage_started_ats,
            &stage_duration_ms,
        );

        self.broadcast(
            ctx,
            ServerMessage::EvoCycleUpdated {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(key).await,
                project,
                workspace,
                cycle_id,
                title,
                ts: Utc::now().to_rfc3339(),
                source: source.to_string(),
                status,
                current_stage,
                global_loop_round: round,
                loop_round_limit,
                verify_iteration,
                verify_iteration_limit: verify_limit,
                agents,
                executions: session_executions,
                terminal_reason_code,
                terminal_error_message,
                rate_limit_error_message,
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
        let sidebar_target = match &message {
            ServerMessage::EvoWorkspaceStarted {
                project, workspace, ..
            }
            | ServerMessage::EvoWorkspaceStopped {
                project, workspace, ..
            }
            | ServerMessage::EvoWorkspaceResumed {
                project, workspace, ..
            }
            | ServerMessage::EvoStageChanged {
                project, workspace, ..
            }
            | ServerMessage::EvoCycleUpdated {
                project, workspace, ..
            }
            | ServerMessage::EvoBlockingRequired {
                project, workspace, ..
            }
            | ServerMessage::EvoBlockersUpdated {
                project, workspace, ..
            } => Some((project.clone(), workspace.clone())),
            ServerMessage::EvoError {
                project: Some(project),
                workspace: Some(workspace),
                ..
            } => Some((project.clone(), workspace.clone())),
            _ => None,
        };

        let _ = crate::server::context::send_task_broadcast_event(
            &ctx.task_broadcast_tx,
            TaskBroadcastEvent {
                origin_conn_id: "evolution_orchestrator".to_string(),
                message,
                target_conn_ids: None,
                skip_when_single_receiver: false,
            },
        );

        if let Some((project, workspace)) = sidebar_target {
            crate::application::sidebar_status::notify_workspace_sidebar_if_evolution_changed(
                ctx, &project, &workspace,
            )
            .await;
        }
    }
}
