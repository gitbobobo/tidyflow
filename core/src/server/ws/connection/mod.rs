use axum::extract::ws::WebSocket;
use futures::StreamExt;
use tracing::{error, info};

use crate::server::context::{
    ConnectionMeta, SharedAppState, SharedRunningAITasks, SharedRunningCommands, SharedTaskHistory,
    TaskBroadcastTx,
};
use crate::server::protocol::ServerMessage;
use crate::server::remote_connection_registry::SharedRemoteConnectionRegistry;
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::terminal_registry::SharedTerminalRegistry;
use crate::workspace::state_store::StateStore;
use std::sync::Arc;

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
    state_store: Arc<StateStore>,
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
        state_store,
    )
    .await
}

async fn run_connection_loop(
    socket: WebSocket,
    conn_meta: &ConnectionMeta,
    runtime: runtime::SocketRuntime,
    mut shutdown_rx: tokio::sync::oneshot::Receiver<String>,
) -> bool {
    let (outbound_tx, outbound_rx) = crate::server::ws::create_outbound_channel();
    if let Err(e) = stages::send_hello_message(&outbound_tx).await {
        error!("Failed to enqueue Hello message: {}", e);
        return false;
    }

    let (socket_tx, socket_rx) = socket.split();
    let reader_conn_meta = conn_meta.clone();
    let writer_conn_id = conn_meta.conn_id.clone();

    let runtime::SocketRuntime {
        app_state,
        subscribed_terms: _,
        watcher,
        handler_ctx,
        agg_rx,
        rx_watch,
        cmd_output_rx,
        task_broadcast_rx,
        remote_term_rx,
    } = runtime;

    let reader_task = tokio::spawn(loop_driver::socket::run_reader_loop(
        socket_rx,
        outbound_tx.clone(),
        handler_ctx.clone(),
        watcher.clone(),
        reader_conn_meta,
    ));

    let event_task = tokio::spawn(loop_driver::run_outbound_event_loop(
        loop_driver::EventLoopDeps {
            conn_meta: conn_meta.clone(),
            handler_ctx,
            app_state,
            outbound_tx: outbound_tx.clone(),
            agg_rx,
            rx_watch,
            cmd_output_rx,
            task_broadcast_rx,
            remote_term_rx,
        },
    ));

    let writer_task = tokio::spawn(crate::server::ws::run_writer_loop(
        socket_tx,
        outbound_rx,
        writer_conn_id,
    ));

    let mut reader_task = reader_task;
    let mut event_task = event_task;
    let mut writer_task = writer_task;

    let result = tokio::select! {
        result = &mut reader_task => {
            event_task.abort();
            drop(outbound_tx);
            let _ = writer_task.await;
            result.ok().unwrap_or(false)
        }
        result = &mut writer_task => {
            event_task.abort();
            reader_task.abort();
            result.ok().unwrap_or(false)
        }
        result = &mut event_task => {
            reader_task.abort();
            drop(outbound_tx);
            let writer_ok = writer_task.await.ok().unwrap_or(false);
            result.is_ok() && writer_ok
        }
        reason = &mut shutdown_rx => {
            let reason = reason.unwrap_or_else(|_| "认证已失效，请重新连接。".to_string());
            let _ = crate::server::ws::send_message(
                &outbound_tx,
                &ServerMessage::Error {
                    code: "authentication_revoked".to_string(),
                    message: reason,
                    project: None,
                    workspace: None,
                    session_id: None,
                    cycle_id: None,
                },
            )
            .await;
            reader_task.abort();
            event_task.abort();
            drop(outbound_tx);
            writer_task.await.ok().unwrap_or(false)
        }
    };

    result
}

pub(super) async fn handle_socket(
    socket: WebSocket,
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    registry: SharedTerminalRegistry,
    scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    conn_meta: ConnectionMeta,
    remote_sub_registry: SharedRemoteSubRegistry,
    remote_connection_registry: SharedRemoteConnectionRegistry,
    task_broadcast_tx: TaskBroadcastTx,
    running_commands: SharedRunningCommands,
    running_ai_tasks: SharedRunningAITasks,
    task_history: SharedTaskHistory,
    ai_state: crate::server::handlers::ai::SharedAIState,
    state_store: Arc<StateStore>,
) {
    info!(
        "New WebSocket connection established (conn_id={}, remote={})",
        conn_meta.conn_id, conn_meta.is_remote
    );
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<String>();
    if let Some(key_id) = conn_meta.api_key_id.as_deref() {
        let mut registry = remote_connection_registry.lock().await;
        registry.register(
            key_id,
            &conn_meta.conn_id,
            conn_meta.remote_subscriber_id(),
            shutdown_tx,
        );
    }
    let runtime = initialize_runtime(
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
        state_store,
    )
    .await;

    let subscribed_terms = runtime.subscribed_terms.clone();
    let handler_ctx = runtime.handler_ctx.clone();

    if !run_connection_loop(socket, &conn_meta, runtime, shutdown_rx).await {
        // Hello 消息入队失败或连接异常关闭，统一走清理。
    }

    {
        let mut registry = remote_connection_registry.lock().await;
        registry.unregister(&conn_meta.conn_id);
    }

    cleanup::cleanup_on_disconnect(
        &subscribed_terms,
        &conn_meta,
        &remote_sub_registry,
        &handler_ctx,
        &handler_ctx.ai_state,
    )
    .await;
}
