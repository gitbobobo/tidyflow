use super::context_usage::{extract_context_remaining_percent, AiSessionContextUsage};
use super::session_status::AiSessionStatus;
use super::shared::path_norm::normalize_directory as shared_normalize_directory;
use super::{
    AiAgent, AiAgentInfo, AiAudioPart, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiSession, AiSessionSelectionHint, AiSlashCommand,
};
use async_trait::async_trait;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{broadcast, mpsc, watch, Mutex};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::{debug, info, warn};
use uuid::Uuid;

#[derive(Debug, Clone)]
struct ClaudeSessionRecord {
    id: String,
    title: String,
    updated_at: i64,
    directory: String,
    claude_session_id: Option<String>,
    selection_hint: AiSessionSelectionHint,
    messages: Vec<AiMessage>,
    context_usage: Option<AiSessionContextUsage>,
}

#[derive(Debug, Clone)]
struct ClaudeToolState {
    part_id: String,
    tool_call_id: String,
    tool_name: String,
    status: String,
    input: Value,
    title: Option<String>,
    output: Option<String>,
    error: Option<String>,
}

impl ClaudeToolState {
    fn to_part(&self) -> AiPart {
        let mut tool_state = serde_json::json!({
            "status": self.status,
            "input": self.input,
            "metadata": {
                "source": "claude_code"
            }
        });
        if let Some(title) = self.title.as_ref() {
            tool_state["title"] = Value::String(title.clone());
        }
        // read 卡片默认不展示正文，避免历史回放中出现超大输出。
        if self.tool_name != "read" {
            if let Some(output) = self.output.as_ref() {
                tool_state["output"] = Value::String(output.clone());
            }
        }
        if let Some(error) = self.error.as_ref() {
            tool_state["error"] = Value::String(error.clone());
        }
        AiPart {
            id: self.part_id.clone(),
            part_type: "tool".to_string(),
            tool_name: Some(self.tool_name.clone()),
            tool_call_id: Some(self.tool_call_id.clone()),
            tool_state: Some(tool_state),
            ..Default::default()
        }
    }
}

/// 从 init 事件中提取的元数据
struct ClaudeInitData {
    session_id: Option<String>,
}

/// 持久 Claude 子进程的运行时句柄
struct ClaudeProcessHandle {
    /// 子进程 stdin，用于发送用户消息
    stdin: Mutex<tokio::process::ChildStdin>,
    /// stdout 行广播通道发送端
    stdout_tx: broadcast::Sender<String>,
    /// init 事件解析结果
    init_data: Mutex<Option<ClaudeInitData>>,
    /// init 完成信号（true = init 完成，可能成功也可能失败）
    init_watch: watch::Sender<bool>,
    /// 进程是否存活
    alive: AtomicBool,
    /// 启动阶段的错误（如认证失败）
    startup_error: Mutex<Option<String>>,
    /// 发送 kill 信号
    kill_tx: Mutex<Option<mpsc::Sender<()>>>,
}

pub struct ClaudeCodeAgent {
    sessions: Arc<Mutex<HashMap<String, ClaudeSessionRecord>>>,
    /// 按 runtime_key (directory::session_id) 存储持久进程句柄
    processes: Arc<Mutex<HashMap<String, Arc<ClaudeProcessHandle>>>>,
    /// 当前有活跃 turn 的 session（runtime_key 集合）
    active_turns: Arc<Mutex<HashSet<String>>>,
    /// 按 directory 缓存斜杠命令（从 init 事件动态获取）
    slash_commands_by_directory: Arc<Mutex<HashMap<String, Vec<AiSlashCommand>>>>,
    /// 按 directory 缓存 agent 列表（从 init 事件动态获取）
    agents_by_directory: Arc<Mutex<HashMap<String, Vec<AiAgentInfo>>>>,
    /// 按 directory 缓存当前模型名（从 init 事件动态获取）
    model_by_directory: Arc<Mutex<HashMap<String, String>>>,
    /// 正在获取 init 元数据的 directory 集合（防止重复触发）
    pending_init_dirs: Arc<Mutex<HashSet<String>>>,
}

impl ClaudeCodeAgent {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            processes: Arc::new(Mutex::new(HashMap::new())),
            active_turns: Arc::new(Mutex::new(HashSet::new())),
            slash_commands_by_directory: Arc::new(Mutex::new(HashMap::new())),
            agents_by_directory: Arc::new(Mutex::new(HashMap::new())),
            model_by_directory: Arc::new(Mutex::new(HashMap::new())),
            pending_init_dirs: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    fn now_ms() -> i64 {
        chrono::Utc::now().timestamp_millis()
    }

    fn normalize_directory(directory: &str) -> String {
        shared_normalize_directory(directory)
    }

    fn runtime_key(directory: &str, session_id: &str) -> String {
        format!("{}::{}", Self::normalize_directory(directory), session_id)
    }

