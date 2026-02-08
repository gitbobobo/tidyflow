use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::State,
    response::IntoResponse,
    routing::get,
    Router,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{Mutex, Notify, RwLock};
use tokio::task::JoinHandle;
use tracing::{debug, error, info, trace, warn};

#[cfg(unix)]
use std::os::unix::process::parent_id;

use crate::server::handlers::file;
use crate::server::handlers::git;
use crate::server::handlers::project;
use crate::server::handlers::settings;
use crate::server::handlers::terminal;
use crate::server::protocol::{
    v1_capabilities, ClientMessage, ServerMessage, PROTOCOL_VERSION,
};
use crate::server::terminal_registry::{
    spawn_scrollback_writer, SharedTerminalRegistry, TerminalRegistry,
};
use crate::server::watcher::{WatchEvent, WorkspaceWatcher};
use crate::server::git::status::invalidate_git_status_cache;
use crate::workspace::state::{AppState, Project};
use crate::workspace::state_saver::spawn_state_saver;

/// 获取工作空间的根路径，支持 "default" 虚拟工作空间
/// 如果 workspace 是 "default"，返回项目根目录
fn get_workspace_root(project: &Project, workspace: &str) -> Option<PathBuf> {
    if workspace == "default" {
        Some(project.root_path.clone())
    } else {
        project
            .get_workspace(workspace)
            .map(|w| w.worktree_path.clone())
    }
}

/// Shared application state for the WebSocket server
pub type SharedAppState = Arc<RwLock<AppState>>;

/// 终端输出流控：per-terminal per-WS-connection 的背压状态
/// 当 unacked 超过 HIGH_WATER_MARK 时暂停转发，等待前端 ACK
pub struct FlowControl {
    pub unacked: AtomicU64,
    pub notify: Notify,
}

/// 流控高水位（100KB）：未确认字节数超过此值时暂停转发
const FLOW_CONTROL_HIGH_WATER: u64 = 100 * 1024;

/// subscribed_terms 的 value 类型：(转发任务句柄, 流控状态)
pub type TermSubscription = (JoinHandle<()>, Arc<FlowControl>);

/// WebSocket 服务器上下文，包含共享状态和防抖保存通道
#[derive(Clone)]
pub struct AppContext {
    pub app_state: SharedAppState,
    pub save_tx: tokio::sync::mpsc::Sender<()>,
    pub terminal_registry: SharedTerminalRegistry,
    pub scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
}

/// Run the WebSocket server on the specified port
pub async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WebSocket server on port {}", port);

    // Start parent process monitor to auto-exit when parent dies (e.g., Xcode force stop)
    #[cfg(unix)]
    spawn_parent_monitor();

    // Load application state
    let app_state = AppState::load().unwrap_or_default();
    let shared_state: SharedAppState = Arc::new(RwLock::new(app_state));

    // 启动防抖保存 actor
    let save_tx = spawn_state_saver(shared_state.clone());

    // 创建全局终端注册表
    let terminal_registry: SharedTerminalRegistry =
        Arc::new(Mutex::new(TerminalRegistry::new()));

    // 启动 scrollback 写入 task
    let scrollback_tx = spawn_scrollback_writer(terminal_registry.clone());

    let ctx = AppContext {
        app_state: shared_state,
        save_tx,
        terminal_registry,
        scrollback_tx,
    };

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .with_state(ctx);

    let addr = format!("127.0.0.1:{}", port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;

    info!(
        "Listening on ws://{}/ws (protocol v{})",
        addr, PROTOCOL_VERSION
    );

    axum::serve(listener, app).await?;

    Ok(())
}

/// Monitor parent process and exit if it dies (becomes orphaned)
/// This handles the case where the Swift app is force-killed by Xcode
#[cfg(unix)]
fn spawn_parent_monitor() {
    let initial_ppid = parent_id();
    info!("Parent process monitor started, PPID: {}", initial_ppid);

    // If already orphaned (PPID is 1/launchd), don't start monitor
    if initial_ppid <= 1 {
        info!("Running without parent process, skipping monitor");
        return;
    }

    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(1));
        loop {
            interval.tick().await;

            let current_ppid = parent_id();
            // On macOS/Unix, when parent dies, PPID becomes 1 (init/launchd)
            if current_ppid != initial_ppid {
                warn!(
                    "Parent process died (PPID changed from {} to {}), shutting down",
                    initial_ppid, current_ppid
                );
                std::process::exit(0);
            }
        }
    });
}

/// WebSocket upgrade handler
async fn ws_handler(
    ws: WebSocketUpgrade,
    State(ctx): State<AppContext>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| {
        handle_socket(
            socket,
            ctx.app_state,
            ctx.save_tx,
            ctx.terminal_registry,
            ctx.scrollback_tx,
        )
    })
}

