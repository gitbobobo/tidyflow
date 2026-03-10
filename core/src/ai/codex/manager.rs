use crate::ai::shared::request_id::request_id_key as shared_request_id_key;
use crate::util::shell_launch::{build_login_zsh_exec_args, LOGIN_ZSH_PATH};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{broadcast, oneshot, Mutex};
use tokio::time::{timeout, Duration};
use tracing::{debug, info, warn};

const REQUEST_TIMEOUT_SECS: u64 = 120;
const GRACEFUL_SHUTDOWN_TIMEOUT_MS: u64 = 5000;
const VSCODE_COPILOT_CLI_SHIM_SEGMENT: &str = "/github.copilot-chat/copilotcli/";
const VSCODE_COPILOT_DEBUG_SHIM_SEGMENT: &str = "/github.copilot-chat/debugcommand/";

#[derive(Debug, Clone, Default)]
pub struct AcpAgentCapabilities {
    pub load_session: bool,
    pub set_config_option: bool,
    pub raw: Option<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AcpContentEncodingMode {
    New,
    Legacy,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Default)]
pub struct AcpPromptCapabilities {
    pub content_types: HashSet<String>,
    pub encoding_mode: AcpContentEncodingMode,
    pub raw: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct AcpAuthMethod {
    pub id: String,
    pub name: Option<String>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct AcpInitializationState {
    pub negotiated_protocol_version: Option<u64>,
    pub agent_capabilities: AcpAgentCapabilities,
    pub prompt_capabilities: AcpPromptCapabilities,
    pub auth_methods: Vec<AcpAuthMethod>,
    pub authenticated: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    pub data: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AppServerRequestError {
    Rpc(JsonRpcError),
    Transport(String),
    MalformedResponse(String),
}

impl AppServerRequestError {
    pub fn to_user_string(&self) -> String {
        match self {
            Self::Rpc(error) => {
                format!("App-server error (code {}): {}", error.code, error.message)
            }
            Self::Transport(message) | Self::MalformedResponse(message) => message.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct CodexNotification {
    pub method: String,
    pub params: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct CodexServerRequest {
    pub id: Value,
    pub method: String,
    pub params: Option<Value>,
}

#[derive(Debug)]
pub struct CodexAppServerManager {
    process: Arc<Mutex<Option<Child>>>,
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, AppServerRequestError>>>>>,
    notifications_tx: broadcast::Sender<CodexNotification>,
    requests_tx: broadcast::Sender<CodexServerRequest>,
    next_id: Arc<Mutex<u64>>,
    started: Arc<Mutex<bool>>,
    working_dir: PathBuf,
    command: String,
    command_args: Vec<String>,
    display_name: String,
    initialize_protocol_version: Option<u64>,
    acp_initialization_state: Arc<Mutex<AcpInitializationState>>,
}

impl CodexAppServerManager {
    pub fn new(working_dir: PathBuf) -> Self {
        Self::new_with_command(
            working_dir,
            "codex",
            vec!["app-server".to_string()],
            "Codex app-server",
        )
    }

    pub fn new_with_command<S1, S2>(
        working_dir: PathBuf,
        command: S1,
        command_args: Vec<String>,
        display_name: S2,
    ) -> Self
    where
        S1: Into<String>,
        S2: Into<String>,
    {
        Self::new_with_command_and_protocol(working_dir, command, command_args, display_name, None)
    }

    pub fn new_with_command_and_protocol<S1, S2>(
        working_dir: PathBuf,
        command: S1,
        command_args: Vec<String>,
        display_name: S2,
        initialize_protocol_version: Option<u64>,
    ) -> Self
    where
        S1: Into<String>,
        S2: Into<String>,
    {
        let (notifications_tx, _) = broadcast::channel(2048);
        let (requests_tx, _) = broadcast::channel(256);
        Self {
            process: Arc::new(Mutex::new(None)),
            stdin: Arc::new(Mutex::new(None)),
            pending: Arc::new(Mutex::new(HashMap::new())),
            notifications_tx,
            requests_tx,
            next_id: Arc::new(Mutex::new(1)),
            started: Arc::new(Mutex::new(false)),
            working_dir,
            command: command.into(),
            command_args,
            display_name: display_name.into(),
            initialize_protocol_version,
            acp_initialization_state: Arc::new(Mutex::new(AcpInitializationState::default())),
        }
    }

    pub fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
        self.notifications_tx.subscribe()
    }

    pub fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
        self.requests_tx.subscribe()
    }

    pub fn is_acp_mode(&self) -> bool {
        self.initialize_protocol_version.is_some()
    }

    pub async fn acp_initialization_state(&self) -> Option<AcpInitializationState> {
        if !self.is_acp_mode() {
            return None;
        }
        Some(self.acp_initialization_state.lock().await.clone())
    }

    pub async fn set_acp_authenticated(&self, authenticated: bool) {
        if !self.is_acp_mode() {
            return;
        }
        self.acp_initialization_state.lock().await.authenticated = authenticated;
    }

    pub async fn ensure_server_running(&self) -> Result<(), String> {
        if self.is_running().await && *self.started.lock().await {
            return Ok(());
        }
        self.stop_server().await?;
        self.start_server().await
    }

    pub async fn start_server(&self) -> Result<(), String> {
        let mut process_lock = self.process.lock().await;
        if process_lock.is_some() && *self.started.lock().await {
            return Ok(());
        }

        if !Path::new(LOGIN_ZSH_PATH).exists() {
            return Err(format!("zsh not found at {}", LOGIN_ZSH_PATH));
        }
        let resolved_command = Self::resolve_command_for_launch(&self.command).map_err(|e| {
            format!(
                "Failed to resolve executable for {} (command=`{}`): {}",
                self.display_name, self.command, e
            )
        })?;
        let launch_args = build_login_zsh_exec_args(&resolved_command, &self.command_args)
            .map_err(|e| {
                format!(
                    "Failed to build launch args for {}: {}",
                    self.display_name, e
                )
            })?;
        let mut command = Command::new(LOGIN_ZSH_PATH);
        command
            .args(&launch_args)
            .current_dir(&self.working_dir)
            .envs(Self::build_extended_env())
            .kill_on_drop(true)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        info!(
            "Starting {} (cwd: {})",
            self.display_name,
            self.working_dir.display()
        );
        let launched_command = if self.command_args.is_empty() {
            resolved_command.clone()
        } else {
            format!("{} {}", resolved_command, self.command_args.join(" "))
        };
        let mut child = command
            .spawn()
            .map_err(|e| format!("Failed to spawn `{}`: {}", launched_command, e))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| format!("{} stdin unavailable", self.display_name))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| format!("{} stdout unavailable", self.display_name))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| format!("{} stderr unavailable", self.display_name))?;

        *self.stdin.lock().await = Some(stdin);
        *process_lock = Some(child);
        drop(process_lock);

        self.reset_acp_initialization_state().await;

        self.spawn_stdout_reader(stdout);
        self.spawn_stderr_reader(stderr);

        self.initialize_connection().await?;
        *self.started.lock().await = true;

        info!("{} initialized", self.display_name);
        Ok(())
    }

    pub async fn stop_server(&self) -> Result<(), String> {
        *self.started.lock().await = false;
        self.reject_all_pending(&format!("{} stopped", self.display_name))
            .await;
        *self.stdin.lock().await = None;

        if let Some(mut child) = self.process.lock().await.take() {
            if let Some(pid) = child.id() {
                Self::signal_process(pid, libc::SIGTERM, &self.display_name, "SIGTERM");
            } else if let Err(e) = child.start_kill() {
                warn!("Failed to kill {}: {}", self.display_name, e);
            }

            match timeout(
                Duration::from_millis(GRACEFUL_SHUTDOWN_TIMEOUT_MS),
                child.wait(),
            )
            .await
            {
                Ok(Ok(_)) => {}
                Ok(Err(e)) => warn!("Failed waiting for {} exit: {}", self.display_name, e),
                Err(_) => {
                    if let Some(pid) = child.id() {
                        Self::signal_process(pid, libc::SIGKILL, &self.display_name, "SIGKILL");
                    }
                    let _ = child.kill().await;
                }
            }
        }
        self.reset_acp_initialization_state().await;
        Ok(())
    }

    pub async fn send_request(&self, method: &str, params: Option<Value>) -> Result<Value, String> {
        self.send_request_with_error(method, params)
            .await
            .map_err(|e| e.to_user_string())
    }

    pub async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, AppServerRequestError> {
        self.ensure_server_running()
            .await
            .map_err(AppServerRequestError::Transport)?;
        // ACP session/prompt 是长生命周期请求，agent 在完成所有工具调用后才返回
        // response，中间进度通过 session/update notification 传递，不应设置超时。
        // 上层 consume_stage_stream 已有 MAX_STAGE_RUNTIME_SECS（3 小时）保护。
        let timeout_secs = if method == "session/prompt" {
            None
        } else {
            Some(REQUEST_TIMEOUT_SECS)
        };
        self.send_request_raw_with_error(method, params, timeout_secs)
            .await
    }

    async fn send_request_raw_with_error(
        &self,
        method: &str,
        params: Option<Value>,
        timeout_secs: Option<u64>,
    ) -> Result<Value, AppServerRequestError> {
        let id = {
            let mut next = self.next_id.lock().await;
            let id = *next;
            *next += 1;
            id
        };
        let id_value = Value::Number(id.into());
        let id_key = Self::request_id_key(&id_value);

        let payload = if let Some(params) = params {
            serde_json::json!({
                "id": id,
                "method": method,
                "params": params
            })
        } else {
            serde_json::json!({
                "id": id,
                "method": method
            })
        };

        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id_key.clone(), tx);

        if let Err(e) = self.write_json_line(&payload).await {
            self.pending.lock().await.remove(&id_key);
            return Err(AppServerRequestError::Transport(e));
        }

        if let Some(secs) = timeout_secs {
            match timeout(Duration::from_secs(secs), rx).await {
                Ok(Ok(result)) => result,
                Ok(Err(_)) => Err(AppServerRequestError::Transport(format!(
                    "{} request channel dropped: {}",
                    self.display_name, method
                ))),
                Err(_) => {
                    self.pending.lock().await.remove(&id_key);
                    Err(AppServerRequestError::Transport(format!(
                        "{} request timeout: {}",
                        self.display_name, method
                    )))
                }
            }
        } else {
            match rx.await {
                Ok(result) => result,
                Err(_) => Err(AppServerRequestError::Transport(format!(
                    "{} request channel dropped: {}",
                    self.display_name, method
                ))),
            }
        }
    }

    pub async fn send_notification(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), String> {
        self.ensure_server_running().await?;
        self.send_notification_raw(method, params).await
    }

    async fn send_notification_raw(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), String> {
        let payload = if let Some(params) = params {
            serde_json::json!({
                "method": method,
                "params": params
            })
        } else {
            serde_json::json!({
                "method": method
            })
        };
        self.write_json_line(&payload).await
    }

    pub async fn send_response(&self, id: Value, result: Value) -> Result<(), String> {
        self.ensure_server_running().await?;
        self.write_json_line(&serde_json::json!({
            "id": id,
            "result": result
        }))
        .await
    }

    fn spawn_stdout_reader(&self, stdout: tokio::process::ChildStdout) {
        let pending = self.pending.clone();
        let notifications_tx = self.notifications_tx.clone();
        let requests_tx = self.requests_tx.clone();
        let started = self.started.clone();
        let display_name = self.display_name.clone();

        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                let value: Value = match serde_json::from_str(trimmed) {
                    Ok(v) => v,
                    Err(e) => {
                        warn!(
                            "{} stdout JSON parse failed: {}; raw={}",
                            display_name, e, trimmed
                        );
                        continue;
                    }
                };
                Self::handle_incoming_value(value, &pending, &notifications_tx, &requests_tx).await;
            }

            *started.lock().await = false;
            let mut map = pending.lock().await;
            for (_, tx) in map.drain() {
                let _ = tx.send(Err(AppServerRequestError::Transport(format!(
                    "{} stdout closed",
                    display_name
                ))));
            }
        });
    }

    fn spawn_stderr_reader(&self, stderr: tokio::process::ChildStderr) {
        let command = self.command.clone();
        let display_name = self.display_name.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                debug!("[{} ({}) stderr] {}", display_name, command, line);
            }
        });
    }

    async fn handle_incoming_value(
        value: Value,
        pending: &Arc<
            Mutex<HashMap<String, oneshot::Sender<Result<Value, AppServerRequestError>>>>,
        >,
        notifications_tx: &broadcast::Sender<CodexNotification>,
        requests_tx: &broadcast::Sender<CodexServerRequest>,
    ) {
        let Some(obj) = value.as_object() else {
            return;
        };

        if let (Some(id), Some(method)) =
            (obj.get("id"), obj.get("method").and_then(|m| m.as_str()))
        {
            let _ = requests_tx.send(CodexServerRequest {
                id: id.clone(),
                method: method.to_string(),
                params: obj.get("params").cloned(),
            });
            return;
        }

        if let Some(method) = obj.get("method").and_then(|m| m.as_str()) {
            let _ = notifications_tx.send(CodexNotification {
                method: method.to_string(),
                params: obj.get("params").cloned(),
            });
            return;
        }

        if let Some(id) = obj.get("id") {
            let key = Self::request_id_key(id);
            let tx = pending.lock().await.remove(&key);
            if let Some(tx) = tx {
                if let Some(result) = obj.get("result") {
                    let _ = tx.send(Ok(result.clone()));
                    return;
                }
                if let Some(error) = obj.get("error") {
                    if let Some(parsed_error) = Self::parse_rpc_error(error) {
                        let _ = tx.send(Err(AppServerRequestError::Rpc(parsed_error)));
                    } else {
                        let _ = tx.send(Err(AppServerRequestError::MalformedResponse(
                            "Malformed JSON-RPC error object".to_string(),
                        )));
                    }
                    return;
                }
                let _ = tx.send(Err(AppServerRequestError::MalformedResponse(
                    "Malformed JSON-RPC response".to_string(),
                )));
            }
        }
    }

    async fn initialize_connection(&self) -> Result<(), String> {
        if let Some(version) = self.initialize_protocol_version {
            let result = self
                .send_request_raw_with_error(
                    "initialize",
                    Some(Self::build_acp_initialize_params(version)),
                    Some(REQUEST_TIMEOUT_SECS),
                )
                .await
                .map_err(|e| e.to_user_string())?;
            let state = Self::parse_acp_initialize_result(&result, version)?;
            if let Some(raw) = state.agent_capabilities.raw.as_ref() {
                debug!(
                    "{} ACP agentCapabilities detected: loadSession={}, setConfigOption={}, raw={}",
                    self.display_name,
                    state.agent_capabilities.load_session,
                    state.agent_capabilities.set_config_option,
                    raw
                );
            } else {
                debug!(
                    "{} ACP agentCapabilities missing; all optional capabilities treated as unsupported",
                    self.display_name
                );
            }
            if !state.auth_methods.is_empty() {
                debug!(
                    "{} ACP auth methods discovered: {:?}",
                    self.display_name,
                    state
                        .auth_methods
                        .iter()
                        .map(|m| m.id.clone())
                        .collect::<Vec<_>>()
                );
            }
            *self.acp_initialization_state.lock().await = state;
        } else {
            let _ = self
                .send_request_raw_with_error(
                    "initialize",
                    Some(Self::build_legacy_initialize_params()),
                    Some(REQUEST_TIMEOUT_SECS),
                )
                .await
                .map_err(|e| e.to_user_string())?;
        }
        self.send_notification_raw("initialized", None).await
    }

    async fn write_json_line(&self, value: &Value) -> Result<(), String> {
        let line = serde_json::to_string(value)
            .map_err(|e| format!("Failed to serialize JSON-RPC payload: {}", e))?;
        let mut stdin_lock = self.stdin.lock().await;
        let stdin = stdin_lock
            .as_mut()
            .ok_or_else(|| format!("{} stdin is not ready", self.display_name))?;
        stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| format!("Failed to write JSON-RPC payload: {}", e))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|e| format!("Failed to write JSON-RPC newline: {}", e))?;
        stdin
            .flush()
            .await
            .map_err(|e| format!("Failed to flush JSON-RPC payload: {}", e))?;
        Ok(())
    }

    async fn is_running(&self) -> bool {
        let mut lock = self.process.lock().await;
        let Some(child) = lock.as_mut() else {
            return false;
        };
        match child.try_wait() {
            Ok(Some(_)) => {
                *lock = None;
                *self.stdin.lock().await = None;
                false
            }
            Ok(None) => true,
            Err(_) => false,
        }
    }

    async fn reject_all_pending(&self, reason: &str) {
        let mut pending = self.pending.lock().await;
        for (_, tx) in pending.drain() {
            let _ = tx.send(Err(AppServerRequestError::Transport(reason.to_string())));
        }
    }

    async fn reset_acp_initialization_state(&self) {
        if !self.is_acp_mode() {
            return;
        }
        *self.acp_initialization_state.lock().await = AcpInitializationState::default();
    }

    fn parse_rpc_error(error: &Value) -> Option<JsonRpcError> {
        let code = error.get("code")?.as_i64()?;
        let message = error
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("unknown error")
            .to_string();
        let data = error.get("data").cloned();
        Some(JsonRpcError {
            code,
            message,
            data,
        })
    }

    fn build_legacy_initialize_params() -> Value {
        serde_json::json!({
            "clientInfo": {
                "name": "tidyflow",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {
                "experimentalApi": true
            }
        })
    }

    fn build_acp_initialize_params(protocol_version: u64) -> Value {
        serde_json::json!({
            "protocolVersion": protocol_version,
            "clientCapabilities": {
                "fs": {
                    "readTextFile": false,
                    "writeTextFile": false
                },
                "terminal": false
            },
            "clientInfo": {
                "name": "tidyflow",
                "title": "TidyFlow",
                "version": env!("CARGO_PKG_VERSION")
            }
        })
    }

    fn parse_acp_initialize_result(
        result: &Value,
        expected_protocol_version: u64,
    ) -> Result<AcpInitializationState, String> {
        let protocol_version = result
            .get("protocolVersion")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| "ACP initialize response missing numeric protocolVersion".to_string())?;
        if protocol_version != expected_protocol_version {
            return Err(format!(
                "ACP protocol version mismatch: client supports {}, server returned {}",
                expected_protocol_version, protocol_version
            ));
        }

        Ok(AcpInitializationState {
            negotiated_protocol_version: Some(protocol_version),
            agent_capabilities: Self::parse_agent_capabilities(result),
            prompt_capabilities: Self::parse_prompt_capabilities(result),
            auth_methods: Self::parse_auth_methods(result),
            authenticated: false,
        })
    }

    fn parse_agent_capabilities(result: &Value) -> AcpAgentCapabilities {
        let agent_raw = result.get("agentCapabilities").cloned();
        let session_raw = result.get("sessionCapabilities").cloned();
        let raw = if agent_raw.is_some() || session_raw.is_some() {
            Some(serde_json::json!({
                "agentCapabilities": agent_raw,
                "sessionCapabilities": session_raw
            }))
        } else {
            None
        };
        let load_session = agent_raw
            .as_ref()
            .and_then(Self::read_load_session_capability)
            .or_else(|| {
                session_raw
                    .as_ref()
                    .and_then(Self::read_load_session_capability)
            })
            .unwrap_or(false);
        let set_config_option = session_raw
            .as_ref()
            .and_then(Self::read_set_config_option_capability)
            .or_else(|| {
                agent_raw
                    .as_ref()
                    .and_then(Self::read_set_config_option_capability)
            })
            .unwrap_or(false);
        AcpAgentCapabilities {
            load_session,
            set_config_option,
            raw,
        }
    }

    fn parse_prompt_capabilities(result: &Value) -> AcpPromptCapabilities {
        let legacy_raw = result.get("promptCapabilities").cloned();
        let new_raw = result
            .get("agentCapabilities")
            .and_then(|v| v.get("promptCapabilities"))
            .cloned();
        let raw = if legacy_raw.is_some() || new_raw.is_some() {
            Some(serde_json::json!({
                "promptCapabilities": legacy_raw,
                "agentCapabilities.promptCapabilities": new_raw
            }))
        } else {
            None
        };

        let mut content_types = HashSet::new();
        let mut has_legacy_decl = false;
        if let Some(capabilities) = legacy_raw.as_ref() {
            let items = capabilities
                .get("contentTypes")
                .and_then(|v| v.as_array())
                .or_else(|| capabilities.get("content_types").and_then(|v| v.as_array()));
            if let Some(items) = items {
                has_legacy_decl = true;
                for item in items {
                    if let Some(content_type) = item.as_str() {
                        let normalized = content_type.trim().to_lowercase();
                        if !normalized.is_empty() {
                            content_types.insert(normalized);
                        }
                    }
                }
            }
        }

        let mut has_new_decl = false;
        if let Some(capabilities) = new_raw.as_ref() {
            if let Some(supported) = Self::read_prompt_content_capability(
                capabilities,
                &["image", "imageInput", "image_input"],
            ) {
                has_new_decl = true;
                if supported {
                    content_types.insert("image".to_string());
                }
            }
            if let Some(supported) = Self::read_prompt_content_capability(
                capabilities,
                &["audio", "audioInput", "audio_input"],
            ) {
                has_new_decl = true;
                if supported {
                    content_types.insert("audio".to_string());
                }
            }
            if let Some(supported) = Self::read_prompt_content_capability(
                capabilities,
                &["embeddedContext", "embedded_context"],
            ) {
                has_new_decl = true;
                if supported {
                    content_types.insert("resource".to_string());
                }
            }
        }

        // ACP content 协议基线能力：始终保留 text + resource_link。
        content_types.insert("text".to_string());
        content_types.insert("resource_link".to_string());

        let encoding_mode = if has_new_decl {
            AcpContentEncodingMode::New
        } else if has_legacy_decl {
            AcpContentEncodingMode::Legacy
        } else {
            AcpContentEncodingMode::Unknown
        };

        AcpPromptCapabilities {
            content_types,
            encoding_mode,
            raw,
        }
    }

    fn read_prompt_content_capability(capabilities: &Value, keys: &[&str]) -> Option<bool> {
        for key in keys {
            if let Some(value) = capabilities.get(*key) {
                if let Some(parsed) = Self::read_bool_like_value(value) {
                    return Some(parsed);
                }
            }
        }
        None
    }

    fn read_load_session_capability(capabilities: &Value) -> Option<bool> {
        Self::read_capability_flag(
            capabilities,
            &["loadSession", "load_session", "load"],
            &["session"],
        )
    }

    fn read_set_config_option_capability(capabilities: &Value) -> Option<bool> {
        Self::read_capability_flag(
            capabilities,
            &["setConfigOption", "set_config_option"],
            &["session"],
        )
    }

    fn read_capability_flag(
        capabilities: &Value,
        direct_keys: &[&str],
        nested_keys: &[&str],
    ) -> Option<bool> {
        for key in direct_keys {
            if let Some(value) = capabilities.get(*key) {
                if let Some(parsed) = Self::read_bool_like_value(value) {
                    return Some(parsed);
                }
            }
        }
        for nest in nested_keys {
            if let Some(obj) = capabilities.get(*nest) {
                for key in direct_keys {
                    if let Some(value) = obj.get(*key) {
                        if let Some(parsed) = Self::read_bool_like_value(value) {
                            return Some(parsed);
                        }
                    }
                }
            }
        }
        None
    }

    fn read_bool_like_value(value: &Value) -> Option<bool> {
        value
            .as_bool()
            .or_else(|| value.get("supported").and_then(|v| v.as_bool()))
            .or_else(|| value.get("enabled").and_then(|v| v.as_bool()))
    }

    fn parse_auth_methods(result: &Value) -> Vec<AcpAuthMethod> {
        let Some(methods) = result.get("authMethods").and_then(|v| v.as_array()) else {
            return Vec::new();
        };

        methods
            .iter()
            .filter_map(|method| {
                let id = method
                    .get("id")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())?
                    .to_string();
                let name = method
                    .get("name")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty());
                let description = method
                    .get("description")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty());
                Some(AcpAuthMethod {
                    id,
                    name,
                    description,
                })
            })
            .collect()
    }

    fn request_id_key(id: &Value) -> String {
        shared_request_id_key(id)
    }

    /// 解析启动命令的可执行路径，避免 macOS App 环境 PATH 不完整导致 `command not found`。
    /// 对 copilot 额外绕开 VSCode 插件 shim，避免进入交互安装流程。
    fn resolve_command_for_launch(command: &str) -> Result<String, String> {
        let trimmed = command.trim();
        if trimmed.is_empty() {
            return Err("empty command".to_string());
        }

        if let Some(path) = Self::resolve_command_from_override(trimmed) {
            return Ok(path);
        }

        // 绝对/相对路径：直接校验可执行性。
        if trimmed.contains('/') {
            let direct = PathBuf::from(trimmed);
            if Self::is_executable_file(&direct)
                && !Self::should_skip_candidate_path(trimmed, &direct)
            {
                return Ok(trimmed.to_string());
            }
            return Err(format!("path is not executable: {}", trimmed));
        }

        for dir in Self::collect_command_search_dirs() {
            let candidate = dir.join(trimmed);
            if !Self::is_executable_file(&candidate) {
                continue;
            }
            if Self::should_skip_candidate_path(trimmed, &candidate) {
                continue;
            }
            return Ok(candidate.to_string_lossy().to_string());
        }

        Err(format!(
            "command `{}` not found in PATH/common install locations",
            trimmed
        ))
    }

    fn resolve_command_from_override(command: &str) -> Option<String> {
        let key = format!(
            "TIDYFLOW_{}_BIN",
            command.trim().to_ascii_uppercase().replace('-', "_")
        );
        let value = std::env::var(&key).ok()?;
        let path = PathBuf::from(value.trim());
        if Self::is_executable_file(&path) {
            Some(path.to_string_lossy().to_string())
        } else {
            warn!(
                "Ignoring {} because path is not executable: {}",
                key,
                path.display()
            );
            None
        }
    }

    fn collect_command_search_dirs() -> Vec<PathBuf> {
        let mut dirs: Vec<PathBuf> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();

        if let Ok(path) = std::env::var("PATH") {
            for entry in path.split(':') {
                Self::push_search_dir(entry, &mut dirs, &mut seen);
            }
        }
        if let Some(path) = Self::get_shell_path() {
            for entry in path.split(':') {
                Self::push_search_dir(entry, &mut dirs, &mut seen);
            }
        }

        let home = dirs::home_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        if !home.is_empty() {
            Self::push_search_dir(&format!("{}/.local/bin", home), &mut dirs, &mut seen);
            Self::push_search_dir(&format!("{}/.cargo/bin", home), &mut dirs, &mut seen);
            Self::push_search_dir(&format!("{}/.opencode/bin", home), &mut dirs, &mut seen);
            Self::push_search_dir(&format!("{}/.bun/bin", home), &mut dirs, &mut seen);
            Self::append_versioned_node_bin_dirs(
                &PathBuf::from(format!("{}/.nvm/versions/node", home)),
                &mut dirs,
                &mut seen,
            );
        }

        Self::push_search_dir("/opt/homebrew/bin", &mut dirs, &mut seen);
        Self::push_search_dir("/opt/homebrew/sbin", &mut dirs, &mut seen);
        Self::push_search_dir("/usr/local/bin", &mut dirs, &mut seen);
        Self::push_search_dir("/usr/local/sbin", &mut dirs, &mut seen);
        Self::push_search_dir("/usr/bin", &mut dirs, &mut seen);
        Self::push_search_dir("/bin", &mut dirs, &mut seen);

        // npm global 常见安装位置：Homebrew Node 的 Cellar 版本目录。
        Self::append_versioned_node_bin_dirs(
            &PathBuf::from("/opt/homebrew/Cellar/node"),
            &mut dirs,
            &mut seen,
        );
        Self::append_versioned_node_bin_dirs(
            &PathBuf::from("/usr/local/Cellar/node"),
            &mut dirs,
            &mut seen,
        );

        dirs
    }

    fn push_search_dir(raw: &str, dirs: &mut Vec<PathBuf>, seen: &mut HashSet<String>) {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return;
        }
        let path = PathBuf::from(trimmed);
        if !path.is_dir() {
            return;
        }
        let key = path.to_string_lossy().to_string();
        if seen.insert(key) {
            dirs.push(path);
        }
    }

    fn append_versioned_node_bin_dirs(
        root: &Path,
        dirs: &mut Vec<PathBuf>,
        seen: &mut HashSet<String>,
    ) {
        let Ok(entries) = fs::read_dir(root) else {
            return;
        };
        let mut versions: Vec<PathBuf> = entries
            .filter_map(|entry| entry.ok().map(|it| it.path()))
            .filter(|path| path.is_dir())
            .collect();
        versions.sort();
        versions.reverse();

        for version_dir in versions {
            let bin = version_dir.join("bin");
            if !bin.is_dir() {
                continue;
            }
            let key = bin.to_string_lossy().to_string();
            if seen.insert(key) {
                dirs.push(bin);
            }
        }
    }

    fn is_executable_file(path: &Path) -> bool {
        if !path.is_file() {
            return false;
        }
        #[cfg(unix)]
        {
            fs::metadata(path)
                .map(|meta| meta.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        }
        #[cfg(not(unix))]
        {
            true
        }
    }

    fn should_skip_candidate_path(command: &str, candidate: &Path) -> bool {
        if !command.eq_ignore_ascii_case("copilot") {
            return false;
        }
        let normalized = candidate
            .to_string_lossy()
            .replace('\\', "/")
            .to_ascii_lowercase();
        normalized.contains(VSCODE_COPILOT_CLI_SHIM_SEGMENT)
            || normalized.contains(VSCODE_COPILOT_DEBUG_SHIM_SEGMENT)
    }

    /// 从登录 shell 获取用户的完整 PATH（包含 .zshrc/.bashrc 中配置的路径）
    fn get_shell_path() -> Option<String> {
        use std::process::Command;

        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
        let output = Command::new(&shell)
            .args(["-l", "-c", "echo $PATH"])
            .output()
            .ok()?;

        if output.status.success() {
            String::from_utf8(output.stdout)
                .ok()
                .map(|s| s.trim().to_string())
        } else {
            None
        }
    }

    fn build_extended_env() -> HashMap<String, String> {
        let mut env: HashMap<String, String> = std::env::vars().collect();
        let home = dirs::home_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();

        // 优先使用从登录 shell 获取的完整 PATH
        let shell_path = Self::get_shell_path();
        let base_path = shell_path
            .as_deref()
            .or_else(|| env.get("PATH").map(|s| s.as_str()));

        let mut extra = vec![
            "/opt/homebrew/bin".to_string(),
            "/opt/homebrew/sbin".to_string(),
            "/usr/local/bin".to_string(),
            "/usr/bin".to_string(),
            "/bin".to_string(),
        ];
        if !home.is_empty() {
            extra.push(format!("{}/.local/bin", home));
            extra.push(format!("{}/.cargo/bin", home));
            extra.push(format!("{}/.opencode/bin", home));
            extra.push(format!("{}/.bun/bin", home));
        }
        if let Some(path) = base_path {
            for p in path.split(':') {
                if !p.is_empty() {
                    extra.push(p.to_string());
                }
            }
        }
        extra.dedup();
        env.insert("PATH".to_string(), extra.join(":"));
        env
    }

    #[cfg(unix)]
    fn signal_process(pid: u32, signal: i32, display_name: &str, label: &str) {
        let result = unsafe { libc::kill(pid as i32, signal) };
        if result == 0 {
            return;
        }

        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::ESRCH) {
            return;
        }
        warn!(
            "Failed to send {} to {} PID {}: {}",
            label, display_name, pid, err
        );
    }

    #[cfg(not(unix))]
    fn signal_process(_pid: u32, _signal: i32, _display_name: &str, _label: &str) {}

    #[cfg(unix)]
    fn is_pid_alive(pid: u32) -> bool {
        let result = unsafe { libc::kill(pid as i32, 0) };
        if result == 0 {
            return true;
        }
        let err = std::io::Error::last_os_error();
        err.raw_os_error() != Some(libc::ESRCH)
    }

    #[cfg(not(unix))]
    fn is_pid_alive(_pid: u32) -> bool {
        false
    }
}

impl Drop for CodexAppServerManager {
    fn drop(&mut self) {
        if let Ok(mut stdin) = self.stdin.try_lock() {
            *stdin = None;
        }

        if let Ok(mut process) = self.process.try_lock() {
            if let Some(child) = process.take() {
                if let Some(pid) = child.id() {
                    info!(
                        "{} dropped with live child PID {}, attempting best-effort cleanup",
                        self.display_name, pid
                    );
                    Self::signal_process(pid, libc::SIGTERM, &self.display_name, "SIGTERM");
                    std::thread::sleep(Duration::from_millis(100));
                    if Self::is_pid_alive(pid) {
                        Self::signal_process(pid, libc::SIGKILL, &self.display_name, "SIGKILL");
                    }
                }
                drop(child);
            }
        } else {
            warn!(
                "{} dropped while process lock was busy, relying on kill_on_drop cleanup",
                self.display_name
            );
        }
    }
}

#[cfg(test)]
mod tests;
