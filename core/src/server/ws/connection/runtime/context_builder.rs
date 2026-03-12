use crate::server::context::{
    ConnectionMeta, HandlerContext, SharedAppState, SharedRunningAITasks, SharedRunningCommands,
    SharedTaskHistory, TaskBroadcastTx,
};
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::terminal_registry::SharedTerminalRegistry;
use crate::workspace::state_store::StateStore;
use std::sync::Arc;

use super::types::{RuntimeChannels, RuntimeSharedState};

pub(in crate::server::ws) fn build_handler_context(
    app_state: &SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    registry: SharedTerminalRegistry,
    scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    conn_meta: &ConnectionMeta,
    remote_sub_registry: &SharedRemoteSubRegistry,
    task_broadcast_tx: TaskBroadcastTx,
    running_commands: SharedRunningCommands,
    running_ai_tasks: SharedRunningAITasks,
    task_history: SharedTaskHistory,
    ai_state: crate::server::handlers::ai::SharedAIState,
    shared_state: &RuntimeSharedState,
    channels: &RuntimeChannels,
    state_store: Arc<StateStore>,
) -> HandlerContext {
    HandlerContext {
        app_state: app_state.clone(),
        terminal_registry: registry,
        save_tx,
        scrollback_tx,
        subscribed_terms: shared_state.subscribed_terms.clone(),
        agg_tx: channels.agg_tx.clone(),
        running_commands,
        running_ai_tasks,
        cmd_output_tx: channels.cmd_output_tx.clone(),
        task_broadcast_tx,
        task_history,
        conn_meta: conn_meta.clone(),
        remote_sub_registry: remote_sub_registry.clone(),
        ai_state,
        state_store,
    }
}
