use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::server::context::{
    SharedAppState, SharedRunningAITasks, SharedRunningCommands, SharedTaskHistory, TaskBroadcastTx,
};
use crate::server::handlers::ai::{AIState, SharedAIState};
use crate::server::remote_connection_registry::{
    RemoteConnectionRegistry, SharedRemoteConnectionRegistry,
};
use crate::server::remote_sub_registry::{RemoteSubRegistry, SharedRemoteSubRegistry};
use crate::server::terminal_registry::{
    spawn_idle_reaper, spawn_scrollback_writer, SharedTerminalRegistry, TerminalRegistry,
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
    pub(in crate::server::ws) api_key_registry:
        crate::server::ws::auth_keys::SharedRemoteAPIKeyRegistry,
    pub(in crate::server::ws) remote_sub_registry: SharedRemoteSubRegistry,
    pub(in crate::server::ws) remote_connection_registry: SharedRemoteConnectionRegistry,
    pub(in crate::server::ws) task_broadcast_tx: TaskBroadcastTx,
    pub(in crate::server::ws) running_commands: SharedRunningCommands,
    pub(in crate::server::ws) running_ai_tasks: SharedRunningAITasks,
    pub(in crate::server::ws) task_history: SharedTaskHistory,
    pub(in crate::server::ws) ai_state: SharedAIState,
    /// StateStore 引用（用于终端恢复元数据持久化，WI-002/WI-003）
    pub(in crate::server::ws) state_store: Arc<StateStore>,
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

fn build_shared_ai_state() -> SharedAIState {
    Arc::new(Mutex::new(AIState::new()))
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
    let _ = crate::server::node::init_global(
        shared_state.clone(),
        save_tx.clone(),
        resolve_bind_addr(),
    )
    .await;
    let terminal_registry: SharedTerminalRegistry = Arc::new(Mutex::new(TerminalRegistry::new()));
    let scrollback_tx = spawn_scrollback_writer(terminal_registry.clone());
    // 启动空闲终端回收后台任务（每 30 秒检查，自动回收无订阅的退出/长期空闲终端）
    spawn_idle_reaper(terminal_registry.clone());

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

    let ai_state = build_shared_ai_state();

    // 注册内置健康探针（含终端恢复状态检测，WI-003）
    crate::server::health::register_builtin_probes(
        shared_state.clone(),
        terminal_registry.clone(),
    );

    // 启动时加载待恢复的终端元数据，标记其恢复阶段（WI-003）
    match state_store.load_terminal_recovery_entries().await {
        Ok(entries) if !entries.is_empty() => {
            let mut reg = terminal_registry.lock().await;
            for (project, workspace, entry) in &entries {
                reg.set_recovery_meta(
                    &entry.term_id,
                    crate::server::terminal_registry::TerminalRecoveryMeta {
                        term_id: entry.term_id.clone(),
                        project: project.clone(),
                        workspace: workspace.clone(),
                        cwd: entry.cwd.clone(),
                        shell: entry.shell.clone(),
                        name: entry.name.clone(),
                        icon: entry.icon.clone(),
                        recovery_state: "recovering".to_string(),
                        failed_reason: None,
                        created_at: entry.recorded_at.to_rfc3339(),
                    },
                );
                reg.mark_recovering(&entry.term_id);
            }
            info!(
                count = entries.len(),
                "Loaded terminal recovery entries on startup"
            );
        }
        Err(e) => {
            warn!(error = %e, "Failed to load terminal recovery entries on startup");
        }
        _ => {}
    }

    let ctx = AppContext {
        app_state: shared_state.clone(),
        save_tx,
        terminal_registry,
        scrollback_tx,
        expected_ws_token,
        api_key_registry: Arc::new(Mutex::new(crate::server::ws::auth_keys::new_api_key_registry(
            &shared_state.read().await.remote_api_keys,
        ))),
        remote_sub_registry: Arc::new(Mutex::new(RemoteSubRegistry::new())),
        remote_connection_registry: Arc::new(Mutex::new(RemoteConnectionRegistry::new())),
        task_broadcast_tx,
        running_commands,
        running_ai_tasks,
        task_history,
        ai_state,
        state_store,
    };

    (ctx, bind_addr)
}

#[cfg(test)]
mod tests {
    use super::build_shared_ai_state;

    #[tokio::test]
    async fn bootstrap_ai_state_should_start_without_preloaded_agents() {
        let ai_state = build_shared_ai_state();
        let ai = ai_state.lock().await;

        assert!(ai.agents.is_empty(), "Core bootstrap 不应预热任何 AI 代理");
        assert!(
            !ai.maintenance_started,
            "仅初始化 bootstrap 上下文时不应提前启动 maintenance"
        );
    }
}
