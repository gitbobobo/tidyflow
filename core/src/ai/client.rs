use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
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

pub struct OpenCodeClient {
    base_url: String,
    client: Client,
}

impl OpenCodeClient {
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

        // 图片附件转为 OpenCode FilePart（data URL 格式）
        if let Some(ref images) = image_parts {
            for img in images {
                let encoded = BASE64.encode(&img.data);
                parts.push(serde_json::json!({
                    "type": "file",
                    "url": format!("data:{};base64,{}", img.mime, encoded),
                    "filename": img.filename,
                    "mime": img.mime,
                }));
            }
        }

        let mut body = serde_json::json!({ "parts": parts });

        // 模型选择
        if let Some(ref m) = model {
            body["model"] = serde_json::json!({
                "providerID": m.provider_id,
                "modelID": m.model_id,
            });
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
                let encoded = BASE64.encode(&img.data);
                parts.push(serde_json::json!({
                    "type": "file",
                    "url": format!("data:{};base64,{}", img.mime, encoded),
                    "filename": img.filename,
                    "mime": img.mime,
                }));
            }
        }

        if !parts.is_empty() {
            body["parts"] = serde_json::Value::Array(parts);
        }

        if let Some(ref m) = model {
            body["model"] = serde_json::json!({
                "providerID": m.provider_id,
                "modelID": m.model_id,
            });
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
        let url = format!("{}/session", self.base_url);

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
}

#[derive(Debug, Clone, Deserialize)]
pub struct PartEnvelope {
    pub id: String,
    #[serde(rename = "type")]
    pub part_type: String,
    #[serde(default)]
    pub text: Option<String>,
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
        // 注意：
        // - message.updated 告知 message role（user/assistant）。
        // - part.updated/delta 可能先于 message.updated 到达，因此需要 role 未知时的兜底过滤。
        let session_id = session_id.to_string();
        let directory = directory.to_string();
        let user_message = message.to_string();
        let message_roles: StdArc<StdMutex<HashMap<String, String>>> =
            StdArc::new(StdMutex::new(HashMap::new()));
        // partID -> part.type （用于把 message.part.delta 路由到 text/reasoning）
        let part_types: StdArc<StdMutex<HashMap<String, String>>> =
            StdArc::new(StdMutex::new(HashMap::new()));

