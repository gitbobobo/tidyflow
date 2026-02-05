use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::State,
    response::IntoResponse,
    routing::get,
    Router,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::process::parent_id;

use crate::pty::PtySession;
use crate::server::handlers::terminal;
use crate::server::handlers::file;
use crate::server::handlers::git;
use crate::server::handlers::project;
use crate::server::handlers::settings;
use crate::server::protocol::{
    ClientMessage, CustomCommandInfo, ServerMessage, TerminalInfo, PROTOCOL_VERSION,
    v1_capabilities,
};
use crate::server::watcher::{WorkspaceWatcher, WatchEvent};
use crate::workspace::state::{AppState, Project};

/// 获取工作空间的根路径，支持 "default" 虚拟工作空间
/// 如果 workspace 是 "default"，返回项目根目录
fn get_workspace_root(project: &Project, workspace: &str) -> Option<PathBuf> {
    if workspace == "default" {
        Some(project.root_path.clone())
    } else {
        project.get_workspace(workspace).map(|w| w.worktree_path.clone())
    }
}

/// 查找数据末尾不完整的 ANSI 转义序列的起始位置
/// 返回 Some(index) 表示从 index 开始是不完整的序列，需要保留到下次发送
/// 返回 None 表示数据完整，可以直接发送
///
/// ANSI 转义序列格式：
/// - CSI (Control Sequence Introducer): ESC [ ... 终止符 (字母)
/// - OSC (Operating System Command): ESC ] ... BEL 或 ESC \
/// - DCS (Device Control String): ESC P ... ESC \
/// - 简单序列: ESC 后跟单个字符
fn find_incomplete_escape_sequence(data: &[u8]) -> Option<usize> {
    if data.is_empty() {
        return None;
    }

    // 从末尾向前查找 ESC (0x1b)
    // 只检查最后 256 字节，避免性能问题
    let search_start = data.len().saturating_sub(256);

    for i in (search_start..data.len()).rev() {
        if data[i] == 0x1b {
            // 找到 ESC，检查后续序列是否完整
            let remaining = &data[i..];

            if remaining.len() < 2 {
                // ESC 后没有字符，不完整
                return Some(i);
            }

            match remaining[1] {
                // CSI 序列: ESC [ ... 终止符
                b'[' => {
                    // 查找终止符（字母 0x40-0x7E）
                    if remaining.len() == 2 {
                        // 只有 ESC [，缺少参数和终止符
                        return Some(i);
                    }
                    let mut found_terminator = false;
                    for j in 2..remaining.len() {
                        let c = remaining[j];
                        if (0x40..=0x7E).contains(&c) {
                            // 找到终止符，序列完整
                            found_terminator = true;
                            break;
                        }
                    }
                    if !found_terminator {
                        // 到达末尾仍未找到终止符，不完整
                        return Some(i);
                    }
                }
                // OSC 序列: ESC ] ... BEL(0x07) 或 ST(ESC \)
                b']' => {
                    let mut found_terminator = false;
                    for j in 2..remaining.len() {
                        if remaining[j] == 0x07 {
                            // BEL 终止符
                            found_terminator = true;
                            break;
                        }
                        if remaining[j] == 0x1b && j + 1 < remaining.len() && remaining[j + 1] == b'\\' {
                            // ST 终止符 (ESC \)
                            found_terminator = true;
                            break;
                        }
                    }
                    if !found_terminator {
                        return Some(i);
                    }
                }
                // DCS 序列: ESC P ... ESC \
                b'P' => {
                    let mut found_terminator = false;
                    for j in 2..remaining.len() {
                        if remaining[j] == 0x1b && j + 1 < remaining.len() && remaining[j + 1] == b'\\' {
                            found_terminator = true;
                            break;
                        }
                    }
                    if !found_terminator {
                        return Some(i);
                    }
                }
                // 简单转义序列: ESC 后跟单个字符
                _ => {
                    // 已经有第二个字符，序列完整
                }
            }
        }
    }

    // 检查 UTF-8 多字节字符是否被截断
    // UTF-8 编码规则：
    // - 1 字节: 0xxxxxxx
    // - 2 字节: 110xxxxx 10xxxxxx
    // - 3 字节: 1110xxxx 10xxxxxx 10xxxxxx
    // - 4 字节: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    if !data.is_empty() {
        let last = data[data.len() - 1];
        // 如果最后一个字节是多字节序列的起始字节，检查是否完整
        if last >= 0xC0 {
            // 这是一个多字节序列的起始字节，但后面没有续字节
            return Some(data.len() - 1);
        }
        // 检查倒数第二个字节
        if data.len() >= 2 {
            let second_last = data[data.len() - 2];
            if second_last >= 0xE0 && last >= 0x80 && last < 0xC0 {
                // 3 字节序列只有 2 字节
                return Some(data.len() - 2);
            }
        }
        // 检查倒数第三个字节
        if data.len() >= 3 {
            let third_last = data[data.len() - 3];
            if third_last >= 0xF0 && data[data.len() - 2] >= 0x80 && last >= 0x80 {
                // 4 字节序列只有 3 字节
                return Some(data.len() - 3);
            }
        }
    }

    None
}

