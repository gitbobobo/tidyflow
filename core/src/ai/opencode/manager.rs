use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;
use tokio::process::Command;
use tokio::sync::Mutex;
use tokio::time::{timeout, Duration};
use tracing::{debug, error, info, warn};

const HEALTH_CHECK_INTERVAL_MS: u64 = 100;
const HEALTH_CHECK_TIMEOUT_MS: u64 = 3000;
const MAX_HEALTH_CHECK_ATTEMPTS: u32 = 30;
const GRACEFUL_SHUTDOWN_TIMEOUT_MS: u64 = 5000;
const HEALTH_CHECK_SUCCESS_CACHE_MS: u64 = 1000;

#[derive(Debug)]
pub struct OpenCodeManager {
    port: u16,
    base_url: String,
    process: Arc<Mutex<Option<tokio::process::Child>>>,
    lifecycle: Arc<Mutex<()>>,
    last_successful_health_check_at: Arc<Mutex<Option<Instant>>>,
    working_dir: PathBuf,
}

impl OpenCodeManager {
    pub fn new(working_dir: PathBuf) -> Self {
        let port = Self::allocate_ephemeral_port();
        let base_url = format!("http://127.0.0.1:{}", port);
        Self {
            port,
            base_url,
            process: Arc::new(Mutex::new(None)),
            lifecycle: Arc::new(Mutex::new(())),
            last_successful_health_check_at: Arc::new(Mutex::new(None)),
            working_dir,
        }
    }

    fn allocate_ephemeral_port() -> u16 {
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").expect("Failed to bind to ephemeral port");
        let addr = listener.local_addr().expect("Failed to get local address");
        drop(listener);
        addr.port()
    }

    pub fn get_base_url(&self) -> String {
        self.base_url.clone()
    }

    pub fn get_port(&self) -> u16 {
        self.port
    }

    pub async fn start_server(&self) -> Result<String, String> {
        let _lifecycle = self.lifecycle.lock().await;
        self.start_server_locked().await
    }

