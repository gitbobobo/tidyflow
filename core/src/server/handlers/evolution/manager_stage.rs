use chrono::Utc;
use futures::StreamExt;
use tokio::time::{timeout, Duration};
use uuid::Uuid;

use crate::ai::AiModelSelection;
use crate::server::context::HandlerContext;
use crate::server::handlers::ai::{ensure_agent, resolve_directory};
use crate::server::protocol::ServerMessage;

use super::profile::profile_for_stage;
use super::utils::sanitize_name;
use super::{EvolutionManager, MAX_STAGE_RUNTIME_SECS, STAGES};

impl EvolutionManager {
    pub(super) async fn run_stage(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        round: u32,
        ctx: &HandlerContext,
    ) -> Result<bool, String> {
        let profile = {
            let state = self.state.lock().await;
            let entry = state
                .workspaces
                .get(key)
                .ok_or_else(|| "workspace state missing".to_string())?;
            profile_for_stage(&entry.stage_profiles, stage)
        };
        let ai_tool = profile.ai_tool.clone();

        self.set_stage_status(key, stage, "running").await;
        self.persist_cycle_file(key).await.ok();
        self.persist_stage_file(key, stage, "running", None, None)
            .await
            .ok();
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;

        let directory = resolve_directory(&ctx.app_state, project, workspace).await?;
        let agent = ensure_agent(&ctx.ai_state, &ai_tool).await?;

        let title = format!("Evolution {} {}", stage, cycle_id);
        let session = agent.create_session(&directory, &title).await?;
        self.set_stage_session(key, stage, &ai_tool, &session.id)
            .await;
        self.persist_chat_map(key).await.ok();

        let prompt = self
            .build_stage_prompt(key, project, workspace, cycle_id, stage, round)
            .await?;

        let model = profile.model.as_ref().map(|m| AiModelSelection {
            provider_id: m.provider_id.clone(),
            model_id: m.model_id.clone(),
        });
        let mode = profile.mode.clone();

        let mut stream = agent
            .send_message(&directory, &session.id, &prompt, None, None, model, mode)
            .await?;

        let mut judge_pass = true;
        loop {
            let next = timeout(Duration::from_secs(MAX_STAGE_RUNTIME_SECS), stream.next()).await;
            match next {
                Ok(Some(Ok(event))) => match event {
                    crate::ai::AiEvent::Done => break,
                    crate::ai::AiEvent::Error { message } => {
                        return Err(format!("stage stream error: {}", message));
                    }
                    crate::ai::AiEvent::PartUpdated { part, .. } => {
                        if stage == "judge" {
                            if let Some(text) = part.text {
                                let normalized = text.to_lowercase();
                                if normalized.contains("\"result\":\"fail\"")
                                    || normalized.contains("result: fail")
                                {
                                    judge_pass = false;
                                }
                            }
                        }
                    }
                    _ => {}
                },
                Ok(Some(Err(err))) => return Err(err),
                Ok(None) => break,
                Err(_) => return Err("stage stream timeout".to_string()),
            }
        }

        self.set_stage_status(key, stage, "done").await;
        self.persist_stage_file(key, stage, "done", Some(&session.id), None)
            .await
            .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "agent").await;

