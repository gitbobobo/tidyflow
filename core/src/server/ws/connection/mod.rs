use axum::extract::ws::WebSocket;
use tracing::{error, info};

use crate::server::context::{
    ConnectionMeta, SharedAppState, SharedRunningAITasks, SharedRunningCommands, SharedTaskHistory,
    TaskBroadcastTx,
};
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::terminal_registry::SharedTerminalRegistry;

mod cleanup;
mod events;
mod loop_driver;
mod runtime;
mod shared_types;
mod stages;

async fn initialize_runtime(
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
) -> runtime::SocketRuntime {
    runtime::build_socket_runtime(
        app_state,
        save_tx,
        registry,
        scrollback_tx,
        conn_meta,
        remote_sub_registry,
        task_broadcast_tx,
        running_commands,
        running_ai_tasks,
        task_history,
        ai_state,
    )
    .await
}

fn build_loop_deps<'a>(
    socket: &'a mut WebSocket,
    conn_meta: &'a ConnectionMeta,
    runtime: &'a mut runtime::SocketRuntime,
) -> loop_driver::LoopDeps<'a> {
    loop_driver::LoopDeps {
        socket: loop_driver::SocketDeps {
            socket,
            conn_meta,
            handler_ctx: &runtime.handler_ctx,
            watcher: &runtime.watcher,
            app_state: &runtime.app_state,
        },
        channels: loop_driver::ChannelDeps {
            agg_rx: &mut runtime.agg_rx,
            rx_watch: &mut runtime.rx_watch,
            cmd_output_rx: &mut runtime.cmd_output_rx,
            task_broadcast_rx: &mut runtime.task_broadcast_rx,
            remote_term_rx: &mut runtime.remote_term_rx,
        },
    }
}

async fn run_connection_loop(
    socket: &mut WebSocket,
    conn_meta: &ConnectionMeta,
    runtime: &mut runtime::SocketRuntime,
) -> bool {
    if let Err(e) = stages::send_hello_message(socket).await {
        error!("Failed to send Hello message: {}", e);
        return false;
    }

    let mut loop_deps = build_loop_deps(socket, conn_meta, runtime);
    loop_driver::run_main_loop(&mut loop_deps).await;
    true
}

pub(super) async fn handle_socket(
    mut socket: WebSocket,
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    registry: SharedTerminalRegistry,
    scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    conn_meta: ConnectionMeta,
    remote_sub_registry: SharedRemoteSubRegistry,
    task_broadcast_tx: TaskBroadcastTx,
    running_commands: SharedRunningCommands,
    running_ai_tasks: SharedRunningAITasks,
    task_history: SharedTaskHistory,
    ai_state: crate::server::handlers::ai::SharedAIState,
) {
    info!(
        "New WebSocket connection established (conn_id={}, remote={})",
        conn_meta.conn_id, conn_meta.is_remote
    );
    let mut runtime = initialize_runtime(
        app_state,
        save_tx,
        registry,
        scrollback_tx,
        &conn_meta,
        remote_sub_registry.clone(),
        task_broadcast_tx,
        running_commands,
        running_ai_tasks,
        task_history,
        ai_state,
    )
    .await;

    if !run_connection_loop(&mut socket, &conn_meta, &mut runtime).await {
        return;
    }

    cleanup::cleanup_on_disconnect(
        &runtime.subscribed_terms,
        &conn_meta,
        &remote_sub_registry,
        &runtime.handler_ctx,
        &runtime.handler_ctx.ai_state,
    )
    .await;
}
