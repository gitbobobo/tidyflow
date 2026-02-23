use crate::ai::context_usage::{extract_context_remaining_percent, AiSessionContextUsage};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;
use tokio_stream::Stream;

fn hex_upper(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        10..=15 => (b'A' + (n - 10)) as char,
        _ => '0',
    }
}

// 与 JS encodeURIComponent 对齐：
// - 保留：A-Z a-z 0-9 - _ . ! ~ * ' ( )
// - 其他 byte（含 UTF-8 非 ASCII）全部按 %XX（大写）编码
fn encode_uri_component_like_js(input: &str) -> String {
    let bytes = input.as_bytes();
    // 常见路径基本都会含 `/`，这里直接按最坏情况预估（%XX 会变长 3 倍）。
    let mut out = String::with_capacity(bytes.len().saturating_mul(3));
    for &b in bytes {
        match b {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'_'
            | b'.'
            | b'!'
            | b'~'
            | b'*'
            | b'\''
            | b'('
            | b')' => out.push(b as char),
            _ => {
                out.push('%');
                out.push(hex_upper(b >> 4));
                out.push(hex_upper(b & 0x0F));
            }
        }
    }
    out
}

fn from_hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

// 仅用于把服务端可能回传的已编码 directory 解码成原始路径，便于与本地 worktree_path 对齐。
// 解码失败时返回 None，调用方应回退使用原字符串。
fn percent_decode_to_utf8(input: &str) -> Option<String> {
    if !input.as_bytes().contains(&b'%') {
        return None;
    }

    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());

    let mut i = 0usize;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let hi = from_hex(bytes[i + 1])?;
            let lo = from_hex(bytes[i + 2])?;
            out.push((hi << 4) | lo);
            i += 3;
            continue;
        }
        out.push(b);
        i += 1;
    }

    String::from_utf8(out).ok()
}

static IMAGE_FILE_SEQ: AtomicU64 = AtomicU64::new(0);

fn safe_file_stem(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    let trimmed = out.trim_matches('_');
    if trimmed.is_empty() {
        "image".to_string()
    } else {
        trimmed.to_string()
    }
}

fn infer_image_extension(filename: &str, mime: &str) -> &'static str {
    if let Some(ext) = Path::new(filename).extension().and_then(|s| s.to_str()) {
        if !ext.is_empty() && ext.len() <= 8 && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
            // 常见大小写统一为小写，便于后续排查。
            match ext.to_ascii_lowercase().as_str() {
                "jpeg" | "jpg" => return "jpg",
                "png" => return "png",
                "webp" => return "webp",
                "gif" => return "gif",
                "heic" => return "heic",
                "heif" => return "heif",
                _ => {}
            }
        }
    }

    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "image/heic" => "heic",
        "image/heif" => "heif",
        _ => "bin",
    }
}

fn image_part_url_for_opencode(image: &super::AiImagePart) -> String {
    // 优先落临时文件并传 file://，避免工具链对超长 data URL 解析失败。
    let ext = {
        let inferred = infer_image_extension(&image.filename, &image.mime);
        if inferred.is_empty() {
            "bin"
        } else {
            inferred
        }
    };
    let stem = Path::new(&image.filename)
        .file_stem()
        .and_then(|s| s.to_str())
        .map(safe_file_stem)
        .unwrap_or_else(|| "image".to_string());
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    let seq = IMAGE_FILE_SEQ.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join("tidyflow-ai-images");
    let file_name = format!("{}-{}-{}.{}", stem, ts, seq, ext);
    let path = dir.join(file_name);

    if std::fs::create_dir_all(&dir).is_ok() && std::fs::write(&path, &image.data).is_ok() {
        if let Ok(url) = reqwest::Url::from_file_path(&path) {
            return url.to_string();
        }
    }

    // 兜底：保持旧行为，避免文件写入失败时消息直接丢失。
    let encoded = BASE64.encode(&image.data);
    format!("data:{};base64,{}", image.mime, encoded)
}