    fn compose_message(
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        audio_parts: Option<Vec<AiAudioPart>>,
    ) -> String {
        let mut chunks = vec![message.to_string()];
        if let Some(files) = file_refs {
            if !files.is_empty() {
                chunks.push(format!("文件引用：\n{}", files.join("\n")));
            }
        }
        if let Some(images) = image_parts {
            if !images.is_empty() {
                let names = images
                    .iter()
                    .map(|img| format!("{} ({})", img.filename, img.mime))
                    .collect::<Vec<_>>()
                    .join("\n");
                chunks.push(format!("图片附件：\n{}", names));
            }
        }
        if let Some(audios) = audio_parts {
            if !audios.is_empty() {
                let names = audios
                    .iter()
                    .map(|audio| format!("{} ({})", audio.filename, audio.mime))
                    .collect::<Vec<_>>()
                    .join("\n");
                chunks.push(format!("音频附件：\n{}", names));
            }
        }
        chunks.join("\n\n")
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

    fn first_string(value: &Value, keys: &[&str]) -> Option<String> {
        for key in keys {
            if let Some(v) = value.get(*key).and_then(|v| v.as_str()) {
                let trimmed = v.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
        }
        None
    }

    fn maybe_join_text(value: &Value) -> Option<String> {
        match value {
            Value::String(s) => {
                if s.trim().is_empty() {
                    None
                } else {
                    Some(s.clone())
                }
            }
            Value::Array(items) => {
                let mut out = String::new();
                for item in items {
                    if let Some(text) = item.get("text").and_then(|v| v.as_str()) {
                        out.push_str(text);
                    } else if let Some(text) = item.as_str() {
                        out.push_str(text);
                    }
                }
                if out.trim().is_empty() {
                    None
                } else {
                    Some(out)
                }
            }
            _ => None,
        }
    }

    fn normalize_tool_name(raw: &str) -> String {
        let normalized = raw.trim().to_lowercase();
        if normalized.contains("bash")
            || normalized.contains("command")
            || normalized.contains("exec")
        {
            return "bash".to_string();
        }
        if normalized.contains("read") {
            return "read".to_string();
        }
        if normalized.contains("write") || normalized.contains("edit") {
            return "write".to_string();
        }
        if normalized.contains("list") || normalized.contains("glob") || normalized.contains("ls") {
            return "list".to_string();
        }
        if normalized.contains("grep") || normalized.contains("search") {
            return "grep".to_string();
        }
        if normalized.is_empty() {
            "tool".to_string()
        } else {
            normalized
        }
    }

    fn tool_path_from_input(input: &Value) -> Option<String> {
        input
            .get("filePath")
            .and_then(|v| v.as_str())
            .or_else(|| input.get("path").and_then(|v| v.as_str()))
            .or_else(|| input.get("file_path").and_then(|v| v.as_str()))
            .or_else(|| input.get("file").and_then(|v| v.as_str()))
            .or_else(|| input.get("uri").and_then(|v| v.as_str()))
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    fn put_path_aliases(input: &mut Value, path: &str) {
        let Some(obj) = input.as_object_mut() else {
            return;
        };
        if !obj.contains_key("path") {
            obj.insert("path".to_string(), Value::String(path.to_string()));
        }
        if !obj.contains_key("filePath") {
            obj.insert("filePath".to_string(), Value::String(path.to_string()));
        }
    }

    fn normalize_tool_input(input: Value) -> Value {
        let mut normalized = input;
        if let Some(path) = Self::tool_path_from_input(&normalized) {
            Self::put_path_aliases(&mut normalized, &path);
        }
        normalized
    }

    fn tool_title(tool_name: &str, input: &Value) -> Option<String> {
        let path = Self::tool_path_from_input(input);
        match tool_name {
            "read" => path.map(|p| format!("read({})", p)),
            "write" => path.map(|p| format!("write({})", p)),
            "list" => path.map(|p| format!("list({})", p)),
            _ => None,
        }
    }

    fn tool_result_file_path(value: &Value) -> Option<String> {
        value
            .pointer("/tool_use_result/file/filePath")
            .and_then(|v| v.as_str())
            .or_else(|| {
                value
                    .pointer("/tool_use_result/file/path")
                    .and_then(|v| v.as_str())
            })
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    fn emit_snapshot_delta(buffer: &mut String, snapshot: &str) -> Option<String> {
        if snapshot.is_empty() {
            return None;
        }
        if snapshot == buffer {
            return None;
        }
        if snapshot.starts_with(buffer.as_str()) {
            let delta = snapshot[buffer.len()..].to_string();
            *buffer = snapshot.to_string();
            if delta.is_empty() {
                return None;
            }
            return Some(delta);
        }
        *buffer = snapshot.to_string();
        Some(snapshot.to_string())
    }

    fn collect_content_blocks<'a>(value: &'a Value) -> Vec<&'a Value> {
        let mut blocks = Vec::new();
        if let Some(arr) = value
            .get("message")
            .and_then(|v| v.get("content"))
            .and_then(|v| v.as_array())
        {
            blocks.extend(arr.iter());
        }
        if let Some(arr) = value.get("content").and_then(|v| v.as_array()) {
            blocks.extend(arr.iter());
        }
        if let Some(typ) = value.get("type").and_then(|v| v.as_str()) {
            let lower = typ.to_lowercase();
            if lower == "tool_use"
                || lower == "tool_result"
                || lower == "text"
                || lower.contains("delta")
                || lower.contains("thinking")
            {
                blocks.push(value);
            }
        }
        blocks
    }

    fn parse_error(value: &Value) -> Option<String> {
        let typ = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if typ.eq_ignore_ascii_case("error") {
            if let Some(msg) = value.get("message").and_then(|v| v.as_str()) {
                let text = msg.trim();
                if !text.is_empty() {
                    return Some(text.to_string());
                }
            }
            if let Some(msg) = value.get("error").and_then(|v| v.as_str()) {
                let text = msg.trim();
                if !text.is_empty() {
                    return Some(text.to_string());
                }
            }
            return Some("Claude Code stream error".to_string());
        }
        None
    }

    /// 构造发送到 claude stdin 的用户消息 JSON
    fn build_user_message_json(text: &str, claude_session_id: Option<&str>) -> String {
        serde_json::json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": text,
            },
            "parent_tool_use_id": Value::Null,
            "session_id": claude_session_id.unwrap_or(""),
        })
        .to_string()
    }

    /// 为指定会话启动一个持久 Claude 子进程
    async fn spawn_persistent_process(
        directory: &str,
        resume_session_id: Option<&str>,
        model_id: Option<&str>,
        slash_commands_cache: Arc<Mutex<HashMap<String, Vec<AiSlashCommand>>>>,
        agents_cache: Arc<Mutex<HashMap<String, Vec<AiAgentInfo>>>>,
        model_cache: Arc<Mutex<HashMap<String, String>>>,
    ) -> Result<Arc<ClaudeProcessHandle>, String> {
        let mut args = vec![
            "--print".to_string(),
            "--output-format".to_string(),
            "stream-json".to_string(),
            "--input-format".to_string(),
            "stream-json".to_string(),
            "--verbose".to_string(),
            "--dangerously-skip-permissions".to_string(),
        ];
        if let Some(resume) = resume_session_id {
            args.push("--resume".to_string());
            args.push(resume.to_string());
        }
        if let Some(model) = model_id {
            args.push("--model".to_string());
            args.push(model.to_string());
        }

        info!(
            "[claude] spawning persistent process: claude {} (dir={})",
            args.join(" "),
            directory
        );

        let mut command = Command::new("claude");
        command
            .args(&args)
            .current_dir(directory)
            .envs(Self::build_extended_env())
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        let mut child = command
            .spawn()
            .map_err(|e| format!("Failed to spawn `claude {}`: {}", args.join(" "), e))?;

        info!(
            "[claude] process spawned successfully, pid={:?}",
            child.id()
        );

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Claude stdin unavailable".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Claude stdout unavailable".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Claude stderr unavailable".to_string())?;

        let (stdout_tx, _) = broadcast::channel::<String>(8192);
        let (kill_tx, mut kill_rx) = mpsc::channel::<()>(1);
        let (init_watch, _) = watch::channel(false);

        let handle = Arc::new(ClaudeProcessHandle {
            stdin: Mutex::new(stdin),
            stdout_tx: stdout_tx.clone(),
            init_data: Mutex::new(None),
            init_watch,
            alive: AtomicBool::new(true),
            startup_error: Mutex::new(None),
            kill_tx: Mutex::new(Some(kill_tx)),
        });

        // 后台 stdout/stderr reader
        let handle_ref = Arc::clone(&handle);
        let dir_for_cache = Self::normalize_directory(directory);
        tokio::spawn(async move {
            info!(
                "[claude reader] background reader started for {}",
                dir_for_cache
            );
            let mut stdout_lines = BufReader::new(stdout).lines();
            let mut stderr_lines = BufReader::new(stderr).lines();
            let mut stdout_closed = false;
            let mut stderr_closed = false;
            let mut init_received = false;
            let mut line_count: u64 = 0;

            while !(stdout_closed && stderr_closed) {
                tokio::select! {
                    _ = kill_rx.recv() => {
                        info!("[claude reader] kill signal received");
                        let _ = child.start_kill();
                        let _ = child.wait().await;
                        handle_ref.alive.store(false, Ordering::SeqCst);
                        return;
                    }
                    line = stdout_lines.next_line(), if !stdout_closed => {
                        match line {
                            Ok(Some(line)) => {
                                line_count += 1;
                                let trimmed = line.trim().to_string();
                                if line_count <= 3 {
                                    info!("[claude reader] stdout line #{}: len={} first_100={}", line_count, trimmed.len(), &trimmed[..trimmed.len().min(100)]);
                                }
                                if trimmed.is_empty() {
                                    continue;
                                }
                                // 解析 init 事件
                                if !init_received {
                                    if let Ok(value) = serde_json::from_str::<Value>(&trimmed) {
                                        let is_init = value.get("type").and_then(|v| v.as_str()) == Some("system")
                                            && value.get("subtype").and_then(|v| v.as_str()) == Some("init");
                                        if is_init {
                                            init_received = true;
                                            let session_id = value
                                                .get("session_id")
                                                .or_else(|| value.get("sessionId"))
                                                .and_then(|v| v.as_str())
                                                .map(|s| s.to_string());
                                            let model = value
                                                .get("model")
                                                .and_then(|v| v.as_str())
                                                .map(|s| s.trim().to_string());
                                            let agents: Vec<String> = value
                                                .get("agents")
                                                .and_then(|v| v.as_array())
                                                .map(|arr| {
                                                    arr.iter()
                                                        .filter_map(|v| v.as_str())
                                                        .filter(|s| !s.is_empty())
                                                        .map(|s| s.to_string())
                                                        .collect()
                                                })
                                                .unwrap_or_default();
                                            let slash_commands: Vec<String> = value
                                                .get("slash_commands")
                                                .and_then(|v| v.as_array())
                                                .map(|arr| {
                                                    arr.iter()
                                                        .filter_map(|v| v.as_str())
                                                        .filter(|s| !s.is_empty())
                                                        .map(|s| s.to_string())
                                                        .collect()
                                                })
                                                .unwrap_or_default();

                                            // 更新 directory 级别缓存
                                            if let Some(ref m) = model {
                                                if !m.is_empty() {
                                                    model_cache
                                                        .lock()
                                                        .await
                                                        .insert(dir_for_cache.clone(), m.clone());
                                                }
                                            }
                                            if !agents.is_empty() {
                                                let agent_infos: Vec<AiAgentInfo> = agents
                                                    .iter()
                                                    .map(|name| AiAgentInfo {
                                                        name: name.to_lowercase(),
                                                        description: None,
                                                        mode: Some("primary".to_string()),
                                                        color: None,
                                                        default_provider_id: Some(
                                                            "anthropic".to_string(),
                                                        ),
                                                        default_model_id: Some(
                                                            "default".to_string(),
                                                        ),
                                                    })
                                                    .collect();
                                                agents_cache
                                                    .lock()
                                                    .await
                                                    .insert(dir_for_cache.clone(), agent_infos);
                                            }
                                            if !slash_commands.is_empty() {
                                                let cmds: Vec<AiSlashCommand> = slash_commands
                                                    .iter()
                                                    .map(|name| AiSlashCommand {
                                                        name: name.clone(),
                                                        description: String::new(),
                                                        action: "agent".to_string(),
                                                        input_hint: None,
                                                    })
                                                    .collect();
                                                slash_commands_cache
                                                    .lock()
                                                    .await
                                                    .insert(dir_for_cache.clone(), cmds);
                                            }

                                            *handle_ref.init_data.lock().await =
                                                Some(ClaudeInitData { session_id });
                                            let _ = handle_ref.init_watch.send(true);
                                            debug!(
                                                "[claude] init metadata received for {}",
                                                dir_for_cache
                                            );
                                        }
                                        // 检查启动阶段的错误
                                        if let Some(err_msg) =
                                            ClaudeCodeAgent::parse_error(&value)
                                        {
                                            *handle_ref.startup_error.lock().await =
                                                Some(err_msg);
                                            let _ = handle_ref.init_watch.send(true);
                                        }
                                    }
                                }
                                // 广播给订阅者（per-turn 解析任务）
                                let _ = handle_ref.stdout_tx.send(trimmed);
                            }
                            Ok(None) => {
                                info!("[claude reader] stdout closed (line_count={})", line_count);
                                stdout_closed = true;
                            }
                            Err(e) => {
                                warn!("[claude reader] stdout error: {}", e);
                                stdout_closed = true;
                            }
                        }
                    }
                    line = stderr_lines.next_line(), if !stderr_closed => {
                        match line {
                            Ok(Some(line)) => {
                                let trimmed = line.trim();
                                if !trimmed.is_empty() {
                                    info!("[claude stderr] {}", trimmed);
                                }
                            }
                            Ok(None) => {
                                info!("[claude reader] stderr closed");
                                stderr_closed = true;
                            }
                            Err(_) => {
                                stderr_closed = true;
                            }
                        }
                    }
                }
            }

            // 进程退出
            let exit_status = child.wait().await;
            info!("[claude reader] process exited: {:?}", exit_status);
            handle_ref.alive.store(false, Ordering::SeqCst);
            // 如果 init 还没收到，通知等待者
            if !init_received {
                *handle_ref.startup_error.lock().await =
                    Some("Claude process exited before init".to_string());
                let _ = handle_ref.init_watch.send(true);
            }
        });

        Ok(handle)
    }

    /// 获取或创建指定会话的持久进程
    async fn get_or_spawn_process(
        &self,
        directory: &str,
        session_id: &str,
        resume_session_id: Option<&str>,
        model_id: Option<&str>,
    ) -> Result<Arc<ClaudeProcessHandle>, String> {
        let key = Self::runtime_key(directory, session_id);

        // 检查现有进程
        {
            let processes = self.processes.lock().await;
            if let Some(handle) = processes.get(&key) {
                if handle.alive.load(Ordering::SeqCst) {
                    return Ok(Arc::clone(handle));
                }
            }
        }

        // 需要新建进程
        let handle = Self::spawn_persistent_process(
            directory,
            resume_session_id,
            model_id,
            Arc::clone(&self.slash_commands_by_directory),
            Arc::clone(&self.agents_by_directory),
            Arc::clone(&self.model_by_directory),
        )
        .await?;

        self.processes.lock().await.insert(key, Arc::clone(&handle));
        Ok(handle)
    }

    /// 等待持久进程完成初始化，返回错误或成功
    async fn wait_for_init(handle: &ClaudeProcessHandle) -> Result<(), String> {
        let mut init_rx = handle.init_watch.subscribe();
        if !*init_rx.borrow() {
            match tokio::time::timeout(std::time::Duration::from_secs(30), init_rx.wait_for(|v| *v))
                .await
            {
                Ok(Ok(_)) => {}
                Ok(Err(_)) => {
                    return Err("Claude process init channel closed".to_string());
                }
                Err(_) => {
                    return Err("Claude process init timeout (30s)".to_string());
                }
            }
        }
        // 检查是否有启动错误
        if let Some(ref err) = *handle.startup_error.lock().await {
            return Err(err.clone());
        }
        Ok(())
    }

    /// 确保指定 directory 的 init 元数据已开始获取。
    /// 如果缓存为空且未在获取中，则后台 spawn 一次 `claude` 命令来拉取 init 事件。
    fn ensure_init_metadata(&self, directory: &str) {
        let dir_key = Self::normalize_directory(directory);

        // 快速检查：如果 agents 缓存已有数据，说明已获取过
        if let Ok(guard) = self.agents_by_directory.try_lock() {
            if guard.contains_key(&dir_key) {
                return;
            }
        }
        if let Ok(guard) = self.pending_init_dirs.try_lock() {
            if guard.contains(&dir_key) {
                return;
            }
        }

        let pending = self.pending_init_dirs.clone();
        let agents_cache = self.agents_by_directory.clone();
        let model_cache = self.model_by_directory.clone();
        let slash_cache = self.slash_commands_by_directory.clone();
        let dir_key_owned = dir_key.clone();
        let directory_owned = directory.to_string();

        tokio::spawn(async move {
            {
                let mut p = pending.lock().await;
                if !p.insert(dir_key_owned.clone()) {
                    return; // 已有其他任务在获取
                }
            }

            let result = Self::fetch_init_event(&directory_owned).await;

            match result {
                Ok(value) => {
                    // 提取 agents
                    if let Some(arr) = value.get("agents").and_then(|v| v.as_array()) {
                        let agents: Vec<AiAgentInfo> = arr
                            .iter()
                            .filter_map(|v| v.as_str())
                            .filter(|s| !s.trim().is_empty())
                            .map(|name| AiAgentInfo {
                                name: name.to_lowercase(),
                                description: None,
                                mode: Some("primary".to_string()),
                                color: None,
                                default_provider_id: Some("anthropic".to_string()),
                                default_model_id: Some("default".to_string()),
                            })
                            .collect();
                        if !agents.is_empty() {
                            agents_cache
                                .lock()
                                .await
                                .insert(dir_key_owned.clone(), agents);
                        }
                    }
                    // 提取 model
                    if let Some(m) = value.get("model").and_then(|v| v.as_str()) {
                        let trimmed = m.trim();
                        if !trimmed.is_empty() {
                            model_cache
                                .lock()
                                .await
                                .insert(dir_key_owned.clone(), trimmed.to_string());
                        }
                    }
                    // 提取 slash_commands
                    if let Some(cmds) = value.get("slash_commands").and_then(|v| v.as_array()) {
                        let commands: Vec<AiSlashCommand> = cmds
                            .iter()
                            .filter_map(|v| v.as_str())
                            .filter(|s| !s.trim().is_empty())
                            .map(|name| AiSlashCommand {
                                name: name.to_string(),
                                description: String::new(),
                                action: "agent".to_string(),
                                input_hint: None,
                            })
                            .collect();
                        if !commands.is_empty() {
                            slash_cache
                                .lock()
                                .await
                                .insert(dir_key_owned.clone(), commands);
                        }
                    }
                    debug!("[claude init] metadata fetched for {}", dir_key_owned);
                }
                Err(e) => {
                    warn!("[claude init] failed to fetch metadata: {}", e);
                }
            }

            pending.lock().await.remove(&dir_key_owned);
        });
    }

    /// 运行一次轻量 `claude` 命令，仅读取 init 事件后立即终止。
    async fn fetch_init_event(directory: &str) -> Result<Value, String> {
        let mut command = Command::new("claude");
        command
            .args([
                "--print",
                "-p",
                "hello",
                "--output-format",
                "stream-json",
                "--verbose",
                "--dangerously-skip-permissions",
                "--max-turns",
                "1",
            ])
            .current_dir(directory)
            .envs(Self::build_extended_env())
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());

        let mut child = command
            .spawn()
            .map_err(|e| format!("Failed to spawn claude for init: {}", e))?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "claude stdout unavailable".to_string())?;

        let mut lines = BufReader::new(stdout).lines();
        let mut init_value: Option<Value> = None;

        // 只读取到 init 事件就够了
        while let Ok(Some(line)) = lines.next_line().await {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
                let is_init = value.get("type").and_then(|v| v.as_str()) == Some("system")
                    && value.get("subtype").and_then(|v| v.as_str()) == Some("init");
                if is_init {
                    init_value = Some(value);
                    break;
                }
            }
        }

        // 拿到 init 后立即终止进程
        let _ = child.start_kill();
        let _ = child.wait().await;

        init_value.ok_or_else(|| "No init event received from claude".to_string())
    }
}

