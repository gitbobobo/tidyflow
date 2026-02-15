use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use thiserror::Error;
use tokio_stream::Stream;

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
pub struct SessionResponse {
    pub id: String,
    pub title: String,
    #[serde(rename = "updatedAt", default)]
    pub updated_at: i64,
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

    pub async fn create_session(&self, title: &str) -> Result<SessionResponse, OpenCodeError> {
        let url = format!("{}/session", self.base_url);
        let request = CreateSessionRequest {
            title: title.to_string(),
        };

        let response = self.client.post(&url).json(&request).send().await?;

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
    /// 实际响应通过 SSE `/event` 端点流式获取
    pub async fn send_message_async(
        &self,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
    ) -> Result<(), OpenCodeError> {
        let url = format!("{}/session/{}/prompt_async", self.base_url, session_id);

        let mut parts = vec![serde_json::json!({
            "type": "text",
            "text": message,
        })];

        if let Some(ref refs) = file_refs {
            for r in refs {
                parts.push(serde_json::json!({
                    "type": "file",
                    "url": format!("file://{}", r),
                    "filename": r,
                    "mime": "text/plain",
                }));
            }
        }

        let body = serde_json::json!({ "parts": parts });

        let response = self.client.post(&url).json(&body).send().await?;

        let status = response.status().as_u16();
        if status == 204 || response.status().is_success() {
            Ok(())
        } else {
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }

    /// 订阅 SSE 事件流（GET /event）
    pub async fn subscribe_events(
        &self,
    ) -> Result<impl Stream<Item = Result<BusEvent, OpenCodeError>>, OpenCodeError> {
        let url = format!("{}/event", self.base_url);

        let response = self.client.get(&url).send().await?;

        if !response.status().is_success() {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            return Err(OpenCodeError::ServerError { status, message });
        }

        let stream = SseStream::new(response.bytes_stream());
        Ok(stream)
    }

    pub async fn list_sessions(&self) -> Result<Vec<SessionResponse>, OpenCodeError> {
        let url = format!("{}/session", self.base_url);

        let response = self.client.get(&url).send().await?;

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

    pub async fn delete_session(&self, session_id: &str) -> Result<(), OpenCodeError> {
        let url = format!("{}/session/{}", self.base_url, session_id);

        let response = self.client.delete(&url).send().await?;

        if response.status().as_u16() == 204 || response.status().is_success() {
            Ok(())
        } else {
            let status = response.status().as_u16();
            let message = response.text().await.unwrap_or_default();
            Err(OpenCodeError::ServerError { status, message })
        }
    }
}

use std::pin::Pin;
use std::task::{Context, Poll};

struct SseStream {
    buffer: String,
    inner: Pin<
        Box<dyn tokio_stream::Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send + Unpin>,
    >,
    /// 已解析但尚未 yield 的事件队列
    pending: std::collections::VecDeque<Result<BusEvent, OpenCodeError>>,
}

impl SseStream {
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

            // 尝试解析为 BusEvent JSON
            match serde_json::from_str::<BusEvent>(&data) {
                Ok(event) => {
                    self.pending.push_back(Ok(event));
                }
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

impl tokio_stream::Stream for SseStream {
    type Item = Result<BusEvent, OpenCodeError>;

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
// OpenCodeAgent: 实现通用 AiAgent trait
// ============================================================================

use super::{AiAgent, AiEvent, AiEventStream, AiSession, OpenCodeManager};
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::{Arc as StdArc, Mutex as StdMutex};

/// OpenCode 后端的 AiAgent 实现
///
/// 封装 OpenCodeManager（进程管理）+ OpenCodeClient（HTTP 通信），
/// 将 OpenCode 特有的 SSE 事件转换为通用 AiEvent。
pub struct OpenCodeAgent {
    manager: Arc<OpenCodeManager>,
}

impl OpenCodeAgent {
    pub fn new(manager: Arc<OpenCodeManager>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl AiAgent for OpenCodeAgent {
    async fn start(&self) -> Result<(), String> {
        self.manager.start_server().await?;
        Ok(())
    }

    async fn stop(&self) -> Result<(), String> {
        self.manager.stop_server().await
    }

    async fn create_session(&self, title: &str) -> Result<AiSession, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let session = client
            .create_session(title)
            .await
            .map_err(|e| format!("Failed to create session: {}", e))?;
        Ok(AiSession {
            id: session.id,
            title: session.title,
            updated_at: session.updated_at,
        })
    }

    async fn send_message(
        &self,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
    ) -> Result<AiEventStream, String> {
        let client = OpenCodeClient::from_manager(&self.manager);

        // 1. 先订阅 SSE 事件流
        let sse_stream = client
            .subscribe_events()
            .await
            .map_err(|e| format!("Failed to subscribe events: {}", e))?;

        // 2. 异步发送消息（立即返回）
        client
            .send_message_async(session_id, message, file_refs)
            .await
            .map_err(|e| format!("Failed to send message: {}", e))?;

        // 3. 过滤 SSE 事件，只保留当前 session 的事件，映射为通用 AiEvent
        //
        // 注意：OpenCode 会通过 message.updated 事件告知 message role（user/assistant），
        // message.part.updated 只有 messageID，不包含 role。若不做 role 过滤，
        // 很容易把用户消息的 part 当成 assistant 文本转发，导致客户端“重复显示用户消息”。
        let session_id = session_id.to_string();
        let user_message = message.to_string();
        let message_roles: StdArc<StdMutex<HashMap<String, String>>> =
            StdArc::new(StdMutex::new(HashMap::new()));
        // partID -> part.type （用于把 message.part.delta 路由到 text/reasoning）
        let part_types: StdArc<StdMutex<HashMap<String, String>>> =
            StdArc::new(StdMutex::new(HashMap::new()));

        let mapped = tokio_stream::StreamExt::filter_map(sse_stream, move |result| {
            let message_roles = message_roles.clone();
            let part_types = part_types.clone();
            let session_id = session_id.clone();
            let user_message = user_message.clone();

            match result {
                Ok(bus_event) => match bus_event.event_type.as_str() {
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
                        None
                    }

                    // 文本增量：message.part.updated
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

                        match part_type {
                            "text" => {
                                // 优先使用 delta（增量），否则用完整 text
                                let delta = props
                                    .get("delta")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string());
                                let text = delta
                                    .or_else(|| {
                                        part.get("text")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.to_string())
                                    })
                                    .unwrap_or_default();
                                if text.is_empty() {
                                    return None;
                                }

                                // role 未知时的兜底：若文本与刚发送的 user message 完全一致，通常是用户消息回放，忽略
                                if role.is_none()
                                    && !user_message.is_empty()
                                    && text.trim() == user_message.trim()
                                {
                                    return None;
                                }
                                Some(Ok(AiEvent::TextDelta { text }))
                            }
                            "reasoning" => {
                                // 思考过程增量：进入可折叠区域，不污染最终回复文本
                                let delta = props
                                    .get("delta")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string());
                                let text = delta
                                    .or_else(|| {
                                        part.get("text")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.to_string())
                                    })
                                    .unwrap_or_default();
                                if text.is_empty() {
                                    return None;
                                }
                                Some(Ok(AiEvent::ThinkingDelta { text }))
                            }
                            "tool" => {
                                let tool = part
                                    .get("name")
                                    .and_then(|v| v.as_str())
                                    .or_else(|| part.get("tool").and_then(|v| v.as_str()))
                                    .unwrap_or("unknown")
                                    .to_string();
                                Some(Ok(AiEvent::ToolUse {
                                    tool,
                                    input: part
                                        .get("state")
                                        .cloned()
                                        .unwrap_or(serde_json::Value::Null),
                                }))
                            }
                            _ => None,
                        }
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
                        let part_id = props.get("partID").and_then(|v| v.as_str()).unwrap_or("");
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

                        match part_type.as_deref() {
                            Some("reasoning") => Some(Ok(AiEvent::ThinkingDelta {
                                text: delta.to_string(),
                            })),
                            Some("text") => {
                                // role 未知时的兜底：若文本与刚发送的 user message 完全一致，通常是用户消息回放，忽略
                                if role.is_none()
                                    && !user_message.is_empty()
                                    && delta.trim() == user_message.trim()
                                {
                                    return None;
                                }
                                Some(Ok(AiEvent::TextDelta {
                                    text: delta.to_string(),
                                }))
                            }
                            // 未知 part 类型：宁可当成 text（至少实现实时输出）
                            None => Some(Ok(AiEvent::TextDelta {
                                text: delta.to_string(),
                            })),
                            _ => None,
                        }
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
                },
                Err(e) => Some(Err(e.to_string())),
            }
        });

        Ok(Box::pin(mapped))
    }

    async fn list_sessions(&self) -> Result<Vec<AiSession>, String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        let sessions = client
            .list_sessions()
            .await
            .map_err(|e| format!("Failed to list sessions: {}", e))?;
        Ok(sessions
            .into_iter()
            .map(|s| AiSession {
                id: s.id,
                title: s.title,
                updated_at: s.updated_at,
            })
            .collect())
    }

    async fn delete_session(&self, session_id: &str) -> Result<(), String> {
        let client = OpenCodeClient::from_manager(&self.manager);
        client
            .delete_session(session_id)
            .await
            .map_err(|e| format!("Failed to delete session: {}", e))?;
        Ok(())
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
        let json = r#"{"id":"ses_123","title":"Test Session","updatedAt":1700000000000}"#;
        let session: SessionResponse = serde_json::from_str(json).unwrap();
        assert_eq!(session.id, "ses_123");
        assert_eq!(session.title, "Test Session");
        assert_eq!(session.updated_at, 1700000000000);
    }

    #[test]
    fn test_session_response_deserialization() {
        let session = SessionResponse {
            id: "ses_abc".to_string(),
            title: "My Session".to_string(),
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
        let json = r#"{"sessions":[{"id":"s1","title":"Session 1","updatedAt":1000},{"id":"s2","title":"Session 2","updatedAt":2000}]}"#;
        let list: SessionListResponse = serde_json::from_str(json).unwrap();
        assert_eq!(list.sessions.len(), 2);
        assert_eq!(list.sessions[0].id, "s1");
        assert_eq!(list.sessions[1].title, "Session 2");
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
