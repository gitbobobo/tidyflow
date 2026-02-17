use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{broadcast, oneshot, Mutex};
use tokio::time::{timeout, Duration};
use tracing::{debug, info, warn};

const REQUEST_TIMEOUT_SECS: u64 = 120;

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
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, String>>>>>,
    notifications_tx: broadcast::Sender<CodexNotification>,
    requests_tx: broadcast::Sender<CodexServerRequest>,
    next_id: Arc<Mutex<u64>>,
    started: Arc<Mutex<bool>>,
    working_dir: PathBuf,
}

impl CodexAppServerManager {
    pub fn new(working_dir: PathBuf) -> Self {
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
        }
    }

    pub fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
        self.notifications_tx.subscribe()
    }

    pub fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
        self.requests_tx.subscribe()
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

        let mut command = Command::new("codex");
        command
            .arg("app-server")
            .current_dir(&self.working_dir)
            .envs(Self::build_extended_env())
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        info!("Starting Codex app-server (cwd: {})", self.working_dir.display());
        let mut child = command
            .spawn()
            .map_err(|e| format!("Failed to spawn `codex app-server`: {}", e))?;

        let stdin = child.stdin.take().ok_or("Codex app-server stdin unavailable")?;
        let stdout = child
            .stdout
            .take()
            .ok_or("Codex app-server stdout unavailable")?;
        let stderr = child
            .stderr
            .take()
            .ok_or("Codex app-server stderr unavailable")?;

        *self.stdin.lock().await = Some(stdin);
        *process_lock = Some(child);
        drop(process_lock);

        self.spawn_stdout_reader(stdout);
        self.spawn_stderr_reader(stderr);

        self.initialize_connection().await?;
        *self.started.lock().await = true;

        info!("Codex app-server initialized");
        Ok(())
    }

    pub async fn stop_server(&self) -> Result<(), String> {
        *self.started.lock().await = false;
        self.reject_all_pending("Codex app-server stopped").await;

        if let Some(mut child) = self.process.lock().await.take() {
            if let Err(e) = child.start_kill() {
                warn!("Failed to kill Codex app-server: {}", e);
            }
            let _ = child.wait().await;
        }
        *self.stdin.lock().await = None;
        Ok(())
    }

    pub async fn send_request(&self, method: &str, params: Option<Value>) -> Result<Value, String> {
        self.ensure_server_running().await?;
        self.send_request_raw(method, params).await
    }

    async fn send_request_raw(&self, method: &str, params: Option<Value>) -> Result<Value, String> {
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
            return Err(e);
        }

        match timeout(Duration::from_secs(REQUEST_TIMEOUT_SECS), rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(format!("Codex request channel dropped: {}", method)),
            Err(_) => {
                self.pending.lock().await.remove(&id_key);
                Err(format!("Codex request timeout: {}", method))
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

    async fn send_notification_raw(&self, method: &str, params: Option<Value>) -> Result<(), String> {
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
                        warn!("Codex app-server stdout JSON parse failed: {}; raw={}", e, trimmed);
                        continue;
                    }
                };
                Self::handle_incoming_value(value, &pending, &notifications_tx, &requests_tx).await;
            }

            *started.lock().await = false;
            let mut map = pending.lock().await;
            for (_, tx) in map.drain() {
                let _ = tx.send(Err("Codex app-server stdout closed".to_string()));
            }
        });
    }

    fn spawn_stderr_reader(&self, stderr: tokio::process::ChildStderr) {
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                debug!("[codex app-server stderr] {}", line);
            }
        });
    }

    async fn handle_incoming_value(
        value: Value,
        pending: &Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, String>>>>>,
        notifications_tx: &broadcast::Sender<CodexNotification>,
        requests_tx: &broadcast::Sender<CodexServerRequest>,
    ) {
        let Some(obj) = value.as_object() else {
            return;
        };

        if let (Some(id), Some(method)) = (
            obj.get("id"),
            obj.get("method").and_then(|m| m.as_str()),
        ) {
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
                    let message = error
                        .get("message")
                        .and_then(|m| m.as_str())
                        .unwrap_or("unknown error")
                        .to_string();
                    let _ = tx.send(Err(format!("Codex app-server error: {}", message)));
                    return;
                }
                let _ = tx.send(Err("Malformed JSON-RPC response".to_string()));
            }
        }
    }

    async fn initialize_connection(&self) -> Result<(), String> {
        let _ = self
            .send_request_raw(
                "initialize",
                Some(serde_json::json!({
                    "clientInfo": {
                        "name": "tidyflow",
                        "version": env!("CARGO_PKG_VERSION")
                    },
                    "capabilities": {
                        "experimentalApi": true
                    }
                })),
            )
            .await?;
        self.send_notification_raw("initialized", None).await
    }

    async fn write_json_line(&self, value: &Value) -> Result<(), String> {
        let line = serde_json::to_string(value)
            .map_err(|e| format!("Failed to serialize JSON-RPC payload: {}", e))?;
        let mut stdin_lock = self.stdin.lock().await;
        let stdin = stdin_lock
            .as_mut()
            .ok_or_else(|| "Codex app-server stdin is not ready".to_string())?;
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
            let _ = tx.send(Err(reason.to_string()));
        }
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
