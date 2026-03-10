use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use crate::server::ws::OutboundTx as WebSocket;
use tokio::sync::{Mutex, Semaphore};
use tokio::task::JoinHandle;
use tokio::time::Duration;

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};

static EVOLUTION_MANAGER: OnceLock<Arc<EvolutionManager>> = OnceLock::new();

mod blocker;
mod broadcast;
mod consts;
mod manager_persistence;
mod manager_stage;
mod manager_worker;
mod profile;
mod profile_control;
mod route;
mod sequence_state;
mod stage;
mod types;
mod utils;
mod workspace_control;

use consts::{
    BACKLOG_CONTRACT_VERSION_V2, DEFAULT_LOOP_ROUND_LIMIT, DEFAULT_MAX_PARALLEL,
    DEFAULT_VERIFY_LIMIT, MAX_STAGE_RUNTIME_SECS, STAGES,
};
use types::{EvolutionState, SnapshotResult, StageSession, StartWorkspaceReq, WorkspaceRunState};

pub async fn handle_evolution_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    route::handle_message(client_msg, socket, ctx).await
}

pub(crate) async fn query_evolution_snapshot(
    project: Option<&str>,
    workspace: Option<&str>,
    ctx: &HandlerContext,
) -> Result<ServerMessage, String> {
    let Some(manager) = maybe_manager() else {
        return Err("evolution manager init failed".to_string());
    };
    let mut snapshot = manager.build_snapshot(ctx).await;
    if project.is_some() || workspace.is_some() {
        crate::server::perf::record_evolution_snapshot_fallback();
        snapshot.workspace_items.retain(|item| {
            let project_match = project.map(|value| item.project == value).unwrap_or(true);
            let workspace_match = workspace
                .map(|value| item.workspace == value)
                .unwrap_or(true);
            project_match && workspace_match
        });
    }
    Ok(ServerMessage::EvoSnapshot {
        scheduler: snapshot.scheduler,
        workspace_items: snapshot.workspace_items,
    })
}

pub(crate) async fn query_evolution_agent_profile(
    project: &str,
    workspace: &str,
    ctx: &HandlerContext,
) -> Result<ServerMessage, String> {
    let Some(manager) = maybe_manager() else {
        return Err("evolution manager init failed".to_string());
    };
    let saved = manager.get_agent_profile(project, workspace, ctx).await;
    Ok(ServerMessage::EvoAgentProfile {
        project: project.to_string(),
        workspace: workspace.to_string(),
        stage_profiles: saved,
    })
}

pub(crate) async fn query_evolution_cycle_history(
    project: &str,
    workspace: &str,
    ctx: &HandlerContext,
) -> Result<ServerMessage, String> {
    let Some(manager) = maybe_manager() else {
        return Err("evolution manager init failed".to_string());
    };
    let cycles = manager.list_cycle_history(project, workspace, ctx).await?;
    Ok(ServerMessage::EvoCycleHistory {
        project: project.to_string(),
        workspace: workspace.to_string(),
        cycles,
    })
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
    debounced_cycle_update_tasks: Arc<Mutex<HashMap<String, JoinHandle<()>>>>,
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
            debounced_cycle_update_tasks: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    async fn cancel_debounced_cycle_update(&self, key: &str) {
        let mut tasks = self.debounced_cycle_update_tasks.lock().await;
        if let Some(handle) = tasks.remove(key) {
            handle.abort();
        }
    }

    fn cycle_update_debounce_window() -> Duration {
        Duration::from_millis(250)
    }
}

fn is_active_workspace_status(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "queued" | "running" | "pending" | "in_progress" | "processing"
    )
}

pub async fn has_active_workspace(project: &str, workspace: &str) -> bool {
    let Some(manager) = maybe_manager() else {
        return false;
    };
    let key = utils::workspace_key(project, workspace);
    let state = manager.state.lock().await;
    state
        .workspaces
        .get(&key)
        .map(|entry| is_active_workspace_status(&entry.status))
        .unwrap_or(false)
}
