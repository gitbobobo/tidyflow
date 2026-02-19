use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use axum::extract::ws::WebSocket;
use chrono::Utc;
use futures::StreamExt;
use tokio::sync::{Mutex, Semaphore};
use tokio::task::JoinHandle;
use tokio::time::{sleep, timeout, Duration};
use tracing::{error, warn};
use uuid::Uuid;

use crate::ai::AiModelSelection;
use crate::server::context::{HandlerContext, TaskBroadcastEvent};
use crate::server::handlers::ai::{ensure_agent, normalize_ai_tool, resolve_directory};
use crate::server::handlers::evolution_prompts::{
    STAGE_DIRECTION_PROMPT, STAGE_IMPLEMENT_PROMPT, STAGE_JUDGE_PROMPT, STAGE_PLAN_PROMPT,
    STAGE_REPORT_PROMPT, STAGE_VERIFY_PROMPT,
};
use crate::server::protocol::{
    ai, ClientMessage, EvolutionAgentInfo, EvolutionSchedulerInfo, EvolutionStageProfileInfo,
    EvolutionWorkspaceItem, ServerMessage,
};
use crate::server::ws::send_message;
use crate::workspace::state::{EvolutionModelSelection, EvolutionStageProfile};

const STAGES: [&str; 6] = [
    "direction",
    "plan",
    "implement",
    "verify",
    "judge",
    "report",
];
const MAX_STAGE_RUNTIME_SECS: u64 = 600;
const DEFAULT_VERIFY_LIMIT: u32 = 3;
const DEFAULT_MAX_PARALLEL: u32 = 4;

static EVOLUTION_MANAGER: OnceLock<Arc<EvolutionManager>> = OnceLock::new();

