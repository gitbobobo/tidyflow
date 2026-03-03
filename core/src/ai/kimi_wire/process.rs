use super::protocol::{parse_rpc_error, parse_wire_event, parse_wire_request, WireRequestError};
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
use tracing::{info, warn};

const REQUEST_TIMEOUT_SECS: u64 = 120;
const KIMI_COMMAND: &str = "kimi";

pub struct KimiWireProcess {
    process: Arc<Mutex<Option<Child>>>,
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, WireRequestError>>>>>,
    last_stderr: Arc<Mutex<Option<String>>>,
    events_tx: broadcast::Sender<super::protocol::KimiWireEvent>,
    requests_tx: broadcast::Sender<super::protocol::KimiWireRequest>,
    next_id: Arc<Mutex<u64>>,
    started: Arc<Mutex<bool>>,
    working_dir: String,
    session_id: String,
}

impl KimiWireProcess {
    pub fn new(working_dir: String, session_id: String) -> Self {
        let (events_tx, _) = broadcast::channel(2048);
        let (requests_tx, _) = broadcast::channel(256);
        Self {
            process: Arc::new(Mutex::new(None)),
            stdin: Arc::new(Mutex::new(None)),
            pending: Arc::new(Mutex::new(HashMap::new())),
            last_stderr: Arc::new(Mutex::new(None)),
            events_tx,
            requests_tx,
            next_id: Arc::new(Mutex::new(1)),
            started: Arc::new(Mutex::new(false)),
            working_dir,
            session_id,
        }
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<super::protocol::KimiWireEvent> {
        self.events_tx.subscribe()
    }

    pub fn subscribe_requests(&self) -> broadcast::Receiver<super::protocol::KimiWireRequest> {
        self.requests_tx.subscribe()
    }

    pub async fn ensure_running(&self) -> Result<(), String> {
        if self.is_running().await && *self.started.lock().await {
            return Ok(());
        }
        self.stop().await?;
        self.start().await
    }

    pub async fn start(&self) -> Result<(), String> {
        let mut process_lock = self.process.lock().await;
        if process_lock.is_some() && *self.started.lock().await {
            return Ok(());
        }

        if !Path::new(LOGIN_ZSH_PATH).exists() {
            return Err(format!("zsh not found at {}", LOGIN_ZSH_PATH));
        }

        let resolved_command = Self::resolve_command_for_launch(KIMI_COMMAND)
            .map_err(|e| format!("Failed to resolve executable for kimi: {}", e))?;
        let command_args = vec![
            "--wire".to_string(),
            "--work-dir".to_string(),
            self.working_dir.clone(),
            "--session".to_string(),
            self.session_id.clone(),
            "--yolo".to_string(),
        ];
        let launch_args = build_login_zsh_exec_args(&resolved_command, &command_args)
            .map_err(|e| format!("build kimi launch args failed: {}", e))?;

        let mut command = Command::new(LOGIN_ZSH_PATH);
        command
            .args(&launch_args)
            .current_dir(&self.working_dir)
            .envs(Self::build_extended_env())
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        info!(
            "Starting Kimi Wire server: {} --wire --work-dir {} --session {} --yolo",
            resolved_command, self.working_dir, self.session_id
        );

        let launched_command = format!("{} {}", resolved_command, command_args.join(" "));
        let mut child = command
            .spawn()
            .map_err(|e| format!("Failed to spawn `{}`: {}", launched_command, e))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Kimi Wire stdin unavailable".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Kimi Wire stdout unavailable".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Kimi Wire stderr unavailable".to_string())?;

        *self.stdin.lock().await = Some(stdin);
        *self.last_stderr.lock().await = None;
        *process_lock = Some(child);
        drop(process_lock);

        self.spawn_stdout_reader(stdout);
        self.spawn_stderr_reader(stderr);
        *self.started.lock().await = true;
        Ok(())
    }

    pub async fn stop(&self) -> Result<(), String> {
        *self.started.lock().await = false;
        self.reject_all_pending("Kimi Wire process stopped").await;

        if let Some(mut child) = self.process.lock().await.take() {
            if let Err(e) = child.start_kill() {
                warn!("Failed to kill Kimi Wire process: {}", e);
            }
            let _ = child.wait().await;
        }
        *self.stdin.lock().await = None;
        *self.last_stderr.lock().await = None;
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
    ) -> Result<Value, WireRequestError> {
        self.ensure_running()
            .await
            .map_err(WireRequestError::Transport)?;
        let timeout_secs = if method == "prompt" {
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
    ) -> Result<Value, WireRequestError> {
        let id_text = {
            let mut next = self.next_id.lock().await;
            let id = *next;
            *next += 1;
            id.to_string()
        };
        let id_value = Value::String(id_text.clone());
        let id_key = Self::request_id_key(&id_value);

        let payload = if let Some(params) = params {
            serde_json::json!({
                "jsonrpc": "2.0",
                "id": id_text,
                "method": method,
                "params": params
            })
        } else {
            serde_json::json!({
                "jsonrpc": "2.0",
                "id": id_text,
                "method": method
            })
        };

        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id_key.clone(), tx);

        if let Err(e) = self.write_json_line(&payload).await {
            self.pending.lock().await.remove(&id_key);
            return Err(WireRequestError::Transport(e));
        }

        if let Some(secs) = timeout_secs {
            match timeout(Duration::from_secs(secs), rx).await {
                Ok(Ok(result)) => result,
                Ok(Err(_)) => Err(WireRequestError::Transport(format!(
                    "Kimi Wire request channel dropped: {}",
                    method
                ))),
                Err(_) => {
                    self.pending.lock().await.remove(&id_key);
                    Err(WireRequestError::Transport(format!(
                        "Kimi Wire request timeout: {}",
                        method
                    )))
                }
            }
        } else {
            match rx.await {
                Ok(result) => result,
                Err(_) => Err(WireRequestError::Transport(format!(
                    "Kimi Wire request channel dropped: {}",
                    method
                ))),
            }
        }
    }

    pub async fn send_notification(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), String> {
        self.ensure_running().await?;
        self.send_notification_raw(method, params).await
    }

    async fn send_notification_raw(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), String> {
        let payload = if let Some(params) = params {
            serde_json::json!({
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            })
        } else {
            serde_json::json!({
                "jsonrpc": "2.0",
                "method": method
            })
        };
        self.write_json_line(&payload).await
    }

    pub async fn send_response(&self, id: Value, result: Value) -> Result<(), String> {
        self.ensure_running().await?;
        self.write_json_line(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        }))
        .await
    }

    fn spawn_stdout_reader(&self, stdout: tokio::process::ChildStdout) {
        let pending = self.pending.clone();
        let events_tx = self.events_tx.clone();
        let requests_tx = self.requests_tx.clone();
        let started = self.started.clone();
        let last_stderr = self.last_stderr.clone();

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
                        warn!("Kimi Wire stdout JSON parse failed: {}; raw={}", e, trimmed);
                        continue;
                    }
                };

                let Some(obj) = value.as_object() else {
                    continue;
                };

                if let (Some(id), Some(method)) =
                    (obj.get("id"), obj.get("method").and_then(|m| m.as_str()))
                {
                    if method == "request" {
                        if let Some(params) = obj.get("params") {
                            if let Some(req) = parse_wire_request(id.clone(), params) {
                                let _ = requests_tx.send(req);
                            }
                        }
                        continue;
                    }
                }

                if let Some(method) = obj.get("method").and_then(|m| m.as_str()) {
                    if method == "event" {
                        if let Some(params) = obj.get("params") {
                            if let Some(event) = parse_wire_event(params) {
                                let _ = events_tx.send(event);
                            }
                        }
                    }
                    continue;
                }

                if let Some(id) = obj.get("id") {
                    let key = Self::request_id_key(id);
                    let tx = pending.lock().await.remove(&key);
                    if let Some(tx) = tx {
                        if let Some(result) = obj.get("result") {
                            let _ = tx.send(Ok(result.clone()));
                            continue;
                        }
                        if let Some(error) = obj.get("error") {
                            if let Some(parsed_error) = parse_rpc_error(error) {
                                let _ = tx.send(Err(WireRequestError::Rpc(parsed_error)));
                            } else {
                                let _ = tx.send(Err(WireRequestError::MalformedResponse(
                                    "Malformed Wire JSON-RPC error object".to_string(),
                                )));
                            }
                            continue;
                        }
                        let _ = tx.send(Err(WireRequestError::MalformedResponse(
                            "Malformed Wire JSON-RPC response".to_string(),
                        )));
                    }
                }
            }

            *started.lock().await = false;
            let last_stderr_line = last_stderr.lock().await.clone();
            let close_reason = if let Some(stderr) = last_stderr_line {
                format!("Kimi Wire server stdout closed (stderr: {})", stderr)
            } else {
                "Kimi Wire server stdout closed".to_string()
            };
            let mut map = pending.lock().await;
            for (_, tx) in map.drain() {
                let _ = tx.send(Err(WireRequestError::Transport(close_reason.clone())));
            }
        });
    }

    fn spawn_stderr_reader(&self, stderr: tokio::process::ChildStderr) {
        let last_stderr = self.last_stderr.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                *last_stderr.lock().await = Some(line.clone());
                warn!("[Kimi Wire stderr] {}", line);
            }
        });
    }

    async fn write_json_line(&self, value: &Value) -> Result<(), String> {
        let line = serde_json::to_string(value)
            .map_err(|e| format!("Failed to serialize Wire JSON-RPC payload: {}", e))?;
        let mut stdin_lock = self.stdin.lock().await;
        let stdin = stdin_lock
            .as_mut()
            .ok_or_else(|| "Kimi Wire stdin is not ready".to_string())?;
        stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| format!("Failed to write Wire payload: {}", e))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|e| format!("Failed to write Wire payload newline: {}", e))?;
        stdin
            .flush()
            .await
            .map_err(|e| format!("Failed to flush Wire payload: {}", e))?;
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
            let _ = tx.send(Err(WireRequestError::Transport(reason.to_string())));
        }
    }

    fn resolve_command_for_launch(command: &str) -> Result<String, String> {
        let trimmed = command.trim();
        if trimmed.is_empty() {
            return Err("empty command".to_string());
        }

        if let Some(path) = Self::resolve_command_from_override(trimmed) {
            return Ok(path);
        }

        if trimmed.contains('/') {
            let direct = PathBuf::from(trimmed);
            if Self::is_executable_file(&direct) {
                return Ok(trimmed.to_string());
            }
            return Err(format!("path is not executable: {}", trimmed));
        }

        for dir in Self::collect_command_search_dirs() {
            let candidate = dir.join(trimmed);
            if Self::is_executable_file(&candidate) {
                return Ok(candidate.to_string_lossy().to_string());
            }
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

    fn get_shell_path() -> Option<String> {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
        let output = std::process::Command::new(&shell)
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

    fn request_id_key(id: &Value) -> String {
        shared_request_id_key(id)
    }
}
