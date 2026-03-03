use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use axum::extract::ws::WebSocket;
use tokio::sync::{Mutex, Semaphore};
use tokio::task::JoinHandle;

use crate::server::context::HandlerContext;
use crate::server::protocol::ClientMessage;

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
    let key = format!("{}:{}", project, workspace);
    let state = manager.state.lock().await;
    state
        .workspaces
        .get(&key)
        .map(|entry| is_active_workspace_status(&entry.status))
        .unwrap_or(false)
}