    async fn start_server_locked(&self) -> Result<String, String> {
        if self.is_running().await {
            if self.check_health().await.is_ok() {
                return Ok(self.base_url.clone());
            }
            self.stop_server_locked().await?;
        }

        info!(
            "Starting OpenCode server on port {} (working_dir: {})",
            self.port,
            self.working_dir.display()
        );

        let opencode_bin = Self::resolve_opencode_path()
            .ok_or_else(|| "opencode not found in PATH or common install locations".to_string())?;

        let mut child = Command::new(&opencode_bin)
            .args([
                "serve",
                "--port",
                &self.port.to_string(),
                "--hostname",
                "127.0.0.1",
            ])
            .current_dir(&self.working_dir)
            .envs(Self::build_extended_env())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to spawn opencode serve: {}", e))?;

        let pid = child.id().unwrap_or(0);
        info!("OpenCode server spawned with PID: {}", pid);

        if let Some(stdout) = child.stdout.take() {
            tokio::spawn(async move {
                use tokio::io::AsyncReadExt;
                let mut reader = tokio::io::BufReader::new(stdout);
                let mut buf = [0u8; 1024];
                loop {
                    match reader.read(&mut buf).await {
                        Ok(0) => break,
                        Ok(n) => {
                            let output = String::from_utf8_lossy(&buf[..n]);
                            debug!("[opencode serve] {}", output.trim());
                        }
                        Err(e) => {
                            warn!("Failed to read opencode stdout: {}", e);
                            break;
                        }
                    }
                }
            });
        }

        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                use tokio::io::AsyncReadExt;
                let mut reader = tokio::io::BufReader::new(stderr);
                let mut buf = [0u8; 1024];
                loop {
                    match reader.read(&mut buf).await {
                        Ok(0) => break,
                        Ok(n) => {
                            let output = String::from_utf8_lossy(&buf[..n]);
                            debug!("[opencode serve stderr] {}", output.trim());
                        }
                        Err(e) => {
                            warn!("Failed to read opencode stderr: {}", e);
                            break;
                        }
                    }
                }
            });
        }

        let process_lock = self.process.clone();
        {
            let mut process = process_lock.lock().await;
            *process = Some(child);
        }

        if let Err(err) = self.check_health().await {
            let _ = self.stop_server_locked().await;
            return Err(err);
        }

        info!("OpenCode server started successfully at {}", self.base_url);
        Ok(self.base_url.clone())
    }

    pub async fn check_health(&self) -> Result<(), String> {
        {
            let last_success = self.last_successful_health_check_at.lock().await;
            if let Some(last_success_at) = *last_success {
                if last_success_at.elapsed() <= Duration::from_millis(HEALTH_CHECK_SUCCESS_CACHE_MS) {
                    debug!(
                        "Health check cache hit within {}ms",
                        HEALTH_CHECK_SUCCESS_CACHE_MS
                    );
                    return Ok(());
                }
            }
        }

        // OpenCode 新版建议使用 /global/health；老版本可能仍有 /health。
        let health_urls = [
            format!("{}/global/health", self.base_url),
            format!("{}/health", self.base_url),
        ];
        let client = reqwest::Client::new();

        for attempt in 1..=MAX_HEALTH_CHECK_ATTEMPTS {
            debug!(
                "Health check attempt {}/{}",
                attempt, MAX_HEALTH_CHECK_ATTEMPTS
            );

            let mut ok = false;
            for url in health_urls.iter() {
                match client
                    .get(url)
                    .timeout(Duration::from_millis(500))
                    .send()
                    .await
                {
                    Ok(response) if response.status().is_success() => {
                        ok = true;
                        break;
                    }
                    Ok(response) => debug!("Health check returned status: {}", response.status()),
                    Err(e) => debug!("Health check failed: {}", e),
                }
            }
            if ok {
                let mut last_success = self.last_successful_health_check_at.lock().await;
                *last_success = Some(Instant::now());
                info!("Health check passed on attempt {}", attempt);
                return Ok(());
            }

            if attempt < MAX_HEALTH_CHECK_ATTEMPTS {
                tokio::time::sleep(Duration::from_millis(HEALTH_CHECK_INTERVAL_MS)).await;
            }
        }

        error!(
            "Health check failed after {} attempts",
            MAX_HEALTH_CHECK_ATTEMPTS
        );
        Err(format!(
            "Health check timed out after {}ms",
            HEALTH_CHECK_TIMEOUT_MS
        ))
    }

    /// 确保 server 正在运行：先 health check，失败才 spawn。
    pub async fn ensure_server_running(&self) -> Result<String, String> {
        let _lifecycle = self.lifecycle.lock().await;
        self.ensure_server_running_locked().await
    }

    async fn ensure_server_running_locked(&self) -> Result<String, String> {
        // 没有子进程在运行时直接启动，跳过无意义的 30 次 health check（否则首次启动要白等 ~33 秒）
        if !self.is_running().await {
            return self.start_server_locked().await;
        }

        // 有子进程在运行，检查是否健康
        if self.check_health().await.is_ok() {
            return Ok(self.base_url.clone());
        }

        // 不健康，先停再起
        let _ = self.stop_server_locked().await;
        self.start_server_locked().await
    }

    pub async fn stop_server(&self) -> Result<(), String> {
        let _lifecycle = self.lifecycle.lock().await;
        self.stop_server_locked().await
    }

    async fn stop_server_locked(&self) -> Result<(), String> {
        info!("Stopping OpenCode server on port {}", self.port);
        {
            let mut last_success = self.last_successful_health_check_at.lock().await;
            *last_success = None;
        }

        let mut process_lock = self.process.lock().await;
        if let Some(mut child) = process_lock.take() {
            info!("Sending SIGTERM to OpenCode server (PID: {:?})", child.id());

            child
                .start_kill()
                .map_err(|e| format!("Failed to send SIGTERM: {}", e))?;

            match timeout(
                Duration::from_millis(GRACEFUL_SHUTDOWN_TIMEOUT_MS),
                child.wait(),
            )
            .await
            {
                Ok(Ok(status)) => {
                    info!("OpenCode server exited with status: {}", status);
                }
                Ok(Err(e)) => {
                    warn!("Error waiting for process: {}", e);
                }
                Err(_) => {
                    warn!(
                        "Graceful shutdown timed out, sending SIGKILL to PID: {:?}",
                        child.id()
                    );
                    let _ = child.kill().await;
                }
            }
        } else {
            warn!("No running process to stop");
        }

        info!("OpenCode server stopped");
        Ok(())
    }

    pub async fn is_running(&self) -> bool {
        let process = self.process.lock().await;
        process.is_some()
    }

    /// 解析 opencode 可执行文件的完整路径
    /// Command::new() 使用当前进程 PATH 查找，macOS App 的 PATH 不含用户安装路径
    fn resolve_opencode_path() -> Option<String> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/unknown".to_string());
        let candidates = [
            format!("{}/.opencode/bin/opencode", home),
            format!("{}/.local/bin/opencode", home),
            format!("{}/.cargo/bin/opencode", home),
            "/opt/homebrew/bin/opencode".to_string(),
            "/usr/local/bin/opencode".to_string(),
        ];
        for path in &candidates {
            if std::path::Path::new(path).exists() {
                return Some(path.clone());
            }
        }
        // 兜底：尝试当前 PATH
        std::env::var("PATH").ok().and_then(|p| {
            p.split(':')
                .map(|dir| format!("{}/opencode", dir))
                .find(|path| std::path::Path::new(path).exists())
        })
    }

    /// macOS App 默认 PATH 不含 Homebrew、~/.local/bin 等用户路径，需手动补充
    fn build_extended_env() -> std::collections::HashMap<String, String> {
        let mut env: std::collections::HashMap<String, String> = std::env::vars().collect();
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/unknown".to_string());
        let extra_paths = [
            format!("{}/.local/bin", home),
            format!("{}/.cargo/bin", home),
            format!("{}/.opencode/bin", home),
            format!("{}/.bun/bin", home),
            "/opt/homebrew/bin".to_string(),
            "/opt/homebrew/sbin".to_string(),
            "/usr/local/bin".to_string(),
            "/usr/local/sbin".to_string(),
        ];
        let system_path =
            std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin:/usr/sbin:/sbin".to_string());
        let mut seen = std::collections::HashSet::new();
        let mut parts = Vec::new();
        for p in extra_paths.iter().chain(
            system_path
                .split(':')
                .map(|s| s.to_string())
                .collect::<Vec<_>>()
                .iter(),
        ) {
            if seen.insert(p.clone()) {
                parts.push(p.clone());
            }
        }
        env.insert("PATH".to_string(), parts.join(":"));
        env
    }
}

impl Drop for OpenCodeManager {
    fn drop(&mut self) {
        info!(
            "OpenCodeManager dropped, port {} will be released",
            self.port
        );
    }
}

#[cfg(test)]
mod tests;