        Ok(judge_pass)
    }

    pub(super) async fn after_stage_success(
        &self,
        key: &str,
        stage: &str,
        judge_pass: bool,
        ctx: &HandlerContext,
    ) -> bool {
        let mut emit_judge: Option<(String, String, String, String)> = None;
        let mut stage_changed: Option<(String, String, String, String)> = None;
        let mut auto_next_cycle = false;

        {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return false;
            };

            let previous = entry.current_stage.clone();
            let mut next_stage = previous.clone();

            match stage {
                "bootstrap" => next_stage = "direction".to_string(),
                "direction" => next_stage = "plan".to_string(),
                "plan" => next_stage = "implement".to_string(),
                "implement" => next_stage = "verify".to_string(),
                "verify" => next_stage = "judge".to_string(),
                "judge" => {
                    if judge_pass {
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "pass".to_string(),
                        ));
                        next_stage = "report".to_string();
                    } else if entry.verify_iteration + 1 < entry.verify_iteration_limit {
                        entry.verify_iteration += 1;
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "fail".to_string(),
                        ));
                        next_stage = "implement".to_string();
                    } else {
                        entry.status = "failed_exhausted".to_string();
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "fail".to_string(),
                        ));
                        next_stage = "report".to_string();
                    }
                }
                "report" => {
                    entry.status = "completed".to_string();
                    if entry.auto_loop_enabled {
                        entry.global_loop_round += 1;
                        entry.verify_iteration = 0;
                        entry.cycle_id = format!(
                            "{}_{}_{}_{}",
                            Utc::now().format("%Y-%m-%dT%H-%M-%SZ"),
                            sanitize_name(&entry.project),
                            sanitize_name(&entry.workspace),
                            Uuid::new_v4().simple()
                        );
                        entry.current_stage = "bootstrap".to_string();
                        entry.status = "queued".to_string();
                        entry.stage_sessions.clear();
                        entry.stage_statuses.clear();
                        for s in STAGES {
                            entry
                                .stage_statuses
                                .insert(s.to_string(), "pending".to_string());
                        }
                        auto_next_cycle = true;
                        stage_changed = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            entry.current_stage.clone(),
                        ));
                    }
                }
                _ => {}
            }

            if stage != "report" {
                entry.current_stage = next_stage.clone();
                stage_changed = Some((
                    entry.project.clone(),
                    entry.workspace.clone(),
                    entry.cycle_id.clone(),
                    next_stage,
                ));
            }
        }

        if let Some((project, workspace, cycle_id, result)) = emit_judge {
            self.broadcast(
                ctx,
                ServerMessage::EvoJudgeResult {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "agent".to_string(),
                    result: result.clone(),
                    reason: if result == "pass" {
                        "judge pass".to_string()
                    } else {
                        "judge fail".to_string()
                    },
                    next_action: if result == "pass" {
                        "goto_stage:report".to_string()
                    } else {
                        "goto_stage:implement".to_string()
                    },
                },
            )
            .await;
        }

        if let Some((project, workspace, cycle_id, to_stage)) = stage_changed {
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
                    from_stage: stage.to_string(),
                    to_stage,
                    verify_iteration: self
                        .state
                        .lock()
                        .await
                        .workspaces
                        .get(key)
                        .map(|v| v.verify_iteration)
                        .unwrap_or(0),
                },
            )
            .await;
        }

        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;
        self.broadcast_scheduler(ctx).await;
        auto_next_cycle
    }

    pub(super) async fn mark_interrupted(&self, key: &str, ctx: &HandlerContext) {
        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "interrupted".to_string();
            entry.stop_requested = true;
            Some((
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
            ))
        };

        if let Some((project, workspace, cycle_id)) = maybe {
            self.persist_cycle_file(key).await.ok();
            self.broadcast(
                ctx,
                ServerMessage::EvoWorkspaceStopped {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "system".to_string(),
                    status: "interrupted".to_string(),
                    reason: Some("stop_requested".to_string()),
                },
            )
            .await;
            self.broadcast_scheduler(ctx).await;
            self.broadcast_cycle_update(key, ctx, "system").await;
        }
    }

    pub(super) async fn mark_failed_system(&self, key: &str, err: &str, ctx: &HandlerContext) {
        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "failed_system".to_string();
            Some((
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
            ))
        };

        if let Some((project, workspace, cycle_id)) = maybe {
            self.persist_cycle_file(key).await.ok();
            self.broadcast(
                ctx,
                ServerMessage::EvoError {
                    event_id: Some(Uuid::new_v4().to_string()),
                    event_seq: Some(self.next_seq(key).await),
                    project: Some(project),
                    workspace: Some(workspace),
                    cycle_id: Some(cycle_id),
                    ts: Utc::now().to_rfc3339(),
                    source: "system".to_string(),
                    code: "evo_internal_error".to_string(),
                    message: err.to_string(),
                    context: None,
                },
            )
            .await;
            self.broadcast_cycle_update(key, ctx, "system").await;
            self.broadcast_scheduler(ctx).await;
        }
    }
}
