use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::server::context::{
    SharedAppState, SharedRunningAITasks, SharedRunningCommands, SharedTaskHistory, TaskBroadcastTx,
};
use crate::server::handlers::ai::{preload_agents_on_startup, AIState, SharedAIState};
use crate::server::remote_sub_registry::{RemoteSubRegistry, SharedRemoteSubRegistry};
use crate::server::terminal_registry::{
    spawn_scrollback_writer, SharedTerminalRegistry, TerminalRegistry,
};
use crate::workspace::state::AppState;
use crate::workspace::state_saver::spawn_state_saver;
use crate::workspace::state_store::StateStore;

/// WebSocket 服务器上下文，包含共享状态和防抖保存通道
#[derive(Clone)]
pub(in crate::server::ws) struct AppContext {
    pub(in crate::server::ws) app_state: SharedAppState,
    pub(in crate::server::ws) save_tx: tokio::sync::mpsc::Sender<()>,
    pub(in crate::server::ws) terminal_registry: SharedTerminalRegistry,
    pub(in crate::server::ws) scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    pub(in crate::server::ws) expected_ws_token: Option<String>,
    pub(in crate::server::ws) pairing_registry: crate::server::ws::pairing::SharedPairingRegistry,
    pub(in crate::server::ws) remote_sub_registry: SharedRemoteSubRegistry,
    pub(in crate::server::ws) task_broadcast_tx: TaskBroadcastTx,
    pub(in crate::server::ws) running_commands: SharedRunningCommands,
    pub(in crate::server::ws) running_ai_tasks: SharedRunningAITasks,
    pub(in crate::server::ws) task_history: SharedTaskHistory,
    pub(in crate::server::ws) ai_state: SharedAIState,
}

fn resolve_expected_ws_token() -> Option<String> {
    std::env::var("TIDYFLOW_WS_TOKEN")
        .ok()
        .filter(|token| !token.trim().is_empty())
}

fn resolve_bind_addr() -> String {
    std::env::var("TIDYFLOW_BIND_ADDR")
        .ok()
        .map(|addr| addr.trim().to_string())
        .filter(|addr| !addr.is_empty())
        .unwrap_or_else(|| "127.0.0.1".to_string())
}

fn resolve_task_broadcast_capacity() -> usize {
    std::env::var("PERF_TASK_BROADCAST_CAPACITY")
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .filter(|v| *v >= 64)
        .unwrap_or(1024)
}

fn log_bootstrap_config(expected_ws_token: Option<&str>, bind_addr: &str) {
    if expected_ws_token.is_some() {
        info!("WebSocket token auth enabled");
    } else {
        warn!("WebSocket token auth disabled (TIDYFLOW_WS_TOKEN not set)");
    }
    info!("Binding on {}", bind_addr);
}

pub(in crate::server::ws) async fn build_app_context() -> (AppContext, String) {
    let state_store = Arc::new(
        StateStore::open_default()
            .await
            .unwrap_or_else(|_| panic!("failed to initialize state store")),
    );
    let app_state = state_store
        .load()
        .await
        .unwrap_or_else(|_| AppState::default());
    let shared_state: SharedAppState = Arc::new(tokio::sync::RwLock::new(app_state));

    let save_tx = spawn_state_saver(shared_state.clone(), state_store.clone());
    let terminal_registry: SharedTerminalRegistry = Arc::new(Mutex::new(TerminalRegistry::new()));
    let scrollback_tx = spawn_scrollback_writer(terminal_registry.clone());

    let expected_ws_token = resolve_expected_ws_token();
    let bind_addr = resolve_bind_addr();
    log_bootstrap_config(expected_ws_token.as_deref(), &bind_addr);

    let task_broadcast_capacity = resolve_task_broadcast_capacity();
    info!(
        "Task broadcast channel capacity: {}",
        task_broadcast_capacity
    );
    let (task_broadcast_tx, _) = tokio::sync::broadcast::channel(task_broadcast_capacity);
    let running_commands: SharedRunningCommands = Arc::new(Mutex::new(HashMap::new()));
    let running_ai_tasks: SharedRunningAITasks = Arc::new(Mutex::new(HashMap::new()));
    let task_history: SharedTaskHistory = Arc::new(Mutex::new(Vec::new()));

    let ai_state: SharedAIState = Arc::new(Mutex::new(AIState::new()));
    preload_agents_on_startup(&ai_state).await;

    let ctx = AppContext {
        app_state: shared_state.clone(),
        save_tx,
        terminal_registry,
        scrollback_tx,
        expected_ws_token,
        pairing_registry: Arc::new(Mutex::new(
            crate::server::ws::pairing::new_pairing_registry(
                &shared_state.read().await.paired_tokens,
            ),
        )),
        remote_sub_registry: Arc::new(Mutex::new(RemoteSubRegistry::new())),
        task_broadcast_tx,
        running_commands,
        running_ai_tasks,
        task_history,
        ai_state,
    };

    (ctx, bind_addr)
}
