use crate::server::context::{
    ConnectionMeta, SharedAppState, SharedRunningAITasks, SharedRunningCommands, SharedTaskHistory,
    TaskBroadcastTx,
};
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::terminal_registry::SharedTerminalRegistry;

mod channels;
mod context_builder;
mod remote_term;
mod shared;
mod types;

pub(in crate::server::ws) use types::SocketRuntime;

pub(in crate::server::ws) async fn build_socket_runtime(
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    registry: SharedTerminalRegistry,
    scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    conn_meta: &ConnectionMeta,
    remote_sub_registry: SharedRemoteSubRegistry,
    task_broadcast_tx: TaskBroadcastTx,
    running_commands: SharedRunningCommands,
    running_ai_tasks: SharedRunningAITasks,
    task_history: SharedTaskHistory,
    ai_state: crate::server::handlers::ai::SharedAIState,
) -> SocketRuntime {
    let channels = channels::build_runtime_channels();
    let shared_state = shared::build_runtime_shared_state(channels.tx_watch.clone());
    let task_broadcast_rx = task_broadcast_tx.subscribe();
    let handler_ctx = context_builder::build_handler_context(
        &app_state,
        save_tx,
        registry,
        scrollback_tx,
        conn_meta,
        &remote_sub_registry,
        task_broadcast_tx,
        running_commands,
        running_ai_tasks,
        task_history,
        ai_state,
        &shared_state,
        &channels,
    );
    let remote_term_rx = remote_term::build_remote_term_rx(conn_meta, &remote_sub_registry).await;

    SocketRuntime {
        app_state,
        subscribed_terms: shared_state.subscribed_terms,
        watcher: shared_state.watcher,
        handler_ctx,
        agg_rx: channels.agg_rx,
        rx_watch: channels.rx_watch,
        cmd_output_rx: channels.cmd_output_rx,
        task_broadcast_rx,
        remote_term_rx,
    }
}