impl Default for ClaudeCodeAgent {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl AiAgent for ClaudeCodeAgent {
    async fn start(&self) -> Result<(), String> {
        Ok(())
    }

    async fn stop(&self) -> Result<(), String> {
        let processes = self.processes.lock().await;
        for (_, handle) in processes.iter() {
            if let Some(kill_tx) = handle.kill_tx.lock().await.take() {
                let _ = kill_tx.send(()).await;
            }
        }
        drop(processes);
        self.processes.lock().await.clear();
        self.active_turns.lock().await.clear();
        Ok(())
    }

    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String> {
        let id = format!("claude-{}", Uuid::new_v4());
        let record = ClaudeSessionRecord {
            id: id.clone(),
            title: title.to_string(),
            updated_at: Self::now_ms(),
            directory: Self::normalize_directory(directory),
            claude_session_id: None,
            selection_hint: AiSessionSelectionHint::default(),
            messages: Vec::new(),
            context_usage: None,
        };
        self.sessions.lock().await.insert(id.clone(), record);
        Ok(AiSession {
            id,
            title: title.to_string(),
            updated_at: Self::now_ms(),
        })
    }

    async fn send_message(
        &self,
        directory: &str,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        audio_parts: Option<Vec<AiAudioPart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
    ) -> Result<AiEventStream, String> {
        let normalized_directory = Self::normalize_directory(directory);
        let key = Self::runtime_key(&normalized_directory, session_id);

        let (resume_session_id, history_hint) = {
            let mut sessions = self.sessions.lock().await;
            let record = sessions
                .get_mut(session_id)
                .ok_or_else(|| format!("Claude session not found: {}", session_id))?;
            if record.directory != normalized_directory {
                return Err(format!(
                    "Claude session directory mismatch: session_id={}, expected={}, got={}",
                    session_id, record.directory, normalized_directory
                ));
            }
            record.updated_at = Self::now_ms();
            if let Some(ref selected) = model {
                record.selection_hint.model_provider_id = Some(selected.provider_id.clone());
                record.selection_hint.model_id = Some(selected.model_id.clone());
            }
            if let Some(ref mode) = agent {
                let normalized = mode.trim().to_lowercase();
                if !normalized.is_empty() {
                    record.selection_hint.agent = Some(normalized);
                }
            }
            (
                record.claude_session_id.clone(),
                record.selection_hint.clone(),
            )
        };

        let user_message_id = format!("claude-user-{}", Uuid::new_v4());
        let user_text = message.to_string();
        {
            let mut sessions = self.sessions.lock().await;
            if let Some(record) = sessions.get_mut(session_id) {
                record.messages.push(AiMessage {
                    id: user_message_id.clone(),
                    role: "user".to_string(),
                    created_at: Some(Self::now_ms()),
                    agent: history_hint.agent.clone(),
                    model_provider_id: history_hint.model_provider_id.clone(),
                    model_id: history_hint.model_id.clone(),
                    parts: vec![AiPart::new_text(
                        format!("{}-text", user_message_id),
                        user_text.clone(),
                    )],
                });
            }
        }

        let (tx, rx) = mpsc::unbounded_channel::<Result<AiEvent, String>>();
        let _ = tx.send(Ok(AiEvent::MessageUpdated {
            message_id: user_message_id.clone(),
            role: "user".to_string(),
            selection_hint: None,
        }));
        let _ = tx.send(Ok(AiEvent::PartUpdated {
            message_id: user_message_id.clone(),
            part: AiPart::new_text(format!("{}-text", user_message_id), user_text.clone()),
        }));

        // 获取或创建持久进程
        let model_id = model.as_ref().map(|m| m.model_id.clone());
        let handle = self
            .get_or_spawn_process(
                &normalized_directory,
                session_id,
                resume_session_id.as_deref(),
                model_id.as_deref(),
            )
            .await;
        let handle = match handle {
            Ok(h) => h,
            Err(e) => {
                let _ = tx.send(Err(e));
                let _ = tx.send(Ok(AiEvent::Done { stop_reason: None }));
                return Ok(Box::pin(UnboundedReceiverStream::new(rx)));
            }
        };

        // 判断进程是否已初始化（已有进程 vs 新进程）
        let already_init = *handle.init_watch.subscribe().borrow();

        // 如果已初始化，可以用 claude_session_id 构建消息
        let claude_session_id_before = if already_init {
            handle
                .init_data
                .lock()
                .await
                .as_ref()
                .and_then(|d| d.session_id.clone())
        } else {
            // 新进程还没 init，先用 resume_session_id 或空
            resume_session_id.clone()
        };

        // 构造用户消息并写入 stdin（必须在等 init 前发送，因为 claude 需要 stdin 输入才输出 init）
        let prompt = Self::compose_message(message, file_refs, image_parts, audio_parts);
        let msg_json = Self::build_user_message_json(&prompt, claude_session_id_before.as_deref());
        {
            let mut stdin = handle.stdin.lock().await;
            let write_result = async {
                stdin
                    .write_all(msg_json.as_bytes())
                    .await
                    .map_err(|e| e.to_string())?;
                stdin.write_all(b"\n").await.map_err(|e| e.to_string())?;
                stdin.flush().await.map_err(|e| e.to_string())
            }
            .await;

            if let Err(e) = write_result {
                handle.alive.store(false, Ordering::SeqCst);
                self.processes.lock().await.remove(&key);
                let _ = tx.send(Err(format!("Failed to write to Claude stdin: {}", e)));
                let _ = tx.send(Ok(AiEvent::Done { stop_reason: None }));
                return Ok(Box::pin(UnboundedReceiverStream::new(rx)));
            }
        }

        // 等待 init 完成（对新进程：stdin 已发送，claude 会先输出 init 再处理消息）
        if let Err(e) = Self::wait_for_init(&handle).await {
            let _ = tx.send(Err(e));
            let _ = tx.send(Ok(AiEvent::Done { stop_reason: None }));
            return Ok(Box::pin(UnboundedReceiverStream::new(rx)));
        }

        // init 完成后更新 claude_session_id
        let claude_session_id = handle
            .init_data
            .lock()
            .await
            .as_ref()
            .and_then(|d| d.session_id.clone());
        {
            let mut sessions = self.sessions.lock().await;
            if let Some(record) = sessions.get_mut(session_id) {
                if let Some(ref csid) = claude_session_id {
                    record.claude_session_id = Some(csid.clone());
                }
            }
        }

        // 订阅 stdout 广播
        let mut stdout_rx = handle.stdout_tx.subscribe();

        // 标记当前 turn 为活跃
        self.active_turns.lock().await.insert(key.clone());

        // 启动 per-turn 解析任务
        let sessions = self.sessions.clone();
        let active_turns = self.active_turns.clone();
        let processes = self.processes.clone();
        let session_id_owned = session_id.to_string();
        let key_owned = key.clone();
        let history_hint_owned = history_hint.clone();
        let handle_alive = Arc::clone(&handle);

        tokio::spawn(async move {
            let assistant_message_id = format!("claude-assistant-{}", Uuid::new_v4());
            let reasoning_part_id = format!("{}-reasoning", assistant_message_id);
            let mut assistant_opened = false;
            let mut text_part_seq: u32 = 0;
            let mut active_text_part_id: Option<String> = None;
            let mut text_part_buffers: HashMap<String, String> = HashMap::new();
            let mut assistant_reasoning = String::new();
            let mut parsed_claude_session_id = claude_session_id;
            let mut tool_states: HashMap<String, ClaudeToolState> = HashMap::new();
            let mut seen_part_ids: HashSet<String> = HashSet::new();
            let mut ordered_part_ids: Vec<String> = Vec::new();
            let mut last_usage_json: Option<Value> = None;

            loop {
                match stdout_rx.recv().await {
                    Ok(line) => {
                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            continue;
                        }

                        match serde_json::from_str::<Value>(trimmed) {
                            Ok(value) => {
                                // 处理系统事件
                                if value.get("type").and_then(|v| v.as_str()) == Some("system") {
                                    let subtype =
                                        value.get("subtype").and_then(|v| v.as_str()).unwrap_or("");
                                    if subtype == "init" {
                                        // 从 init 事件提取斜杠命令并推送到客户端
                                        if let Some(cmds) =
                                            value.get("slash_commands").and_then(|v| v.as_array())
                                        {
                                            let commands: Vec<AiSlashCommand> = cmds
                                                .iter()
                                                .filter_map(|v| v.as_str())
                                                .filter(|s| !s.trim().is_empty())
                                                .map(|name| AiSlashCommand {
                                                    name: name.to_string(),
                                                    description: String::new(),
                                                    action: "agent".to_string(),
                                                    input_hint: None,
                                                })
                                                .collect();
                                            if !commands.is_empty() {
                                                let _ =
                                                    tx.send(Ok(AiEvent::SlashCommandsUpdated {
                                                        session_id: session_id_owned.clone(),
                                                        commands,
                                                    }));
                                            }
                                        }
                                        continue;
                                    }
                                    continue;
                                }

                                // 错误检查
                                if let Some(err_msg) = ClaudeCodeAgent::parse_error(&value) {
                                    let _ = tx.send(Err(err_msg));
                                    break;
                                }

                                // 提取 session ID
                                if let Some(stream_session_id) = ClaudeCodeAgent::first_string(
                                    &value,
                                    &["session_id", "sessionId"],
                                ) {
                                    parsed_claude_session_id = Some(stream_session_id);
                                }

                                // 处理 content blocks
                                for block in ClaudeCodeAgent::collect_content_blocks(&value) {
                                    let block_type = block
                                        .get("type")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_lowercase();

                                    if block_type == "tool_use" {
                                        let tool_call_id = ClaudeCodeAgent::first_string(
                                            block,
                                            &[
                                                "id",
                                                "tool_use_id",
                                                "toolUseId",
                                                "call_id",
                                                "callId",
                                            ],
                                        )
                                        .unwrap_or_else(|| Uuid::new_v4().to_string());
                                        let input = block
                                            .get("input")
                                            .cloned()
                                            .or_else(|| block.get("arguments").cloned())
                                            .unwrap_or_else(|| {
                                                Value::Object(serde_json::Map::new())
                                            });
                                        let raw_name =
                                            ClaudeCodeAgent::first_string(block, &["name", "tool"])
                                                .unwrap_or_else(|| "tool".to_string());
                                        let tool_name =
                                            ClaudeCodeAgent::normalize_tool_name(&raw_name);
                                        let input = ClaudeCodeAgent::normalize_tool_input(input);
                                        let part_id = format!(
                                            "claude-tool-{}-{}",
                                            assistant_message_id, tool_call_id
                                        );
                                        let state = ClaudeToolState {
                                            part_id,
                                            tool_call_id: tool_call_id.clone(),
                                            tool_name: tool_name.clone(),
                                            status: "running".to_string(),
                                            title: ClaudeCodeAgent::tool_title(&tool_name, &input),
                                            input,
                                            output: None,
                                            error: None,
                                        };
                                        tool_states.insert(tool_call_id.clone(), state.clone());
                                        if seen_part_ids.insert(state.part_id.clone()) {
                                            ordered_part_ids.push(state.part_id.clone());
                                        }
                                        // tool 卡片与文本片段按时间轴交错，工具开始后切分下一段文本。
                                        active_text_part_id = None;
                                        if !assistant_opened {
                                            assistant_opened = true;
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: assistant_message_id.clone(),
                                                role: "assistant".to_string(),
                                                selection_hint: None,
                                            }));
                                        }
                                        let _ = tx.send(Ok(AiEvent::PartUpdated {
                                            message_id: assistant_message_id.clone(),
                                            part: state.to_part(),
                                        }));
                                        continue;
                                    }

                                    if block_type == "tool_result" {
                                        let tool_call_id = ClaudeCodeAgent::first_string(
                                            block,
                                            &[
                                                "tool_use_id",
                                                "toolUseId",
                                                "id",
                                                "call_id",
                                                "callId",
                                            ],
                                        );
                                        let Some(tool_call_id) = tool_call_id else {
                                            continue;
                                        };
                                        let output = block
                                            .get("content")
                                            .and_then(ClaudeCodeAgent::maybe_join_text)
                                            .or_else(|| {
                                                block
                                                    .get("output")
                                                    .and_then(ClaudeCodeAgent::maybe_join_text)
                                            })
                                            .or_else(|| {
                                                block
                                                    .get("text")
                                                    .and_then(|v| v.as_str())
                                                    .map(|s| s.to_string())
                                            });
                                        let is_error = block
                                            .get("is_error")
                                            .and_then(|v| v.as_bool())
                                            .unwrap_or(false);
                                        let entry = tool_states
                                            .entry(tool_call_id.clone())
                                            .or_insert_with(|| ClaudeToolState {
                                                part_id: format!(
                                                    "claude-tool-{}-{}",
                                                    assistant_message_id, tool_call_id
                                                ),
                                                tool_call_id: tool_call_id.clone(),
                                                tool_name: "tool".to_string(),
                                                status: "running".to_string(),
                                                input: Value::Object(serde_json::Map::new()),
                                                title: None,
                                                output: None,
                                                error: None,
                                            });
                                        if seen_part_ids.insert(entry.part_id.clone()) {
                                            ordered_part_ids.push(entry.part_id.clone());
                                        }
                                        if let Some(path) =
                                            ClaudeCodeAgent::tool_result_file_path(&value)
                                        {
                                            ClaudeCodeAgent::put_path_aliases(
                                                &mut entry.input,
                                                &path,
                                            );
                                        }
                                        if let Some(output) = output {
                                            entry.output = Some(output);
                                        }
                                        if is_error {
                                            entry.status = "error".to_string();
                                            entry.error = entry.output.clone();
                                        } else {
                                            entry.status = "completed".to_string();
                                        }
                                        entry.title = ClaudeCodeAgent::tool_title(
                                            &entry.tool_name,
                                            &entry.input,
                                        );
                                        active_text_part_id = None;
                                        if !assistant_opened {
                                            assistant_opened = true;
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: assistant_message_id.clone(),
                                                role: "assistant".to_string(),
                                                selection_hint: None,
                                            }));
                                        }
                                        let _ = tx.send(Ok(AiEvent::PartUpdated {
                                            message_id: assistant_message_id.clone(),
                                            part: entry.to_part(),
                                        }));
                                        continue;
                                    }

                                    if block_type.contains("thinking")
                                        || block_type.contains("reasoning")
                                    {
                                        if let Some(text) =
                                            block.get("text").and_then(|v| v.as_str()).or_else(
                                                || block.get("thinking").and_then(|v| v.as_str()),
                                            )
                                        {
                                            if !assistant_opened {
                                                assistant_opened = true;
                                                let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                    message_id: assistant_message_id.clone(),
                                                    role: "assistant".to_string(),
                                                    selection_hint: None,
                                                }));
                                            }
                                            if seen_part_ids.insert(reasoning_part_id.clone()) {
                                                ordered_part_ids.push(reasoning_part_id.clone());
                                            }
                                            assistant_reasoning.push_str(text);
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
                                                part_id: reasoning_part_id.clone(),
                                                part_type: "reasoning".to_string(),
                                                field: "text".to_string(),
                                                delta: text.to_string(),
                                            }));
                                        }
                                        continue;
                                    }

                                    if block_type.ends_with("delta") {
                                        if let Some(text) = block
                                            .get("text")
                                            .and_then(|v| v.as_str())
                                            .or_else(|| block.get("delta").and_then(|v| v.as_str()))
                                        {
                                            if !assistant_opened {
                                                assistant_opened = true;
                                                let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                    message_id: assistant_message_id.clone(),
                                                    role: "assistant".to_string(),
                                                    selection_hint: None,
                                                }));
                                            }
                                            let part_id = if let Some(existing) =
                                                active_text_part_id.as_ref()
                                            {
                                                existing.clone()
                                            } else {
                                                text_part_seq += 1;
                                                let new_id = format!(
                                                    "{}-text-{}",
                                                    assistant_message_id, text_part_seq
                                                );
                                                active_text_part_id = Some(new_id.clone());
                                                text_part_buffers
                                                    .entry(new_id.clone())
                                                    .or_default();
                                                if seen_part_ids.insert(new_id.clone()) {
                                                    ordered_part_ids.push(new_id.clone());
                                                }
                                                new_id
                                            };
                                            if let Some(buffer) =
                                                text_part_buffers.get_mut(&part_id)
                                            {
                                                buffer.push_str(text);
                                            }
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
                                                part_id,
                                                part_type: "text".to_string(),
                                                field: "text".to_string(),
                                                delta: text.to_string(),
                                            }));
                                        }
                                        continue;
                                    }

                                    if block_type == "text" {
                                        if let Some(snapshot) =
                                            block.get("text").and_then(|v| v.as_str())
                                        {
                                            let part_id = if let Some(existing) =
                                                active_text_part_id.as_ref()
                                            {
                                                existing.clone()
                                            } else {
                                                text_part_seq += 1;
                                                let new_id = format!(
                                                    "{}-text-{}",
                                                    assistant_message_id, text_part_seq
                                                );
                                                active_text_part_id = Some(new_id.clone());
                                                text_part_buffers
                                                    .entry(new_id.clone())
                                                    .or_default();
                                                if seen_part_ids.insert(new_id.clone()) {
                                                    ordered_part_ids.push(new_id.clone());
                                                }
                                                new_id
                                            };
                                            if let Some(delta) =
                                                ClaudeCodeAgent::emit_snapshot_delta(
                                                    text_part_buffers
                                                        .entry(part_id.clone())
                                                        .or_default(),
                                                    snapshot,
                                                )
                                            {
                                                if !assistant_opened {
                                                    assistant_opened = true;
                                                    let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                        message_id: assistant_message_id.clone(),
                                                        role: "assistant".to_string(),
                                                        selection_hint: None,
                                                    }));
                                                }
                                                let _ = tx.send(Ok(AiEvent::PartDelta {
                                                    message_id: assistant_message_id.clone(),
                                                    part_id,
                                                    part_type: "text".to_string(),
                                                    field: "text".to_string(),
                                                    delta,
                                                }));
                                            }
                                        }
                                    }
                                }

                                // 检查 result 事件（标志一轮对话结束）
                                let event_type = value
                                    .get("type")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_lowercase();
                                if event_type == "result" {
                                    if let Some(usage) = value.get("usage") {
                                        last_usage_json = Some(usage.clone());
                                    }
                                    if let Some(snapshot) =
                                        value.get("result").and_then(|v| v.as_str())
                                    {
                                        let part_id = if let Some(existing) =
                                            active_text_part_id.as_ref()
                                        {
                                            existing.clone()
                                        } else {
                                            text_part_seq += 1;
                                            let new_id = format!(
                                                "{}-text-{}",
                                                assistant_message_id, text_part_seq
                                            );
                                            text_part_buffers.entry(new_id.clone()).or_default();
                                            if seen_part_ids.insert(new_id.clone()) {
                                                ordered_part_ids.push(new_id.clone());
                                            }
                                            new_id
                                        };
                                        if let Some(delta) = ClaudeCodeAgent::emit_snapshot_delta(
                                            text_part_buffers.entry(part_id.clone()).or_default(),
                                            snapshot,
                                        ) {
                                            if !assistant_opened {
                                                assistant_opened = true;
                                                let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                    message_id: assistant_message_id.clone(),
                                                    role: "assistant".to_string(),
                                                    selection_hint: None,
                                                }));
                                            }
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: assistant_message_id.clone(),
                                                part_id,
                                                part_type: "text".to_string(),
                                                field: "text".to_string(),
                                                delta,
                                            }));
                                        }
                                    }
                                    break;
                                }
                            }
                            Err(_) => {
                                if !assistant_opened {
                                    assistant_opened = true;
                                    let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                        message_id: assistant_message_id.clone(),
                                        role: "assistant".to_string(),
                                        selection_hint: None,
                                    }));
                                }
                                let part_id = if let Some(existing) = active_text_part_id.as_ref() {
                                    existing.clone()
                                } else {
                                    text_part_seq += 1;
                                    let new_id =
                                        format!("{}-text-{}", assistant_message_id, text_part_seq);
                                    active_text_part_id = Some(new_id.clone());
                                    text_part_buffers.entry(new_id.clone()).or_default();
                                    if seen_part_ids.insert(new_id.clone()) {
                                        ordered_part_ids.push(new_id.clone());
                                    }
                                    new_id
                                };
                                let delta = format!("{}\n", trimmed);
                                if let Some(buffer) = text_part_buffers.get_mut(&part_id) {
                                    buffer.push_str(&delta);
                                }
                                let _ = tx.send(Ok(AiEvent::PartDelta {
                                    message_id: assistant_message_id.clone(),
                                    part_id,
                                    part_type: "text".to_string(),
                                    field: "text".to_string(),
                                    delta,
                                }));
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        // 进程退出
                        if !assistant_opened {
                            let _ = tx.send(Err("Claude process exited unexpectedly".to_string()));
                        }
                        break;
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!("[claude] broadcast lagged by {} messages", n);
                        continue;
                    }
                }
            }

            // 构建助手消息并存入内存
            let mut assistant_parts = Vec::<AiPart>::new();
            let tool_parts_by_id: HashMap<String, ClaudeToolState> = tool_states
                .values()
                .cloned()
                .map(|state| (state.part_id.clone(), state))
                .collect();

            for part_id in &ordered_part_ids {
                if part_id == &reasoning_part_id {
                    if !assistant_reasoning.is_empty() {
                        assistant_parts.push(AiPart {
                            id: reasoning_part_id.clone(),
                            part_type: "reasoning".to_string(),
                            text: Some(assistant_reasoning.clone()),
                            ..Default::default()
                        });
                    }
                    continue;
                }
                if let Some(text) = text_part_buffers.get(part_id) {
                    if !text.trim().is_empty() {
                        assistant_parts.push(AiPart::new_text(part_id.clone(), text.clone()));
                    }
                    continue;
                }
                if let Some(state) = tool_parts_by_id.get(part_id) {
                    assistant_parts.push(state.to_part());
                }
            }

            {
                let mut sessions_guard = sessions.lock().await;
                if let Some(record) = sessions_guard.get_mut(&session_id_owned) {
                    record.updated_at = ClaudeCodeAgent::now_ms();
                    if let Some(real_session_id) = parsed_claude_session_id {
                        record.claude_session_id = Some(real_session_id);
                    }
                    record.selection_hint = history_hint_owned.clone();
                    if let Some(usage_json) = last_usage_json {
                        if let Some(percent) = extract_context_remaining_percent(&usage_json) {
                            record.context_usage = Some(AiSessionContextUsage {
                                context_remaining_percent: Some(percent),
                            });
                        }
                    }
                    if !assistant_parts.is_empty() {
                        record.messages.push(AiMessage {
                            id: assistant_message_id.clone(),
                            role: "assistant".to_string(),
                            created_at: Some(ClaudeCodeAgent::now_ms()),
                            agent: None,
                            model_provider_id: history_hint_owned.model_provider_id,
                            model_id: history_hint_owned.model_id,
                            parts: assistant_parts,
                        });
                    }
                }
            }

            if !assistant_opened {
                let _ = tx.send(Ok(AiEvent::MessageUpdated {
                    message_id: assistant_message_id,
                    role: "assistant".to_string(),
                    selection_hint: None,
                }));
            }
            let _ = tx.send(Ok(AiEvent::Done { stop_reason: None }));

            // 清理 turn 标记
            active_turns.lock().await.remove(&key_owned);

            // 如果进程已死，清理进程句柄
            if !handle_alive.alive.load(Ordering::SeqCst) {
                processes.lock().await.remove(&key_owned);
            }
        });

        Ok(Box::pin(UnboundedReceiverStream::new(rx)))
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        let normalized = Self::normalize_directory(directory);
        let mut sessions = self
            .sessions
            .lock()
            .await
            .values()
            .filter(|record| record.directory == normalized)
            .map(|record| AiSession {
                id: record.id.clone(),
                title: record.title.clone(),
                updated_at: record.updated_at,
            })
            .collect::<Vec<_>>();
        sessions.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        Ok(sessions)
    }

    async fn delete_session(&self, directory: &str, session_id: &str) -> Result<(), String> {
        // 先终止进程
        let key = Self::runtime_key(&Self::normalize_directory(directory), session_id);
        if let Some(handle) = self.processes.lock().await.remove(&key) {
            if let Some(kill_tx) = handle.kill_tx.lock().await.take() {
                let _ = kill_tx.send(()).await;
            }
        }
        self.active_turns.lock().await.remove(&key);
        self.sessions.lock().await.remove(session_id);
        Ok(())
    }

    async fn list_messages(
        &self,
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String> {
        let normalized = Self::normalize_directory(directory);
        let record = self
            .sessions
            .lock()
            .await
            .get(session_id)
            .cloned()
            .ok_or_else(|| format!("Claude session not found: {}", session_id))?;
        if record.directory != normalized {
            return Err(format!(
                "Claude session directory mismatch: session_id={}, expected={}, got={}",
                session_id, record.directory, normalized
            ));
        }
        let mut messages = record.messages;
        if let Some(limit) = limit {
            let limit = limit as usize;
            if messages.len() > limit {
                messages = messages.split_off(messages.len() - limit);
            }
        }
        Ok(messages)
    }

    async fn session_selection_hint(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionSelectionHint>, String> {
        let normalized = Self::normalize_directory(directory);
        let record = self
            .sessions
            .lock()
            .await
            .get(session_id)
            .cloned()
            .ok_or_else(|| format!("Claude session not found: {}", session_id))?;
        if record.directory != normalized {
            return Ok(None);
        }
        if record.selection_hint.agent.is_none()
            && record.selection_hint.model_provider_id.is_none()
            && record.selection_hint.model_id.is_none()
        {
            Ok(None)
        } else {
            Ok(Some(record.selection_hint))
        }
    }

    async fn abort_session(&self, directory: &str, session_id: &str) -> Result<(), String> {
        let key = Self::runtime_key(directory, session_id);
        if let Some(handle) = self.processes.lock().await.remove(&key) {
            if let Some(kill_tx) = handle.kill_tx.lock().await.take() {
                let _ = kill_tx.send(()).await;
            }
        }
        self.active_turns.lock().await.remove(&key);
        Ok(())
    }

    async fn dispose_instance(&self, _directory: &str) -> Result<(), String> {
        Ok(())
    }

    async fn get_session_status(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<AiSessionStatus, String> {
        let key = Self::runtime_key(directory, session_id);
        if self.active_turns.lock().await.contains(&key) {
            Ok(AiSessionStatus::Busy)
        } else {
            Ok(AiSessionStatus::Idle)
        }
    }

    async fn get_session_context_usage(
        &self,
        _directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionContextUsage>, String> {
        Ok(self
            .sessions
            .lock()
            .await
            .get(session_id)
            .and_then(|r| r.context_usage.clone()))
    }

    async fn list_providers(&self, directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        self.ensure_init_metadata(directory);
        let dir_key = Self::normalize_directory(directory);
        let mut models = vec![AiModelInfo {
            id: "default".to_string(),
            name: "Default".to_string(),
            provider_id: "anthropic".to_string(),
            supports_image_input: true,
        }];
        // 如果从 init 事件获取到了当前模型名，将其作为额外选项展示
        if let Some(current_model) = self.model_by_directory.lock().await.get(&dir_key).cloned() {
            if current_model != "default" {
                models.push(AiModelInfo {
                    id: current_model.clone(),
                    name: current_model,
                    provider_id: "anthropic".to_string(),
                    supports_image_input: true,
                });
            }
        }
        // Claude CLI 支持通过别名切换模型
        for (id, name) in [("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")] {
            if !models.iter().any(|m| m.id == id) {
                models.push(AiModelInfo {
                    id: id.to_string(),
                    name: name.to_string(),
                    provider_id: "anthropic".to_string(),
                    supports_image_input: true,
                });
            }
        }
        Ok(vec![AiProviderInfo {
            id: "anthropic".to_string(),
            name: "Anthropic".to_string(),
            models,
        }])
    }

    async fn list_agents(&self, directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        self.ensure_init_metadata(directory);
        let dir_key = Self::normalize_directory(directory);
        if let Some(cached) = self.agents_by_directory.lock().await.get(&dir_key).cloned() {
            if !cached.is_empty() {
                return Ok(cached);
            }
        }
        // fallback：尚未从 init 事件获取到时返回默认值
        Ok(vec![
            AiAgentInfo {
                name: "agent".to_string(),
                description: Some("Claude Code agent mode".to_string()),
                mode: Some("primary".to_string()),
                color: Some("orange".to_string()),
                default_provider_id: Some("anthropic".to_string()),
                default_model_id: Some("default".to_string()),
            },
            AiAgentInfo {
                name: "plan".to_string(),
                description: Some("Claude Code plan mode".to_string()),
                mode: Some("primary".to_string()),
                color: Some("blue".to_string()),
                default_provider_id: Some("anthropic".to_string()),
                default_model_id: Some("default".to_string()),
            },
        ])
    }

    async fn list_slash_commands(
        &self,
        directory: &str,
        _session_id: Option<&str>,
    ) -> Result<Vec<AiSlashCommand>, String> {
        self.ensure_init_metadata(directory);
        // 客户端命令始终可用
        let mut commands = vec![AiSlashCommand {
            name: "new".to_string(),
            description: "新建会话".to_string(),
            action: "client".to_string(),
            input_hint: None,
        }];
        // 追加从 Claude CLI init 事件动态获取的命令
        let dir_key = Self::normalize_directory(directory);
        if let Some(cached) = self.slash_commands_by_directory.lock().await.get(&dir_key) {
            commands.extend(cached.iter().cloned());
        }
        Ok(commands)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_tool_input_adds_path_aliases() {
        let input = serde_json::json!({
            "file_path": "/tmp/demo.txt",
            "limit": 10
        });
        let normalized = ClaudeCodeAgent::normalize_tool_input(input);
        assert_eq!(
            normalized.get("path").and_then(|v| v.as_str()),
            Some("/tmp/demo.txt")
        );
        assert_eq!(
            normalized.get("filePath").and_then(|v| v.as_str()),
            Some("/tmp/demo.txt")
        );
    }

    #[test]
    fn tool_title_for_read_uses_normalized_path() {
        let input = serde_json::json!({
            "file_path": "README.md"
        });
        let normalized = ClaudeCodeAgent::normalize_tool_input(input);
        let title = ClaudeCodeAgent::tool_title("read", &normalized);
        assert_eq!(title.as_deref(), Some("read(README.md)"));
    }

    #[test]
    fn tool_result_file_path_extracts_from_payload() {
        let payload = serde_json::json!({
            "tool_use_result": {
                "file": {
                    "filePath": "/Users/demo/project/src/main.rs"
                }
            }
        });
        let path = ClaudeCodeAgent::tool_result_file_path(&payload);
        assert_eq!(path.as_deref(), Some("/Users/demo/project/src/main.rs"));
    }

    #[test]
    fn read_tool_part_omits_large_output_and_keeps_title() {
        let part = ClaudeToolState {
            part_id: "p-1".to_string(),
            tool_call_id: "c-1".to_string(),
            tool_name: "read".to_string(),
            status: "completed".to_string(),
            input: serde_json::json!({ "path": "README.md" }),
            title: Some("read(README.md)".to_string()),
            output: Some("huge-content".to_string()),
            error: None,
        }
        .to_part();

        let state = part.tool_state.expect("tool_state should exist");
        assert_eq!(
            state.get("title").and_then(|v| v.as_str()),
            Some("read(README.md)")
        );
        assert!(state.get("output").is_none());
    }
}