/// Handle a WebSocket connection
async fn handle_socket(
    mut socket: WebSocket,
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    registry: SharedTerminalRegistry,
    scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
) {
    info!("New WebSocket connection established");

    // 聚合输出通道：所有订阅终端的输出汇聚到这里
    let (agg_tx, mut agg_rx) =
        tokio::sync::mpsc::channel::<(String, Vec<u8>)>(256);

    // 跟踪当前 WS 连接订阅的终端及其转发 task + 流控状态
    let subscribed_terms: Arc<Mutex<HashMap<String, TermSubscription>>> =
        Arc::new(Mutex::new(HashMap::new()));

    // Create channel for file watcher events
    let (tx_watch, mut rx_watch) =
        tokio::sync::mpsc::channel::<WatchEvent>(100);

    // Create file watcher
    let watcher = Arc::new(Mutex::new(WorkspaceWatcher::new(tx_watch)));

    // 不再自动创建默认终端，前端重连时通过 TermAttach 附着已有终端

    // Send Hello message with v1 capabilities（session_id/shell 发空，前端需兼容）
    let hello_msg = ServerMessage::Hello {
        version: PROTOCOL_VERSION,
        session_id: String::new(),
        shell: String::new(),
        capabilities: Some(v1_capabilities()),
    };

    if let Err(e) = send_message(&mut socket, &hello_msg).await {
        error!("Failed to send Hello message: {}", e);
        return;
    }

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
                        if let Err(e) = handle_client_message(
                            &data,
                            &mut socket,
                            &registry,
                            &watcher,
                            &app_state,
                            &save_tx,
                            &scrollback_tx,
                            &subscribed_terms,
                            &agg_tx,
                        ).await {
                            warn!("Error handling client message: {}", e);
                            if let Err(send_err) = send_message(&mut socket, &ServerMessage::Error {
                                code: "message_error".to_string(),
                                message: e.clone(),
                            }).await {
                                error!("Failed to send error message: {}", send_err);
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) => {
                        info!("WebSocket connection closed by client");
                        break;
                    }
                    Some(Ok(Message::Text(_))) => {
                        warn!("Received deprecated text message, binary MessagePack expected");
                    }
                    Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => {
                        // Handled automatically by axum
                    }
                    Some(Err(e)) => {
                        error!("WebSocket error: {}", e);
                        break;
                    }
                    None => {
                        info!("WebSocket connection closed (recv returned None)");
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

                        // 文件变化可能影响 git status，主动失效缓存
                        {
                            let state = app_state.read().await;
                            if let Some(proj) = state.projects.get(&project) {
                                if let Some(root) = get_workspace_root(proj, &workspace) {
                                    invalidate_git_status_cache(&root);
                                }
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
                            let state = app_state.read().await;
                            if let Some(proj) = state.projects.get(&project) {
                                if let Some(root) = get_workspace_root(proj, &workspace) {
                                    invalidate_git_status_cache(&root);
                                }
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

            else => {
                debug!("All channels closed, exiting");
                break;
            }
        }
    }

    // WS 断开：只清理订阅关系，不杀终端
    {
        let mut subs = subscribed_terms.lock().await;
        for (term_id, (handle, _fc)) in subs.drain() {
            info!("Unsubscribing from terminal {} on WS disconnect", term_id);
            handle.abort();
        }
    }

    info!("WebSocket connection handler finished");
}

/// Send a server message over WebSocket
pub async fn send_message(socket: &mut WebSocket, msg: &ServerMessage) -> Result<(), String> {
    // 使用 to_vec_named 确保输出字典格式（带字段名），而不是数组格式
    // 这样 Swift 端的 AnyCodable 才能正确解析
    let bytes = rmp_serde::to_vec_named(msg).map_err(|e| e.to_string())?;
    socket
        .send(Message::Binary(bytes))
        .await
        .map_err(|e| e.to_string())
}

/// 订阅终端输出：从 registry 的 broadcast 接收数据，转发到聚合通道
/// 带流控：当 unacked 超过高水位时暂停转发，等待前端 ACK
pub async fn subscribe_terminal(
    term_id: &str,
    registry: &SharedTerminalRegistry,
    subscribed_terms: &Arc<Mutex<HashMap<String, TermSubscription>>>,
    agg_tx: &tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
) -> bool {
    let reg = registry.lock().await;
    let rx = match reg.subscribe(term_id) {
        Some(rx) => rx,
        None => return false,
    };
    drop(reg);

    let agg_tx = agg_tx.clone();
    let tid = term_id.to_string();

    let fc = Arc::new(FlowControl {
        unacked: AtomicU64::new(0),
        notify: Notify::new(),
    });
    let fc_clone = fc.clone();

    let handle = tokio::spawn(async move {
        let mut rx = rx;
        loop {
            // 流控：unacked 超过高水位时暂停，等待 ACK 唤醒
            while fc_clone.unacked.load(Ordering::Relaxed) > FLOW_CONTROL_HIGH_WATER {
                // 带超时等待，防止前端 ACK 丢失导致永久阻塞
                tokio::select! {
                    _ = fc_clone.notify.notified() => {}
                    _ = tokio::time::sleep(tokio::time::Duration::from_millis(500)) => {
                        // 超时后强制重置 unacked，避免死锁
                        warn!("Terminal {} flow control timeout, resetting unacked", tid);
                        fc_clone.unacked.store(0, Ordering::Relaxed);
                    }
                }
            }

            match rx.recv().await {
                Ok((id, data)) => {
                    if id == tid {
                        let data_len = data.len() as u64;
                        if agg_tx.send((id, data)).await.is_err() {
                            break;
                        }
                        // 记录未确认字节数
                        fc_clone.unacked.fetch_add(data_len, Ordering::Relaxed);
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    warn!("Terminal {} output lagged by {} messages", tid, n);
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break;
                }
            }
        }
    });

    let mut subs = subscribed_terms.lock().await;
    // 如果已有旧订阅，先取消
    if let Some((old_handle, _old_fc)) = subs.remove(term_id) {
        old_handle.abort();
    }
    subs.insert(term_id.to_string(), (handle, fc));
    true
}

/// 取消订阅终端输出
pub async fn unsubscribe_terminal(
    term_id: &str,
    subscribed_terms: &Arc<Mutex<HashMap<String, TermSubscription>>>,
) {
    let mut subs = subscribed_terms.lock().await;
    if let Some((handle, _fc)) = subs.remove(term_id) {
        handle.abort();
    }
}

/// 处理前端 ACK，释放流控背压
pub async fn ack_terminal_output(
    term_id: &str,
    bytes: u64,
    subscribed_terms: &Arc<Mutex<HashMap<String, TermSubscription>>>,
) {
    let subs = subscribed_terms.lock().await;
    if let Some((_handle, fc)) = subs.get(term_id) {
        // 减少未确认字节数（使用饱和减法避免下溢）
        let prev = fc.unacked.load(Ordering::Relaxed);
        let new_val = prev.saturating_sub(bytes);
        fc.unacked.store(new_val, Ordering::Relaxed);
        // 如果降至高水位以下，唤醒转发 task
        if prev > FLOW_CONTROL_HIGH_WATER && new_val <= FLOW_CONTROL_HIGH_WATER {
            fc.notify.notify_one();
        }
    }
}

/// Handle a client message
async fn handle_client_message(
    data: &[u8],
    socket: &mut WebSocket,
    registry: &SharedTerminalRegistry,
    watcher: &Arc<Mutex<WorkspaceWatcher>>,
    app_state: &SharedAppState,
    save_tx: &tokio::sync::mpsc::Sender<()>,
    scrollback_tx: &tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    subscribed_terms: &Arc<Mutex<HashMap<String, TermSubscription>>>,
    agg_tx: &tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
) -> Result<(), String> {
    trace!(
        "handle_client_message called with data length: {}",
        data.len()
    );
    let client_msg: ClientMessage = rmp_serde::from_slice(data).map_err(|e| {
        error!("Failed to parse client message: {}", e);
        format!("Parse error: {}", e)
    })?;
    trace!(
        "Parsed client message: {:?}",
        std::mem::discriminant(&client_msg)
    );

    // Try terminal handler first
    if terminal::handle_terminal_message(
        &client_msg,
        socket,
        registry,
        app_state,
        scrollback_tx,
        subscribed_terms,
        agg_tx,
    )
    .await?
    {
        return Ok(());
    }

    // Try file handler
    if file::handle_file_message(&client_msg, socket, app_state).await? {
        return Ok(());
    }

    // Try git handler
    if git::handle_git_message(&client_msg, socket, app_state).await? {
        return Ok(());
    }

    // Try project handler
    if project::handle_project_message(
        &client_msg,
        socket,
        registry,
        app_state,
        scrollback_tx,
        subscribed_terms,
        agg_tx,
    )
    .await?
    {
        return Ok(());
    }

    // Try settings handler
    if settings::handle_settings_message(&client_msg, socket, app_state, save_tx).await? {
        return Ok(());
    }

    match client_msg {
        ClientMessage::Ping => {
            send_message(socket, &ServerMessage::Pong).await?;
        }

        // v1.22: File watcher
        ClientMessage::WatchSubscribe { project, workspace } => {
            info!(
                "WatchSubscribe: project={}, workspace={}",
                project, workspace
            );

            // 获取工作空间路径
            let state = app_state.read().await;
            let watch_path = state
                .projects
                .get(&project)
                .and_then(|p| get_workspace_root(p, &workspace));
            drop(state);

            match watch_path {
                Some(path) => {
                    let mut w = watcher.lock().await;
                    match w.subscribe(project.clone(), workspace.clone(), path) {
                        Ok(_) => {
                            send_message(
                                socket,
                                &ServerMessage::WatchSubscribed { project, workspace },
                            )
                            .await?;
                        }
                        Err(e) => {
                            send_message(
                                socket,
                                &ServerMessage::Error {
                                    code: "watch_subscribe_failed".to_string(),
                                    message: e,
                                },
                            )
                            .await?;
                        }
                    }
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "workspace_not_found".to_string(),
                            message: format!(
                                "Workspace '{}' not found in project '{}'",
                                workspace, project
                            ),
                        },
                    )
                    .await?;
                }
            }
        }

        ClientMessage::WatchUnsubscribe => {
            info!("WatchUnsubscribe");
            let mut w = watcher.lock().await;
            w.unsubscribe();
            send_message(socket, &ServerMessage::WatchUnsubscribed).await?;
        }

        ClientMessage::Input { .. }
        | ClientMessage::Resize { .. }
        | ClientMessage::SpawnTerminal { .. }
        | ClientMessage::KillTerminal
        | ClientMessage::TermCreate { .. }
        | ClientMessage::TermList
        | ClientMessage::TermClose { .. }
        | ClientMessage::TermFocus { .. }
        | ClientMessage::TermAttach { .. }
        | ClientMessage::TermOutputAck { .. } => {
            unreachable!("Terminal messages should be handled by terminal handler");
        }

        ClientMessage::FileList { .. }
        | ClientMessage::FileRead { .. }
        | ClientMessage::FileWrite { .. }
        | ClientMessage::FileIndex { .. }
        | ClientMessage::FileRename { .. }
        | ClientMessage::FileDelete { .. }
        | ClientMessage::FileCopy { .. }
        | ClientMessage::FileMove { .. } => {
            unreachable!("File messages should be handled by file handler");
        }

        ClientMessage::GitStatus { .. }
        | ClientMessage::GitDiff { .. }
        | ClientMessage::GitStage { .. }
        | ClientMessage::GitUnstage { .. }
        | ClientMessage::GitDiscard { .. }
        | ClientMessage::GitBranches { .. }
        | ClientMessage::GitSwitchBranch { .. }
        | ClientMessage::GitCreateBranch { .. }
        | ClientMessage::GitCommit { .. }
        | ClientMessage::GitFetch { .. }
        | ClientMessage::GitRebase { .. }
        | ClientMessage::GitRebaseContinue { .. }
        | ClientMessage::GitRebaseAbort { .. }
        | ClientMessage::GitOpStatus { .. }
        | ClientMessage::GitEnsureIntegrationWorktree { .. }
        | ClientMessage::GitMergeToDefault { .. }
        | ClientMessage::GitMergeContinue { .. }
        | ClientMessage::GitMergeAbort { .. }
        | ClientMessage::GitIntegrationStatus { .. }
        | ClientMessage::GitRebaseOntoDefault { .. }
        | ClientMessage::GitRebaseOntoDefaultContinue { .. }
        | ClientMessage::GitRebaseOntoDefaultAbort { .. }
        | ClientMessage::GitResetIntegrationWorktree { .. }
        | ClientMessage::GitCheckBranchUpToDate { .. }
        | ClientMessage::GitLog { .. }
        | ClientMessage::GitShow { .. }
        | ClientMessage::GitAICommit { .. } => {
            unreachable!("Git messages should be handled by git handler");
        }

        ClientMessage::ListProjects
        | ClientMessage::ListWorkspaces { .. }
        | ClientMessage::SelectWorkspace { .. }
        | ClientMessage::ImportProject { .. }
        | ClientMessage::CreateWorkspace { .. }
        | ClientMessage::RemoveProject { .. }
        | ClientMessage::RemoveWorkspace { .. } => {
            unreachable!("Project messages should be handled by project handler");
        }

        ClientMessage::GetClientSettings
        | ClientMessage::SaveClientSettings { .. } => {
            unreachable!("Settings messages should be handled by settings handler");
        }
    }

    Ok(())
}
