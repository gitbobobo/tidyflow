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
        if source == "agent" {
            crate::server::perf::record_evolution_cycle_update_debounced();
            self.cancel_debounced_cycle_update(key).await;
            let key_owned = key.to_string();
            let ctx_cloned = ctx.clone();
            let manager = self.clone();
            let handle = tokio::spawn(async move {
                tokio::time::sleep(Self::cycle_update_debounce_window()).await;
                manager
                    .emit_cycle_update_now(&key_owned, &ctx_cloned, "agent")
                    .await;
                let mut tasks = manager.debounced_cycle_update_tasks.lock().await;
                tasks.remove(&key_owned);
            });
            let mut tasks = self.debounced_cycle_update_tasks.lock().await;
            tasks.insert(key.to_string(), handle);
            return;
        }

        self.cancel_debounced_cycle_update(key).await;
        self.emit_cycle_update_now(key, ctx, source).await;
    }

    pub(super) async fn emit_cycle_update_now(
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
            coordination_state,
            coordination_scope,
            coordination_reason,
            coordination_peer_node_id,
            coordination_peer_node_name,
            coordination_peer_project,
            coordination_peer_workspace,
            coordination_queue_index,
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
                entry.coordination_state.clone(),
                entry.coordination_scope.clone(),
                entry.coordination_reason.clone(),
                entry.coordination_peer_node_id.clone(),
                entry.coordination_peer_node_name.clone(),
                entry.coordination_peer_project.clone(),
                entry.coordination_peer_workspace.clone(),
                entry.coordination_queue_index,
            )
        };

        let agents = build_agents(
            &stage_statuses,
            &stage_tool_call_counts,
            &stage_started_ats,
            &stage_duration_ms,
        );

        crate::server::perf::record_evolution_cycle_update_emitted();
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
                coordination_state,
                coordination_scope,
                coordination_reason,
                coordination_peer_node_id,
                coordination_peer_node_name,
                coordination_peer_project,
                coordination_peer_workspace,
                coordination_queue_index,
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

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};
    use std::sync::Arc;

    use tokio::sync::{broadcast, mpsc, Mutex, RwLock};
    use tokio::time::{sleep, Duration};

    use super::super::types::WorkspaceRunState;
    use super::super::EvolutionManager;
    use crate::server::context::{
        ConnectionMeta, HandlerContext, SharedRunningAITasks, SharedRunningCommands,
        SharedTaskHistory, TaskBroadcastEvent,
    };
    use crate::server::handlers::ai::AIState;
    use crate::server::protocol::ServerMessage;
    use crate::server::remote_sub_registry::RemoteSubRegistry;
    use crate::server::terminal_registry::TerminalRegistry;
    use crate::workspace::state::AppState;
    use crate::workspace::state_store::StateStore;

    async fn make_handler_context(
        task_broadcast_tx: broadcast::Sender<TaskBroadcastEvent>,
    ) -> HandlerContext {
        let (save_tx, _) = mpsc::channel(1);
        let (scrollback_tx, _) = mpsc::channel(1);
        let (agg_tx, _) = mpsc::channel(1);
        let (cmd_output_tx, _) = mpsc::channel(1);
        let app_state = Arc::new(RwLock::new(AppState::default()));
        let running_commands: SharedRunningCommands = Arc::new(Mutex::new(HashMap::new()));
        let running_ai_tasks: SharedRunningAITasks = Arc::new(Mutex::new(HashMap::new()));
        let task_history: SharedTaskHistory = Arc::new(Mutex::new(Vec::new()));
        let state_store = Arc::new(
            StateStore::open_in_memory_for_test()
                .await
                .expect("test state store"),
        );

        HandlerContext {
            app_state,
            terminal_registry: Arc::new(Mutex::new(TerminalRegistry::new())),
            save_tx,
            scrollback_tx,
            subscribed_terms: Arc::new(Mutex::new(HashMap::new())),
            agg_tx,
            running_commands,
            running_ai_tasks,
            cmd_output_tx,
            task_broadcast_tx,
            task_history,
            conn_meta: ConnectionMeta {
                conn_id: "test-conn".to_string(),
                api_key_id: None,
                client_id: None,
                subscriber_id: None,
                is_remote: false,
                device_name: None,
            },
            remote_sub_registry: Arc::new(Mutex::new(RemoteSubRegistry::new())),
            ai_state: Arc::new(Mutex::new(AIState::new())),
            state_store,
        }
    }

    fn make_workspace_run_state() -> WorkspaceRunState {
        WorkspaceRunState {
            project: "demo".to_string(),
            workspace: "default".to_string(),
            workspace_root: "/tmp/demo".to_string(),
            priority: 0,
            status: "running".to_string(),
            cycle_id: "cycle-1".to_string(),
            cycle_title: Some("测试循环".to_string()),
            current_stage: "plan".to_string(),
            global_loop_round: 1,
            loop_round_limit: 3,
            verify_iteration: 0,
            verify_iteration_limit: 5,
            backlog_contract_version: 2,
            created_at: "2026-03-09T00:00:00Z".to_string(),
            stop_requested: false,
            terminal_reason_code: None,
            terminal_error_message: None,
            rate_limit_resume_at: None,
            rate_limit_error_message: None,
            stage_profiles: Vec::new(),
            stage_statuses: HashMap::from([("plan".to_string(), "running".to_string())]),
            stage_sessions: HashMap::new(),
            stage_session_history: HashMap::new(),
            stage_tool_call_counts: HashMap::new(),
            stage_seen_tool_calls: HashMap::<String, HashSet<String>>::new(),
            stage_retry_counts: HashMap::new(),
            session_executions: Vec::new(),
            stage_started_ats: HashMap::new(),
            stage_duration_ms: HashMap::new(),
            coordination_state: None,
            coordination_scope: None,
            coordination_reason: None,
            coordination_peer_node_id: None,
            coordination_peer_node_name: None,
            coordination_peer_project: None,
            coordination_peer_workspace: None,
            coordination_queue_index: None,
        }
    }

    #[tokio::test]
    async fn broadcast_cycle_update_should_include_running_session_execution() {
        let manager = EvolutionManager::new();
        let key = "demo::default".to_string();
        {
            let mut state = manager.state.lock().await;
            state
                .workspaces
                .insert(key.clone(), make_workspace_run_state());
        }

        manager
            .record_session_execution_started(&key, "plan", "codex", "sess-running")
            .await;

        let (tx, mut rx) = broadcast::channel(8);
        let ctx = make_handler_context(tx).await;
        manager.broadcast_cycle_update(&key, &ctx, "agent").await;
        sleep(Duration::from_millis(280)).await;

        let event = rx.recv().await.expect("应收到 evo_cycle_updated 广播");
        match event.message {
            ServerMessage::EvoCycleUpdated { executions, .. } => {
                assert_eq!(executions.len(), 1);
                assert_eq!(executions[0].stage, "plan");
                assert_eq!(executions[0].ai_tool, "codex");
                assert_eq!(executions[0].session_id, "sess-running");
                assert_eq!(executions[0].status, "running");
            }
            other => panic!("unexpected message: {:?}", other),
        }
    }

    #[tokio::test]
    async fn broadcast_cycle_update_should_debounce_agent_updates() {
        let manager = EvolutionManager::new();
        let key = "demo::default".to_string();
        {
            let mut state = manager.state.lock().await;
            let mut workspace = make_workspace_run_state();
            workspace
                .stage_tool_call_counts
                .insert("plan".to_string(), 1);
            state.workspaces.insert(key.clone(), workspace);
        }

        let (tx, mut rx) = broadcast::channel(8);
        let ctx = make_handler_context(tx).await;
        manager.broadcast_cycle_update(&key, &ctx, "agent").await;
        {
            let mut state = manager.state.lock().await;
            state
                .workspaces
                .get_mut(&key)
                .expect("workspace")
                .stage_tool_call_counts
                .insert("plan".to_string(), 2);
        }
        sleep(Duration::from_millis(40)).await;
        manager.broadcast_cycle_update(&key, &ctx, "agent").await;

        sleep(Duration::from_millis(280)).await;

        let event = rx
            .recv()
            .await
            .expect("应收到合并后的 evo_cycle_updated 广播");
        match event.message {
            ServerMessage::EvoCycleUpdated { agents, .. } => {
                let plan_agent = agents
                    .iter()
                    .find(|agent| agent.stage == "plan")
                    .expect("plan agent");
                assert_eq!(plan_agent.tool_call_count, 2);
            }
            other => panic!("unexpected message: {:?}", other),
        }
        assert!(rx.try_recv().is_err(), "防抖窗口内不应产生第二条广播");
    }

    #[tokio::test]
    async fn broadcast_cycle_update_should_flush_immediately_for_non_agent_source() {
        let manager = EvolutionManager::new();
        let key = "demo::default".to_string();
        {
            let mut state = manager.state.lock().await;
            state
                .workspaces
                .insert(key.clone(), make_workspace_run_state());
        }

        let (tx, mut rx) = broadcast::channel(8);
        let ctx = make_handler_context(tx).await;
        manager.broadcast_cycle_update(&key, &ctx, "agent").await;
        manager.broadcast_cycle_update(&key, &ctx, "system").await;

        let event = rx.recv().await.expect("非 agent 广播应立即送达");
        match event.message {
            ServerMessage::EvoCycleUpdated { source, .. } => {
                assert_eq!(source, "system");
            }
            other => panic!("unexpected message: {:?}", other),
        }

        sleep(Duration::from_millis(280)).await;
        assert!(rx.try_recv().is_err(), "立即广播后不应残留延迟 agent 广播");
    }
}