        let stream = tokio_stream::wrappers::BroadcastStream::new(rx);
        let mapped = tokio_stream::StreamExt::filter_map(stream, move |result| {
            let message_roles = message_roles.clone();
            let part_types = part_types.clone();
            let session_id = session_id.clone();
            let directory = directory.clone();
            let user_message = user_message.clone();

            match result {
                Ok(hub_event) => {
                    if hub_event.directory.as_deref() != Some(directory.as_str()) {
                        return None;
                    }
                    let bus_event = hub_event.event;
                    match bus_event.event_type.as_str() {
                        // message.updated：记录 messageID -> role 映射
                        "message.updated" => {
                            let props = &bus_event.properties;
                            let info = props.get("info")?;
                            let info_session = info.get("sessionID").and_then(|v| v.as_str())?;
                            if info_session != session_id {
                                return None;
                            }
                            let message_id = info.get("id").and_then(|v| v.as_str())?.to_string();
                            let role = info
                                .get("role")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            if !message_id.is_empty() && !role.is_empty() {
                                if let Ok(mut map) = message_roles.lock() {
                                    map.insert(message_id, role);
                                }
                            }
                            // 只对 assistant 转发，用户消息不需要展示（UI 已本地插入）
                            let role = info.get("role").and_then(|v| v.as_str()).unwrap_or("");
                            if role == "assistant" {
                                Some(Ok(AiEvent::MessageUpdated {
                                    message_id: info.get("id")?.as_str()?.to_string(),
                                    role: role.to_string(),
                                }))
                            } else {
                                None
                            }
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

                            let role = if !message_id.is_empty() {
                                message_roles
                                    .lock()
                                    .ok()
                                    .and_then(|m| m.get(message_id).cloned())
                            } else {
                                None
                            };

                            // 已知是 user 的 message：一律不转发到 AIChatText，避免重复显示
                            if let Some(ref r) = role {
                                if r == "user" {
                                    return None;
                                }
                            }

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
                            let tool_call_id = part
                                .get("callID")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());

                            let text = part
                                .get("text")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());

                            // role 未知时的兜底：若文本与刚发送的 user message 完全一致，通常是用户消息回放，忽略
                            if role.is_none()
                                && part_type == "text"
                                && !user_message.is_empty()
                                && text.as_deref().unwrap_or("").trim() == user_message.trim()
                            {
                                return None;
                            }

                            let tool_state = part.get("state").cloned();
                            let tool_part_metadata = part.get("metadata").cloned();

                            Some(Ok(AiEvent::PartUpdated {
                                message_id: message_id_s,
                                part: AiPart {
                                    id: part_id,
                                    part_type: part_type_s,
                                    text,
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

                            let role = if !message_id.is_empty() {
                                message_roles
                                    .lock()
                                    .ok()
                                    .and_then(|m| m.get(message_id).cloned())
                            } else {
                                None
                            };
                            if let Some(ref r) = role {
                                if r == "user" {
                                    return None;
                                }
                            }

                            let part_type = if !part_id.is_empty() {
                                part_types.lock().ok().and_then(|m| m.get(part_id).cloned())
                            } else {
                                None
                            };

                            let part_type_s =
                                part_type.clone().unwrap_or_else(|| "text".to_string());
                            if role.is_none()
                                && !user_message.is_empty()
                                && delta.trim() == user_message.trim()
                            {
                                return None;
                            }
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
                        // 心跳和连接事件忽略
                        "server.heartbeat" | "server.connected" => None,
                        _ => None,
                    }
                }
                Err(e) => Some(Err(e.to_string())),
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
        let user_message = if arguments.trim().is_empty() {
            format!("/{}", command.trim())
        } else {
            format!("/{} {}", command.trim(), arguments.trim())
        };
        let message_roles: StdArc<StdMutex<HashMap<String, String>>> =
            StdArc::new(StdMutex::new(HashMap::new()));
        let part_types: StdArc<StdMutex<HashMap<String, String>>> =
            StdArc::new(StdMutex::new(HashMap::new()));

        let stream = tokio_stream::wrappers::BroadcastStream::new(rx);
        let mapped = tokio_stream::StreamExt::filter_map(stream, move |result| {
            let message_roles = message_roles.clone();
            let part_types = part_types.clone();
            let session_id = session_id.clone();
            let directory = directory.clone();
            let user_message = user_message.clone();

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
                            let message_id = info.get("id").and_then(|v| v.as_str())?.to_string();
                            let role = info
                                .get("role")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            if !message_id.is_empty() && !role.is_empty() {
                                if let Ok(mut map) = message_roles.lock() {
                                    map.insert(message_id, role);
                                }
                            }
                            let role = info.get("role").and_then(|v| v.as_str()).unwrap_or("");
                            if role == "assistant" {
                                Some(Ok(AiEvent::MessageUpdated {
                                    message_id: info.get("id")?.as_str()?.to_string(),
                                    role: role.to_string(),
                                }))
                            } else {
                                None
                            }
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

                            let role = if !message_id.is_empty() {
                                message_roles
                                    .lock()
                                    .ok()
                                    .and_then(|m| m.get(message_id).cloned())
                            } else {
                                None
                            };

                            if let Some(ref r) = role {
                                if r == "user" {
                                    return None;
                                }
                            }

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
                            let tool_call_id = part
                                .get("callID")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());

                            let text = part
                                .get("text")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string());

                            if role.is_none()
                                && part_type == "text"
                                && !user_message.is_empty()
                                && text.as_deref().unwrap_or("").trim() == user_message.trim()
                            {
                                return None;
                            }

                            let tool_state = part.get("state").cloned();
                            let tool_part_metadata = part.get("metadata").cloned();

                            Some(Ok(AiEvent::PartUpdated {
                                message_id: message_id_s,
                                part: AiPart {
                                    id: part_id,
                                    part_type: part_type_s,
                                    text,
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

                            let role = if !message_id.is_empty() {
                                message_roles
                                    .lock()
                                    .ok()
                                    .and_then(|m| m.get(message_id).cloned())
                            } else {
                                None
                            };
                            if let Some(ref r) = role {
                                if r == "user" {
                                    return None;
                                }
                            }

                            let part_type = if !part_id.is_empty() {
                                part_types.lock().ok().and_then(|m| m.get(part_id).cloned())
                            } else {
                                None
                            };

                            let part_type_s =
                                part_type.clone().unwrap_or_else(|| "text".to_string());
                            if role.is_none()
                                && !user_message.is_empty()
                                && delta.trim() == user_message.trim()
                            {
                                return None;
                            }
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
                        "server.heartbeat" | "server.connected" => None,
                        _ => None,
                    }
                }
                Err(e) => Some(Err(e.to_string())),
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
            .map(|m| AiMessage {
                id: m.info.id,
                role: m.info.role,
                created_at: m.info.created_at,
                parts: m
                    .parts
                    .into_iter()
                    .map(|p| AiPart {
                        id: p.id,
                        part_type: p.part_type,
                        text: p.text,
                        tool_name: p.name.or(p.tool),
                        tool_call_id: p.call_id,
                        tool_state: p.state,
                        tool_part_metadata: p.metadata,
                    })
                    .collect(),
            })
            .collect();
        Ok(messages)
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