pub async fn handle_evolution_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    let Some(manager) = maybe_manager() else {
        return Err("evolution manager init failed".to_string());
    };

    match client_msg {
        ClientMessage::EvoStartWorkspace {
            project,
            workspace,
            priority,
            max_verify_iterations,
            stage_profiles,
        } => {
            let req = StartWorkspaceReq {
                project: project.clone(),
                workspace: workspace.clone(),
                priority: *priority,
                max_verify_iterations: max_verify_iterations.unwrap_or(DEFAULT_VERIFY_LIMIT),
                stage_profiles: stage_profiles.clone(),
            };
            manager.start_workspace(req, ctx).await?;
            let snapshot = manager.build_snapshot().await;
            send_message(
                socket,
                &ServerMessage::EvoSnapshot {
                    scheduler: snapshot.scheduler,
                    workspace_items: snapshot.workspace_items,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoStopWorkspace {
            project,
            workspace,
            reason,
        } => {
            manager
                .stop_workspace(project, workspace, reason.clone(), ctx)
                .await?;
            let snapshot = manager.build_snapshot().await;
            send_message(
                socket,
                &ServerMessage::EvoSnapshot {
                    scheduler: snapshot.scheduler,
                    workspace_items: snapshot.workspace_items,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoStopAll { reason } => {
            manager.stop_all(reason.clone(), ctx).await;
            let snapshot = manager.build_snapshot().await;
            send_message(
                socket,
                &ServerMessage::EvoSnapshot {
                    scheduler: snapshot.scheduler,
                    workspace_items: snapshot.workspace_items,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoResumeWorkspace { project, workspace } => {
            manager.resume_workspace(project, workspace, ctx).await?;
            let snapshot = manager.build_snapshot().await;
            send_message(
                socket,
                &ServerMessage::EvoSnapshot {
                    scheduler: snapshot.scheduler,
                    workspace_items: snapshot.workspace_items,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoGetSnapshot { .. } => {
            let snapshot = manager.build_snapshot().await;
            send_message(
                socket,
                &ServerMessage::EvoSnapshot {
                    scheduler: snapshot.scheduler,
                    workspace_items: snapshot.workspace_items,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoOpenStageChat {
            project,
            workspace,
            cycle_id,
            stage,
        } => {
            match manager
                .open_stage_chat(project, workspace, cycle_id, stage)
                .await
            {
                Some((ai_tool, session_id)) => {
                    send_message(
                        socket,
                        &ServerMessage::EvoStageChatOpened {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            cycle_id: cycle_id.clone(),
                            stage: stage.clone(),
                            ai_tool,
                            session_id,
                        },
                    )
                    .await?;
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::EvoError {
                            event_id: None,
                            event_seq: None,
                            project: Some(project.clone()),
                            workspace: Some(workspace.clone()),
                            cycle_id: Some(cycle_id.clone()),
                            ts: Utc::now().to_rfc3339(),
                            source: "system".to_string(),
                            code: "evo_chat_session_not_found".to_string(),
                            message: format!("stage '{}' session not found", stage),
                            context: None,
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }
        ClientMessage::EvoUpdateAgentProfile {
            project,
            workspace,
            stage_profiles,
        } => {
            let saved = manager
                .update_agent_profile(project, workspace, stage_profiles.clone(), ctx)
                .await?;
            send_message(
                socket,
                &ServerMessage::EvoAgentProfile {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    stage_profiles: saved,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoGetAgentProfile { project, workspace } => {
            let saved = manager.get_agent_profile(project, workspace, ctx).await;
            send_message(
                socket,
                &ServerMessage::EvoAgentProfile {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    stage_profiles: saved,
                },
            )
            .await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

fn maybe_manager() -> Option<Arc<EvolutionManager>> {
    let manager = EVOLUTION_MANAGER.get_or_init(|| Arc::new(EvolutionManager::new()));
    Some(manager.clone())
}

#[derive(Clone)]
struct EvolutionManager {
    state: Arc<Mutex<EvolutionState>>,
    workers: Arc<Mutex<HashMap<String, JoinHandle<()>>>>,
    semaphore: Arc<Semaphore>,
}

struct EvolutionState {
    activation_state: String,
    max_parallel_workspaces: u32,
    seq_by_workspace: HashMap<String, u64>,
    workspaces: HashMap<String, WorkspaceRunState>,
}

#[derive(Clone)]
struct WorkspaceRunState {
    project: String,
    workspace: String,
    priority: i32,
    status: String,
    cycle_id: String,
    current_stage: String,
    global_loop_round: u32,
    verify_iteration: u32,
    verify_iteration_limit: u32,
    stop_requested: bool,
    stage_profiles: Vec<EvolutionStageProfileInfo>,
    stage_statuses: HashMap<String, String>,
    stage_sessions: HashMap<String, StageSession>,
}

#[derive(Clone)]
struct StageSession {
    ai_tool: String,
    session_id: String,
}

#[derive(Clone)]
struct StartWorkspaceReq {
    project: String,
    workspace: String,
    priority: i32,
    max_verify_iterations: u32,
    stage_profiles: Vec<EvolutionStageProfileInfo>,
}

struct SnapshotResult {
    scheduler: EvolutionSchedulerInfo,
    workspace_items: Vec<EvolutionWorkspaceItem>,
}

impl EvolutionManager {
    fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(EvolutionState {
                activation_state: "idle".to_string(),
                max_parallel_workspaces: DEFAULT_MAX_PARALLEL,
                seq_by_workspace: HashMap::new(),
                workspaces: HashMap::new(),
            })),
            workers: Arc::new(Mutex::new(HashMap::new())),
            semaphore: Arc::new(Semaphore::new(DEFAULT_MAX_PARALLEL as usize)),
        }
    }

    async fn start_workspace(
        &self,
        req: StartWorkspaceReq,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let key = workspace_key(&req.project, &req.workspace);

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
            normalize_profiles(req.stage_profiles)?
        };

        let now = Utc::now();
        let cycle_id = format!(
            "{}_{}_{}_{}",
            now.format("%Y-%m-%dT%H-%M-%SZ"),
            sanitize_name(&req.project),
            sanitize_name(&req.workspace),
            Uuid::new_v4().simple()
        );

        let mut stage_statuses = HashMap::new();
        for stage in STAGES {
            stage_statuses.insert(stage.to_string(), "pending".to_string());
        }

        let global_loop_round = {
            let mut state = self.state.lock().await;
            state.activation_state = "activated".to_string();
            let prev_round = state
                .workspaces
                .get(&key)
                .map(|v| v.global_loop_round)
                .unwrap_or(0);
            let round = prev_round + 1;
            state.workspaces.insert(
                key.clone(),
                WorkspaceRunState {
                    project: req.project.clone(),
                    workspace: req.workspace.clone(),
                    priority: req.priority,
                    status: "queued".to_string(),
                    cycle_id: cycle_id.clone(),
                    current_stage: "direction".to_string(),
                    global_loop_round: round,
                    verify_iteration: 0,
                    verify_iteration_limit: req.max_verify_iterations.max(1),
                    stop_requested: false,
                    stage_profiles,
                    stage_statuses,
                    stage_sessions: HashMap::new(),
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

    async fn stop_workspace(
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

    async fn stop_all(&self, reason: Option<String>, ctx: &HandlerContext) {
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

    async fn resume_workspace(
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

        let cycle_id = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(&key) else {
                return Err(format!("evo_cycle_not_found: {}", key));
            };
            if entry.status != "interrupted" && entry.status != "stopped" {
                return Err(format!("evo_resume_not_allowed: {}", entry.status));
            }
            entry.stop_requested = false;
            entry.status = "queued".to_string();
            entry.cycle_id.clone()
        };

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

    async fn open_stage_chat(
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

    async fn update_agent_profile(
        &self,
        project: &str,
        workspace: &str,
        stage_profiles: Vec<EvolutionStageProfileInfo>,
        ctx: &HandlerContext,
    ) -> Result<Vec<EvolutionStageProfileInfo>, String> {
        let normalized = normalize_profiles(stage_profiles)?;
        let storage_key = profile_key(project, workspace);
        {
            let mut state = ctx.app_state.write().await;
            state
                .client_settings
                .evolution_agent_profiles
                .insert(storage_key, to_persisted_profiles(&normalized));
        }
        let _ = ctx.save_tx.send(()).await;

        // 当前 workspace 若未运行，实时更新默认配置；运行中保持 cycle 快照不变。
        let key = workspace_key(project, workspace);
        {
            let mut state = self.state.lock().await;
            if let Some(entry) = state.workspaces.get_mut(&key) {
                if entry.status != "running" && entry.status != "queued" {
                    entry.stage_profiles = normalized.clone();
                }
            }
        }

        Ok(normalized)
    }

    async fn get_agent_profile(
        &self,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Vec<EvolutionStageProfileInfo> {
        let storage_key = profile_key(project, workspace);
        let from_state = {
            let state = ctx.app_state.read().await;
            state
                .client_settings
                .evolution_agent_profiles
                .get(&storage_key)
                .cloned()
                .unwrap_or_default()
        };

        if from_state.is_empty() {
            default_stage_profiles()
        } else {
            match normalize_profiles(from_persisted_profiles(from_state)) {
                Ok(profiles) => profiles,
                Err(err) => {
                    warn!(
                        "invalid persisted evolution profiles, fallback to default: project={}, workspace={}, error={}",
                        project, workspace, err
                    );
                    default_stage_profiles()
                }
            }
        }
    }

    async fn build_snapshot(&self) -> SnapshotResult {
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

        let mut workspace_items: Vec<EvolutionWorkspaceItem> = state
            .workspaces
            .values()
            .map(|w| EvolutionWorkspaceItem {
                project: w.project.clone(),
                workspace: w.workspace.clone(),
                cycle_id: w.cycle_id.clone(),
                status: w.status.clone(),
                current_stage: w.current_stage.clone(),
                global_loop_round: w.global_loop_round,
                verify_iteration: w.verify_iteration,
                verify_iteration_limit: w.verify_iteration_limit,
                agents: build_agents(&w.stage_statuses),
                active_agents: active_agents(&w.stage_statuses),
            })
            .collect();
        workspace_items.sort_by(|a, b| {
            (a.project.clone(), a.workspace.clone()).cmp(&(b.project.clone(), b.workspace.clone()))
        });

        SnapshotResult {
            scheduler: EvolutionSchedulerInfo {
                activation_state: state.activation_state.clone(),
                max_parallel_workspaces: state.max_parallel_workspaces,
                running_count,
                queued_count,
            },
            workspace_items,
        }
    }

    async fn spawn_worker(&self, key: String, preferred_round: u32, ctx: HandlerContext) {
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

    async fn run_workspace(&self, key: String, preferred_round: u32, ctx: HandlerContext) {
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

            // 简单优先级调度：仅在不存在更高优先级待运行工作空间时抢占并发槽位。
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
                        // true 表示 cycle 完成并自动进入下一轮，继续循环
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

            let stop_now = {
                let state = self.state.lock().await;
                state
                    .workspaces
                    .get(&key)
                    .map(|w| w.stop_requested)
                    .unwrap_or(true)
            };
            if stop_now {
                self.mark_interrupted(&key, &ctx).await;
                return;
            }
        }
    }

    async fn run_stage(
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

    async fn after_stage_success(
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
                    // 自动续轮：人工启动后自动调度
                    entry.global_loop_round += 1;
                    entry.verify_iteration = 0;
                    entry.cycle_id = format!(
                        "{}_{}_{}_{}",
                        Utc::now().format("%Y-%m-%dT%H-%M-%SZ"),
                        sanitize_name(&entry.project),
                        sanitize_name(&entry.workspace),
                        Uuid::new_v4().simple()
                    );
                    entry.current_stage = "direction".to_string();
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

    async fn mark_interrupted(&self, key: &str, ctx: &HandlerContext) {
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

    async fn mark_failed_system(&self, key: &str, err: &str, ctx: &HandlerContext) {
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

    async fn set_stage_status(&self, key: &str, stage: &str, status: &str) {
        let mut state = self.state.lock().await;
        if let Some(entry) = state.workspaces.get_mut(key) {
            entry
                .stage_statuses
                .insert(stage.to_string(), status.to_string());
        }
    }

    async fn set_stage_session(&self, key: &str, stage: &str, ai_tool: &str, session_id: &str) {
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

    async fn next_seq(&self, key: &str) -> u64 {
        let mut state = self.state.lock().await;
        let seq = state.seq_by_workspace.entry(key.to_string()).or_insert(0);
        *seq += 1;
        *seq
    }

    async fn broadcast_cycle_update(&self, key: &str, ctx: &HandlerContext, source: &str) {
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

    async fn broadcast_scheduler(&self, ctx: &HandlerContext) {
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

    async fn broadcast(&self, ctx: &HandlerContext, message: ServerMessage) {
        let _ = ctx.task_broadcast_tx.send(TaskBroadcastEvent {
            origin_conn_id: "evolution_orchestrator".to_string(),
            message,
        });
    }

    async fn can_run_with_priority(&self, key: &str) -> bool {
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

    async fn persist_cycle_file(&self, key: &str) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.project, &entry.workspace, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;

        let mut stage_files = serde_json::Map::new();
        for stage in STAGES {
            stage_files.insert(
                stage.to_string(),
                serde_json::Value::String(format!("stage.{}.json", stage)),
            );
        }

        let payload = serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": entry.cycle_id,
            "project": entry.project,
            "workspace": entry.workspace,
            "status": entry.status,
            "current_stage": entry.current_stage,
            "pipeline": STAGES,
            "verify_iteration": entry.verify_iteration,
            "verify_iteration_limit": entry.verify_iteration_limit,
            "global_loop_round": entry.global_loop_round,
            "interrupt": {
                "requested": entry.stop_requested,
                "requested_by": if entry.stop_requested { "user" } else { "" },
                "requested_at": if entry.stop_requested { Utc::now().to_rfc3339() } else { "".to_string() },
                "reason": if entry.stop_requested { "manual stop" } else { "" }
            },
            "direction": {
                "selected_type": "architecture",
                "candidate_scores": [],
                "final_reason": "evolution auto scheduler"
            },
            "llm_defined_acceptance": {
                "criteria": [],
                "minimum_evidence_policy": {
                    "strategy": "llm_decided",
                    "description": "auto"
                }
            },
            "stage_files": stage_files,
            "chat_map_file": "chat.map.json",
            "evidence_index_file": "evidence.index.json",
            "handoff_file": "handoff.md",
            "created_at": Utc::now().to_rfc3339(),
            "updated_at": Utc::now().to_rfc3339(),
        });

        write_json(&cycle_dir.join("cycle.json"), &payload)
    }

    async fn persist_stage_file(
        &self,
        key: &str,
        stage: &str,
        status: &str,
        session_id: Option<&str>,
        error_message: Option<&str>,
    ) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.project, &entry.workspace, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;

        let payload = serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": entry.cycle_id,
            "stage": stage,
            "agent": agent_name(stage),
            "status": status,
            "inputs": [
                {"type": "prompt", "path": prompt_id_for_stage(stage).unwrap_or_default()}
            ],
            "outputs": if let Some(sid) = session_id {
                serde_json::json!([
                    {"type": "chat_session", "session_id": sid}
                ])
            } else {
                serde_json::json!([])
            },
            "decision": {
                "result": if stage == "judge" && status == "done" { "pass" } else { "n/a" },
                "reason": ""
            },
            "next_action": {
                "type": "goto_stage",
                "target": next_stage(stage).unwrap_or("none")
            },
            "timing": {
                "started_at": Utc::now().to_rfc3339(),
                "completed_at": if status == "done" { Utc::now().to_rfc3339() } else { "".to_string() },
                "duration_ms": if status == "done" { serde_json::json!(0) } else { serde_json::Value::Null }
            },
            "error": error_message.map(|e| serde_json::json!({"message": e}))
        });

        write_json(&cycle_dir.join(format!("stage.{}.json", stage)), &payload)
    }

    async fn persist_chat_map(&self, key: &str) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.project, &entry.workspace, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;

        let mut session_rows: Vec<(String, StageSession)> = entry
            .stage_sessions
            .iter()
            .map(|(stage, session)| (stage.clone(), session.clone()))
            .collect();
        session_rows.sort_by(|a, b| a.0.cmp(&b.0));
        let sessions: Vec<serde_json::Value> = session_rows
            .into_iter()
            .map(|(stage, session)| {
                serde_json::json!({
                    "stage": stage,
                    "ai_tool": session.ai_tool,
                    "session_id": session.session_id,
                })
            })
            .collect();

        let payload = serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": entry.cycle_id,
            "project": entry.project,
            "workspace": entry.workspace,
            "sessions": sessions,
            "updated_at": Utc::now().to_rfc3339(),
        });

        write_json(&cycle_dir.join("chat.map.json"), &payload)
    }

    async fn build_stage_prompt(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        round: u32,
    ) -> Result<String, String> {
        let prompt_body = prompt_template_for_stage(stage)
            .ok_or_else(|| format!("unknown stage prompt template: {}", stage))?;

        let (verify_iteration, verify_iteration_limit) = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            (entry.verify_iteration, entry.verify_iteration_limit)
        };

        let cycle_dir = cycle_dir_path(project, workspace, cycle_id)?;
        let stage_file = cycle_dir.join(format!("stage.{}.json", stage));
        let context = serde_json::json!({
            "PROJECT": project,
            "WORKSPACE": workspace,
            "CYCLE_ID": cycle_id,
            "GLOBAL_LOOP_ROUND": round,
            "CURRENT_STAGE": stage,
            "VERIFY_ITERATION": verify_iteration,
            "VERIFY_ITERATION_LIMIT": verify_iteration_limit,
            "CYCLE_DIR": cycle_dir,
            "STAGE_FILE_PATH": stage_file,
            "EVIDENCE_INDEX_PATH": cycle_dir.join("evidence.index.json"),
            "CHAT_MAP_PATH": cycle_dir.join("chat.map.json"),
            "WORKSPACE_ROOT": "由程序注入，禁止自行推断",
        });

        Ok(format!(
            "{}\n\n---\n\n## 程序注入上下文（请直接使用，禁止自行推断路径）\n```json\n{}\n```\n",
            prompt_body,
            serde_json::to_string_pretty(&context).unwrap_or_else(|_| "{}".to_string())
        ))
    }
}

fn default_evolution_ai_tool() -> String {
    "codex".to_string()
}

fn normalize_profiles(
    input: Vec<EvolutionStageProfileInfo>,
) -> Result<Vec<EvolutionStageProfileInfo>, String> {
    let mut by_stage: HashMap<String, EvolutionStageProfileInfo> = HashMap::new();
    for profile in input {
        let stage = profile.stage.trim().to_lowercase();
        if STAGES.contains(&stage.as_str()) {
            let ai_tool = normalize_ai_tool(&profile.ai_tool).map_err(|_| {
                format!("invalid ai_tool for stage '{}': {}", stage, profile.ai_tool)
            })?;
            by_stage.insert(
                stage.clone(),
                EvolutionStageProfileInfo {
                    stage,
                    ai_tool,
                    mode: profile.mode,
                    model: profile.model,
                },
            );
        }
    }

    let mut result = Vec::with_capacity(STAGES.len());
    for stage in STAGES {
        result.push(by_stage.remove(stage).unwrap_or(EvolutionStageProfileInfo {
            stage: stage.to_string(),
            ai_tool: default_evolution_ai_tool(),
            mode: None,
            model: None,
        }));
    }
    Ok(result)
}

fn default_stage_profiles() -> Vec<EvolutionStageProfileInfo> {
    STAGES
        .iter()
        .map(|stage| EvolutionStageProfileInfo {
            stage: stage.to_string(),
            ai_tool: default_evolution_ai_tool(),
            mode: None,
            model: None,
        })
        .collect()
}

fn profile_for_stage(
    profiles: &[EvolutionStageProfileInfo],
    stage: &str,
) -> EvolutionStageProfileInfo {
    profiles
        .iter()
        .find(|p| p.stage == stage)
        .cloned()
        .unwrap_or(EvolutionStageProfileInfo {
            stage: stage.to_string(),
            ai_tool: default_evolution_ai_tool(),
            mode: None,
            model: None,
        })
}

fn to_persisted_profiles(input: &[EvolutionStageProfileInfo]) -> Vec<EvolutionStageProfile> {
    input
        .iter()
        .map(|p| EvolutionStageProfile {
            stage: p.stage.clone(),
            ai_tool: p.ai_tool.clone(),
            mode: p.mode.clone(),
            model: p.model.as_ref().map(|m| EvolutionModelSelection {
                provider_id: m.provider_id.clone(),
                model_id: m.model_id.clone(),
            }),
        })
        .collect()
}

fn from_persisted_profiles(input: Vec<EvolutionStageProfile>) -> Vec<EvolutionStageProfileInfo> {
    input
        .into_iter()
        .map(|p| EvolutionStageProfileInfo {
            stage: p.stage,
            ai_tool: p.ai_tool,
            mode: p.mode,
            model: p.model.map(|m| ai::ModelSelection {
                provider_id: m.provider_id,
                model_id: m.model_id,
            }),
        })
        .collect()
}

fn build_agents(stage_statuses: &HashMap<String, String>) -> Vec<EvolutionAgentInfo> {
    let mut agents = Vec::with_capacity(STAGES.len());
    for stage in STAGES {
        let status = stage_statuses
            .get(stage)
            .cloned()
            .unwrap_or_else(|| "pending".to_string());
        agents.push(EvolutionAgentInfo {
            stage: stage.to_string(),
            agent: agent_name(stage).to_string(),
            status,
        });
    }
    agents
}

fn active_agents(stage_statuses: &HashMap<String, String>) -> Vec<String> {
    STAGES
        .iter()
        .filter_map(|stage| {
            let status = stage_statuses
                .get(*stage)
                .map(|v| v.as_str())
                .unwrap_or("pending");
            if status == "running" {
                Some(agent_name(stage).to_string())
            } else {
                None
            }
        })
        .collect()
}

fn agent_name(stage: &str) -> &'static str {
    match stage {
        "direction" => "DirectionAgent",
        "plan" => "PlanAgent",
        "implement" => "ImplementAgent",
        "verify" => "VerifyAgent",
        "judge" => "JudgeAgent",
        "report" => "ReportAgent",
        _ => "UnknownAgent",
    }
}

fn next_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some("plan"),
        "plan" => Some("implement"),
        "implement" => Some("verify"),
        "verify" => Some("judge"),
        "judge" => Some("report"),
        "report" => Some("direction"),
        _ => None,
    }
}

fn prompt_template_for_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some(STAGE_DIRECTION_PROMPT),
        "plan" => Some(STAGE_PLAN_PROMPT),
        "implement" => Some(STAGE_IMPLEMENT_PROMPT),
        "verify" => Some(STAGE_VERIFY_PROMPT),
        "judge" => Some(STAGE_JUDGE_PROMPT),
        "report" => Some(STAGE_REPORT_PROMPT),
        _ => None,
    }
}

fn prompt_id_for_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some("builtin://evolution/stage.direction.prompt"),
        "plan" => Some("builtin://evolution/stage.plan.prompt"),
        "implement" => Some("builtin://evolution/stage.implement.prompt"),
        "verify" => Some("builtin://evolution/stage.verify.prompt"),
        "judge" => Some("builtin://evolution/stage.judge.prompt"),
        "report" => Some("builtin://evolution/stage.report.prompt"),
        _ => None,
    }
}

fn write_json(path: &Path, value: &serde_json::Value) -> Result<(), String> {
    let data = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    std::fs::write(path, data).map_err(|e| e.to_string())
}

fn cycle_dir_path(project: &str, workspace: &str, cycle_id: &str) -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "home directory not found".to_string())?;
    Ok(home
        .join(".tidyflow")
        .join("evolution")
        .join(sanitize_name(project))
        .join(sanitize_name(workspace))
        .join(cycle_id))
}

fn sanitize_name(raw: &str) -> String {
    raw.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>()
}

fn workspace_key(project: &str, workspace: &str) -> String {
    format!("{}:{}", project, workspace)
}

fn profile_key(project: &str, workspace: &str) -> String {
    format!("{}/{}", project, workspace)
}
