use super::context_usage::{extract_context_remaining_percent, AiSessionContextUsage};
use super::session_status::AiSessionStatus;
use super::shared::path_norm::normalize_directory as shared_normalize_directory;
use super::{
    AiAgent, AiAgentInfo, AiAudioPart, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiSession, AiSessionSelectionHint, AiSlashCommand,
};
use async_trait::async_trait;
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::{debug, warn};
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
        if let Some(output) = self.output.as_ref() {
            tool_state["output"] = Value::String(output.clone());
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

pub struct ClaudeCodeAgent {
    sessions: Arc<Mutex<HashMap<String, ClaudeSessionRecord>>>,
    active_aborters: Arc<Mutex<HashMap<String, mpsc::Sender<()>>>>,
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
            active_aborters: Arc::new(Mutex::new(HashMap::new())),
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
                            agents_cache.lock().await.insert(dir_key_owned.clone(), agents);
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
                "",
                "--output-format",
                "stream-json",
                "--verbose",
                "--dangerously-skip-permissions",
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
        let aborters = self.active_aborters.lock().await.clone();
        for (_, tx) in aborters {
            let _ = tx.send(()).await;
        }
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

        let (abort_tx, mut abort_rx) = mpsc::channel::<()>(1);
        self.active_aborters
            .lock()
            .await
            .insert(key.clone(), abort_tx);

        let sessions = self.sessions.clone();
        let active_aborters = self.active_aborters.clone();
        let slash_commands_cache = self.slash_commands_by_directory.clone();
        let agents_cache = self.agents_by_directory.clone();
        let model_cache = self.model_by_directory.clone();
        let directory = normalized_directory.clone();
        let session_id_owned = session_id.to_string();
        let message_owned = message.to_string();
        let model_id = model.as_ref().map(|m| m.model_id.clone());
        let prompt = Self::compose_message(&message_owned, file_refs, image_parts, audio_parts);

        tokio::spawn(async move {
            let assistant_message_id = format!("claude-assistant-{}", Uuid::new_v4());
            let text_part_id = format!("{}-text", assistant_message_id);
            let reasoning_part_id = format!("{}-reasoning", assistant_message_id);
            let mut assistant_opened = false;
            let mut assistant_text = String::new();
            let mut assistant_reasoning = String::new();
            let mut parsed_claude_session_id = resume_session_id.clone();
            let mut tool_states: HashMap<String, ClaudeToolState> = HashMap::new();
            let mut terminated_with_error = false;
            let mut last_usage_json: Option<Value> = None;

            let mut command = Command::new("claude");
            let mut args = vec![
                "--dangerously-skip-permissions".to_string(),
                "-p".to_string(),
                prompt,
                "--output-format".to_string(),
                "stream-json".to_string(),
                "--verbose".to_string(),
            ];
            if let Some(resume) = resume_session_id.as_ref() {
                args.push("--resume".to_string());
                args.push(resume.clone());
            }
            if let Some(model_id) = model_id.as_ref() {
                args.push("--model".to_string());
                args.push(model_id.clone());
            }

            command
                .args(&args)
                .current_dir(&directory)
                .envs(ClaudeCodeAgent::build_extended_env())
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped());

            let mut child = match command.spawn() {
                Ok(child) => child,
                Err(err) => {
                    let _ = tx.send(Err(format!(
                        "Failed to spawn `claude {}`: {}",
                        args.join(" "),
                        err
                    )));
                    active_aborters.lock().await.remove(&key);
                    return;
                }
            };

            let stdout = match child.stdout.take() {
                Some(stdout) => stdout,
                None => {
                    let _ = tx.send(Err("Claude stdout unavailable".to_string()));
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                    active_aborters.lock().await.remove(&key);
                    return;
                }
            };
            let stderr = match child.stderr.take() {
                Some(stderr) => stderr,
                None => {
                    let _ = tx.send(Err("Claude stderr unavailable".to_string()));
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                    active_aborters.lock().await.remove(&key);
                    return;
                }
            };

            let mut stdout_lines = BufReader::new(stdout).lines();
            let mut stderr_lines = BufReader::new(stderr).lines();
            let mut stdout_closed = false;
            let mut stderr_closed = false;
            let mut stderr_tail: VecDeque<String> = VecDeque::new();
            const STDERR_TAIL_MAX: usize = 8;

            while !(stdout_closed && stderr_closed) {
                tokio::select! {
                    _ = abort_rx.recv() => {
                        let _ = child.start_kill();
                        let _ = child.wait().await;
                        let _ = tx.send(Ok(AiEvent::Done { stop_reason: None }));
                        active_aborters.lock().await.remove(&key);
                        return;
                    }
                    line = stdout_lines.next_line(), if !stdout_closed => {
                        match line {
                            Ok(Some(line)) => {
                                let trimmed = line.trim();
                                if trimmed.is_empty() {
                                    continue;
                                }

                                match serde_json::from_str::<Value>(trimmed) {
                                    Ok(value) => {
                                        if let Some(err_msg) = ClaudeCodeAgent::parse_error(&value) {
                                            terminated_with_error = true;
                                            let _ = tx.send(Err(err_msg));
                                            break;
                                        }

                                        if let Some(stream_session_id) = ClaudeCodeAgent::first_string(
                                            &value,
                                            &["session_id", "sessionId"],
                                        ) {
                                            parsed_claude_session_id = Some(stream_session_id);
                                        }

                                        // 从 init 事件中提取斜杠命令并缓存
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
                                                let dir_key = ClaudeCodeAgent::normalize_directory(&directory);
                                                slash_commands_cache.lock().await.insert(dir_key, commands.clone());
                                                let _ = tx.send(Ok(AiEvent::SlashCommandsUpdated {
                                                    session_id: session_id_owned.clone(),
                                                    commands,
                                                }));
                                            }
                                        }

                                        // 从 init 事件中提取 agents 列表并缓存
                                        if let Some(agents_arr) = value.get("agents").and_then(|v| v.as_array()) {
                                            let agents: Vec<AiAgentInfo> = agents_arr
                                                .iter()
                                                .filter_map(|v| v.as_str())
                                                .filter(|s| !s.trim().is_empty())
                                                .map(|name| {
                                                    let lower = name.to_lowercase();
                                                    AiAgentInfo {
                                                        name: lower,
                                                        description: None,
                                                        mode: Some("primary".to_string()),
                                                        color: None,
                                                        default_provider_id: Some("anthropic".to_string()),
                                                        default_model_id: Some("default".to_string()),
                                                    }
                                                })
                                                .collect();
                                            if !agents.is_empty() {
                                                let dir_key = ClaudeCodeAgent::normalize_directory(&directory);
                                                agents_cache.lock().await.insert(dir_key, agents);
                                            }
                                        }

                                        // 从 init 事件中提取当前模型并缓存
                                        if let Some(model_name) = value.get("model").and_then(|v| v.as_str()) {
                                            let trimmed = model_name.trim();
                                            if !trimmed.is_empty() {
                                                let dir_key = ClaudeCodeAgent::normalize_directory(&directory);
                                                model_cache.lock().await.insert(dir_key, trimmed.to_string());
                                            }
                                        }

                                        for block in ClaudeCodeAgent::collect_content_blocks(&value) {
                                            let block_type = block
                                                .get("type")
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("")
                                                .to_lowercase();

                                            if block_type == "tool_use" {
                                                let tool_call_id = ClaudeCodeAgent::first_string(
                                                    block,
                                                    &["id", "tool_use_id", "toolUseId", "call_id", "callId"],
                                                )
                                                .unwrap_or_else(|| Uuid::new_v4().to_string());
                                                let input = block
                                                    .get("input")
                                                    .cloned()
                                                    .or_else(|| block.get("arguments").cloned())
                                                    .unwrap_or_else(|| Value::Object(serde_json::Map::new()));
                                                let raw_name = ClaudeCodeAgent::first_string(
                                                    block,
                                                    &["name", "tool"],
                                                )
                                                .unwrap_or_else(|| "tool".to_string());
                                                let tool_name =
                                                    ClaudeCodeAgent::normalize_tool_name(&raw_name);
                                                let part_id = format!(
                                                    "claude-tool-{}-{}",
                                                    assistant_message_id, tool_call_id
                                                );
                                                let state = ClaudeToolState {
                                                    part_id,
                                                    tool_call_id: tool_call_id.clone(),
                                                    tool_name,
                                                    status: "running".to_string(),
                                                    input,
                                                    output: None,
                                                    error: None,
                                                };
                                                tool_states.insert(tool_call_id.clone(), state.clone());
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
                                                    &["tool_use_id", "toolUseId", "id", "call_id", "callId"],
                                                );
                                                let Some(tool_call_id) = tool_call_id else {
                                                    continue;
                                                };
                                                let output = block
                                                    .get("content")
                                                    .and_then(ClaudeCodeAgent::maybe_join_text)
                                                    .or_else(|| block.get("output").and_then(ClaudeCodeAgent::maybe_join_text))
                                                    .or_else(|| block.get("text").and_then(|v| v.as_str()).map(|s| s.to_string()));
                                                let is_error = block
                                                    .get("is_error")
                                                    .and_then(|v| v.as_bool())
                                                    .unwrap_or(false);
                                                let entry = tool_states.entry(tool_call_id.clone()).or_insert_with(|| ClaudeToolState {
                                                    part_id: format!(
                                                        "claude-tool-{}-{}",
                                                        assistant_message_id, tool_call_id
                                                    ),
                                                    tool_call_id: tool_call_id.clone(),
                                                    tool_name: "tool".to_string(),
                                                    status: "running".to_string(),
                                                    input: Value::Object(serde_json::Map::new()),
                                                    output: None,
                                                    error: None,
                                                });
                                                if let Some(output) = output {
                                                    entry.output = Some(output);
                                                }
                                                if is_error {
                                                    entry.status = "error".to_string();
                                                    entry.error = entry.output.clone();
                                                } else {
                                                    entry.status = "completed".to_string();
                                                }
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

                                            if block_type.contains("thinking") || block_type.contains("reasoning") {
                                                if let Some(text) = block.get("text").and_then(|v| v.as_str()) {
                                                    if !assistant_opened {
                                                        assistant_opened = true;
                                                        let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                            message_id: assistant_message_id.clone(),
                                                            role: "assistant".to_string(),
                                                            selection_hint: None,
                                                        }));
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
                                                    assistant_text.push_str(text);
                                                    let _ = tx.send(Ok(AiEvent::PartDelta {
                                                        message_id: assistant_message_id.clone(),
                                                        part_id: text_part_id.clone(),
                                                        part_type: "text".to_string(),
                                                        field: "text".to_string(),
                                                        delta: text.to_string(),
                                                    }));
                                                }
                                                continue;
                                            }

                                            if block_type == "text" {
                                                if let Some(snapshot) = block.get("text").and_then(|v| v.as_str()) {
                                                    if let Some(delta) =
                                                        ClaudeCodeAgent::emit_snapshot_delta(&mut assistant_text, snapshot)
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
                                                            part_id: text_part_id.clone(),
                                                            part_type: "text".to_string(),
                                                            field: "text".to_string(),
                                                            delta,
                                                        }));
                                                    }
                                                }
                                            }
                                        }

                                        let event_type = value
                                            .get("type")
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("")
                                            .to_lowercase();
                                        if event_type == "result" {
                                            // 提取 usage 信息用于 context usage 上报
                                            if let Some(usage) = value.get("usage") {
                                                last_usage_json = Some(usage.clone());
                                            }
                                            if let Some(snapshot) = value.get("result").and_then(|v| v.as_str()) {
                                                if let Some(delta) =
                                                    ClaudeCodeAgent::emit_snapshot_delta(&mut assistant_text, snapshot)
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
                                                        part_id: text_part_id.clone(),
                                                        part_type: "text".to_string(),
                                                        field: "text".to_string(),
                                                        delta,
                                                    }));
                                                }
                                            }
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
                                        assistant_text.push_str(trimmed);
                                        assistant_text.push('\n');
                                        let _ = tx.send(Ok(AiEvent::PartDelta {
                                            message_id: assistant_message_id.clone(),
                                            part_id: text_part_id.clone(),
                                            part_type: "text".to_string(),
                                            field: "text".to_string(),
                                            delta: format!("{}\n", trimmed),
                                        }));
                                    }
                                }
                            }
                            Ok(None) => {
                                stdout_closed = true;
                            }
                            Err(err) => {
                                terminated_with_error = true;
                                let _ = tx.send(Err(format!("Claude stdout read failed: {}", err)));
                                break;
                            }
                        }
                    }
                    line = stderr_lines.next_line(), if !stderr_closed => {
                        match line {
                            Ok(Some(line)) => {
                                let trimmed = line.trim();
                                if !trimmed.is_empty() {
                                    debug!("[claude stderr] {}", trimmed);
                                    let snippet = if trimmed.chars().count() > 300 {
                                        format!("{}...", trimmed.chars().take(300).collect::<String>())
                                    } else {
                                        trimmed.to_string()
                                    };
                                    if stderr_tail.len() >= STDERR_TAIL_MAX {
                                        stderr_tail.pop_front();
                                    }
                                    stderr_tail.push_back(snippet);
                                }
                            }
                            Ok(None) => {
                                stderr_closed = true;
                            }
                            Err(err) => {
                                terminated_with_error = true;
                                let _ = tx.send(Err(format!("Claude stderr read failed: {}", err)));
                                break;
                            }
                        }
                    }
                }
            }

            // 先构建助手消息并存入内存，再发送 Done，
            // 避免客户端收到 Done 后立即 requestAISessionMessages 时助手消息尚未入库。
            let mut assistant_parts = Vec::<AiPart>::new();
            if !assistant_reasoning.is_empty() {
                assistant_parts.push(AiPart {
                    id: reasoning_part_id,
                    part_type: "reasoning".to_string(),
                    text: Some(assistant_reasoning),
                    ..Default::default()
                });
            }
            if !assistant_text.trim().is_empty() {
                assistant_parts.push(AiPart::new_text(text_part_id, assistant_text));
            }
            let mut tool_parts = tool_states.values().cloned().collect::<Vec<_>>();
            tool_parts.sort_by(|a, b| a.part_id.cmp(&b.part_id));
            for state in tool_parts {
                assistant_parts.push(state.to_part());
            }

            {
                let mut sessions_guard = sessions.lock().await;
                if let Some(record) = sessions_guard.get_mut(&session_id_owned) {
                    record.updated_at = ClaudeCodeAgent::now_ms();
                    if let Some(real_session_id) = parsed_claude_session_id {
                        record.claude_session_id = Some(real_session_id);
                    }
                    record.selection_hint = history_hint.clone();
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
                            model_provider_id: history_hint.model_provider_id.clone(),
                            model_id: history_hint.model_id.clone(),
                            parts: assistant_parts,
                        });
                    }
                }
            }

            if !terminated_with_error {
                match child.wait().await {
                    Ok(status) if status.success() => {
                        if !assistant_opened {
                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                message_id: assistant_message_id,
                                role: "assistant".to_string(),
                                selection_hint: None,
                            }));
                        }
                        let _ = tx.send(Ok(AiEvent::Done { stop_reason: None }));
                    }
                    Ok(status) => {
                        if stderr_tail.is_empty() {
                            let _ = tx.send(Err(format!("Claude exited with status: {}", status)));
                        } else {
                            let stderr_summary =
                                stderr_tail.into_iter().collect::<Vec<_>>().join(" | ");
                            let _ = tx.send(Err(format!(
                                "Claude exited with status: {}. stderr: {}",
                                status, stderr_summary
                            )));
                        }
                    }
                    Err(err) => {
                        let _ = tx.send(Err(format!("Claude wait failed: {}", err)));
                    }
                }
            }

            active_aborters.lock().await.remove(&key);
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
        let normalized = Self::normalize_directory(directory);
        let key = Self::runtime_key(&normalized, session_id);
        if let Some(aborter) = self.active_aborters.lock().await.remove(&key) {
            let _ = aborter.send(()).await;
        }
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
        if let Some(aborter) = self.active_aborters.lock().await.remove(&key) {
            let _ = aborter.send(()).await;
        }
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
        if self.active_aborters.lock().await.contains_key(&key) {
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
        for (id, name) in [
            ("sonnet", "Sonnet"),
            ("opus", "Opus"),
            ("haiku", "Haiku"),
        ] {
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
