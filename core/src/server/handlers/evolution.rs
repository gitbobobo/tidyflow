use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use axum::extract::ws::WebSocket;
use chrono::Utc;
use tokio::sync::{Mutex, Semaphore};
use tokio::task::JoinHandle;
use tracing::{info, warn};
use uuid::Uuid;

use crate::server::context::HandlerContext;
use crate::server::handlers::ai::resolve_directory;
use crate::server::protocol::{
    ClientMessage, EvolutionSchedulerInfo, EvolutionStageProfileInfo, EvolutionWorkspaceItem,
    ServerMessage,
};

const STAGES: [&str; 7] = [
    "bootstrap",
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

mod manager_persistence;
mod manager_pipeline;
mod manager_runtime;
mod profile;
mod route;
mod stage;
mod utils;

use profile::{
    default_stage_profiles, from_persisted_profiles, normalize_profiles,
    normalize_profiles_lenient, profile_key, profile_legacy_keys, to_persisted_profiles,
};
use stage::{active_agents, build_agents};
use utils::{sanitize_name, workspace_key};

pub async fn handle_evolution_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    route::handle_message(client_msg, socket, ctx).await
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
    workspace_root: String,
    priority: i32,
    status: String,
    cycle_id: String,
    current_stage: String,
    global_loop_round: u32,
    auto_loop_enabled: bool,
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
    auto_loop_enabled: bool,
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
        let workspace_root =
            resolve_directory(&ctx.app_state, &req.project, &req.workspace).await?;

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
                    workspace_root: workspace_root.clone(),
                    priority: req.priority,
                    status: "queued".to_string(),
                    cycle_id: cycle_id.clone(),
                    current_stage: "bootstrap".to_string(),
                    global_loop_round: round,
                    auto_loop_enabled: req.auto_loop_enabled,
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
        let legacy_keys = profile_legacy_keys(project, workspace);
        {
            let mut state = ctx.app_state.write().await;
            state
                .client_settings
                .evolution_agent_profiles
                .insert(storage_key, to_persisted_profiles(&normalized));
            for legacy in legacy_keys {
                state
                    .client_settings
                    .evolution_agent_profiles
                    .remove(&legacy);
            }
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

        let direction_model = normalized
            .iter()
            .find(|item| item.stage == "direction")
            .and_then(|item| item.model.as_ref())
            .map(|m| format!("{}/{}", m.provider_id, m.model_id))
            .unwrap_or_else(|| "default".to_string());
        info!(
            "evolution profile updated: project={}, workspace={}, stages={}, direction_model={}",
            project,
            workspace,
            normalized.len(),
            direction_model
        );

        Ok(normalized)
    }

    async fn get_agent_profile(
        &self,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Vec<EvolutionStageProfileInfo> {
        let storage_key = profile_key(project, workspace);
        let legacy_keys = profile_legacy_keys(project, workspace);
        let (profile_source, from_state) = {
            let state = ctx.app_state.read().await;
            let canonical = state
                .client_settings
                .evolution_agent_profiles
                .get(&storage_key)
                .cloned();
            if let Some(found) = canonical {
                ("canonical", found)
            } else {
                let legacy = legacy_keys
                    .into_iter()
                    .find_map(|key| {
                        state
                            .client_settings
                            .evolution_agent_profiles
                            .get(&key)
                            .cloned()
                    })
                    .unwrap_or_default();
                let source = if legacy.is_empty() {
                    "default"
                } else {
                    "legacy"
                };
                (source, legacy)
            }
        };

        let profiles = if from_state.is_empty() {
            default_stage_profiles()
        } else {
            normalize_profiles_lenient(from_persisted_profiles(from_state))
        };

        let direction_model = profiles
            .iter()
            .find(|item| item.stage == "direction")
            .and_then(|item| item.model.as_ref())
            .map(|m| format!("{}/{}", m.provider_id, m.model_id))
            .unwrap_or_else(|| "default".to_string());
        info!(
            "evolution profile loaded: project={}, workspace={}, source={}, stages={}, direction_model={}",
            project,
            workspace,
            profile_source,
            profiles.len(),
            direction_model
        );

        profiles
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
                auto_loop_enabled: w.auto_loop_enabled,
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
}
