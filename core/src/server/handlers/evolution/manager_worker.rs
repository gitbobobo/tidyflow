use chrono::Utc;
use tokio::time::{sleep, Duration};
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::server::context::HandlerContext;
use crate::server::protocol::ServerMessage;

use super::utils::bootstrap_skip_reason;
use super::EvolutionManager;

impl EvolutionManager {
    pub(super) async fn spawn_worker(
        &self,
        key: String,
        preferred_round: u32,
        ctx: HandlerContext,
    ) {
        let mut workers = self.workers.lock().await;
        if workers.contains_key(&key) {
            return;
        }

        let manager = self.clone();
        let worker_key = key.clone();
        let handle = tokio::spawn(async move {
            manager
                .run_workspace(worker_key.clone(), preferred_round, ctx)
                .await;
            let mut workers = manager.workers.lock().await;
            workers.remove(&worker_key);
        });
        workers.insert(key, handle);
    }

    pub(super) async fn run_workspace(
        &self,
        key: String,
        preferred_round: u32,
        ctx: HandlerContext,
    ) {
        loop {
            if self.maybe_skip_bootstrap_stage(&key, &ctx).await {
                continue;
            }

            {
                let state = self.state.lock().await;
                let Some(entry) = state.workspaces.get(&key) else {
                    return;
                };
                if entry.stop_requested {
                    drop(state);
                    self.mark_interrupted(&key, &ctx).await;
                    return;
                }
            }

            while !self.can_run_with_priority(&key).await {
                sleep(Duration::from_millis(80)).await;
                let should_stop = {
                    let state = self.state.lock().await;
                    state
                        .workspaces
                        .get(&key)
                        .map(|w| w.stop_requested)
                        .unwrap_or(true)
                };
                if should_stop {
                    self.mark_interrupted(&key, &ctx).await;
                    return;
                }
            }

            let permit = match self.semaphore.acquire().await {
                Ok(permit) => permit,
                Err(_) => return,
            };

            let (project, workspace, stage, cycle_id, round) = {
                let mut state = self.state.lock().await;
                let Some(entry) = state.workspaces.get_mut(&key) else {
                    drop(permit);
                    return;
                };
                entry.status = "running".to_string();
                if preferred_round > 0 && entry.global_loop_round < preferred_round {
                    entry.global_loop_round = preferred_round;
                }
                (
                    entry.project.clone(),
                    entry.workspace.clone(),
                    entry.current_stage.clone(),
                    entry.cycle_id.clone(),
                    entry.global_loop_round,
                )
            };

            self.broadcast_scheduler(&ctx).await;
            self.broadcast_cycle_update(&key, &ctx, "orchestrator")
                .await;

            let stage_result = self
                .run_stage(&key, &project, &workspace, &cycle_id, &stage, round, &ctx)
                .await;

            drop(permit);

            match stage_result {
                Ok(judge_pass) => {
                    if self
                        .after_stage_success(&key, &stage, judge_pass, &ctx)
                        .await
                    {
                        continue;
                    }
                }
                Err(err) => {
                    error!(
                        "evolution stage failed: key={}, stage={}, error={}",
                        key, stage, err
                    );
                    self.mark_failed_system(&key, &err, &ctx).await;
                    return;
                }
            }

            let (stop_now, terminal_completed) = {
                let state = self.state.lock().await;
                let stop_now = state
                    .workspaces
                    .get(&key)
                    .map(|w| w.stop_requested)
                    .unwrap_or(true);
                let terminal_completed = state
                    .workspaces
                    .get(&key)
                    .map(|w| w.status == "completed")
                    .unwrap_or(true);
                (stop_now, terminal_completed)
            };
            if terminal_completed {
                return;
            }
            if stop_now {
                self.mark_interrupted(&key, &ctx).await;
                return;
            }
        }
    }

    pub(super) async fn maybe_skip_bootstrap_stage(&self, key: &str, ctx: &HandlerContext) -> bool {
        let (project, workspace, workspace_root, cycle_id, verify_iteration, is_bootstrap_stage) = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return false;
            };
            (
                entry.project.clone(),
                entry.workspace.clone(),
                entry.workspace_root.clone(),
                entry.cycle_id.clone(),
                entry.verify_iteration,
                entry.current_stage == "bootstrap",
            )
        };

        if !is_bootstrap_stage {
            return false;
        }

        let skip_reason = match bootstrap_skip_reason(&workspace_root) {
            Ok(reason) => reason,
            Err(err) => {
                warn!(
                    "bootstrap skip check failed: key={}, workspace_root={}, error={}",
                    key, workspace_root, err
                );
                None
            }
        };
        let Some(reason) = skip_reason else {
            return false;
        };

        {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return false;
            };
            if entry.current_stage != "bootstrap" {
                return false;
            }
            entry
                .stage_statuses
                .insert("bootstrap".to_string(), "done".to_string());
            entry.current_stage = "direction".to_string();
        }

        info!("bootstrap stage skipped: key={}, reason={}", key, reason);
        self.persist_stage_file(key, "bootstrap", "done", None, None)
            .await
            .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast(
            ctx,
            ServerMessage::EvoStageChanged {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(key).await,
                project,
                workspace,
                cycle_id,
                ts: Utc::now().to_rfc3339(),
                source: "orchestrator".to_string(),
                from_stage: "bootstrap".to_string(),
                to_stage: "direction".to_string(),
                verify_iteration,
            },
        )
        .await;
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;
        self.broadcast_scheduler(ctx).await;
        true
    }
}
