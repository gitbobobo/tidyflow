use tokio::time::{sleep, Duration};
use tracing::error;

use super::EvolutionManager;
use crate::server::context::HandlerContext;

fn is_terminal_status(status: &str) -> bool {
    matches!(status, "completed" | "failed_exhausted" | "failed_system")
}

fn is_round_limit_exceeded(global_loop_round: u32, loop_round_limit: u32) -> bool {
    let normalized_limit = loop_round_limit.max(1);
    global_loop_round > normalized_limit
}

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

            let (project, workspace, stage, cycle_id, round, round_limit, round_exceeded) = {
                let mut state = self.state.lock().await;
                let Some(entry) = state.workspaces.get_mut(&key) else {
                    drop(permit);
                    return;
                };
                if is_round_limit_exceeded(entry.global_loop_round, entry.loop_round_limit) {
                    (
                        entry.project.clone(),
                        entry.workspace.clone(),
                        entry.current_stage.clone(),
                        entry.cycle_id.clone(),
                        entry.global_loop_round,
                        entry.loop_round_limit,
                        true,
                    )
                } else {
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
                        entry.loop_round_limit,
                        false,
                    )
                }
            };
            if round_exceeded {
                drop(permit);
                self.mark_failed_with_code(
                    &key,
                    "evo_round_limit_exceeded",
                    &format!(
                        "global_loop_round exceeded loop_round_limit: round={}, limit={}, project={}, workspace={}",
                        round, round_limit, project, workspace
                    ),
                    &ctx,
                )
                .await;
                return;
            }

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
                    if err.starts_with("evo_human_blocking_required") {
                        let cycle_id = {
                            let state = self.state.lock().await;
                            state
                                .workspaces
                                .get(&key)
                                .map(|w| w.cycle_id.clone())
                                .unwrap_or_default()
                        };
                        self.interrupt_for_blockers(
                            &key,
                            &cycle_id,
                            "workspace_blockers_pending",
                            &ctx,
                        )
                        .await;
                        return;
                    }
                    error!(
                        "evolution stage failed: key={}, stage={}, error={}",
                        key, stage, err
                    );
                    self.mark_failed_system(&key, &err, &ctx).await;
                    return;
                }
            }

            let (stop_now, terminal_reached) = {
                let state = self.state.lock().await;
                let stop_now = state
                    .workspaces
                    .get(&key)
                    .map(|w| w.stop_requested)
                    .unwrap_or(true);
                let terminal_reached = state
                    .workspaces
                    .get(&key)
                    .map(|w| is_terminal_status(&w.status))
                    .unwrap_or(true);
                (stop_now, terminal_reached)
            };
            if terminal_reached {
                return;
            }
            if stop_now {
                self.mark_interrupted(&key, &ctx).await;
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{is_round_limit_exceeded, is_terminal_status};

    #[test]
    fn terminal_status_should_include_failed_exhausted_and_failed_system() {
        assert!(is_terminal_status("completed"));
        assert!(is_terminal_status("failed_exhausted"));
        assert!(is_terminal_status("failed_system"));
        assert!(!is_terminal_status("running"));
        assert!(!is_terminal_status("queued"));
    }

    #[test]
    fn round_limit_guard_should_reject_exceeded_round() {
        assert!(!is_round_limit_exceeded(1, 1));
        assert!(!is_round_limit_exceeded(1, 3));
        assert!(is_round_limit_exceeded(2, 1));
    }
}
