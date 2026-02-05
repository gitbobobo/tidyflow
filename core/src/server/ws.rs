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
use crate::server::file_api::{self, FileApiError};
use crate::server::file_index;
use crate::server::git_tools;
use crate::server::protocol::{
    ClientMessage, CustomCommandInfo, FileEntryInfo, GitBranchInfo, GitStatusEntry, ProjectInfo, ServerMessage, TerminalInfo, WorkspaceInfo, PROTOCOL_VERSION,
    v1_capabilities,
};
use crate::workspace::state::{AppState, Project, WorkspaceStatus};
use crate::workspace::project::ProjectManager;
use crate::workspace::workspace::WorkspaceManager;

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
struct TerminalHandle {
    session: PtySession,
    term_id: String,
    project: String,
    workspace: String,
    cwd: PathBuf,
}

/// Terminal manager for a connection - manages multiple terminals (v1.2: multi-workspace)
struct TerminalManager {
    terminals: HashMap<String, TerminalHandle>,
    default_term_id: Option<String>,
}

impl TerminalManager {
    fn new() -> Self {
        Self {
            terminals: HashMap::new(),
            default_term_id: None,
        }
    }

    fn spawn(
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

    fn get(&self, term_id: &str) -> Option<&TerminalHandle> {
        self.terminals.get(term_id)
    }

    fn get_mut(&mut self, term_id: &str) -> Option<&mut TerminalHandle> {
        self.terminals.get_mut(term_id)
    }

    fn resolve_term_id(&self, term_id: Option<&str>) -> Option<String> {
        match term_id {
            Some(id) if self.terminals.contains_key(id) => Some(id.to_string()),
            Some(_) => None, // Invalid term_id
            None => self.default_term_id.clone(), // Use default
        }
    }

    fn close(&mut self, term_id: &str) -> bool {
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

    fn close_all(&mut self) {
        for (_, mut handle) in self.terminals.drain() {
            handle.session.kill();
        }
        self.default_term_id = None;
    }

    fn list(&self) -> Vec<TerminalInfo> {
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

    fn term_ids(&self) -> Vec<String> {
        self.terminals.keys().cloned().collect()
    }
}

/// Handle a WebSocket connection
async fn handle_socket(mut socket: WebSocket, app_state: SharedAppState) {
    info!("New WebSocket connection established");

    // Create channels for terminal output and exit events
    let (tx_output, mut rx_output) = tokio::sync::mpsc::channel::<(String, Vec<u8>)>(100);
    let (tx_exit, mut rx_exit) = tokio::sync::mpsc::channel::<(String, i32)>(10);

    // Create terminal manager
    let manager = Arc::new(Mutex::new(TerminalManager::new()));

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
async fn send_message(socket: &mut WebSocket, msg: &ServerMessage) -> Result<(), String> {
    // 使用 to_vec_named 确保输出字典格式（带字段名），而不是数组格式
    // 这样 Swift 端的 AnyCodable 才能正确解析
    let bytes = rmp_serde::to_vec_named(msg).map_err(|e| e.to_string())?;
    socket
        .send(Message::Binary(bytes))
        .await
        .map_err(|e| e.to_string())
}

/// Convert FileApiError to error response tuple
fn file_error_to_response(e: &FileApiError) -> (String, String) {
    match e {
        FileApiError::PathEscape => ("path_escape".to_string(), e.to_string()),
        FileApiError::PathTooLong => ("path_too_long".to_string(), e.to_string()),
        FileApiError::FileNotFound => ("file_not_found".to_string(), e.to_string()),
        FileApiError::FileTooLarge => ("file_too_large".to_string(), e.to_string()),
        FileApiError::InvalidUtf8 => ("invalid_utf8".to_string(), e.to_string()),
        FileApiError::IoError(_) => ("io_error".to_string(), e.to_string()),
    }
}

/// Handle a client message
async fn handle_client_message(
    data: &[u8],
    socket: &mut WebSocket,
    manager: &Arc<Mutex<TerminalManager>>,
    app_state: &SharedAppState,
    tx_output: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    tx_exit: tokio::sync::mpsc::Sender<(String, i32)>,
) -> Result<(), String> {
    info!("handle_client_message called with data length: {}", data.len());
    // 打印接收到的原始数据（前100字节）
    let preview_len = data.len().min(100);
    info!("Raw data (first {} bytes): {:02x?}", preview_len, &data[..preview_len]);
    let client_msg: ClientMessage =
        rmp_serde::from_slice(data).map_err(|e| {
            error!("Failed to parse client message: {}", e);
            error!("Raw data hex: {:02x?}", data);
            format!("Parse error: {}", e)
        })?;
    info!("Parsed client message: {:?}", std::mem::discriminant(&client_msg));

    match client_msg {
        // v0/v1.1: Terminal data plane with optional term_id
        ClientMessage::Input { data, term_id } => {
            info!("[DEBUG] Input received: term_id={:?}, data_len={}", term_id, data.len());

            let mut mgr = manager.lock().await;
            let resolved_id = mgr.resolve_term_id(term_id.as_deref());
            info!("[DEBUG] Resolved term_id: {:?}, available_terms: {:?}", resolved_id, mgr.term_ids());

            if let Some(id) = resolved_id {
                if let Some(handle) = mgr.get_mut(&id) {
                    info!("[DEBUG] Writing input to PTY: term_id={}", id);
                    handle.session.write_input(&data)
                        .map_err(|e| format!("Write error: {}", e))?;
                    info!("[DEBUG] Input written successfully");
                } else {
                    info!("[DEBUG] Handle not found for term_id={}", id);
                }
            } else if term_id.is_some() {
                // Invalid term_id provided
                info!("[DEBUG] Term not found: {:?}", term_id);
                send_message(socket, &ServerMessage::Error {
                    code: "term_not_found".to_string(),
                    message: format!("Terminal '{}' not found", term_id.unwrap()),
                }).await?;
            } else {
                info!("[DEBUG] No term_id provided and no default terminal");
            }
        }

        ClientMessage::Resize { cols, rows, term_id } => {
            let mgr = manager.lock().await;
            let resolved_id = mgr.resolve_term_id(term_id.as_deref());

            if let Some(id) = resolved_id {
                if let Some(handle) = mgr.get(&id) {
                    handle.session.resize(cols, rows)
                        .map_err(|e| format!("Resize error: {}", e))?;
                }
            }
        }

        ClientMessage::Ping => {
            send_message(socket, &ServerMessage::Pong).await?;
        }

        // v1: Control plane - Workspace management
        ClientMessage::ListProjects => {
            let state = app_state.lock().await;
            let items: Vec<ProjectInfo> = state
                .projects
                .values()
                .map(|p| ProjectInfo {
                    name: p.name.clone(),
                    root: p.root_path.to_string_lossy().to_string(),
                    workspace_count: p.workspaces.len(),
                })
                .collect();
            send_message(socket, &ServerMessage::Projects { items }).await?;
        }

        ClientMessage::ListWorkspaces { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 收集所有真实的工作空间
                    let mut items: Vec<WorkspaceInfo> = p
                        .workspaces
                        .values()
                        .map(|w| WorkspaceInfo {
                            name: w.name.clone(),
                            root: w.worktree_path.to_string_lossy().to_string(),
                            branch: w.branch.clone(),
                            status: match w.status {
                                WorkspaceStatus::Ready => "ready".to_string(),
                                WorkspaceStatus::SetupFailed => "setup_failed".to_string(),
                                WorkspaceStatus::Creating => "creating".to_string(),
                                WorkspaceStatus::Initializing => "initializing".to_string(),
                                WorkspaceStatus::Destroying => "destroying".to_string(),
                            },
                        })
                        .collect();
                    
                    // 在列表开头添加虚拟的 "default" 工作空间，指向项目根目录
                    let default_ws = WorkspaceInfo {
                        name: "default".to_string(),
                        root: p.root_path.to_string_lossy().to_string(),
                        branch: p.default_branch.clone(),
                        status: "ready".to_string(),
                    };
                    items.insert(0, default_ws);
                    
                    send_message(
                        socket,
                        &ServerMessage::Workspaces {
                            project: project.clone(),
                            items,
                        },
                    )
                    .await?;
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
        }

        ClientMessage::SelectWorkspace { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 处理默认工作空间：如果 workspace 是 "default"，使用项目根目录
                    let (root_path, _branch) = if workspace == "default" {
                        (p.root_path.clone(), p.default_branch.clone())
                    } else {
                        match p.get_workspace(&workspace) {
                            Some(w) => (w.worktree_path.clone(), w.branch.clone()),
                            None => {
                                drop(state);
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
                                return Ok(());
                            }
                        }
                    };
                    drop(state);

                    // v1.2: Create new terminal in workspace WITHOUT closing existing terminals
                    // This enables multi-workspace parallel support
                    let (session_id, shell_name) = {
                        let mut mgr = manager.lock().await;
                        mgr.spawn(
                            Some(root_path.clone()),
                            Some(project.clone()),
                            Some(workspace.clone()),
                            tx_output.clone(),
                            tx_exit.clone(),
                        )
                        .map_err(|e| format!("Spawn error: {}", e))?
                    };

                    info!(
                        project = %project,
                        workspace = %workspace,
                        root = %root_path.display(),
                        term_id = %session_id,
                        "Terminal spawned in workspace"
                    );

                    send_message(
                        socket,
                        &ServerMessage::SelectedWorkspace {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            root: root_path.to_string_lossy().to_string(),
                            session_id,
                            shell: shell_name,
                        },
                    )
                    .await?;
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
        }

        ClientMessage::SpawnTerminal { cwd } => {
            let cwd_path = PathBuf::from(&cwd);
            if !cwd_path.exists() {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "invalid_path".to_string(),
                        message: format!("Path '{}' does not exist", cwd),
                    },
                )
                .await?;
                return Ok(());
            }

            // v1.2: Spawn new terminal WITHOUT closing existing (parallel support)
            let (session_id, shell_name) = {
                let mut mgr = manager.lock().await;
                mgr.spawn(Some(cwd_path.clone()), None, None, tx_output.clone(), tx_exit.clone())
                    .map_err(|e| format!("Spawn error: {}", e))?
            };

            info!(
                cwd = %cwd,
                term_id = %session_id,
                "Terminal spawned with custom cwd"
            );

            send_message(
                socket,
                &ServerMessage::TerminalSpawned {
                    session_id,
                    shell: shell_name,
                    cwd,
                },
            )
            .await?;
        }

        ClientMessage::KillTerminal => {
            let session_id = {
                let mut mgr = manager.lock().await;
                if let Some(default_id) = mgr.default_term_id.clone() {
                    mgr.close(&default_id);
                    default_id
                } else {
                    return Ok(());
                }
            };

            info!(term_id = %session_id, "Terminal killed by client request");
            send_message(socket, &ServerMessage::TerminalKilled { session_id }).await?;
        }

        // v1.2: Multi-workspace extension
        ClientMessage::TermCreate { project, workspace } => {
            info!(project = %project, workspace = %workspace, "TermCreate request received");
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 处理默认工作空间：如果 workspace 是 "default"，使用项目根目录
                    let root_path = if workspace == "default" {
                        info!(project = %project, "Using project root for default workspace");
                        p.root_path.clone()
                    } else {
                        match p.get_workspace(&workspace) {
                            Some(w) => w.worktree_path.clone(),
                            None => {
                                drop(state);
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
                                return Ok(());
                            }
                        }
                    };
                    drop(state);

                    let (term_id, shell_name) = {
                        let mut mgr = manager.lock().await;
                        mgr.spawn(
                            Some(root_path.clone()),
                            Some(project.clone()),
                            Some(workspace.clone()),
                            tx_output.clone(),
                            tx_exit.clone(),
                        )
                        .map_err(|e| format!("Spawn error: {}", e))?
                    };

                    info!(
                        project = %project,
                        workspace = %workspace,
                        term_id = %term_id,
                        "New terminal created in workspace"
                    );

                    send_message(
                        socket,
                        &ServerMessage::TermCreated {
                            term_id,
                            project: project.clone(),
                            workspace: workspace.clone(),
                            cwd: root_path.to_string_lossy().to_string(),
                            shell: shell_name,
                        },
                    )
                    .await?;
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
        }

        ClientMessage::TermList => {
            let mgr = manager.lock().await;
            let items = mgr.list();
            send_message(socket, &ServerMessage::TermList { items }).await?;
        }

        ClientMessage::TermClose { term_id } => {
            let closed = {
                let mut mgr = manager.lock().await;
                mgr.close(&term_id)
            };

            if closed {
                info!(term_id = %term_id, "Terminal closed by client request");
                send_message(socket, &ServerMessage::TermClosed { term_id }).await?;
            } else {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!("Terminal '{}' not found", term_id),
                    },
                )
                .await?;
            }
        }

        ClientMessage::TermFocus { term_id } => {
            // Optional: server can use this for optimization
            debug!(term_id = %term_id, "Client focused terminal");
        }

        // v1.3: File operations
        ClientMessage::FileList { project, workspace, path } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let path_str = if path.is_empty() { ".".to_string() } else { path };
                            match file_api::list_files(&root, &path_str) {
                                Ok(entries) => {
                                    let items: Vec<FileEntryInfo> = entries
                                        .into_iter()
                                        .map(|e| FileEntryInfo {
                                            name: e.name,
                                            is_dir: e.is_dir,
                                            size: e.size,
                                        })
                                        .collect();
                                    send_message(socket, &ServerMessage::FileListResult {
                                        project,
                                        workspace,
                                        path: path_str,
                                        items,
                                    }).await?;
                                }
                                Err(e) => {
                                    let (code, message) = file_error_to_response(&e);
                                    send_message(socket, &ServerMessage::Error { code, message }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        ClientMessage::FileRead { project, workspace, path } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            match file_api::read_file(&root, &path) {
                                Ok((content, size)) => {
                                    send_message(socket, &ServerMessage::FileReadResult {
                                        project,
                                        workspace,
                                        path,
                                        content: content.into_bytes(),
                                        size,
                                    }).await?;
                                }
                                Err(e) => {
                                    let (code, message) = file_error_to_response(&e);
                                    send_message(socket, &ServerMessage::Error { code, message }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        ClientMessage::FileWrite { project, workspace, path, content } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Decode UTF-8 content
                            match String::from_utf8(content) {
                                Ok(content_str) => {
                                    match file_api::write_file(&root, &path, &content_str) {
                                        Ok(size) => {
                                            send_message(socket, &ServerMessage::FileWriteResult {
                                                project,
                                                workspace,
                                                path,
                                                success: true,
                                                size,
                                            }).await?;
                                        }
                                        Err(e) => {
                                            let (code, message) = file_error_to_response(&e);
                                            send_message(socket, &ServerMessage::Error { code, message }).await?;
                                        }
                                    }
                                }
                                Err(_) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "invalid_utf8".to_string(),
                                        message: "Content is not valid UTF-8".to_string(),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.4: File index for Quick Open
        ClientMessage::FileIndex { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run indexing in blocking task to avoid blocking async runtime
                            let result = tokio::task::spawn_blocking(move || {
                                file_index::index_files(&root)
                            }).await;

                            match result {
                                Ok(Ok(index_result)) => {
                                    send_message(socket, &ServerMessage::FileIndexResult {
                                        project,
                                        workspace,
                                        items: index_result.items,
                                        truncated: index_result.truncated,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "io_error".to_string(),
                                        message: format!("Failed to index files: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Index task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.5: Git status
        ClientMessage::GitStatus { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git status in blocking task
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_status(&root)
                            }).await;

                            match result {
                                Ok(Ok(status_result)) => {
                                    let items: Vec<GitStatusEntry> = status_result.items
                                        .into_iter()
                                        .map(|e| GitStatusEntry {
                                            path: e.path,
                                            code: e.code,
                                            orig_path: e.orig_path,
                                            staged: e.staged,
                                            additions: e.additions,
                                            deletions: e.deletions,
                                        })
                                        .collect();

                                    send_message(socket, &ServerMessage::GitStatusResult {
                                        project,
                                        workspace,
                                        repo_root: status_result.repo_root,
                                        items,
                                        has_staged_changes: status_result.has_staged_changes,
                                        staged_count: status_result.staged_count,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git status failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git status task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.5: Git diff
        ClientMessage::GitDiff { project, workspace, path, base, mode } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git diff in blocking task
                            let path_clone = path.clone();
                            let mode_clone = mode.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_diff(&root, &path_clone, base.as_deref(), &mode_clone)
                            }).await;

                            match result {
                                Ok(Ok(diff_result)) => {
                                    send_message(socket, &ServerMessage::GitDiffResult {
                                        project,
                                        workspace,
                                        path,
                                        code: diff_result.code,
                                        format: diff_result.format,
                                        text: diff_result.text,
                                        is_binary: diff_result.is_binary,
                                        truncated: diff_result.truncated,
                                        mode: diff_result.mode,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git diff failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git diff task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.6: Git stage
        ClientMessage::GitStage { project, workspace, path, scope } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let path_clone = path.clone();
                            let scope_clone = scope.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_stage(&root, path_clone.as_deref(), &scope_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: "stage".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path,
                                        scope,
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git stage task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.6: Git unstage
        ClientMessage::GitUnstage { project, workspace, path, scope } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let path_clone = path.clone();
                            let scope_clone = scope.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_unstage(&root, path_clone.as_deref(), &scope_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: "unstage".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path,
                                        scope,
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git unstage task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.7: Git discard
        ClientMessage::GitDiscard { project, workspace, path, scope } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let path_clone = path.clone();
                            let scope_clone = scope.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_discard(&root, path_clone.as_deref(), &scope_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: "discard".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path,
                                        scope,
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git discard task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.8: Git branches
        ClientMessage::GitBranches { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_branches(&root)
                            }).await;

                            match result {
                                Ok(Ok(branches_result)) => {
                                    let branches: Vec<GitBranchInfo> = branches_result.branches
                                        .into_iter()
                                        .map(|b| GitBranchInfo { name: b.name })
                                        .collect();

                                    send_message(socket, &ServerMessage::GitBranchesResult {
                                        project,
                                        workspace,
                                        current: branches_result.current,
                                        branches,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git branches failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git branches task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.8: Git switch branch
        ClientMessage::GitSwitchBranch { project, workspace, branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let branch_clone = branch.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_switch_branch(&root, &branch_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: "switch_branch".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: Some(branch),
                                        scope: "branch".to_string(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git switch branch task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.9: Git create branch
        ClientMessage::GitCreateBranch { project, workspace, branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let branch_clone = branch.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_create_branch(&root, &branch_clone)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: "create_branch".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: Some(branch),
                                        scope: "branch".to_string(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git create branch task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.10: Git commit
        ClientMessage::GitCommit { project, workspace, message } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let message_clone = message.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_commit(&root, &message_clone)
                            }).await;

                            match result {
                                Ok(Ok(commit_result)) => {
                                    send_message(socket, &ServerMessage::GitCommitResult {
                                        project,
                                        workspace,
                                        ok: commit_result.ok,
                                        message: commit_result.message,
                                        sha: commit_result.sha,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitCommitResult {
                                        project,
                                        workspace,
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        sha: None,
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git commit task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.11: Git fetch (UX-3a)
        ClientMessage::GitFetch { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_fetch(&root)
                            }).await;

                            match result {
                                Ok(Ok(op_result)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitOpResult {
                                        project,
                                        workspace,
                                        op: "fetch".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: None,
                                        scope: "all".to_string(),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git fetch task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.11: Git rebase (UX-3a)
        ClientMessage::GitRebase { project, workspace, onto_branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let onto_clone = onto_branch.clone();
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_rebase(&root, &onto_clone)
                            }).await;

                            match result {
                                Ok(Ok(rebase_result)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project,
                                        workspace,
                                        ok: rebase_result.ok,
                                        state: rebase_result.state,
                                        message: rebase_result.message,
                                        conflicts: rebase_result.conflicts,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project,
                                        workspace,
                                        ok: false,
                                        state: "error".to_string(),
                                        message: Some(format!("{}", e)),
                                        conflicts: vec![],
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git rebase task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.11: Git rebase continue (UX-3a)
        ClientMessage::GitRebaseContinue { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_rebase_continue(&root)
                            }).await;

                            match result {
                                Ok(Ok(rebase_result)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project,
                                        workspace,
                                        ok: rebase_result.ok,
                                        state: rebase_result.state,
                                        message: rebase_result.message,
                                        conflicts: rebase_result.conflicts,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project,
                                        workspace,
                                        ok: false,
                                        state: "error".to_string(),
                                        message: Some(format!("{}", e)),
                                        conflicts: vec![],
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git rebase continue task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.11: Git rebase abort (UX-3a)
        ClientMessage::GitRebaseAbort { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_rebase_abort(&root)
                            }).await;

                            match result {
                                Ok(Ok(rebase_result)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project,
                                        workspace,
                                        ok: rebase_result.ok,
                                        state: rebase_result.state,
                                        message: rebase_result.message,
                                        conflicts: rebase_result.conflicts,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::GitRebaseResult {
                                        project,
                                        workspace,
                                        ok: false,
                                        state: "error".to_string(),
                                        message: Some(format!("{}", e)),
                                        conflicts: vec![],
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git rebase abort task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.11: Git operation status (UX-3a)
        ClientMessage::GitOpStatus { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_op_status(&root)
                            }).await;

                            match result {
                                Ok(Ok(status_result)) => {
                                    send_message(socket, &ServerMessage::GitOpStatusResult {
                                        project,
                                        workspace,
                                        state: status_result.state.as_str().to_string(),
                                        conflicts: status_result.conflicts,
                                        head: status_result.head,
                                        onto: status_result.onto,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git op status failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git op status task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.12: Git ensure integration worktree (UX-3b)
        ClientMessage::GitEnsureIntegrationWorktree { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let root = p.root_path.clone();
                    let project_name = p.name.clone();
                    drop(state);

                    // Default to "main" branch for now
                    let default_branch = "main".to_string();
                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::ensure_integration_worktree(&root, &project_name, &default_branch)
                    }).await;

                    match result {
                        Ok(Ok(path)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project,
                                ok: true,
                                state: "idle".to_string(),
                                message: Some("Integration worktree ready".to_string()),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: Some(path),
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project,
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Ensure integration worktree task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.12: Git merge to default (UX-3b)
        ClientMessage::GitMergeToDefault { project, workspace, default_branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 获取源分支：如果是默认工作空间，使用项目默认分支
                    let source_branch = if workspace == "default" {
                        p.default_branch.clone()
                    } else {
                        match p.get_workspace(&workspace) {
                            Some(w) => w.branch.clone(),
                            None => {
                                drop(state);
                                send_message(socket, &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                }).await?;
                                return Ok(());
                            }
                        }
                    };
                    let root = p.root_path.clone();
                    let project_name = p.name.clone();
                    drop(state);

                    // Check if workspace is on a branch (not detached HEAD)
                    if source_branch == "HEAD" || source_branch.is_empty() {
                        send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                            project,
                            ok: false,
                            state: "failed".to_string(),
                            message: Some("Workspace is in detached HEAD state. Create/switch to a branch first.".to_string()),
                            conflicts: vec![],
                            head_sha: None,
                            integration_path: None,
                        }).await?;
                        return Ok(());
                    }

                    let default_branch_clone = default_branch.clone();
                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::merge_to_default(&root, &project_name, &source_branch, &default_branch_clone)
                    }).await;

                    match result {
                        Ok(Ok(merge_result)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project,
                                ok: merge_result.ok,
                                state: merge_result.state,
                                message: merge_result.message,
                                conflicts: merge_result.conflicts,
                                head_sha: merge_result.head_sha,
                                integration_path: merge_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project,
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Merge to default task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.12: Git merge continue (UX-3b)
        ClientMessage::GitMergeContinue { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::merge_continue(&project_name)
                    }).await;

                    match result {
                        Ok(Ok(merge_result)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project,
                                ok: merge_result.ok,
                                state: merge_result.state,
                                message: merge_result.message,
                                conflicts: merge_result.conflicts,
                                head_sha: merge_result.head_sha,
                                integration_path: merge_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project,
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Merge continue task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.12: Git merge abort (UX-3b)
        ClientMessage::GitMergeAbort { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::merge_abort(&project_name)
                    }).await;

                    match result {
                        Ok(Ok(merge_result)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project,
                                ok: merge_result.ok,
                                state: merge_result.state,
                                message: merge_result.message,
                                conflicts: merge_result.conflicts,
                                head_sha: merge_result.head_sha,
                                integration_path: merge_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitMergeToDefaultResult {
                                project,
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Merge abort task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.12: Git integration status (UX-3b)
        ClientMessage::GitIntegrationStatus { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    // Default to "main" branch for now
                    let default_branch = "main".to_string();
                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::integration_status(&project_name, &default_branch)
                    }).await;

                    match result {
                        Ok(Ok(status_result)) => {
                            send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                                project,
                                state: status_result.state.as_str().to_string(),
                                conflicts: status_result.conflicts,
                                head: status_result.head,
                                default_branch: status_result.default_branch,
                                path: status_result.path,
                                is_clean: status_result.is_clean,
                                branch_ahead_by: status_result.branch_ahead_by,
                                branch_behind_by: status_result.branch_behind_by,
                                compared_branch: status_result.compared_branch,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "git_error".to_string(),
                                message: format!("Integration status failed: {}", e),
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Integration status task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.13: Git rebase onto default (UX-4)
        ClientMessage::GitRebaseOntoDefault { project, workspace, default_branch } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 获取源分支：如果是默认工作空间，使用项目默认分支
                    let source_branch = if workspace == "default" {
                        p.default_branch.clone()
                    } else {
                        match p.get_workspace(&workspace) {
                            Some(w) => w.branch.clone(),
                            None => {
                                drop(state);
                                send_message(socket, &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                }).await?;
                                return Ok(());
                            }
                        }
                    };
                    let root = p.root_path.clone();
                    let project_name = p.name.clone();
                    drop(state);

                    // Check if workspace is on a branch (not detached HEAD)
                    if source_branch == "HEAD" || source_branch.is_empty() {
                        send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                            project,
                            ok: false,
                            state: "failed".to_string(),
                            message: Some("Workspace is in detached HEAD state. Create/switch to a branch first.".to_string()),
                            conflicts: vec![],
                            head_sha: None,
                            integration_path: None,
                        }).await?;
                        return Ok(());
                    }

                    let default_branch_clone = default_branch.clone();
                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::rebase_onto_default(&root, &project_name, &source_branch, &default_branch_clone)
                    }).await;

                    match result {
                        Ok(Ok(rebase_result)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project,
                                ok: rebase_result.ok,
                                state: rebase_result.state,
                                message: rebase_result.message,
                                conflicts: rebase_result.conflicts,
                                head_sha: rebase_result.head_sha,
                                integration_path: rebase_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project,
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Rebase onto default task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.13: Git rebase onto default continue (UX-4)
        ClientMessage::GitRebaseOntoDefaultContinue { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::rebase_onto_default_continue(&project_name)
                    }).await;

                    match result {
                        Ok(Ok(rebase_result)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project,
                                ok: rebase_result.ok,
                                state: rebase_result.state,
                                message: rebase_result.message,
                                conflicts: rebase_result.conflicts,
                                head_sha: rebase_result.head_sha,
                                integration_path: rebase_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project,
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Rebase continue task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.13: Git rebase onto default abort (UX-4)
        ClientMessage::GitRebaseOntoDefaultAbort { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    drop(state);

                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::rebase_onto_default_abort(&project_name)
                    }).await;

                    match result {
                        Ok(Ok(rebase_result)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project,
                                ok: rebase_result.ok,
                                state: rebase_result.state,
                                message: rebase_result.message,
                                conflicts: rebase_result.conflicts,
                                head_sha: rebase_result.head_sha,
                                integration_path: rebase_result.integration_path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitRebaseOntoDefaultResult {
                                project,
                                ok: false,
                                state: "failed".to_string(),
                                message: Some(format!("{}", e)),
                                conflicts: vec![],
                                head_sha: None,
                                integration_path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Rebase abort task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.14: Git reset integration worktree (UX-5)
        ClientMessage::GitResetIntegrationWorktree { project } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    let project_name = p.name.clone();
                    let repo_root = p.root_path.clone();
                    drop(state);

                    // Use "main" as default branch for reset
                    let default_branch = "main".to_string();
                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::reset_integration_worktree(
                            &PathBuf::from(&repo_root),
                            &project_name,
                            &default_branch,
                        )
                    }).await;

                    match result {
                        Ok(Ok(reset_result)) => {
                            send_message(socket, &ServerMessage::GitResetIntegrationWorktreeResult {
                                project,
                                ok: reset_result.ok,
                                message: reset_result.message,
                                path: reset_result.path,
                            }).await?;
                        }
                        Ok(Err(e)) => {
                            send_message(socket, &ServerMessage::GitResetIntegrationWorktreeResult {
                                project,
                                ok: false,
                                message: Some(format!("{}", e)),
                                path: None,
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Reset integration worktree task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.15: Git check branch up to date (UX-6)
        ClientMessage::GitCheckBranchUpToDate { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    // 获取工作空间信息：如果是默认工作空间，使用项目根目录和默认分支
                    let (root, current_branch) = if workspace == "default" {
                        (p.root_path.clone(), p.default_branch.clone())
                    } else {
                        match p.get_workspace(&workspace) {
                            Some(w) => (w.worktree_path.clone(), w.branch.clone()),
                            None => {
                                drop(state);
                                send_message(socket, &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                }).await?;
                                return Ok(());
                            }
                        }
                    };
                    let project_name = p.name.clone();
                    drop(state);

                    // Check if workspace is on a branch (not detached HEAD)
                    if current_branch == "HEAD" || current_branch.is_empty() {
                        send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                            project,
                            state: "idle".to_string(),
                            conflicts: vec![],
                            head: None,
                            default_branch: "main".to_string(),
                            path: root.to_string_lossy().to_string(),
                            is_clean: true,
                            branch_ahead_by: None,
                            branch_behind_by: None,
                            compared_branch: None,
                        }).await?;
                        return Ok(());
                    }

                    // Default to "main" branch for comparison
                    let default_branch = "main".to_string();
                    let default_branch_clone = default_branch.clone();
                    let current_branch_clone = current_branch.clone();

                    let result = tokio::task::spawn_blocking(move || {
                        git_tools::check_branch_divergence(&root, &current_branch_clone, &default_branch_clone)
                    }).await;

                    match result {
                        Ok(Ok(divergence_result)) => {
                            // Get integration status for the full response
                            let integration_result = tokio::task::spawn_blocking({
                                let project_name = project_name.clone();
                                let default_branch = default_branch.clone();
                                move || {
                                    git_tools::integration_status(&project_name, &default_branch)
                                }
                            }).await;

                            match integration_result {
                                Ok(Ok(status_result)) => {
                                    send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                                        project,
                                        state: status_result.state.as_str().to_string(),
                                        conflicts: status_result.conflicts,
                                        head: status_result.head,
                                        default_branch: status_result.default_branch,
                                        path: status_result.path,
                                        is_clean: status_result.is_clean,
                                        branch_ahead_by: Some(divergence_result.ahead_by),
                                        branch_behind_by: Some(divergence_result.behind_by),
                                        compared_branch: Some(divergence_result.compared_branch),
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    // Integration status failed, but we still have divergence info
                                    send_message(socket, &ServerMessage::GitIntegrationStatusResult {
                                        project,
                                        state: "idle".to_string(),
                                        conflicts: vec![],
                                        head: None,
                                        default_branch,
                                        path: String::new(),
                                        is_clean: true,
                                        branch_ahead_by: Some(divergence_result.ahead_by),
                                        branch_behind_by: Some(divergence_result.behind_by),
                                        compared_branch: Some(divergence_result.compared_branch),
                                    }).await?;
                                    warn!("Integration status failed: {}", e);
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Integration status task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        Ok(Err(e)) => {
                            // Divergence check failed, return error
                            send_message(socket, &ServerMessage::Error {
                                code: "git_error".to_string(),
                                message: format!("Branch divergence check failed: {}", e),
                            }).await?;
                        }
                        Err(e) => {
                            send_message(socket, &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("Branch divergence task failed: {}", e),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.16: Import project
        ClientMessage::ImportProject { name, path } => {
            info!("ImportProject request: name={}, path={}", name, path);
            let path_buf = PathBuf::from(&path);
            info!("Acquiring app_state lock...");
            let mut state = app_state.lock().await;
            info!("app_state lock acquired, calling ProjectManager::import_local");

            match ProjectManager::import_local(&mut state, &name, &path_buf) {
                Ok(project) => {
                    info!("Project imported successfully: {}", project.name);
                    let default_branch = project.default_branch.clone();
                    let root = project.root_path.to_string_lossy().to_string();

                    info!("Sending ProjectImported response...");
                    send_message(socket, &ServerMessage::ProjectImported {
                        name,
                        root,
                        default_branch,
                        workspace: None, // 不再自动创建工作空间
                    }).await?;
                    info!("ProjectImported response sent successfully");
                }
                Err(e) => {
                    let (code, message) = match &e {
                        crate::workspace::project::ProjectError::AlreadyExists(_) => {
                            ("project_exists".to_string(), e.to_string())
                        }
                        crate::workspace::project::ProjectError::PathNotFound(_) => {
                            ("path_not_found".to_string(), e.to_string())
                        }
                        crate::workspace::project::ProjectError::NotGitRepo(_) => {
                            ("not_git_repo".to_string(), e.to_string())
                        }
                        _ => ("import_error".to_string(), e.to_string()),
                    };
                    send_message(socket, &ServerMessage::Error { code, message }).await?;
                }
            }
        }

        // v1.16: Create workspace（名称由 Core 用 petname 生成）
        ClientMessage::CreateWorkspace { project, from_branch } => {
            let mut state = app_state.lock().await;

            match WorkspaceManager::create(&mut state, &project, from_branch.as_deref(), false) {
                Ok(ws) => {
                    send_message(socket, &ServerMessage::WorkspaceCreated {
                        project,
                        workspace: WorkspaceInfo {
                            name: ws.name,
                            root: ws.worktree_path.to_string_lossy().to_string(),
                            branch: ws.branch,
                            status: match ws.status {
                                WorkspaceStatus::Ready => "ready".to_string(),
                                WorkspaceStatus::SetupFailed => "setup_failed".to_string(),
                                WorkspaceStatus::Creating => "creating".to_string(),
                                WorkspaceStatus::Initializing => "initializing".to_string(),
                                WorkspaceStatus::Destroying => "destroying".to_string(),
                            },
                        },
                    }).await?;
                }
                Err(e) => {
                    let (code, message) = match &e {
                        crate::workspace::workspace::WorkspaceError::AlreadyExists(_) => {
                            ("workspace_exists".to_string(), e.to_string())
                        }
                        crate::workspace::workspace::WorkspaceError::ProjectNotFound(_) => {
                            ("project_not_found".to_string(), e.to_string())
                        }
                        _ => ("workspace_error".to_string(), e.to_string()),
                    };
                    send_message(socket, &ServerMessage::Error { code, message }).await?;
                }
            }
        }

        // v1.17: Remove project
        ClientMessage::RemoveProject { name } => {
            info!("RemoveProject request: name={}", name);
            let mut state = app_state.lock().await;

            match ProjectManager::remove(&mut state, &name) {
                Ok(_) => {
                    info!("Project removed successfully: {}", name);
                    send_message(socket, &ServerMessage::ProjectRemoved {
                        name,
                        ok: true,
                        message: Some("项目已移除".to_string()),
                    }).await?;
                }
                Err(e) => {
                    warn!("Failed to remove project: {}, error: {}", name, e);
                    send_message(socket, &ServerMessage::ProjectRemoved {
                        name,
                        ok: false,
                        message: Some(e.to_string()),
                    }).await?;
                }
            }
        }

        // v1.18: Remove workspace
        ClientMessage::RemoveWorkspace { project, workspace } => {
            info!("RemoveWorkspace request: project={}, workspace={}", project, workspace);
            let mut state = app_state.lock().await;

            match WorkspaceManager::remove(&mut state, &project, &workspace) {
                Ok(_) => {
                    info!("Workspace removed successfully: {} / {}", project, workspace);
                    send_message(socket, &ServerMessage::WorkspaceRemoved {
                        project: project.clone(),
                        workspace: workspace.clone(),
                        ok: true,
                        message: Some("工作空间已删除".to_string()),
                    }).await?;
                }
                Err(e) => {
                    warn!("Failed to remove workspace: {} / {}, error: {}", project, workspace, e);
                    send_message(socket, &ServerMessage::WorkspaceRemoved {
                        project,
                        workspace,
                        ok: false,
                        message: Some(e.to_string()),
                    }).await?;
                }
            }
        }

        // v1.19: Git log (commit history)
        ClientMessage::GitLog { project, workspace, limit } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git log in blocking task
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_log(&root, limit)
                            }).await;

                            match result {
                                Ok(Ok(log_result)) => {
                                    use crate::server::protocol::GitLogEntryInfo;
                                    let entries: Vec<GitLogEntryInfo> = log_result.entries
                                        .into_iter()
                                        .map(|e| GitLogEntryInfo {
                                            sha: e.sha,
                                            message: e.message,
                                            author: e.author,
                                            date: e.date,
                                            refs: e.refs,
                                        })
                                        .collect();

                                    send_message(socket, &ServerMessage::GitLogResult {
                                        project,
                                        workspace,
                                        entries,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git log failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git log task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        // v1.20: Git show (single commit details)
        ClientMessage::GitShow { project, workspace, sha } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => {
                    match get_workspace_root(p, &workspace) {
                        Some(root) => {
                            drop(state);

                            // Run git show in blocking task
                            let result = tokio::task::spawn_blocking(move || {
                                git_tools::git_show(&root, &sha)
                            }).await;

                            match result {
                                Ok(Ok(show_result)) => {
                                    use crate::server::protocol::GitShowFileInfo;
                                    let files: Vec<GitShowFileInfo> = show_result.files
                                        .into_iter()
                                        .map(|f| GitShowFileInfo {
                                            status: f.status,
                                            path: f.path,
                                            old_path: f.old_path,
                                        })
                                        .collect();

                                    send_message(socket, &ServerMessage::GitShowResult {
                                        project,
                                        workspace,
                                        sha: show_result.sha,
                                        full_sha: show_result.full_sha,
                                        message: show_result.message,
                                        author: show_result.author,
                                        author_email: show_result.author_email,
                                        date: show_result.date,
                                        files,
                                    }).await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git show failed: {}", e),
                                    }).await?;
                                }
                                Err(e) => {
                                    send_message(socket, &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git show task failed: {}", e),
                                    }).await?;
                                }
                            }
                        }
                        None => {
                            send_message(socket, &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            }).await?;
                        }
                    }
                }
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
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
