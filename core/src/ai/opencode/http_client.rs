use super::attachment::{append_audio_fallback_text, image_part_url_for_opencode};
use super::protocol::{
    AgentResponse, BusEvent, CommandResponse, CreateSessionRequest, GlobalBusEventEnvelope,
    MessageEnvelope, ProviderResponse, SessionListResponse, SessionResponse, SessionStatusItem,
};
use super::sse::SseJsonStream;
use reqwest::Client;
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

pub struct OpenCodeClient {
    base_url: String,
    client: Client,
}

impl OpenCodeClient {
    fn opencode_model_payload(model: &crate::ai::AiModelSelection) -> serde_json::Value {
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
        image_parts: Option<Vec<crate::ai::AiImagePart>>,
        audio_parts: Option<Vec<crate::ai::AiAudioPart>>,
        model: Option<crate::ai::AiModelSelection>,
        agent: Option<String>,
    ) -> Result<(), OpenCodeError> {
        let url = format!("{}/session/{}/prompt_async", self.base_url, session_id);
        let effective_message = append_audio_fallback_text(message, audio_parts.as_deref());

        let mut parts = vec![serde_json::json!({
            "type": "text",
            "text": effective_message,
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
        image_parts: Option<Vec<crate::ai::AiImagePart>>,
        audio_parts: Option<Vec<crate::ai::AiAudioPart>>,
        model: Option<crate::ai::AiModelSelection>,
        agent: Option<String>,
    ) -> Result<(), OpenCodeError> {
        let url = format!("{}/session/{}/command", self.base_url, session_id);
        let effective_arguments = append_audio_fallback_text(arguments, audio_parts.as_deref());

        let mut body = serde_json::json!({
            "command": command,
            "arguments": effective_arguments,
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
            body["model"] = serde_json::json!(format!("{}/{}", m.provider_id, m.model_id));
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

#[cfg(test)]
mod tests;
