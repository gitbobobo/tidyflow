//! AI 代理统一抽象层
//!
//! 定义通用的 AiAgent trait 和事件类型，
//! 不同 AI 后端（OpenCode、Claude CLI 等）实现此 trait。

pub mod client;
pub mod event_hub;
pub mod manager;

pub use client::OpenCodeAgent;
pub use client::OpenCodeClient;
pub use manager::OpenCodeManager;

use async_trait::async_trait;
use std::pin::Pin;
use tokio_stream::Stream;

// ============================================================================
// 通用 AI 事件（代理无关）
// ============================================================================

/// AI 流式事件（结构化、带 ID）
#[derive(Debug, Clone)]
pub enum AiEvent {
    /// message.updated：用于建立 message_id -> role 映射，以及创建消息壳
    MessageUpdated { message_id: String, role: String },
    /// message.part.updated：全量 part（text/reasoning/tool）
    PartUpdated {
        message_id: String,
        part: AiPart,
    },
    /// message.part.delta：按 part_id 的增量更新（通常 field=text）
    PartDelta {
        message_id: String,
        part_id: String,
        part_type: String,
        field: String,
        delta: String,
    },
    /// 错误
    Error { message: String },
    /// 流结束
    Done,
}

/// AI Part（通用模型，直接对应 OpenCode 的 part）
#[derive(Debug, Clone)]
pub struct AiPart {
    pub id: String,
    /// "text" | "reasoning" | "tool"
    pub part_type: String,
    /// text/reasoning 的内容（全量）
    pub text: Option<String>,
    /// tool 名（若为 tool）
    pub tool_name: Option<String>,
    /// tool 的状态/state（JSON 透传）
    pub tool_state: Option<serde_json::Value>,
}

/// AI 会话信息
#[derive(Debug, Clone)]
pub struct AiSession {
    pub id: String,
    pub title: String,
    pub updated_at: i64,
}

/// AI 历史消息（用于会话加载）
#[derive(Debug, Clone)]
pub struct AiMessage {
    pub id: String,
    pub role: String,
    pub created_at: Option<i64>,
    pub parts: Vec<AiPart>,
}

/// AI 事件流类型别名
pub type AiEventStream = Pin<Box<dyn Stream<Item = Result<AiEvent, String>> + Send>>;

// ============================================================================
// 通用 AI 代理 trait
// ============================================================================

/// AI 代理统一接口
///
/// 不同 AI 后端（OpenCode、Claude CLI 等）实现此 trait，
/// handler 层通过 trait 对象调用，不感知具体后端。
#[async_trait]
pub trait AiAgent: Send + Sync {
    /// 启动代理后端（如启动子进程、建立连接）
    async fn start(&self) -> Result<(), String>;

    /// 停止代理后端
    async fn stop(&self) -> Result<(), String>;

    /// 创建会话
    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String>;

    /// 发送消息，返回通用事件流
    async fn send_message(
        &self,
        directory: &str,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
    ) -> Result<AiEventStream, String>;

    /// 列出会话
    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String>;

    /// 删除会话
    async fn delete_session(&self, directory: &str, session_id: &str) -> Result<(), String>;

    /// 拉取会话历史消息
    async fn list_messages(
        &self,
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String>;

    /// 中止会话当前生成（若后端支持）
    async fn abort_session(&self, directory: &str, session_id: &str) -> Result<(), String>;

    /// 释放某个 directory 的 instance 资源（节省占用）
    async fn dispose_instance(&self, directory: &str) -> Result<(), String>;
}
