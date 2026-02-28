use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{broadcast, oneshot, Mutex};
use tokio::time::{timeout, Duration};
use tracing::{debug, info, warn};

const REQUEST_TIMEOUT_SECS: u64 = 120;

#[derive(Debug, Clone, Default)]
pub struct AcpAgentCapabilities {
    pub load_session: bool,
    pub set_config_option: bool,
    pub raw: Option<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct AcpPromptCapabilities {
    pub content_types: HashSet<String>,
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

        let mut command = Command::new(&self.command);
        command
            .args(&self.command_args)
            .current_dir(&self.working_dir)
            .envs(Self::build_extended_env())
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        info!(
            "Starting {} (cwd: {})",
            self.display_name,
            self.working_dir.display()
        );
        let mut child = command.spawn().map_err(|e| {
            format!(
                "Failed to spawn `{}`: {}",
                if self.command_args.is_empty() {
                    self.command.clone()
                } else {
                    format!("{} {}", self.command, self.command_args.join(" "))
                },
                e
            )
        })?;

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

        if let Some(mut child) = self.process.lock().await.take() {
            if let Err(e) = child.start_kill() {
                warn!("Failed to kill {}: {}", self.display_name, e);
            }
            let _ = child.wait().await;
        }
        *self.stdin.lock().await = None;
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
        self.send_request_raw_with_error(method, params).await
    }

    async fn send_request_raw_with_error(
        &self,
        method: &str,
        params: Option<Value>,
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

        match timeout(Duration::from_secs(REQUEST_TIMEOUT_SECS), rx).await {
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
        let raw = result.get("promptCapabilities").cloned();
        let mut content_types = HashSet::new();
        if let Some(capabilities) = raw.as_ref() {
            let items = capabilities
                .get("contentTypes")
                .and_then(|v| v.as_array())
                .or_else(|| capabilities.get("content_types").and_then(|v| v.as_array()));
            if let Some(items) = items {
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
        if content_types.is_empty() {
            content_types.insert("text".to_string());
        }
        AcpPromptCapabilities { content_types, raw }
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
        match id {
            Value::String(s) => format!("s:{}", s),
            Value::Number(n) => format!("n:{}", n),
            _ => format!("j:{}", id),
        }
    }

    fn build_extended_env() -> HashMap<String, String> {
        let mut env: HashMap<String, String> = std::env::vars().collect();
        let home = dirs::home_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        let mut extra = vec![
            "/opt/homebrew/bin".to_string(),
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
        let existing = env.get("PATH").cloned().unwrap_or_default();
        for p in existing.split(':') {
            if !p.is_empty() {
                extra.push(p.to_string());
            }
        }
        extra.dedup();
        env.insert("PATH".to_string(), extra.join(":"));
        env
    }
}

#[cfg(test)]
mod tests {
    use super::{AppServerRequestError, CodexAppServerManager};
    use serde_json::json;

    #[test]
    fn acp_initialize_payload_should_match_schema_fields() {
        let payload = CodexAppServerManager::build_acp_initialize_params(1);
        assert_eq!(
            payload.get("protocolVersion").and_then(|v| v.as_u64()),
            Some(1)
        );
        assert!(payload.get("clientCapabilities").is_some());
        assert!(payload.get("clientInfo").is_some());
        assert!(payload.get("capabilities").is_none());
        assert!(
            payload
                .get("clientCapabilities")
                .and_then(|v| v.get("fs"))
                .and_then(|v| v.get("readTextFile"))
                .and_then(|v| v.as_bool())
                == Some(false)
        );
        assert!(
            payload
                .get("clientCapabilities")
                .and_then(|v| v.get("fs"))
                .and_then(|v| v.get("writeTextFile"))
                .and_then(|v| v.as_bool())
                == Some(false)
        );
        assert!(
            payload
                .get("clientCapabilities")
                .and_then(|v| v.get("terminal"))
                .and_then(|v| v.as_bool())
                == Some(false)
        );
    }

    #[test]
    fn legacy_initialize_payload_should_keep_existing_contract() {
        let payload = CodexAppServerManager::build_legacy_initialize_params();
        assert!(payload.get("clientInfo").is_some());
        assert_eq!(
            payload
                .get("capabilities")
                .and_then(|v| v.get("experimentalApi"))
                .and_then(|v| v.as_bool()),
            Some(true)
        );
    }

    #[test]
    fn parse_acp_initialize_response_should_extract_capabilities_and_auth_methods() {
        let response = json!({
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": true,
                "session": {
                    "resume": false
                }
            },
            "sessionCapabilities": {
                "setConfigOption": true
            },
            "promptCapabilities": {
                "contentTypes": ["text", "image", "resource_link"]
            },
            "authMethods": [
                {
                    "id": "oauth",
                    "name": "OAuth",
                    "description": "Sign in with browser"
                },
                {
                    "id": "device-code"
                }
            ]
        });
        let state = CodexAppServerManager::parse_acp_initialize_result(&response, 1)
            .expect("parse initialize response should succeed");
        assert_eq!(state.negotiated_protocol_version, Some(1));
        assert!(state.agent_capabilities.load_session);
        assert!(state.agent_capabilities.set_config_option);
        assert!(state.prompt_capabilities.content_types.contains("text"));
        assert!(state.prompt_capabilities.content_types.contains("image"));
        assert!(
            state
                .prompt_capabilities
                .content_types
                .contains("resource_link")
        );
        assert_eq!(state.auth_methods.len(), 2);
        assert_eq!(state.auth_methods[0].id, "oauth");
        assert_eq!(state.auth_methods[1].id, "device-code");
    }

    #[test]
    fn parse_acp_initialize_response_should_default_prompt_content_type_to_text() {
        let response = json!({
            "protocolVersion": 1
        });
        let state = CodexAppServerManager::parse_acp_initialize_result(&response, 1)
            .expect("parse initialize response should succeed");
        assert_eq!(state.prompt_capabilities.content_types.len(), 1);
        assert!(state.prompt_capabilities.content_types.contains("text"));
    }

    #[test]
    fn parse_acp_initialize_response_should_fail_for_unsupported_version() {
        let response = json!({
            "protocolVersion": 2
        });
        let err = CodexAppServerManager::parse_acp_initialize_result(&response, 1)
            .expect_err("version mismatch should fail");
        assert!(err.contains("mismatch"));
    }

    #[test]
    fn parse_rpc_error_should_keep_auth_required_code() {
        let error = json!({
            "code": -32000,
            "message": "Authentication required",
            "data": {
                "hint": "please authenticate"
            }
        });
        let parsed =
            CodexAppServerManager::parse_rpc_error(&error).expect("rpc error should parse");
        assert_eq!(parsed.code, -32000);
        assert_eq!(parsed.message, "Authentication required");
        assert_eq!(
            AppServerRequestError::Rpc(parsed).to_user_string(),
            "App-server error (code -32000): Authentication required"
        );
    }
}
