use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use tracing::{debug, error, info, trace, warn};

use crate::server::context::{
    ConnectionMeta, HandlerContext, SharedAppState, SharedRunningAITasks, SharedRunningCommands,
    SharedTaskHistory, TaskBroadcastTx, TermSubscription,
};
use crate::server::git::status::invalidate_git_status_cache;
use crate::server::lsp::LspSupervisor;
use crate::server::protocol::ServerMessage;
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::terminal_registry::SharedTerminalRegistry;
use crate::server::watcher::{WatchEvent, WorkspaceWatcher};

use super::{dispatch, send_message};

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

    // 聚合输出通道：所有订阅终端的输出汇聚到这里
    let (agg_tx, mut agg_rx) = tokio::sync::mpsc::channel::<(String, Vec<u8>)>(256);

    // 跟踪当前 WS 连接订阅的终端及其转发 task + 流控状态
    let subscribed_terms: Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>> =
        Arc::new(tokio::sync::Mutex::new(HashMap::new()));

    // Create channel for file watcher events
    let (tx_watch, mut rx_watch) = tokio::sync::mpsc::channel::<WatchEvent>(100);

    // Create file watcher
    let watcher = Arc::new(tokio::sync::Mutex::new(WorkspaceWatcher::new(tx_watch)));

    // 项目命令输出通道：后台 task 逐行推送 → 主循环转发到 WebSocket
    let (cmd_output_tx, mut cmd_output_rx) = tokio::sync::mpsc::channel::<ServerMessage>(256);
    let lsp_supervisor = LspSupervisor::new(cmd_output_tx.clone());

    // 订阅任务广播通道（接收其他连接发起的任务事件）
    let mut task_broadcast_rx = task_broadcast_tx.subscribe();

    // 构造 HandlerContext，收拢所有共享依赖
    let handler_ctx = HandlerContext {
        app_state: app_state.clone(),
        terminal_registry: registry.clone(),
        save_tx: save_tx.clone(),
        scrollback_tx: scrollback_tx.clone(),
        subscribed_terms: subscribed_terms.clone(),
        agg_tx: agg_tx.clone(),
        running_commands: running_commands.clone(),
        running_ai_tasks: running_ai_tasks.clone(),
        cmd_output_tx: cmd_output_tx.clone(),
        task_broadcast_tx: task_broadcast_tx.clone(),
        task_history: task_history.clone(),
        lsp_supervisor: lsp_supervisor.clone(),
        conn_meta: conn_meta.clone(),
        remote_sub_registry: remote_sub_registry.clone(),
        ai_state: ai_state.clone(),
    };

    // Send Hello message with v1 capabilities
    let hello_msg = ServerMessage::Hello {
        version: super::PROTOCOL_VERSION,
        session_id: String::new(),
        shell: String::new(),
        capabilities: Some(crate::server::protocol::v1_capabilities()),
    };

    if let Err(e) = send_message(&mut socket, &hello_msg).await {
        error!("Failed to send Hello message: {}", e);
        return;
    }

    // 远程终端变更事件接收器（仅本地连接使用）
    let mut remote_term_rx = if !conn_meta.is_remote {
        Some(remote_sub_registry.lock().await.subscribe_events())
    } else {
        None
    };

    // Main loop: handle WebSocket messages and PTY output
    info!("Entering main WebSocket loop");
    crate::util::flush_logs();
    let mut loop_count: u64 = 0;
    let mut last_log_time = std::time::Instant::now();
    loop {
        loop_count += 1;

        if loop_count == 1 {
            debug!("First loop iteration, about to call tokio::select!");
            crate::util::flush_logs();
        } else if last_log_time.elapsed().as_secs() >= 5 {
            trace!("Main loop still running, iteration {}", loop_count);
            crate::util::flush_logs();
            last_log_time = std::time::Instant::now();
        }

        tokio::select! {
            biased;  // 优先处理 WebSocket 消息

            // Handle WebSocket messages (优先)
            msg_result = socket.recv() => {
                trace!("socket.recv() returned: {:?}", msg_result.as_ref().map(|r| r.as_ref().map(|m| match m {
                    Message::Text(t) => format!("Text({}...)", &t[..t.len().min(50)]),
                    Message::Binary(b) => format!("Binary({} bytes)", b.len()),
                    Message::Ping(_) => "Ping".to_string(),
                    Message::Pong(_) => "Pong".to_string(),
                    Message::Close(_) => "Close".to_string(),
                })));
                match msg_result {
                    Some(Ok(Message::Binary(data))) => {
                        trace!("Received binary client message: {} bytes", data.len());
                        let client_message_type = dispatch::probe_client_message_type(&data);
                        if let Err(e) = dispatch::handle_client_message(
                            &data,
                            &mut socket,
                            &handler_ctx,
                            &watcher,
                        ).await {
                            warn!(
                                "Error handling client message: conn_id={}, message_type={}, error={}",
                                conn_meta.conn_id, client_message_type, e
                            );
                            if let Err(send_err) = send_message(&mut socket, &ServerMessage::Error {
                                code: "message_error".to_string(),
                                message: e.clone(),
                            }).await {
                                error!(
                                    "Failed to send error message: conn_id={}, message_type={}, error={}",
                                    conn_meta.conn_id, client_message_type, send_err
                                );
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) => {
                        info!(
                            "WebSocket connection closed by client (conn_id={})",
                            conn_meta.conn_id
                        );
                        break;
                    }
                    Some(Ok(Message::Text(_))) => {
                        warn!("Received deprecated text message, binary MessagePack expected");
                    }
                    Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => {
                        // Handled automatically by axum
                    }
                    Some(Err(e)) => {
                        error!("WebSocket error: conn_id={}, error={}", conn_meta.conn_id, e);
                        break;
                    }
                    None => {
                        info!(
                            "WebSocket connection closed (recv returned None, conn_id={})",
                            conn_meta.conn_id
                        );
                        break;
                    }
                }
            }

            // Handle aggregated PTY output from subscribed terminals
            // 批量合并：一次性取出多条消息，合并同一终端的输出为单个 WS 帧
            Some((term_id, output)) = agg_rx.recv() => {
                const MAX_BATCH_SIZE: usize = 256 * 1024; // 256KB
                let mut batched: HashMap<String, Vec<u8>> = HashMap::new();
                let first_len = output.len();
                batched.entry(term_id).or_default().extend(output);
                let mut total = first_len;

                // 继续 try_recv 直到通道为空或达到预算上限
                while total < MAX_BATCH_SIZE {
                    match agg_rx.try_recv() {
                        Ok((id, data)) => {
                            total += data.len();
                            batched.entry(id).or_default().extend(data);
                        }
                        Err(_) => break,
                    }
                }

                trace!("Batched PTY output: {} terminals, {} bytes total", batched.len(), total);

                // 逐终端发送合并后的数据
                let mut send_failed = false;
                for (id, data) in batched {
                    let msg = ServerMessage::Output {
                        data,
                        term_id: Some(id),
                    };
                    if let Err(e) = send_message(&mut socket, &msg).await {
                        error!("Failed to send output message: {}", e);
                        send_failed = true;
                        break;
                    }
                }
                if send_failed {
                    break;
                }
            }

            // Handle file watcher events
            Some(watch_event) = rx_watch.recv() => {
                match watch_event {
                    WatchEvent::FileChanged { project, workspace, paths, kind } => {
                        debug!("File changed: project={}, workspace={}, paths={:?}", project, workspace, paths);

                        handler_ctx
                            .lsp_supervisor
                            .handle_paths_changed(&project, &workspace, &paths)
                            .await;

                        // 文件变化可能影响 git status，主动失效缓存
                        {
                            let ws_ctx = crate::server::context::resolve_workspace(
                                &app_state, &project, &workspace,
                            ).await;
                            if let Ok(ctx) = ws_ctx {
                                invalidate_git_status_cache(&ctx.root_path);
                            }
                        }

                        let msg = ServerMessage::FileChanged {
                            project,
                            workspace,
                            paths,
                            kind,
                        };
                        if let Err(e) = send_message(&mut socket, &msg).await {
                            error!("Failed to send file changed message: {}", e);
                        }
                    }
                    WatchEvent::GitStatusChanged { project, workspace } => {
                        debug!("Git status changed: project={}, workspace={}", project, workspace);

                        // Git 元数据变化（index/HEAD/refs），主动失效缓存
                        {
                            let ws_ctx = crate::server::context::resolve_workspace(
                                &app_state, &project, &workspace,
                            ).await;
                            if let Ok(ctx) = ws_ctx {
                                invalidate_git_status_cache(&ctx.root_path);
                            }
                        }

                        let msg = ServerMessage::GitStatusChanged {
                            project,
                            workspace,
                        };
                        if let Err(e) = send_message(&mut socket, &msg).await {
                            error!("Failed to send git status changed message: {}", e);
                        }
                    }
                }
            }

            // 项目命令后台 task 的输出/完成消息
            Some(msg) = cmd_output_rx.recv() => {
                if let Err(e) = send_message(&mut socket, &msg).await {
                    error!("Failed to send command output message: {}", e);
                }
            }

            // 任务广播：接收其他连接发起的任务事件
            result = task_broadcast_rx.recv() => {
                match result {
                    Ok(event) => {
                        if event.origin_conn_id != conn_meta.conn_id {
                            if let Err(e) = send_message(&mut socket, &event.message).await {
                                error!("Failed to send broadcast task event: {}", e);
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!("Task broadcast lagged by {} messages", n);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        debug!("Task broadcast channel closed");
                    }
                }
            }

            // 远程终端订阅变更通知（仅本地连接接收）
            result = async {
                match remote_term_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                match result {
                    Ok(_event) => {
                        info!("Received RemoteTermEvent::Changed, sending remote_term_changed to local conn {}", conn_meta.conn_id);
                        if let Err(e) = send_message(&mut socket, &ServerMessage::RemoteTermChanged).await {
                            error!("Failed to send remote_term_changed: {}", e);
                        }
                    }
                    Err(e) => {
                        warn!("remote_term_rx recv error (lagged?): {:?}", e);
                    }
                }
            }

            else => {
                debug!("All channels closed, exiting");
                break;
            }
        }
    }

    // WS 断开：只清理订阅关系，不杀终端
    {
        let mut subs = subscribed_terms.lock().await;
        for (term_id, (handle, _fc, flow_gate)) in subs.drain() {
            info!("Unsubscribing from terminal {} on WS disconnect", term_id);
            handle.abort();
            flow_gate.remove_subscriber();
        }
    }

    // WS 断开：配对设备订阅长期保留，未配对远程连接仍按 conn_id 清理
    if conn_meta.is_remote {
        if conn_meta.token_id.is_some() {
            info!(
                conn_id = %conn_meta.conn_id,
                subscriber_id = %conn_meta.remote_subscriber_id(),
                "Remote WebSocket disconnected; keeping remote terminal subscriptions"
            );
        } else {
            let mut reg = remote_sub_registry.lock().await;
            reg.unsubscribe_all(&conn_meta.conn_id);
        }
    }

    // WS 断开：关闭该连接托管的 LSP 会话
    handler_ctx.lsp_supervisor.shutdown_all().await;

    info!("WebSocket connection handler finished");
}
