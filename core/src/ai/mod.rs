//! AI 代理统一抽象层
//!
//! 定义通用的 AiAgent trait 和事件类型，
//! 不同 AI 后端（OpenCode、Claude CLI 等）实现此 trait。

pub mod client;
pub mod manager;

pub use client::OpenCodeClient;
pub use client::OpenCodeAgent;
pub use manager::OpenCodeManager;

use async_trait::async_trait;
use std::pin::Pin;
use tokio_stream::Stream;

// ============================================================================
// 通用 AI 事件（代理无关）
// ============================================================================

/// AI 流式事件
#[derive(Debug, Clone)]
pub enum AiEvent {
    /// 文本增量
    TextDelta { text: String },
    /// 工具调用
    ToolUse {
        tool: String,
        input: serde_json::Value,
    },
    /// 错误
    Error { message: String },
    /// 流结束
    Done,
}

/// AI 会话信息
#[derive(Debug, Clone)]
pub struct AiSession {
    pub id: String,
    pub title: String,
    pub updated_at: i64,
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
    async fn create_session(&self, title: &str) -> Result<AiSession, String>;

    /// 发送消息，返回通用事件流
    async fn send_message(
        &self,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
    ) -> Result<AiEventStream, String>;

    /// 列出会话
    async fn list_sessions(&self) -> Result<Vec<AiSession>, String>;

    /// 删除会话
    async fn delete_session(&self, session_id: &str) -> Result<(), String>;
}
