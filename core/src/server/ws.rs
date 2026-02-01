use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::State,
    response::IntoResponse,
    routing::get,
    Router,
};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

use crate::pty::PtySession;
use crate::server::file_api::{self, FileApiError};
use crate::server::file_index;
use crate::server::git_tools;
use crate::server::protocol::{
    ClientMessage, FileEntryInfo, GitBranchInfo, GitStatusEntry, ProjectInfo, ServerMessage, TerminalInfo, WorkspaceInfo, PROTOCOL_VERSION,
    v1_capabilities,
};
use crate::workspace::state::{AppState, WorkspaceStatus};

/// Shared application state for the WebSocket server
pub type SharedAppState = Arc<Mutex<AppState>>;

/// Run the WebSocket server on the specified port
pub async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WebSocket server on port {}", port);

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
        _tx_output: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
        _tx_exit: tokio::sync::mpsc::Sender<(String, i32)>,
    ) -> Result<(String, String), String> {
        let term_id = Uuid::new_v4().to_string();
        let cwd_path = cwd.unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".to_string())));

        let session = PtySession::new(Some(cwd_path.clone()))
            .map_err(|e| format!("Failed to create PTY: {}", e))?;

        let shell_name = session.shell_name().to_string();

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

    // Spawn PTY reader tasks for all terminals
    let manager_reader = Arc::clone(&manager);
    let tx_output_reader = tx_output.clone();
    let tx_exit_reader = tx_exit.clone();

    tokio::spawn(async move {
        loop {
            // Get list of terminal IDs to read from
            let term_ids = {
                let mgr = manager_reader.lock().await;
                mgr.term_ids()
            };

            if term_ids.is_empty() {
                tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
                continue;
            }

            for term_id in term_ids {
                let (bytes_read, exit_code) = {
                    let mut mgr = manager_reader.lock().await;
                    if let Some(handle) = mgr.get_mut(&term_id) {
                        let mut buf = [0u8; 8192];
                        let bytes = match handle.session.read_output(&mut buf) {
                            Ok(n) if n > 0 => Some(buf[..n].to_vec()),
                            Ok(_) => None,
                            Err(_) => None,
                        };
                        let exit = handle.session.wait();
                        (bytes, exit)
                    } else {
                        (None, None)
                    }
                };

                if let Some(data) = bytes_read {
                    if tx_output_reader.send((term_id.clone(), data)).await.is_err() {
                        debug!("PTY reader: output channel closed");
                        return;
                    }
                }

                if let Some(code) = exit_code {
                    info!(term_id = %term_id, exit_code = code, "Terminal process exited");
                    let _ = tx_exit_reader.send((term_id.clone(), code)).await;
                    // Remove from manager
                    let mut mgr = manager_reader.lock().await;
                    mgr.close(&term_id);
                }
            }

            // Small delay to prevent busy loop
            tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
        }
    });

    // Main loop: handle WebSocket messages and PTY output
    loop {
        tokio::select! {
            // Handle PTY output
            Some((term_id, output)) = rx_output.recv() => {
                let data_b64 = BASE64.encode(&output);
                let msg = ServerMessage::Output {
                    data_b64,
                    term_id: Some(term_id),
                };
                if let Err(e) = send_message(&mut socket, &msg).await {
                    error!("Failed to send output message: {}", e);
                    break;
                }
            }

            // Handle WebSocket messages
            Some(msg) = socket.recv() => {
                match msg {
                    Ok(Message::Text(text)) => {
                        if let Err(e) = handle_client_message(
                            &text,
                            &mut socket,
                            &manager,
                            &app_state,
                            tx_output.clone(),
                            tx_exit.clone(),
                        ).await {
                            warn!("Error handling client message: {}", e);
                        }
                    }
                    Ok(Message::Close(_)) => {
                        info!("WebSocket connection closed by client");
                        break;
                    }
                    Ok(Message::Binary(_)) => {
                        warn!("Received unexpected binary message");
                    }
                    Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                        // Handled automatically by axum
                    }
                    Err(e) => {
                        error!("WebSocket error: {}", e);
                        break;
                    }
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
    let json = serde_json::to_string(msg).map_err(|e| e.to_string())?;
    socket
        .send(Message::Text(json))
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
    text: &str,
    socket: &mut WebSocket,
    manager: &Arc<Mutex<TerminalManager>>,
    app_state: &SharedAppState,
    tx_output: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    tx_exit: tokio::sync::mpsc::Sender<(String, i32)>,
) -> Result<(), String> {
    let client_msg: ClientMessage =
        serde_json::from_str(text).map_err(|e| format!("Parse error: {}", e))?;

    match client_msg {
        // v0/v1.1: Terminal data plane with optional term_id
        ClientMessage::Input { data_b64, term_id } => {
            let data = BASE64
                .decode(&data_b64)
                .map_err(|e| format!("Base64 decode error: {}", e))?;

            let mut mgr = manager.lock().await;
            let resolved_id = mgr.resolve_term_id(term_id.as_deref());

            if let Some(id) = resolved_id {
                if let Some(handle) = mgr.get_mut(&id) {
                    handle.session.write_input(&data)
                        .map_err(|e| format!("Write error: {}", e))?;
                }
            } else if term_id.is_some() {
                // Invalid term_id provided
                send_message(socket, &ServerMessage::Error {
                    code: "term_not_found".to_string(),
                    message: format!("Terminal '{}' not found", term_id.unwrap()),
                }).await?;
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
                    let items: Vec<WorkspaceInfo> = p
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root_path = w.worktree_path.clone();
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
                                code: "workspace_not_found".to_string(),
                                message: format!(
                                    "Workspace '{}' not found in project '{}'",
                                    workspace, project
                                ),
                            },
                        )
                        .await?;
                    }
                },
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
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root_path = w.worktree_path.clone();
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
                                code: "workspace_not_found".to_string(),
                                message: format!(
                                    "Workspace '{}' not found in project '{}'",
                                    workspace, project
                                ),
                            },
                        )
                        .await?;
                    }
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
                        drop(state);

                        match file_api::read_file(&root, &path) {
                            Ok((content, size)) => {
                                let content_b64 = BASE64.encode(content.as_bytes());
                                send_message(socket, &ServerMessage::FileReadResult {
                                    project,
                                    workspace,
                                    path,
                                    content_b64,
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
                },
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }

        ClientMessage::FileWrite { project, workspace, path, content_b64 } => {
            let state = app_state.lock().await;
            match state.get_project(&project) {
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
                        drop(state);

                        // Decode base64 content
                        match BASE64.decode(&content_b64) {
                            Ok(bytes) => {
                                match String::from_utf8(bytes) {
                                    Ok(content) => {
                                        match file_api::write_file(&root, &path, &content) {
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
                            Err(_) => {
                                send_message(socket, &ServerMessage::Error {
                                    code: "invalid_base64".to_string(),
                                    message: "Invalid base64 encoding".to_string(),
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
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
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = p.root_path.clone();
                        let project_name = p.name.clone();
                        let source_branch = w.branch.clone();
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
                            code: "workspace_not_found".to_string(),
                            message: format!("Workspace '{}' not found", workspace),
                        }).await?;
                    }
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = p.root_path.clone();
                        let project_name = p.name.clone();
                        let source_branch = w.branch.clone();
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
                            code: "workspace_not_found".to_string(),
                            message: format!("Workspace '{}' not found", workspace),
                        }).await?;
                    }
                },
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
                Some(p) => match p.get_workspace(&workspace) {
                    Some(w) => {
                        let root = w.worktree_path.clone();
                        let current_branch = w.branch.clone();
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
                            code: "workspace_not_found".to_string(),
                            message: format!("Workspace '{}' not found", workspace),
                        }).await?;
                    }
                },
                None => {
                    send_message(socket, &ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    }).await?;
                }
            }
        }
    }

    Ok(())
}