#[derive(Debug, Error)]
pub enum OpenCodeError {
    #[error("HTTP error: {0}")]
    HttpError(#[from] reqwest::Error),
    #[error("JSON error: {0}")]
    JsonError(#[from] serde_json::Error),
    #[error("Server error: {status} - {message}")]
    ServerError { status: u16, message: String },
    #[error("SSE error: {0}")]
    SseError(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionTime {
    #[serde(default)]
    pub created: i64,
    #[serde(default)]
    pub updated: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionResponse {
    pub id: String,
    pub title: String,
    /// OpenCode 新版会把目录放在 session 上，用于区分不同工作目录的会话。
    #[serde(default)]
    pub directory: Option<String>,
    /// 新版时间字段：{ time: { created, updated } }
    #[serde(default)]
    pub time: Option<SessionTime>,
    /// 旧版兼容字段（若存在则使用）；新版通常不返回 updatedAt。
    #[serde(default, alias = "updatedAt", alias = "updated_at")]
    pub updated_at: i64,
    /// 透传未知字段，便于后续从真实接口数据里提取会话级配置（model/agent）。
    #[serde(flatten, default)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

impl SessionResponse {
    fn effective_updated_at(&self) -> i64 {
        if let Some(t) = &self.time {
            if t.updated > 0 {
                return t.updated;
            }
        }
        self.updated_at
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSessionRequest {
    pub title: String,
}

/// OpenCode Bus 事件（SSE `/event` 端点返回的格式）
#[derive(Debug, Clone, Deserialize)]
pub struct BusEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    #[serde(default)]
    pub properties: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionListResponse {
    pub sessions: Vec<SessionResponse>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SessionStatusItem {
    #[serde(rename = "type")]
    pub status_type: String,
    #[serde(flatten, default)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

impl SessionStatusItem {
    pub fn context_remaining_percent(&self) -> Option<f64> {
        let value = serde_json::json!({
            "type": self.status_type,
            "extra": self.extra,
        });
        extract_context_remaining_percent(&value)
    }
}

pub struct OpenCodeClient {
    base_url: String,
    client: Client,
}

impl OpenCodeClient {
    fn opencode_model_payload(model: &super::AiModelSelection) -> serde_json::Value {
        serde_json::json!({
            "providerID": model.provider_id,
            "modelID": model.model_id,
        })
    }

    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            client: Client::new(),
        }
    }

    pub fn from_manager(manager: &Arc<crate::ai::OpenCodeManager>) -> Self {
        Self::new(manager.get_base_url())
    }

    fn with_directory(
        &self,
        builder: reqwest::RequestBuilder,
        directory: &str,
    ) -> reqwest::RequestBuilder {
        // OpenCode Desktop 会把路径通过 encodeURIComponent 写入 header；
        // 这里保持一致，避免包含中文/空格等字符时 header 无法构造，或服务端路由不一致。
        let encoded = encode_uri_component_like_js(directory);
        builder.header("x-opencode-directory", encoded)
    }

    pub async fn create_session(
        &self,
        directory: &str,
        title: &str,
    ) -> Result<SessionResponse, OpenCodeError> {
        let url = format!("{}/session", self.base_url);
        let request = CreateSessionRequest {
            title: title.to_string(),
        };

        let response = self
            .with_directory(self.client.post(&url), directory)
            .json(&request)
            .send()
            .await?;

        if response.status().is_success() {
            let session: SessionResponse = response.json().await?;
            Ok(session)
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 异步发送消息（POST prompt_async，立即返回 204）
    /// 实际响应通过 SSE `/global/event` 端点流式获取
    pub async fn send_message_async(
        &self,
        directory: &str,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<super::AiImagePart>>,
        model: Option<super::AiModelSelection>,
        agent: Option<String>,
    ) -> Result<(), OpenCodeError> {
        let url = format!("{}/session/{}/prompt_async", self.base_url, session_id);

        let mut parts = vec![serde_json::json!({
            "type": "text",
            "text": message,
        })];

        if let Some(ref refs) = file_refs {
            for r in refs {
                // 尽量使用绝对路径，避免后端对相对路径的解释不一致。
                let abs = if r.starts_with('/') {
                    r.to_string()
                } else {
                    format!("{}/{}", directory.trim_end_matches('/'), r)
                };
                parts.push(serde_json::json!({
                    "type": "file",
                    "url": format!("file://{}", abs),
                    "filename": r,
                    "mime": "text/plain",
                }));
            }
        }

        // 图片附件优先落临时文件走 file://，失败时回退 data URL。
        if let Some(ref images) = image_parts {
            for img in images {
                let url = image_part_url_for_opencode(img);
                parts.push(serde_json::json!({
                    "type": "file",
                    "url": url,
                    "filename": img.filename,
                    "mime": img.mime,
                }));
            }
        }

        let mut body = serde_json::json!({ "parts": parts });

        // OpenCode v2: model 需要对象 { providerID, modelID }。
        if let Some(ref m) = model {
            body["model"] = Self::opencode_model_payload(m);
        }

        // Agent 选择
        if let Some(ref a) = agent {
            body["agent"] = serde_json::json!(a);
        }

        let response = self
            .with_directory(self.client.post(&url), directory)
            .json(&body)
            .send()
            .await?;

        let status = response.status().as_u16();
        if status == 204 || response.status().is_success() {
            Ok(())
        } else {
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 异步发送斜杠命令（POST /session/{id}/command，立即返回）
    pub async fn send_command_async(
        &self,
        directory: &str,
        session_id: &str,
        command: &str,
        arguments: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<super::AiImagePart>>,
        model: Option<super::AiModelSelection>,
        agent: Option<String>,
    ) -> Result<(), OpenCodeError> {
        let url = format!("{}/session/{}/command", self.base_url, session_id);

        let mut body = serde_json::json!({
            "command": command,
            "arguments": arguments,
        });

        let mut parts: Vec<serde_json::Value> = Vec::new();

        if let Some(ref refs) = file_refs {
            for r in refs {
                let abs = if r.starts_with('/') {
                    r.to_string()
                } else {
                    format!("{}/{}", directory.trim_end_matches('/'), r)
                };
                parts.push(serde_json::json!({
                    "type": "file",
                    "url": format!("file://{}", abs),
                    "filename": r,
                    "mime": "text/plain",
                }));
            }
        }

        if let Some(ref images) = image_parts {
            for img in images {
                let url = image_part_url_for_opencode(img);
                parts.push(serde_json::json!({
                    "type": "file",
                    "url": url,
                    "filename": img.filename,
                    "mime": img.mime,
                }));
            }
        }

        if !parts.is_empty() {
            body["parts"] = serde_json::Value::Array(parts);
        }

        if let Some(ref m) = model {
            body["model"] = serde_json::json!(m.model_id);
        }

        if let Some(ref a) = agent {
            body["agent"] = serde_json::json!(a);
        }

        let response = self
            .with_directory(self.client.post(&url), directory)
            .json(&body)
            .send()
            .await?;

        let status = response.status().as_u16();
        if status == 204 || response.status().is_success() {
            Ok(())
        } else {
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 订阅全局 SSE 事件流（GET /global/event）
    pub async fn subscribe_global_events(
        &self,
    ) -> Result<impl Stream<Item = Result<GlobalBusEventEnvelope, OpenCodeError>>, OpenCodeError>
    {
        let url = format!("{}/global/event", self.base_url);

        let response = self.client.get(&url).send().await?;

        if !response.status().is_success() {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            return Err(OpenCodeError::ServerError { status, message });
        }

        let stream = SseJsonStream::new(response.bytes_stream());
        let mapped = tokio_stream::StreamExt::filter_map(stream, move |item| match item {
            Ok(v) => {
                // 全局事件常见格式：{ directory, payload:{type,properties} }
                // 也可能直接返回 payload（此时 directory 可能在顶层或 properties 内）
                let directory_raw = v
                    .get("directory")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
                    .or_else(|| {
                        v.get("properties")
                            .and_then(|p| p.get("directory"))
                            .and_then(|x| x.as_str())
                            .map(|s| s.to_string())
                    });
                let directory = directory_raw
                    .as_deref()
                    .and_then(percent_decode_to_utf8)
                    .or(directory_raw);

                let payload_value = v.get("payload").cloned().unwrap_or(v);
                match serde_json::from_value::<BusEvent>(payload_value) {
                    Ok(payload) => Some(Ok(GlobalBusEventEnvelope { directory, payload })),
                    Err(e) => Some(Err(OpenCodeError::JsonError(e))),
                }
            }
            Err(e) => Some(Err(e)),
        });
        Ok(mapped)
    }

    pub async fn list_sessions(
        &self,
        directory: &str,
    ) -> Result<Vec<SessionResponse>, OpenCodeError> {
        let url = format!("{}/session?roots=true", self.base_url);

        let response = self
            .with_directory(self.client.get(&url), directory)
            .send()
            .await?;

        if response.status().is_success() {
            // OpenCode 返回数组格式，兼容两种：直接数组 或 {sessions: [...]}
            let body = response.text().await?;
            if let Ok(sessions) = serde_json::from_str::<Vec<SessionResponse>>(&body) {
                return Ok(sessions);
            }
            if let Ok(list) = serde_json::from_str::<SessionListResponse>(&body) {
                return Ok(list.sessions);
            }
            Err(OpenCodeError::SseError(format!(
                "Failed to parse session list: {}",
                &body[..body.len().min(200)]
            )))
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 获取会话状态（GET /session/status）
    ///
    /// OpenCode 返回 Record<sessionID, {type: "idle"|"busy"|"retry"|...}>
    pub async fn get_session_statuses(
        &self,
        directory: &str,
    ) -> Result<std::collections::HashMap<String, SessionStatusItem>, OpenCodeError> {
        let url = format!("{}/session/status", self.base_url);
        let response = self
            .with_directory(self.client.get(&url), directory)
            .send()
            .await?;

        if response.status().is_success() {
            let map: std::collections::HashMap<String, SessionStatusItem> = response.json().await?;
            Ok(map)
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    pub async fn get_session(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<SessionResponse, OpenCodeError> {
        let encoded_dir = encode_uri_component_like_js(directory);
        let url = format!(
            "{}/session/{}?directory={}",
            self.base_url, session_id, encoded_dir
        );

        let response = self
            .with_directory(self.client.get(&url), directory)
            .send()
            .await?;

        if response.status().is_success() {
            let session: SessionResponse = response.json().await?;
            Ok(session)
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    pub async fn delete_session(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<(), OpenCodeError> {
        let url = format!("{}/session/{}", self.base_url, session_id);

        let response = self
            .with_directory(self.client.delete(&url), directory)
            .send()
            .await?;

        if response.status().as_u16() == 204 || response.status().is_success() {
            Ok(())
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    pub async fn abort_session(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<(), OpenCodeError> {
        let encoded_dir = encode_uri_component_like_js(directory);
        let url = format!(
            "{}/session/{}/abort?directory={}",
            self.base_url, session_id, encoded_dir
        );
        let response = self
            .with_directory(self.client.post(&url), directory)
            .send()
            .await?;
        if response.status().is_success() {
            // OpenCode SDK 定义返回 200 + boolean；兼容旧版空响应。
            let body = response.text().await.unwrap_or_default();
            let trimmed = body.trim();
            if trimmed.is_empty() {
                return Ok(());
            }
            if let Ok(flag) = serde_json::from_str::<bool>(trimmed) {
                if flag {
                    return Ok(());
                }
                return Err(OpenCodeError::ServerError {
                    status: 200,
                    message: "Abort returned false".to_string(),
                });
            }
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
                if value.get("data").and_then(|v| v.as_bool()).unwrap_or(false)
                    || value.get("ok").and_then(|v| v.as_bool()).unwrap_or(false)
                {
                    return Ok(());
                }
            }
            Ok(())
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    pub async fn dispose_instance(&self, directory: &str) -> Result<(), OpenCodeError> {
        let url = format!("{}/instance/dispose", self.base_url);
        let response = self
            .with_directory(self.client.post(&url), directory)
            .send()
            .await?;
        if response.status().is_success() {
            Ok(())
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    pub async fn list_messages(
        &self,
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<MessageEnvelope>, OpenCodeError> {
        let mut url = format!("{}/session/{}/message", self.base_url, session_id);
        if let Some(l) = limit {
            url = format!("{}?limit={}", url, l);
        }
        let response = self
            .with_directory(self.client.get(&url), directory)
            .send()
            .await?;

        if response.status().is_success() {
            let body = response.text().await?;
            let messages: Vec<MessageEnvelope> = serde_json::from_str(&body)?;
            Ok(messages)
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 获取 provider 列表（GET /provider）
    /// 优先返回 connected 列表（已配置 API Key 的），回退到 all
    pub async fn list_providers(
        &self,
        directory: &str,
    ) -> Result<Vec<ProviderResponse>, OpenCodeError> {
        let url = format!("{}/provider", self.base_url);
        let response = self
            .with_directory(self.client.get(&url), directory)
            .send()
            .await?;

        if response.status().is_success() {
            let body = response.text().await?;
            if let Ok(wrapper) = serde_json::from_str::<serde_json::Value>(&body) {
                // 提取 connected ID 列表（若存在）
                let connected_ids: Option<std::collections::HashSet<String>> = wrapper
                    .get("connected")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(|s| s.to_string()))
                            .collect()
                    });

                // 从 all 数组解析完整 provider 对象
                let all_providers: Vec<ProviderResponse> = wrapper
                    .get("all")
                    .and_then(|v| v.as_array())
                    .or_else(|| wrapper.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| serde_json::from_value(v.clone()).ok())
                            .collect()
                    })
                    .unwrap_or_default();

                // 若有 connected 列表则过滤，否则返回全部
                if let Some(ids) = connected_ids {
                    return Ok(all_providers
                        .into_iter()
                        .filter(|p| ids.contains(&p.id))
                        .collect());
                }
                return Ok(all_providers);
            }
            Ok(vec![])
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 获取 agent 列表（GET /agent）
    pub async fn list_agents(&self, directory: &str) -> Result<Vec<AgentResponse>, OpenCodeError> {
        let url = format!("{}/agent", self.base_url);
        let response = self
            .with_directory(self.client.get(&url), directory)
            .send()
            .await?;

        if response.status().is_success() {
            let body = response.text().await?;
            // 兼容数组或 { agents: [...] } 或 Record<name, agent>
            if let Ok(agents) = serde_json::from_str::<Vec<AgentResponse>>(&body) {
                return Ok(agents);
            }
            if let Ok(wrapper) = serde_json::from_str::<serde_json::Value>(&body) {
                if let Some(arr) = wrapper.get("agents").and_then(|v| v.as_array()) {
                    let agents: Vec<AgentResponse> = arr
                        .iter()
                        .filter_map(|v| serde_json::from_value(v.clone()).ok())
                        .collect();
                    return Ok(agents);
                }
                if let Some(obj) = wrapper.as_object() {
                    let agents: Vec<AgentResponse> = obj
                        .iter()
                        .filter_map(|(key, v)| {
                            let mut agent: AgentResponse =
                                serde_json::from_value(v.clone()).ok()?;
                            if agent.name.is_empty() {
                                agent.name = key.clone();
                            }
                            Some(agent)
                        })
                        .collect();
                    if !agents.is_empty() {
                        return Ok(agents);
                    }
                }
            }
            Ok(vec![])
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 获取命令列表（GET /command）
    pub async fn list_commands(
        &self,
        directory: &str,
    ) -> Result<Vec<CommandResponse>, OpenCodeError> {
        let url = format!("{}/command", self.base_url);
        let response = self
            .with_directory(self.client.get(&url), directory)
            .send()
            .await?;

        if response.status().is_success() {
            let body = response.text().await?;
            // OpenCode 返回数组格式；解析失败时降级为空，避免影响聊天主链路。
            match serde_json::from_str::<Vec<CommandResponse>>(&body) {
                Ok(items) => Ok(items),
                Err(_) => Ok(vec![]),
            }
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 回复 question 请求（POST /question/{id}/reply）
    pub async fn reply_question(
        &self,
        directory: &str,
        request_id: &str,
        answers: Vec<Vec<String>>,
    ) -> Result<(), OpenCodeError> {
        let url = format!("{}/question/{}/reply", self.base_url, request_id);
        let body = serde_json::json!({ "answers": answers });
        let response = self
            .with_directory(self.client.post(&url), directory)
            .json(&body)
            .send()
            .await?;

        if response.status().is_success() {
            Ok(())
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 拒绝 question 请求（POST /question/{id}/reject）
    pub async fn reject_question(
        &self,
        directory: &str,
        request_id: &str,
    ) -> Result<(), OpenCodeError> {
        let url = format!("{}/question/{}/reject", self.base_url, request_id);
        let response = self
            .with_directory(self.client.post(&url), directory)
            .send()
            .await?;

        if response.status().is_success() {
            Ok(())
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct GlobalBusEventEnvelope {
    #[serde(default)]
    pub directory: Option<String>,
    pub payload: BusEvent,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProviderResponse {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// models 可能是数组或 Record<id, model>
    #[serde(default)]
    pub models: serde_json::Value,
}

impl ProviderResponse {
    /// 将 models（可能是 dict 或 array）统一转为 Vec
    pub fn models_vec(&self) -> Vec<ProviderModelResponse> {
        if let Some(obj) = self.models.as_object() {
            obj.values()
                .filter_map(|v| serde_json::from_value(v.clone()).ok())
                .collect()
        } else if let Some(arr) = self.models.as_array() {
            arr.iter()
                .filter_map(|v| serde_json::from_value(v.clone()).ok())
                .collect()
        } else {
            vec![]
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProviderModelResponse {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "providerID")]
    pub provider_id: String,
    /// 仅展示 active 模型
    #[serde(default)]
    pub status: Option<String>,
    /// OpenCode Provider.Model.capabilities（新协议）
    #[serde(default)]
    pub capabilities: Option<ProviderModelCapabilitiesResponse>,
    /// models.dev modalities（旧字段兜底）
    #[serde(default)]
    pub modalities: Option<ProviderModelModalitiesResponse>,
    /// 模型限制信息（例如 limit.context）
    #[serde(default)]
    pub limit: Option<serde_json::Value>,
}

impl ProviderModelResponse {
    pub fn supports_image_input(&self) -> bool {
        if let Some(cap) = &self.capabilities {
            if cap.input.image || cap.attachment {
                return true;
            }
        }
        if let Some(modalities) = &self.modalities {
            return modalities
                .input
                .iter()
                .any(|m| m.eq_ignore_ascii_case("image"));
        }
        false
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProviderModelCapabilitiesResponse {
    #[serde(default)]
    pub attachment: bool,
    #[serde(default)]
    pub input: ProviderModelInputCapabilitiesResponse,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProviderModelInputCapabilitiesResponse {
    #[serde(default)]
    pub image: bool,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProviderModelModalitiesResponse {
    #[serde(default)]
    pub input: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AgentResponse {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub hidden: Option<bool>,
    /// agent 默认模型 { providerID, modelID }
    #[serde(default)]
    pub model: Option<AgentDefaultModel>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CommandResponse {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AgentDefaultModel {
    #[serde(default, rename = "providerID")]
    pub provider_id: String,
    #[serde(default, rename = "modelID")]
    pub model_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MessageEnvelope {
    pub info: MessageInfo,
    #[serde(default)]
    pub parts: Vec<PartEnvelope>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MessageInfo {
    pub id: String,
    #[serde(default)]
    pub role: String,
    #[serde(rename = "createdAt", default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default, rename = "providerID")]
    pub provider_id: Option<String>,
    #[serde(default, rename = "modelID")]
    pub model_id: Option<String>,
    #[serde(default)]
    pub model: Option<MessageModelSelection>,
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct MessageModelSelection {
    #[serde(default, rename = "providerID")]
    pub provider_id: Option<String>,
    #[serde(default, rename = "modelID")]
    pub model_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PartEnvelope {
    pub id: String,
    #[serde(rename = "type")]
    pub part_type: String,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub mime: Option<String>,
    #[serde(default)]
    pub filename: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub synthetic: Option<bool>,
    #[serde(default)]
    pub ignored: Option<bool>,
    #[serde(default)]
    pub source: Option<serde_json::Value>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub tool: Option<String>,
    #[serde(rename = "callID", default)]
    pub call_id: Option<String>,
    #[serde(default)]
    pub state: Option<serde_json::Value>,
    #[serde(default)]
    pub metadata: Option<serde_json::Value>,
}

use std::pin::Pin;
use std::task::{Context, Poll};

struct SseJsonStream {
    buffer: String,
    inner: Pin<
        Box<dyn tokio_stream::Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send + Unpin>,
    >,
    /// 已解析但尚未 yield 的事件队列
    pending: std::collections::VecDeque<Result<serde_json::Value, OpenCodeError>>,
}

impl SseJsonStream {
    fn new(
        bytes: impl tokio_stream::Stream<Item = Result<bytes::Bytes, reqwest::Error>>
            + Send
            + Unpin
            + 'static,
    ) -> Self {
        Self {
            buffer: String::new(),
            inner: Box::pin(bytes),
            pending: std::collections::VecDeque::new(),
        }
    }

    /// 从 buffer 中提取完整的 SSE 事件（以空行分隔），解析 data 字段
    fn parse_buffer(&mut self) {
        // SSE 事件以 "\n\n" 分隔
        while let Some(pos) = self.buffer.find("\n\n") {
            let event_block = self.buffer[..pos].to_string();
            self.buffer = self.buffer[pos + 2..].to_string();

            // 提取 data: 行并拼接（SSE 规范允许多行 data）
            let mut data = String::new();
            for line in event_block.lines() {
                if let Some(d) = line.strip_prefix("data:") {
                    if !data.is_empty() {
                        data.push('\n');
                    }
                    data.push_str(d.trim_start());
                }
            }

            if data.is_empty() {
                continue;
            }

            match serde_json::from_str::<serde_json::Value>(&data) {
                Ok(event) => self.pending.push_back(Ok(event)),
                Err(e) => {
                    self.pending.push_back(Err(OpenCodeError::SseError(format!(
                        "Failed to parse SSE event: {} (data: {})",
                        e,
                        &data[..data.len().min(200)]
                    ))));
                }
            }
        }
    }
}

impl tokio_stream::Stream for SseJsonStream {
    type Item = Result<serde_json::Value, OpenCodeError>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();

        // 先返回已解析的事件
        if let Some(event) = this.pending.pop_front() {
            return Poll::Ready(Some(event));
        }

        // 从内部字节流拉取数据
        match Pin::new(&mut this.inner).poll_next(cx) {
            Poll::Ready(Some(Ok(bytes))) => {
                if let Ok(text) = std::str::from_utf8(&bytes) {
                    this.buffer.push_str(text);
                }
                this.parse_buffer();

                if let Some(event) = this.pending.pop_front() {
                    Poll::Ready(Some(event))
                } else {
                    // 数据不完整，继续等待
                    cx.waker().wake_by_ref();
                    Poll::Pending
                }
            }
            Poll::Ready(Some(Err(e))) => Poll::Ready(Some(Err(OpenCodeError::HttpError(e)))),
            Poll::Ready(None) => {
                // 流结束，处理 buffer 中剩余数据
                if !this.buffer.trim().is_empty() {
                    this.buffer.push_str("\n\n");
                    this.parse_buffer();
                }
                if let Some(event) = this.pending.pop_front() {
                    Poll::Ready(Some(event))
                } else {
                    Poll::Ready(None)
                }
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

// ============================================================================
// OpenCodeAgent: 实现通用 AiAgent trait（单 serve + directory 路由）
// ============================================================================

use super::event_hub::OpenCodeEventHub;
use super::session_status::AiSessionStatus;
use super::{
    AiAgent, AiAgentInfo, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiSession, AiSlashCommand, OpenCodeManager,
};
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::{Arc as StdArc, Mutex as StdMutex};

/// OpenCode 后端的 AiAgent 实现
///
/// 封装 OpenCodeManager（进程管理）+ OpenCodeClient（HTTP 通信），
/// 将 OpenCode 特有的 SSE 事件转换为通用 AiEvent。
pub struct OpenCodeAgent {
    manager: Arc<OpenCodeManager>,
    hub: Arc<OpenCodeEventHub>,
}

impl OpenCodeAgent {
    pub fn new(manager: Arc<OpenCodeManager>) -> Self {
        let hub = Arc::new(OpenCodeEventHub::new(manager.clone()));
        Self { manager, hub }
    }

    async fn verify_session_directory(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let session = client
            .get_session(directory, session_id)
            .await
            .map_err(|e| format!("Failed to fetch session info: {}", e))?;

        let expected = directory.trim_end_matches('/');
        let actual = session
            .directory
            .as_deref()
            .unwrap_or("")
            .trim_end_matches('/');

        if actual.is_empty() {
            return Err(format!(
                "Session '{}' missing directory; cannot verify workspace isolation",
                session_id
            ));
        }
        if actual != expected {
            return Err(format!(
                "Session '{}' does not belong to current workspace directory (expected='{}', actual='{}')",
                session_id, expected, actual
            ));
        }
        Ok(())
    }

    fn canonical_meta_key(raw: &str) -> String {
        raw.chars()
            .filter(|ch| *ch != '_' && *ch != '-')
            .flat_map(|ch| ch.to_lowercase())
            .collect::<String>()
    }

    fn json_value_to_trimmed_string(value: &serde_json::Value) -> Option<String> {
        match value {
            serde_json::Value::String(s) => {
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed.to_string())
                }
            }
            serde_json::Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    }

    fn json_value_to_f64(value: &serde_json::Value) -> Option<f64> {
        match value {
            serde_json::Value::Number(n) => n.as_f64(),
            serde_json::Value::String(s) => s.trim().parse::<f64>().ok(),
            _ => None,
        }
    }

    fn find_scalar_by_keys(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
        let target = keys
            .iter()
            .map(|key| Self::canonical_meta_key(key))
            .collect::<Vec<_>>();
        let mut stack = vec![value];
        let mut visited = 0usize;
        const MAX_VISITS: usize = 300;

        while let Some(node) = stack.pop() {
            if visited >= MAX_VISITS {
                break;
            }
            visited += 1;
            match node {
                serde_json::Value::Object(map) => {
                    for (k, v) in map {
                        let canonical = Self::canonical_meta_key(k);
                        if target.iter().any(|key| key == &canonical) {
                            if let Some(found) = Self::json_value_to_trimmed_string(v) {
                                return Some(found);
                            }
                        }
                        if matches!(
                            v,
                            serde_json::Value::Object(_) | serde_json::Value::Array(_)
                        ) {
                            stack.push(v);
                        }
                    }
                }
                serde_json::Value::Array(arr) => {
                    for item in arr {
                        if matches!(
                            item,
                            serde_json::Value::Object(_) | serde_json::Value::Array(_)
                        ) {
                            stack.push(item);
                        }
                    }
                }
                _ => {}
            }
        }

        None
    }

    fn normalize_agent_hint(raw: &str) -> Option<String> {
        let normalized = raw.trim().to_lowercase();
        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    }

    fn normalize_optional_token(raw: Option<String>) -> Option<String> {
        let token = raw?;
        let trimmed = token.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    }

    fn selection_hint_from_session(
        session: &SessionResponse,
    ) -> Option<super::AiSessionSelectionHint> {
        let mut root = serde_json::Map::<String, serde_json::Value>::new();
        for (k, v) in &session.extra {
            root.insert(k.clone(), v.clone());
        }
        // 把已知字段也放进统一搜索根，兼容不同服务端字段形态。
        root.insert(
            "id".to_string(),
            serde_json::Value::String(session.id.clone()),
        );
        root.insert(
            "title".to_string(),
            serde_json::Value::String(session.title.clone()),
        );
        if let Some(directory) = &session.directory {
            root.insert(
                "directory".to_string(),
                serde_json::Value::String(directory.clone()),
            );
        }
        let value = serde_json::Value::Object(root);

        let agent = Self::find_scalar_by_keys(
            &value,
            &[
                "agent",
                "agent_name",
                "selected_agent",
                "current_agent",
                "mode",
            ],
        )
        .and_then(|v| Self::normalize_agent_hint(&v));
        let model_provider_id = Self::normalize_optional_token(Self::find_scalar_by_keys(
            &value,
            &[
                "model_provider_id",
                "model_provider",
                "provider_id",
                "providerID",
                "modelProviderID",
            ],
        ));
        let model_id = Self::normalize_optional_token(Self::find_scalar_by_keys(
            &value,
            &[
                "model_id",
                "modelID",
                "selected_model",
                "current_model_id",
                "model",
            ],
        ));

        if agent.is_none() && model_id.is_none() {
            None
        } else {
            Some(super::AiSessionSelectionHint {
                agent,
                model_provider_id,
                model_id,
            })
        }
    }

    fn message_info_selection_source(info: &MessageInfo) -> Option<serde_json::Value> {
        let mut root = serde_json::Map::<String, serde_json::Value>::new();

        if let Some(agent) = Self::normalize_optional_token(info.agent.clone()) {
            root.insert("agent".to_string(), serde_json::Value::String(agent));
        }
        if let Some(mode) = Self::normalize_optional_token(info.mode.clone()) {
            root.insert("mode".to_string(), serde_json::Value::String(mode));
        }

        let provider_id = Self::normalize_optional_token(
            info.model
                .as_ref()
                .and_then(|m| m.provider_id.clone())
                .or_else(|| info.provider_id.clone()),
        );
        if let Some(provider_id) = provider_id {
            root.insert(
                "providerID".to_string(),
                serde_json::Value::String(provider_id.clone()),
            );
            root.insert(
                "model_provider_id".to_string(),
                serde_json::Value::String(provider_id),
            );
        }

        let model_id = Self::normalize_optional_token(
            info.model
                .as_ref()
                .and_then(|m| m.model_id.clone())
                .or_else(|| info.model_id.clone()),
        );
        if let Some(model_id) = model_id {
            root.insert(
                "modelID".to_string(),
                serde_json::Value::String(model_id.clone()),
            );
            root.insert("model_id".to_string(), serde_json::Value::String(model_id));
        }

        for (k, v) in &info.extra {
            let canonical = Self::canonical_meta_key(k);
            if matches!(
                canonical.as_str(),
                "agent"
                    | "mode"
                    | "model"
                    | "modelid"
                    | "providerid"
                    | "modelprovider"
                    | "modelproviderid"
                    | "currentmodelid"
                    | "currentmodeid"
                    | "selectedmodel"
                    | "selectedagent"
            ) {
                root.insert(k.clone(), v.clone());
            }
        }

        if root.is_empty() {
            None
        } else {
            Some(serde_json::Value::Object(root))
        }
    }

    fn merge_part_source_with_message_info(
        part_source: Option<serde_json::Value>,
        message_info_source: Option<&serde_json::Value>,
    ) -> Option<serde_json::Value> {
        let Some(message_info_source) = message_info_source else {
            return part_source;
        };
        match part_source {
            Some(serde_json::Value::Object(mut part_obj)) => {
                if let serde_json::Value::Object(info_obj) = message_info_source {
                    for (k, v) in info_obj {
                        if !part_obj.contains_key(k) {
                            part_obj.insert(k.clone(), v.clone());
                        }
                    }
                }
                Some(serde_json::Value::Object(part_obj))
            }
            Some(other) => {
                let mut wrapped = serde_json::Map::<String, serde_json::Value>::new();
                wrapped.insert("source".to_string(), other);
                if let serde_json::Value::Object(info_obj) = message_info_source {
                    for (k, v) in info_obj {
                        wrapped.insert(k.clone(), v.clone());
                    }
                }
                Some(serde_json::Value::Object(wrapped))
            }
            None => Some(message_info_source.clone()),
        }
    }

    fn message_total_tokens(message: &MessageEnvelope) -> Option<f64> {
        message
            .info
            .extra
            .get("tokens")
            .and_then(|v| v.get("total"))
            .and_then(Self::json_value_to_f64)
            .or_else(|| {
                message
                    .info
                    .extra
                    .get("usage")
                    .and_then(|v| {
                        v.get("total_tokens")
                            .or_else(|| v.get("totalTokens"))
                            .or_else(|| v.get("total"))
                    })
                    .and_then(Self::json_value_to_f64)
            })
    }

    fn message_model_identity(message: &MessageEnvelope) -> (Option<String>, Option<String>) {
        let provider_id = Self::normalize_optional_token(
            message
                .info
                .model
                .as_ref()
                .and_then(|m| m.provider_id.clone())
                .or_else(|| message.info.provider_id.clone()),
        );
        let model_id = Self::normalize_optional_token(
            message
                .info
                .model
                .as_ref()
                .and_then(|m| m.model_id.clone())
                .or_else(|| message.info.model_id.clone()),
        );
        (provider_id, model_id)
    }

    fn latest_assistant_usage(
        messages: &[MessageEnvelope],
    ) -> Option<(f64, Option<String>, Option<String>)> {
        let mut best: Option<(i64, f64, Option<String>, Option<String>)> = None;
        for message in messages {
            if !message.info.role.eq_ignore_ascii_case("assistant") {
                continue;
            }
            let Some(total_tokens) = Self::message_total_tokens(message) else {
                continue;
            };
            let created_at = message.info.created_at.unwrap_or(0);
            let (provider_id, model_id) = Self::message_model_identity(message);
            match best {
                Some((best_created_at, _, _, _)) if best_created_at > created_at => {}
                _ => best = Some((created_at, total_tokens, provider_id, model_id)),
            }
        }
        best.map(|(_, total_tokens, provider_id, model_id)| (total_tokens, provider_id, model_id))
    }

    fn context_window_from_model(model: &ProviderModelResponse) -> Option<f64> {
        let limit = model.limit.as_ref()?;
        let obj = limit.as_object()?;
        for key in [
            "context",
            "contextWindow",
            "context_window",
            "contextTokens",
            "context_tokens",
        ] {
            if let Some(value) = obj.get(key).and_then(Self::json_value_to_f64) {
                if value > 0.0 {
                    return Some(value);
                }
            }
        }
        None
    }

    fn resolve_context_window(
        providers: &[ProviderResponse],
        provider_id: Option<&str>,
        model_id: Option<&str>,
    ) -> Option<f64> {
        let model_id = model_id?.trim();
        if model_id.is_empty() {
            return None;
        }

        if let Some(provider_id) = provider_id.map(str::trim).filter(|v| !v.is_empty()) {
            if let Some(provider) = providers.iter().find(|p| p.id == provider_id) {
                if let Some(model) = provider.models_vec().into_iter().find(|m| m.id == model_id) {
                    if let Some(window) = Self::context_window_from_model(&model) {
                        return Some(window);
                    }
                }
            }
        }

        for provider in providers {
            if let Some(model) = provider.models_vec().into_iter().find(|m| m.id == model_id) {
                if let Some(window) = Self::context_window_from_model(&model) {
                    return Some(window);
                }
            }
        }

        None
    }

    fn compute_remaining_percent(total_tokens: f64, context_window: f64) -> Option<f64> {
        if !total_tokens.is_finite() || !context_window.is_finite() || context_window <= 0.0 {
            return None;
        }
        Some((((context_window - total_tokens) / context_window) * 100.0).clamp(0.0, 100.0))
    }
}

#[async_trait]
impl AiAgent for OpenCodeAgent {
    async fn start(&self) -> Result<(), String> {
        self.manager.ensure_server_running().await?;
        self.hub.ensure_started().await?;
        Ok(())
    }

    async fn stop(&self) -> Result<(), String> {
        self.manager.stop_server().await
    }

    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let session = client
            .create_session(directory, title)
            .await
            .map_err(|e| format!("Failed to create session: {}", e))?;
        let updated_at = session.effective_updated_at();
        Ok(AiSession {
            id: session.id,
            title: session.title,
            updated_at,
        })
    }

    async fn send_message(
        &self,
        directory: &str,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
    ) -> Result<AiEventStream, String> {
        // 会话隔离：防止跨工作空间误用 session_id
        self.verify_session_directory(directory, session_id).await?;

        let client = OpenCodeClient::from_manager(&self.manager);

        // 1. 先订阅 Hub（避免丢首包）
        let rx = self.hub.subscribe();

        // 2. 异步发送消息（立即返回）
        client
            .send_message_async(
                directory,
                session_id,
                message,
                file_refs,
                image_parts,
                model,
                agent,
            )
            .await
            .map_err(|e| format!("Failed to send message: {}", e))?;

        // 3. 过滤全局事件流，只保留当前 directory + session 的事件，映射为通用 AiEvent
        //
        // 注意：message.updated/part.updated/part.delta 均透传（含 user）。
        let session_id = session_id.to_string();
        let directory = directory.to_string();
        // partID -> part.type （用于把 message.part.delta 路由到 text/reasoning）
        let part_types: StdArc<StdMutex<HashMap<String, String>>> =
            StdArc::new(StdMutex::new(HashMap::new()));

        let stream = tokio_stream::wrappers::BroadcastStream::new(rx);
        let mapped = tokio_stream::StreamExt::filter_map(stream, move |result| {
            let part_types = part_types.clone();
            let session_id = session_id.clone();
            let directory = directory.clone();

            match result {
                Ok(hub_event) => {
                    if hub_event.directory.as_deref() != Some(directory.as_str()) {
                        return None;
                    }
                    let bus_event = hub_event.event;
                    match bus_event.event_type.as_str() {
                        // message.updated：透传 messageID + role
                        "message.updated" => {
                            let props = &bus_event.properties;
                            let info = props.get("info")?;
                            let info_session = info.get("sessionID").and_then(|v| v.as_str())?;
                            if info_session != session_id {
                                return None;
                            }
                            let role = info.get("role").and_then(|v| v.as_str()).unwrap_or("");
                            Some(Ok(AiEvent::MessageUpdated {
                                message_id: info.get("id")?.as_str()?.to_string(),
                                role: role.to_string(),
                            }))
                        }

                        // part 全量：message.part.updated
                        "message.part.updated" => {
                            let props = &bus_event.properties;
                            let part = props.get("part")?;
                            let part_session = part.get("sessionID").and_then(|v| v.as_str())?;
                            if part_session != session_id {
                                return None;
                            }
                            let message_id =
                                part.get("messageID").and_then(|v| v.as_str()).unwrap_or("");
                            let part_id = part.get("id").and_then(|v| v.as_str()).unwrap_or("");

                            let part_type = part.get("type").and_then(|v| v.as_str()).unwrap_or("");

                            // 记录 partID -> type，用于后续 message.part.delta
                            if !part_id.is_empty() && !part_type.is_empty() {
                                if let Ok(mut map) = part_types.lock() {
                                    map.insert(part_id.to_string(), part_type.to_string());
                                }
                            }

                            let part_id = part_id.to_string();
                            let part_type_s = part_type.to_string();
                            let message_id_s = message_id.to_string();

                            let tool_name = part
                                .get("name")
                                .and_then(|v| v.as_str())
                                .or_else(|| part.get("tool").and_then(|v| v.as_str()))
                                .map(|s| s.to_string());

                            let tool_state = part.get("state").cloned();
                            let tool_part_metadata = part.get("metadata").cloned();

                            let part_call_id = part.get("callID").and_then(|v| v.as_str());

                            let tool_call_id = part_call_id.map(|s| s.to_string()).or_else(|| {
                                tool_state.as_ref().and_then(|s| {
                                    s.get("callID")
                                        .and_then(|v| v.as_str())
                                        .map(|s| s.to_string())
                                })
                            });

                            let text = part
                                .get("text")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());

                            let mime = part
                                .get("mime")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());
                            let filename = part
                                .get("filename")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());
                            let url = part
                                .get("url")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());
                            let synthetic = part.get("synthetic").and_then(|v| v.as_bool());
                            let ignored = part.get("ignored").and_then(|v| v.as_bool());
                            let source = part.get("source").cloned();

                            Some(Ok(AiEvent::PartUpdated {
                                message_id: message_id_s,
                                part: AiPart {
                                    id: part_id,
                                    part_type: part_type_s,
                                    text,
                                    mime,
                                    filename,
                                    url,
                                    synthetic,
                                    ignored,
                                    source,
                                    tool_name,
                                    tool_call_id,
                                    tool_state,
                                    tool_part_metadata,
                                },
                            }))
                        }
                        // OpenCode 新版：message.part.delta 承载真正的流式增量（按 partID 分发）
                        "message.part.delta" => {
                            let props = &bus_event.properties;
                            let delta_session = props.get("sessionID").and_then(|v| v.as_str())?;
                            if delta_session != session_id {
                                return None;
                            }
                            let message_id = props
                                .get("messageID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            let part_id =
                                props.get("partID").and_then(|v| v.as_str()).unwrap_or("");
                            let field = props.get("field").and_then(|v| v.as_str()).unwrap_or("");
                            let delta = props.get("delta").and_then(|v| v.as_str()).unwrap_or("");
                            if delta.is_empty() || field != "text" {
                                return None;
                            }

                            let part_type = if !part_id.is_empty() {
                                part_types.lock().ok().and_then(|m| m.get(part_id).cloned())
                            } else {
                                None
                            };

                            let part_type_s =
                                part_type.clone().unwrap_or_else(|| "text".to_string());
                            Some(Ok(AiEvent::PartDelta {
                                message_id: message_id.to_string(),
                                part_id: part_id.to_string(),
                                part_type: part_type_s,
                                field: field.to_string(),
                                delta: delta.to_string(),
                            }))
                        }
                        // 会话状态变为 idle 表示处理完成
                        "session.idle" => {
                            let props = &bus_event.properties;
                            let idle_session = props
                                .get("sessionID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if idle_session == session_id {
                                Some(Ok(AiEvent::Done))
                            } else {
                                None
                            }
                        }
                        "session.status" => {
                            let props = &bus_event.properties;
                            // session.status 的 properties 可能直接包含 sessionID
                            // 也可能是 Record<sessionID, status>
                            let matches_session = props.get(&session_id).is_some()
                                || props
                                    .get("sessionID")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s == session_id)
                                    .unwrap_or(false);
                            if !matches_session {
                                return None;
                            }
                            let is_idle = props
                                .get(&session_id)
                                .and_then(|v| v.get("type"))
                                .and_then(|v| v.as_str())
                                .map(|s| s == "idle")
                                .unwrap_or(false)
                                || props
                                    .get("status")
                                    .and_then(|v| v.get("type"))
                                    .and_then(|v| v.as_str())
                                    .map(|s| s == "idle")
                                    .unwrap_or(false)
                                || props
                                    .get("type")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s == "idle")
                                    .unwrap_or(false);
                            if is_idle {
                                Some(Ok(AiEvent::Done))
                            } else {
                                None
                            }
                        }
                        // 会话错误
                        "session.error" => {
                            let props = &bus_event.properties;
                            let err_session = props
                                .get("sessionID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if err_session != session_id {
                                return None;
                            }
                            let message = props
                                .get("error")
                                .and_then(|v| v.get("message"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("Unknown error")
                                .to_string();
                            Some(Ok(AiEvent::Error { message }))
                        }
                        "question.asked" => {
                            let props = &bus_event.properties;
                            let asked_session = props.get("sessionID").and_then(|v| v.as_str())?;
                            if asked_session != session_id {
                                return None;
                            }

                            let request_id = props.get("id").and_then(|v| v.as_str())?.to_string();
                            let questions = props
                                .get("questions")
                                .and_then(|v| v.as_array())
                                .map(|arr| {
                                    arr.iter()
                                        .filter_map(|item| {
                                            let obj = item.as_object()?;
                                            let question = obj
                                                .get("question")
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("")
                                                .to_string();
                                            let header = obj
                                                .get("header")
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("")
                                                .to_string();
                                            let options = obj
                                                .get("options")
                                                .and_then(|v| v.as_array())
                                                .map(|opts| {
                                                    opts.iter()
                                                        .filter_map(|opt| {
                                                            let o = opt.as_object()?;
                                                            let label = o
                                                                .get("label")
                                                                .and_then(|v| v.as_str())
                                                                .unwrap_or("")
                                                                .to_string();
                                                            if label.is_empty() {
                                                                return None;
                                                            }
                                                            let description = o
                                                                .get("description")
                                                                .and_then(|v| v.as_str())
                                                                .unwrap_or("")
                                                                .to_string();
                                                            Some(crate::ai::AiQuestionOption {
                                                                label,
                                                                description,
                                                            })
                                                        })
                                                        .collect::<Vec<_>>()
                                                })
                                                .unwrap_or_default();
                                            if question.is_empty() {
                                                return None;
                                            }
                                            Some(crate::ai::AiQuestionInfo {
                                                question,
                                                header,
                                                options,
                                                multiple: obj
                                                    .get("multiple")
                                                    .and_then(|v| v.as_bool())
                                                    .unwrap_or(false),
                                                custom: obj
                                                    .get("custom")
                                                    .and_then(|v| v.as_bool())
                                                    .unwrap_or(true),
                                            })
                                        })
                                        .collect::<Vec<_>>()
                                })
                                .unwrap_or_default();

                            let (tool_message_id, tool_call_id) = props
                                .get("tool")
                                .and_then(|v| v.as_object())
                                .map(|tool| {
                                    (
                                        tool.get("messageID")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.to_string()),
                                        tool.get("callID")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.to_string()),
                                    )
                                })
                                .unwrap_or((None, None));

                            Some(Ok(AiEvent::QuestionAsked {
                                request: crate::ai::AiQuestionRequest {
                                    id: request_id,
                                    session_id: asked_session.to_string(),
                                    questions,
                                    tool_message_id,
                                    tool_call_id,
                                },
                            }))
                        }
                        "question.replied" | "question.rejected" => {
                            let props = &bus_event.properties;
                            let asked_session = props
                                .get("sessionID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if asked_session != session_id {
                                return None;
                            }
                            let request_id = props
                                .get("requestID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            if request_id.is_empty() {
                                return None;
                            }
                            Some(Ok(AiEvent::QuestionCleared {
                                session_id: asked_session.to_string(),
                                request_id,
                            }))
                        }
                        // 心跳和连接事件忽略
                        "server.heartbeat" | "server.connected" => None,
                        _ => None,
                    }
                }
                // Lagged 错误只记录日志，继续处理后续事件（不中断流）
                Err(tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(n)) => {
                    tracing::warn!("OpenCode event hub lagged by {} messages, continuing...", n);
                    None
                }
            }
        });

        Ok(Box::pin(mapped))
    }

    async fn send_command(
        &self,
        directory: &str,
        session_id: &str,
        command: &str,
        arguments: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
    ) -> Result<AiEventStream, String> {
        self.verify_session_directory(directory, session_id).await?;

        let client = OpenCodeClient::from_manager(&self.manager);

        // 1. 先订阅 Hub，避免丢首包
        let rx = self.hub.subscribe();

        // 2. 触发 command 请求
        client
            .send_command_async(
                directory,
                session_id,
                command,
                arguments,
                file_refs,
                image_parts,
                model,
                agent,
            )
            .await
            .map_err(|e| format!("Failed to send command: {}", e))?;

        // 3. 与 send_message 使用同一套事件映射逻辑（避免行为分叉）
        let session_id = session_id.to_string();
        let directory = directory.to_string();
        let part_types: StdArc<StdMutex<HashMap<String, String>>> =
            StdArc::new(StdMutex::new(HashMap::new()));

        let stream = tokio_stream::wrappers::BroadcastStream::new(rx);
        let mapped = tokio_stream::StreamExt::filter_map(stream, move |result| {
            let part_types = part_types.clone();
            let session_id = session_id.clone();
            let directory = directory.clone();

            match result {
                Ok(hub_event) => {
                    if hub_event.directory.as_deref() != Some(directory.as_str()) {
                        return None;
                    }
                    let bus_event = hub_event.event;
                    match bus_event.event_type.as_str() {
                        "message.updated" => {
                            let props = &bus_event.properties;
                            let info = props.get("info")?;
                            let info_session = info.get("sessionID").and_then(|v| v.as_str())?;
                            if info_session != session_id {
                                return None;
                            }
                            let role = info.get("role").and_then(|v| v.as_str()).unwrap_or("");
                            Some(Ok(AiEvent::MessageUpdated {
                                message_id: info.get("id")?.as_str()?.to_string(),
                                role: role.to_string(),
                            }))
                        }
                        "message.part.updated" => {
                            let props = &bus_event.properties;
                            let part = props.get("part")?;
                            let part_session = part.get("sessionID").and_then(|v| v.as_str())?;
                            if part_session != session_id {
                                return None;
                            }
                            let message_id =
                                part.get("messageID").and_then(|v| v.as_str()).unwrap_or("");
                            let part_id = part.get("id").and_then(|v| v.as_str()).unwrap_or("");

                            let part_type = part.get("type").and_then(|v| v.as_str()).unwrap_or("");

                            if !part_id.is_empty() && !part_type.is_empty() {
                                if let Ok(mut map) = part_types.lock() {
                                    map.insert(part_id.to_string(), part_type.to_string());
                                }
                            }

                            let part_id = part_id.to_string();
                            let part_type_s = part_type.to_string();
                            let message_id_s = message_id.to_string();

                            let tool_name = part
                                .get("name")
                                .and_then(|v| v.as_str())
                                .or_else(|| part.get("tool").and_then(|v| v.as_str()))
                                .map(|s| s.to_string());

                            let tool_state = part.get("state").cloned();
                            let tool_part_metadata = part.get("metadata").cloned();

                            // 优先从 part.callID 获取，其次从 state.callID 获取
                            let tool_call_id = part
                                .get("callID")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                                .or_else(|| {
                                    tool_state.as_ref().and_then(|s| {
                                        s.get("callID")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.to_string())
                                    })
                                });

                            let text = part
                                .get("text")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());

                            let mime = part
                                .get("mime")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());
                            let filename = part
                                .get("filename")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());
                            let url = part
                                .get("url")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());
                            let synthetic = part.get("synthetic").and_then(|v| v.as_bool());
                            let ignored = part.get("ignored").and_then(|v| v.as_bool());
                            let source = part.get("source").cloned();

                            Some(Ok(AiEvent::PartUpdated {
                                message_id: message_id_s,
                                part: AiPart {
                                    id: part_id,
                                    part_type: part_type_s,
                                    text,
                                    mime,
                                    filename,
                                    url,
                                    synthetic,
                                    ignored,
                                    source,
                                    tool_name,
                                    tool_call_id,
                                    tool_state,
                                    tool_part_metadata,
                                },
                            }))
                        }
                        "message.part.delta" => {
                            let props = &bus_event.properties;
                            let delta_session = props.get("sessionID").and_then(|v| v.as_str())?;
                            if delta_session != session_id {
                                return None;
                            }
                            let message_id = props
                                .get("messageID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            let part_id =
                                props.get("partID").and_then(|v| v.as_str()).unwrap_or("");
                            let field = props.get("field").and_then(|v| v.as_str()).unwrap_or("");
                            let delta = props.get("delta").and_then(|v| v.as_str()).unwrap_or("");
                            if delta.is_empty() || field != "text" {
                                return None;
                            }

                            let part_type = if !part_id.is_empty() {
                                part_types.lock().ok().and_then(|m| m.get(part_id).cloned())
                            } else {
                                None
                            };

                            let part_type_s =
                                part_type.clone().unwrap_or_else(|| "text".to_string());
                            Some(Ok(AiEvent::PartDelta {
                                message_id: message_id.to_string(),
                                part_id: part_id.to_string(),
                                part_type: part_type_s,
                                field: field.to_string(),
                                delta: delta.to_string(),
                            }))
                        }
                        "session.idle" => {
                            let props = &bus_event.properties;
                            let idle_session = props
                                .get("sessionID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if idle_session == session_id {
                                Some(Ok(AiEvent::Done))
                            } else {
                                None
                            }
                        }
                        "session.status" => {
                            let props = &bus_event.properties;
                            let matches_session = props.get(&session_id).is_some()
                                || props
                                    .get("sessionID")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s == session_id)
                                    .unwrap_or(false);
                            if !matches_session {
                                return None;
                            }
                            let is_idle = props
                                .get(&session_id)
                                .and_then(|v| v.get("type"))
                                .and_then(|v| v.as_str())
                                .map(|s| s == "idle")
                                .unwrap_or(false)
                                || props
                                    .get("status")
                                    .and_then(|v| v.get("type"))
                                    .and_then(|v| v.as_str())
                                    .map(|s| s == "idle")
                                    .unwrap_or(false)
                                || props
                                    .get("type")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s == "idle")
                                    .unwrap_or(false);
                            if is_idle {
                                Some(Ok(AiEvent::Done))
                            } else {
                                None
                            }
                        }
                        "session.error" => {
                            let props = &bus_event.properties;
                            let err_session = props
                                .get("sessionID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if err_session != session_id {
                                return None;
                            }
                            let message = props
                                .get("error")
                                .and_then(|v| v.get("message"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("Unknown error")
                                .to_string();
                            Some(Ok(AiEvent::Error { message }))
                        }
                        "question.asked" => {
                            let props = &bus_event.properties;
                            let asked_session = props.get("sessionID").and_then(|v| v.as_str())?;
                            if asked_session != session_id {
                                return None;
                            }

                            let request_id = props.get("id").and_then(|v| v.as_str())?.to_string();
                            let questions = props
                                .get("questions")
                                .and_then(|v| v.as_array())
                                .map(|arr| {
                                    arr.iter()
                                        .filter_map(|item| {
                                            let obj = item.as_object()?;
                                            let question = obj
                                                .get("question")
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("")
                                                .to_string();
                                            let header = obj
                                                .get("header")
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("")
                                                .to_string();
                                            let options = obj
                                                .get("options")
                                                .and_then(|v| v.as_array())
                                                .map(|opts| {
                                                    opts.iter()
                                                        .filter_map(|opt| {
                                                            let o = opt.as_object()?;
                                                            let label = o
                                                                .get("label")
                                                                .and_then(|v| v.as_str())
                                                                .unwrap_or("")
                                                                .to_string();
                                                            if label.is_empty() {
                                                                return None;
                                                            }
                                                            let description = o
                                                                .get("description")
                                                                .and_then(|v| v.as_str())
                                                                .unwrap_or("")
                                                                .to_string();
                                                            Some(crate::ai::AiQuestionOption {
                                                                label,
                                                                description,
                                                            })
                                                        })
                                                        .collect::<Vec<_>>()
                                                })
                                                .unwrap_or_default();
                                            if question.is_empty() {
                                                return None;
                                            }
                                            Some(crate::ai::AiQuestionInfo {
                                                question,
                                                header,
                                                options,
                                                multiple: obj
                                                    .get("multiple")
                                                    .and_then(|v| v.as_bool())
                                                    .unwrap_or(false),
                                                custom: obj
                                                    .get("custom")
                                                    .and_then(|v| v.as_bool())
                                                    .unwrap_or(true),
                                            })
                                        })
                                        .collect::<Vec<_>>()
                                })
                                .unwrap_or_default();

                            let (tool_message_id, tool_call_id) = props
                                .get("tool")
                                .and_then(|v| v.as_object())
                                .map(|tool| {
                                    (
                                        tool.get("messageID")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.to_string()),
                                        tool.get("callID")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.to_string()),
                                    )
                                })
                                .unwrap_or((None, None));

                            Some(Ok(AiEvent::QuestionAsked {
                                request: crate::ai::AiQuestionRequest {
                                    id: request_id,
                                    session_id: asked_session.to_string(),
                                    questions,
                                    tool_message_id,
                                    tool_call_id,
                                },
                            }))
                        }
                        "question.replied" | "question.rejected" => {
                            let props = &bus_event.properties;
                            let asked_session = props
                                .get("sessionID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if asked_session != session_id {
                                return None;
                            }
                            let request_id = props
                                .get("requestID")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            if request_id.is_empty() {
                                return None;
                            }
                            Some(Ok(AiEvent::QuestionCleared {
                                session_id: asked_session.to_string(),
                                request_id,
                            }))
                        }
                        "server.heartbeat" | "server.connected" => None,
                        _ => None,
                    }
                }
                // Lagged 错误只记录日志，继续处理后续事件（不中断流）
                Err(tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(n)) => {
                    tracing::warn!("OpenCode event hub lagged by {} messages, continuing...", n);
                    None
                }
            }
        });

        Ok(Box::pin(mapped))
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let sessions = client
            .list_sessions(directory)
            .await
            .map_err(|e| format!("Failed to list sessions: {}", e))?;
        let expected = directory.trim_end_matches('/');
        Ok(sessions
            .into_iter()
            .filter(|s| {
                s.directory
                    .as_deref()
                    .map(|d| d.trim_end_matches('/') == expected)
                    .unwrap_or(false)
            })
            .map(|s| AiSession {
                updated_at: s.effective_updated_at(),
                id: s.id,
                title: s.title,
            })
            .collect())
    }

    async fn delete_session(&self, directory: &str, session_id: &str) -> Result<(), String> {
        self.verify_session_directory(directory, session_id).await?;
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .delete_session(directory, session_id)
            .await
            .map_err(|e| format!("Failed to delete session: {}", e))?;
        Ok(())
    }

    async fn list_messages(
        &self,
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String> {
        self.verify_session_directory(directory, session_id).await?;
        let client = OpenCodeClient::from_manager(&self.manager);
        let raw = client
            .list_messages(directory, session_id, limit)
            .await
            .map_err(|e| format!("Failed to list messages: {}", e))?;

        let messages = raw
            .into_iter()
            .map(|m| {
                let MessageEnvelope { info, parts } = m;
                let info_source = Self::message_info_selection_source(&info);
                AiMessage {
                    id: info.id,
                    role: info.role,
                    created_at: info.created_at,
                    parts: parts
                        .into_iter()
                        .map(|p| AiPart {
                            id: p.id,
                            part_type: p.part_type,
                            text: p.text,
                            mime: p.mime,
                            filename: p.filename,
                            url: p.url,
                            synthetic: p.synthetic,
                            ignored: p.ignored,
                            source: Self::merge_part_source_with_message_info(
                                p.source,
                                info_source.as_ref(),
                            ),
                            tool_name: p.name.or(p.tool),
                            tool_call_id: p.call_id,
                            tool_state: p.state,
                            tool_part_metadata: p.metadata,
                        })
                        .collect(),
                }
            })
            .collect();
        Ok(messages)
    }

    async fn session_selection_hint(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<super::AiSessionSelectionHint>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let session = client
            .get_session(directory, session_id)
            .await
            .map_err(|e| format!("Failed to fetch session info for selection hint: {}", e))?;
        let expected = directory.trim_end_matches('/');
        let actual = session
            .directory
            .as_deref()
            .unwrap_or("")
            .trim_end_matches('/');
        if !actual.is_empty() && actual != expected {
            return Ok(None);
        }
        let hint = Self::selection_hint_from_session(&session);
        if hint.is_none() {
            tracing::debug!(
                "OpenCode session_selection_hint empty from /session: directory={}, session_id={}, session_extra_keys={:?}",
                directory,
                session_id,
                session.extra.keys().collect::<Vec<_>>()
            );
        }
        Ok(hint)
    }

    async fn abort_session(&self, directory: &str, session_id: &str) -> Result<(), String> {
        self.verify_session_directory(directory, session_id).await?;
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .abort_session(directory, session_id)
            .await
            .map_err(|e| format!("Failed to abort session: {}", e))?;
        Ok(())
    }

    async fn dispose_instance(&self, directory: &str) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .dispose_instance(directory)
            .await
            .map_err(|e| format!("Failed to dispose instance: {}", e))?;
        Ok(())
    }

    async fn get_session_status(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<AiSessionStatus, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let map = client
            .get_session_statuses(directory)
            .await
            .map_err(|e| format!("Failed to get session status: {}", e))?;

        let raw = map
            .get(session_id)
            .map(|item| item.status_type.trim().to_lowercase())
            .unwrap_or_else(|| "idle".to_string());

        let status = match raw.as_str() {
            "idle" => AiSessionStatus::Idle,
            // OpenCode 可能返回 busy/retry 等，统一映射为 busy
            "busy" | "retry" | "running" => AiSessionStatus::Busy,
            other => {
                // 未知状态不视为 error，避免误伤；倾向认为仍在进行中。
                tracing::debug!("Unknown OpenCode session status type: {}", other);
                AiSessionStatus::Busy
            }
        };

        Ok(status)
    }

    async fn get_session_context_usage(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionContextUsage>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let map = client
            .get_session_statuses(directory)
            .await
            .map_err(|e| format!("Failed to get session status for context usage: {}", e))?;
        let percent = map
            .get(session_id)
            .and_then(|item| item.context_remaining_percent());
        if percent.is_some() {
            return Ok(Some(AiSessionContextUsage {
                context_remaining_percent: percent,
            }));
        }

        let messages = client
            .list_messages(directory, session_id, Some(32))
            .await
            .map_err(|e| format!("Failed to list messages for context usage: {}", e))?;
        let latest_usage = Self::latest_assistant_usage(&messages);

        let computed_percent = if let Some((total_tokens, provider_id, model_id)) = latest_usage {
            let providers = client
                .list_providers(directory)
                .await
                .map_err(|e| format!("Failed to list providers for context usage: {}", e))?;
            let context_window = Self::resolve_context_window(
                &providers,
                provider_id.as_deref(),
                model_id.as_deref(),
            );
            context_window.and_then(|window| Self::compute_remaining_percent(total_tokens, window))
        } else {
            None
        };

        Ok(Some(AiSessionContextUsage {
            context_remaining_percent: computed_percent,
        }))
    }

    async fn list_providers(&self, directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let providers = client
            .list_providers(directory)
            .await
            .map_err(|e| format!("Failed to list providers: {}", e))?;
        Ok(providers
            .into_iter()
            .map(|p| {
                let pid = p.id.clone();
                AiProviderInfo {
                    id: p.id.clone(),
                    name: if p.name.is_empty() {
                        p.id.clone()
                    } else {
                        p.name.clone()
                    },
                    models: p
                        .models_vec()
                        .into_iter()
                        .filter(|m| m.status.as_deref() != Some("disabled"))
                        .map(|m| AiModelInfo {
                            supports_image_input: m.supports_image_input(),
                            id: m.id.clone(),
                            name: if m.name.is_empty() {
                                m.id.clone()
                            } else {
                                m.name
                            },
                            provider_id: if m.provider_id.is_empty() {
                                pid.clone()
                            } else {
                                m.provider_id
                            },
                        })
                        .collect(),
                }
            })
            .filter(|p: &AiProviderInfo| !p.models.is_empty())
            .collect())
    }

    async fn list_agents(&self, directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let agents = client
            .list_agents(directory)
            .await
            .map_err(|e| format!("Failed to list agents: {}", e))?;
        Ok(agents
            .into_iter()
            // 排除 hidden agent（compaction/title/summary 等内部 agent）
            .filter(|a| !a.hidden.unwrap_or(false))
            .map(|a| AiAgentInfo {
                name: a.name,
                description: a.description,
                mode: a.mode,
                color: a.color,
                default_provider_id: a.model.as_ref().map(|m| m.provider_id.clone()),
                default_model_id: a.model.as_ref().map(|m| m.model_id.clone()),
            })
            .collect())
    }

    async fn list_slash_commands(&self, directory: &str) -> Result<Vec<AiSlashCommand>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let commands = client
            .list_commands(directory)
            .await
            .map_err(|e| format!("Failed to list commands: {}", e))?;

        Ok(commands
            .into_iter()
            .filter(|c| !c.name.trim().is_empty())
            .map(|c| {
                let _source = c.source;
                AiSlashCommand {
                    name: c.name,
                    description: c.description.unwrap_or_default(),
                    // OpenCode /command 返回的是可在会话内执行的命令，
                    // 前端按 agent 命令处理（写入 `/xxx` 后发送）。
                    action: "agent".to_string(),
                }
            })
            .collect())
    }

    async fn reply_question(
        &self,
        directory: &str,
        request_id: &str,
        answers: Vec<Vec<String>>,
    ) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .reply_question(directory, request_id, answers)
            .await
            .map_err(|e| format!("Failed to reply question: {}", e))
    }

    async fn reject_question(&self, directory: &str, request_id: &str) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .reject_question(directory, request_id)
            .await
            .map_err(|e| format!("Failed to reject question: {}", e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_client_new() {
        let client = OpenCodeClient::new("http://localhost:8080");
        assert_eq!(client.base_url, "http://localhost:8080");
    }

    #[test]
    fn test_session_response_serialization() {
        let json = r#"{"id":"ses_123","title":"Test Session","directory":"/tmp/x","time":{"created":1700000000000,"updated":1700000001234}}"#;
        let session: SessionResponse = serde_json::from_str(json).unwrap();
        assert_eq!(session.id, "ses_123");
        assert_eq!(session.title, "Test Session");
        assert_eq!(session.directory.as_deref(), Some("/tmp/x"));
        assert_eq!(session.effective_updated_at(), 1700000001234);
    }

    #[test]
    fn test_session_response_deserialization() {
        let session = SessionResponse {
            id: "ses_abc".to_string(),
            title: "My Session".to_string(),
            directory: None,
            time: None,
            updated_at: 1234567890,
            extra: std::collections::HashMap::new(),
        };
        let json = serde_json::to_string(&session).unwrap();
        assert!(json.contains("\"id\":\"ses_abc\""));
        assert!(json.contains("\"title\":\"My Session\""));
    }

    #[test]
    fn test_create_session_request() {
        let request = CreateSessionRequest {
            title: "New Session".to_string(),
        };
        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("\"title\":\"New Session\""));
    }

    #[test]
    fn test_prompt_async_body() {
        let body = serde_json::json!({
            "parts": [
                { "type": "text", "text": "Hello" },
                { "type": "file", "url": "file:///src/main.rs", "filename": "src/main.rs", "mime": "text/plain" },
            ]
        });
        let json = serde_json::to_string(&body).unwrap();
        assert!(json.contains("\"parts\""));
        assert!(json.contains("\"type\":\"text\""));
        assert!(json.contains("\"type\":\"file\""));
    }

    #[test]
    fn test_opencode_model_payload_shape() {
        let model = super::super::AiModelSelection {
            provider_id: "openrouter".to_string(),
            model_id: "glm-5".to_string(),
        };
        let payload = OpenCodeClient::opencode_model_payload(&model);
        assert!(payload.is_object());
        assert_eq!(payload["providerID"], "openrouter");
        assert_eq!(payload["modelID"], "glm-5");
    }

    #[test]
    fn test_bus_event_message_part_updated() {
        let json = r#"{"type":"message.part.updated","properties":{"part":{"id":"p1","sessionID":"s1","messageID":"m1","type":"text","text":"Hello World"},"delta":"Hello World"}}"#;
        let event: BusEvent = serde_json::from_str(json).unwrap();
        assert_eq!(event.event_type, "message.part.updated");
        let part = event.properties.get("part").unwrap();
        assert_eq!(part.get("type").unwrap().as_str().unwrap(), "text");
        assert_eq!(
            event.properties.get("delta").unwrap().as_str().unwrap(),
            "Hello World"
        );
    }

    #[test]
    fn test_part_envelope_file_fields() {
        let json = r#"{
            "id":"p_file_1",
            "type":"file",
            "mime":"image/png",
            "filename":"image.png",
            "url":"data:image/png;base64,AAA"
        }"#;
        let part: PartEnvelope = serde_json::from_str(json).unwrap();
        assert_eq!(part.part_type, "file");
        assert_eq!(part.mime.as_deref(), Some("image/png"));
        assert_eq!(part.filename.as_deref(), Some("image.png"));
        assert_eq!(part.url.as_deref(), Some("data:image/png;base64,AAA"));
    }

    #[test]
    fn test_bus_event_session_status() {
        let json = r#"{"type":"session.status","properties":{"ses_123":{"type":"idle"}}}"#;
        let event: BusEvent = serde_json::from_str(json).unwrap();
        assert_eq!(event.event_type, "session.status");
        let status = event.properties.get("ses_123").unwrap();
        assert_eq!(status.get("type").unwrap().as_str().unwrap(), "idle");
    }

    #[test]
    fn test_bus_event_heartbeat() {
        let json = r#"{"type":"server.heartbeat","properties":{}}"#;
        let event: BusEvent = serde_json::from_str(json).unwrap();
        assert_eq!(event.event_type, "server.heartbeat");
    }

    #[test]
    fn test_infer_image_extension() {
        assert_eq!(infer_image_extension("photo.jpeg", "image/png"), "jpg");
        assert_eq!(infer_image_extension("photo.png", "image/jpeg"), "png");
        assert_eq!(infer_image_extension("photo", "image/webp"), "webp");
        assert_eq!(
            infer_image_extension("photo.unknown", "application/octet-stream"),
            "bin"
        );
    }

    #[test]
    fn test_image_part_url_for_opencode_prefers_file_url() {
        let image = super::super::AiImagePart {
            filename: "clipboard_test.jpg".to_string(),
            mime: "image/jpeg".to_string(),
            data: vec![0xFF, 0xD8, 0xFF, 0xD9],
        };

        let url = image_part_url_for_opencode(&image);
        assert!(url.starts_with("file://") || url.starts_with("data:image/jpeg;base64,"));
    }

    #[test]
    fn test_session_list_response() {
        let json = r#"{"sessions":[{"id":"s1","title":"Session 1","directory":"/a","time":{"created":1,"updated":1000}},{"id":"s2","title":"Session 2","directory":"/b","time":{"created":2,"updated":2000}}]}"#;
        let list: SessionListResponse = serde_json::from_str(json).unwrap();
        assert_eq!(list.sessions.len(), 2);
        assert_eq!(list.sessions[0].id, "s1");
        assert_eq!(list.sessions[1].title, "Session 2");
        assert_eq!(list.sessions[1].effective_updated_at(), 2000);
    }

    #[test]
    fn test_error_display() {
        let err = OpenCodeError::ServerError {
            status: 500,
            message: "Internal Server Error".to_string(),
        };
        assert_eq!(err.to_string(), "Server error: 500 - Internal Server Error");

        let json_err = OpenCodeError::JsonError(
            serde_json::from_str::<serde_json::Value>("invalid").unwrap_err(),
        );
        assert!(json_err.to_string().contains("JSON error"));
    }
}