/// Shared application state for the WebSocket server
pub type SharedAppState = Arc<Mutex<AppState>>;

/// Run the WebSocket server on the specified port
pub async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WebSocket server on port {}", port);

    // Start parent process monitor to auto-exit when parent dies (e.g., Xcode force stop)
    #[cfg(unix)]
    spawn_parent_monitor();

    // Load application state
    let app_state = AppState::load().unwrap_or_default();
    let shared_state: SharedAppState = Arc::new(Mutex::new(app_state));

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .with_state(shared_state);

    let addr = format!("127.0.0.1:{}", port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;

    info!("Listening on ws://{}/ws (protocol v{})", addr, PROTOCOL_VERSION);

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
    State(state): State<SharedAppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Single terminal session handle with workspace binding (v1.2)
pub struct TerminalHandle {
    pub session: PtySession,
    pub term_id: String,
    pub project: String,
    pub workspace: String,
    pub cwd: PathBuf,
}

/// Terminal manager for a connection - manages multiple terminals (v1.2: multi-workspace)
pub struct TerminalManager {
    pub terminals: HashMap<String, TerminalHandle>,
    pub default_term_id: Option<String>,
}

impl TerminalManager {
    pub fn new() -> Self {
        Self {
            terminals: HashMap::new(),
            default_term_id: None,
        }
    }

    pub fn spawn(
        &mut self,
        cwd: Option<PathBuf>,
        project: Option<String>,
        workspace: Option<String>,
        tx_output: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
        _tx_exit: tokio::sync::mpsc::Sender<(String, i32)>,
    ) -> Result<(String, String), String> {
        let term_id = Uuid::new_v4().to_string();
        let cwd_path = cwd.unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".to_string())));

        let mut session = PtySession::new(Some(cwd_path.clone()))
            .map_err(|e| format!("Failed to create PTY: {}", e))?;

        let shell_name = session.shell_name().to_string();
        
        // 为这个终端创建独立的读取线程
        let reader_term_id = term_id.clone();
        let reader = session.take_reader()
            .map_err(|e| format!("Failed to take reader: {}", e))?;
        
        std::thread::spawn(move || {
            use std::io::Read;
            let mut reader = reader;
            let mut buf = [0u8; 8192];
            // 保存不完整的 ANSI 转义序列，避免在缓冲区边界截断导致花屏
            let mut pending: Vec<u8> = Vec::new();
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => {
                        // EOF - terminal closed
                        // 发送剩余的 pending 数据
                        if !pending.is_empty() {
                            let _ = tx_output.blocking_send((reader_term_id.clone(), pending));
                        }
                        break;
                    }
                    Ok(n) => {
                        // 合并 pending 数据和新读取的数据
                        let mut data = if pending.is_empty() {
                            buf[..n].to_vec()
                        } else {
                            let mut combined = std::mem::take(&mut pending);
                            combined.extend_from_slice(&buf[..n]);
                            combined
                        };

                        // 检查数据末尾是否有不完整的 ANSI 转义序列
                        // ANSI 转义序列以 ESC (0x1b) 开头
                        if let Some(incomplete_start) = find_incomplete_escape_sequence(&data) {
                            // 将不完整的序列保存到 pending
                            pending = data.split_off(incomplete_start);
                        }

                        // 发送完整的数据
                        if !data.is_empty() {
                            if tx_output.blocking_send((reader_term_id.clone(), data)).is_err() {
                                // Channel closed, exit
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        debug!("PTY read error for {}: {}", reader_term_id, e);
                        break;
                    }
                }
            }
        });

        let handle = TerminalHandle {
            session,
            term_id: term_id.clone(),
            project: project.unwrap_or_default(),
            workspace: workspace.unwrap_or_default(),
            cwd: cwd_path,
        };

        // Set as default if first terminal
        if self.default_term_id.is_none() {
            self.default_term_id = Some(term_id.clone());
        }

        self.terminals.insert(term_id.clone(), handle);

        Ok((term_id, shell_name))
    }

    pub fn get(&self, term_id: &str) -> Option<&TerminalHandle> {
        self.terminals.get(term_id)
    }

    pub fn get_mut(&mut self, term_id: &str) -> Option<&mut TerminalHandle> {
        self.terminals.get_mut(term_id)
    }

    pub fn resolve_term_id(&self, term_id: Option<&str>) -> Option<String> {
        match term_id {
            Some(id) if self.terminals.contains_key(id) => Some(id.to_string()),
            Some(_) => None, // Invalid term_id
            None => self.default_term_id.clone(), // Use default
        }
    }

    pub fn close(&mut self, term_id: &str) -> bool {
        if let Some(mut handle) = self.terminals.remove(term_id) {
            handle.session.kill();
            // Update default if we closed the default terminal
            if self.default_term_id.as_ref() == Some(&term_id.to_string()) {
                self.default_term_id = self.terminals.keys().next().cloned();
            }
            true
        } else {
            false
        }
    }

    pub fn close_all(&mut self) {
        for (_, mut handle) in self.terminals.drain() {
            handle.session.kill();
        }
        self.default_term_id = None;
    }

    pub fn list(&self) -> Vec<TerminalInfo> {
        self.terminals
            .values()
            .map(|h| TerminalInfo {
                term_id: h.term_id.clone(),
                project: h.project.clone(),
                workspace: h.workspace.clone(),
                cwd: h.cwd.to_string_lossy().to_string(),
                status: "running".to_string(),
            })
            .collect()
    }

    pub fn term_ids(&self) -> Vec<String> {
        self.terminals.keys().cloned().collect()
    }
}

/// Handle a WebSocket connection
async fn handle_socket(mut socket: WebSocket, app_state: SharedAppState) {
    info!("New WebSocket connection established");

    // Create channels for terminal output and exit events
    let (tx_output, mut rx_output) = tokio::sync::mpsc::channel::<(String, Vec<u8>)>(100);
    let (tx_exit, mut rx_exit) = tokio::sync::mpsc::channel::<(String, i32)>(10);

    // Create channel for file watcher events
    let (tx_watch, mut rx_watch) = tokio::sync::mpsc::channel::<WatchEvent>(100);

    // Create terminal manager
    let manager = Arc::new(Mutex::new(TerminalManager::new()));

    // Create file watcher
    let watcher = Arc::new(Mutex::new(WorkspaceWatcher::new(tx_watch)));

    // Auto-spawn a default terminal session
    let (default_term_id, shell_name) = {
        let mut mgr = manager.lock().await;
        match mgr.spawn(None, None, None, tx_output.clone(), tx_exit.clone()) {
            Ok((term_id, shell)) => (term_id, shell),
            Err(e) => {
                error!("Failed to create initial PTY session: {}", e);
                let _ = socket.close().await;
                return;
            }
        }
    };

    info!(
        term_id = %default_term_id,
        shell = %shell_name,
        "Default PTY session created for WebSocket connection"
    );

    // Send Hello message with v1 capabilities
    let hello_msg = ServerMessage::Hello {
        version: PROTOCOL_VERSION,
        session_id: default_term_id.clone(),
        shell: shell_name.clone(),
        capabilities: Some(v1_capabilities()),
    };

    if let Err(e) = send_message(&mut socket, &hello_msg).await {
        error!("Failed to send Hello message: {}", e);
        return;
    }

    // 注意：PTY 读取现在由每个终端的独立线程处理，
    // 在 TerminalManager::spawn() 中创建

    // Main loop: handle WebSocket messages and PTY output
    info!("Entering main WebSocket loop");
    crate::util::flush_logs();
    let mut loop_count: u64 = 0;
    let mut last_log_time = std::time::Instant::now();
    loop {
        loop_count += 1;

        // Log first iteration and every 5 seconds
        if loop_count == 1 {
            info!("First loop iteration, about to call tokio::select!");
            crate::util::flush_logs();
        } else if last_log_time.elapsed().as_secs() >= 5 {
            info!("Main loop still running, iteration {}", loop_count);
            crate::util::flush_logs();
            last_log_time = std::time::Instant::now();
        }

        tokio::select! {
            biased;  // 优先处理 WebSocket 消息

            // Handle WebSocket messages (优先)
            msg_result = socket.recv() => {
                info!("socket.recv() returned: {:?}", msg_result.as_ref().map(|r| r.as_ref().map(|m| match m {
                    Message::Text(t) => format!("Text({}...)", &t[..t.len().min(50)]),
                    Message::Binary(b) => format!("Binary({} bytes)", b.len()),
                    Message::Ping(_) => "Ping".to_string(),
                    Message::Pong(_) => "Pong".to_string(),
                    Message::Close(_) => "Close".to_string(),
                })));
                match msg_result {
                    Some(Ok(Message::Binary(data))) => {
                        info!("Received binary client message: {} bytes", data.len());
                        if let Err(e) = handle_client_message(
                            &data,
                            &mut socket,
                            &manager,
                            &watcher,
                            &app_state,
                            tx_output.clone(),
                            tx_exit.clone(),
                        ).await {
                            warn!("Error handling client message: {}", e);
                            // 发送错误消息给客户端
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

            // Handle PTY output
            Some((term_id, output)) = rx_output.recv() => {
                debug!("PTY output received for term_id: {}, {} bytes", term_id, output.len());
                let msg = ServerMessage::Output {
                    data: output,
                    term_id: Some(term_id),
                };
                if let Err(e) = send_message(&mut socket, &msg).await {
                    error!("Failed to send output message: {}", e);
                    break;
                }
            }

            // Handle process exit
            Some((term_id, exit_code)) = rx_exit.recv() => {
                info!(term_id = %term_id, exit_code, "Sending exit message");
                let exit_msg = ServerMessage::Exit {
                    code: exit_code,
                    term_id: Some(term_id),
                };
                let _ = send_message(&mut socket, &exit_msg).await;
            }

            // Handle file watcher events
            Some(watch_event) = rx_watch.recv() => {
                match watch_event {
                    WatchEvent::FileChanged { project, workspace, paths, kind } => {
                        debug!("File changed: project={}, workspace={}, paths={:?}", project, workspace, paths);
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

    // Clean up all terminals
    {
        let mut mgr = manager.lock().await;
        mgr.close_all();
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

/// Handle a client message
async fn handle_client_message(
    data: &[u8],
    socket: &mut WebSocket,
    manager: &Arc<Mutex<TerminalManager>>,
    watcher: &Arc<Mutex<WorkspaceWatcher>>,
    app_state: &SharedAppState,
    tx_output: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    tx_exit: tokio::sync::mpsc::Sender<(String, i32)>,
) -> Result<(), String> {
    info!("handle_client_message called with data length: {}", data.len());
    let client_msg: ClientMessage =
        rmp_serde::from_slice(data).map_err(|e| {
            error!("Failed to parse client message: {}", e);
            format!("Parse error: {}", e)
        })?;
    info!("Parsed client message: {:?}", std::mem::discriminant(&client_msg));

    // Try terminal handler first
    if terminal::handle_terminal_message(&client_msg, socket, manager, app_state, tx_output.clone(), tx_exit.clone()).await? {
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
    if project::handle_project_message(&client_msg, socket, manager, app_state, tx_output.clone(), tx_exit.clone()).await? {
        return Ok(());
    }

    match client_msg {
        ClientMessage::Ping => {
            send_message(socket, &ServerMessage::Pong).await?;
        }

        // v1.21: Client settings
        ClientMessage::GetClientSettings => {
            let state = app_state.lock().await;
            let commands: Vec<CustomCommandInfo> = state.client_settings.custom_commands
                .iter()
                .map(|c| CustomCommandInfo {
                    id: c.id.clone(),
                    name: c.name.clone(),
                    icon: c.icon.clone(),
                    command: c.command.clone(),
                })
                .collect();
            send_message(socket, &ServerMessage::ClientSettingsResult {
                custom_commands: commands,
                workspace_shortcuts: state.client_settings.workspace_shortcuts.clone(),
            }).await?;
        }

        ClientMessage::SaveClientSettings { custom_commands, workspace_shortcuts } => {
            let mut state = app_state.lock().await;
            state.client_settings.custom_commands = custom_commands
                .into_iter()
                .map(|c| crate::workspace::state::CustomCommand {
                    id: c.id,
                    name: c.name,
                    icon: c.icon,
                    command: c.command,
                })
                .collect();
            state.client_settings.workspace_shortcuts = workspace_shortcuts;
            
            match state.save() {
                Ok(_) => {
                    send_message(socket, &ServerMessage::ClientSettingsSaved {
                        ok: true,
                        message: None,
                    }).await?;
                }
                Err(e) => {
                    send_message(socket, &ServerMessage::ClientSettingsSaved {
                        ok: false,
                        message: Some(format!("保存设置失败: {}", e)),
                    }).await?;
                }
            }
        }

        // v1.22: File watcher
        ClientMessage::WatchSubscribe { project, workspace } => {
            info!("WatchSubscribe: project={}, workspace={}", project, workspace);

            // 获取工作空间路径
            let state = app_state.lock().await;
            let watch_path = state.projects.get(&project).and_then(|p| {
                get_workspace_root(p, &workspace)
            });
            drop(state);

            match watch_path {
                Some(path) => {
                    let mut w = watcher.lock().await;
                    match w.subscribe(project.clone(), workspace.clone(), path) {
                        Ok(_) => {
                            send_message(socket, &ServerMessage::WatchSubscribed {
                                project,
                                workspace,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "watch_subscribe_failed".to_string(),
                                message: e,
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "workspace_not_found".to_string(),
                        message: format!("Workspace '{}' not found in project '{}'", workspace, project),
                    }).await?;
                }
            }
        }

        ClientMessage::WatchUnsubscribe => {
            info!("WatchUnsubscribe");
            let mut w = watcher.lock().await;
            w.unsubscribe();
            send_message(socket, &ServerMessage::WatchUnsubscribed).await?;
        }

        ClientMessage::Input { .. } |
        ClientMessage::Resize { .. } |
        ClientMessage::SpawnTerminal { .. } |
        ClientMessage::KillTerminal |
        ClientMessage::TermCreate { .. } |
        ClientMessage::TermList |
        ClientMessage::TermClose { .. } |
        ClientMessage::TermFocus { .. } => {
            unreachable!("Terminal messages should be handled by terminal handler");
        }

        ClientMessage::FileList { .. } |
        ClientMessage::FileRead { .. } |
        ClientMessage::FileWrite { .. } |
        ClientMessage::FileIndex { .. } |
        ClientMessage::FileRename { .. } |
        ClientMessage::FileDelete { .. } => {
            unreachable!("File messages should be handled by file handler");
        }

        ClientMessage::GitStatus { .. } |
        ClientMessage::GitDiff { .. } |
        ClientMessage::GitStage { .. } |
        ClientMessage::GitUnstage { .. } |
        ClientMessage::GitDiscard { .. } |
        ClientMessage::GitBranches { .. } |
        ClientMessage::GitSwitchBranch { .. } |
        ClientMessage::GitCreateBranch { .. } |
        ClientMessage::GitCommit { .. } |
        ClientMessage::GitFetch { .. } |
        ClientMessage::GitRebase { .. } |
        ClientMessage::GitRebaseContinue { .. } |
        ClientMessage::GitRebaseAbort { .. } |
        ClientMessage::GitOpStatus { .. } |
        ClientMessage::GitEnsureIntegrationWorktree { .. } |
        ClientMessage::GitMergeToDefault { .. } |
        ClientMessage::GitMergeContinue { .. } |
        ClientMessage::GitMergeAbort { .. } |
        ClientMessage::GitIntegrationStatus { .. } |
        ClientMessage::GitRebaseOntoDefault { .. } |
        ClientMessage::GitRebaseOntoDefaultContinue { .. } |
        ClientMessage::GitRebaseOntoDefaultAbort { .. } |
        ClientMessage::GitResetIntegrationWorktree { .. } |
        ClientMessage::GitCheckBranchUpToDate { .. } |
        ClientMessage::GitLog { .. } |
        ClientMessage::GitShow { .. } => {
            unreachable!("Git messages should be handled by git handler");
        }

        ClientMessage::ListProjects |
        ClientMessage::ListWorkspaces { .. } |
        ClientMessage::SelectWorkspace { .. } |
        ClientMessage::ImportProject { .. } |
        ClientMessage::CreateWorkspace { .. } |
        ClientMessage::RemoveProject { .. } |
        ClientMessage::RemoveWorkspace { .. } => {
            unreachable!("Project messages should be handled by project handler");
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_find_incomplete_escape_sequence_complete() {
        // 完整的 CSI 序列
        let data = b"\x1b[31mHello\x1b[0m";
        assert_eq!(find_incomplete_escape_sequence(data), None);

        // 完整的 OSC 序列 (BEL 终止)
        let data = b"\x1b]0;Title\x07";
        assert_eq!(find_incomplete_escape_sequence(data), None);

        // 普通文本
        let data = b"Hello World";
        assert_eq!(find_incomplete_escape_sequence(data), None);
    }

    #[test]
    fn test_find_incomplete_escape_sequence_incomplete_csi() {
        // 不完整的 CSI 序列 - 只有 ESC [
        let data = b"Hello\x1b[";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));

        // 不完整的 CSI 序列 - 缺少终止符
        let data = b"Hello\x1b[38;2;255";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));
    }

    #[test]
    fn test_find_incomplete_escape_sequence_incomplete_osc() {
        // 不完整的 OSC 序列
        let data = b"Hello\x1b]0;Title";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));
    }

    #[test]
    fn test_find_incomplete_escape_sequence_lone_esc() {
        // 单独的 ESC
        let data = b"Hello\x1b";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));
    }

    #[test]
    fn test_find_incomplete_escape_sequence_utf8() {
        // 完整的 UTF-8 中文
        let data = "你好".as_bytes();
        assert_eq!(find_incomplete_escape_sequence(data), None);

        // 不完整的 UTF-8 - 3 字节字符只有 1 字节
        let data = b"Hello\xe4";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));

        // 不完整的 UTF-8 - 3 字节字符只有 2 字节
        let data = b"Hello\xe4\xbd";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));
    }
}
