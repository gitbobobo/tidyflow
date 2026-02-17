//! AI 代理统一抽象层
//!
//! 定义通用的 AiAgent trait 和事件类型，
//! 不同 AI 后端（OpenCode、Claude CLI 等）实现此 trait。

pub mod client;
pub mod codex_adapter;
pub mod codex_client;
pub mod codex_manager;
pub mod event_hub;
pub mod manager;

pub use codex_adapter::CodexAppServerAgent;
pub use codex_manager::CodexAppServerManager;
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
    PartUpdated { message_id: String, part: AiPart },
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
    /// question.asked：请求用户选择
    QuestionAsked { request: AiQuestionRequest },
    /// question.replied / question.rejected：清理 pending 请求
    QuestionCleared {
        session_id: String,
        request_id: String,
    },
    /// 流结束
    Done,
}

/// AI Part（通用模型，直接对应 OpenCode 的 part）
#[derive(Debug, Clone)]
pub struct AiPart {
    pub id: String,
    /// "text" | "reasoning" | "tool" | "file"
    pub part_type: String,
    /// text/reasoning 的内容（全量）
    pub text: Option<String>,
    /// file part 的 MIME（若为 file）
    pub mime: Option<String>,
    /// file part 的文件名（若为 file）
    pub filename: Option<String>,
    /// file part 的 URL（若为 file）
    pub url: Option<String>,
    /// text part 的 synthetic 标记（若有）
    pub synthetic: Option<bool>,
    /// text part 的 ignored 标记（若有）
    pub ignored: Option<bool>,
    /// part source（JSON 透传）
    pub source: Option<serde_json::Value>,
    /// tool 名（若为 tool）
    pub tool_name: Option<String>,
    /// tool 调用 ID（若为 tool）
    pub tool_call_id: Option<String>,
    /// tool 的状态/state（JSON 透传）
    pub tool_state: Option<serde_json::Value>,
    /// tool part 上的 metadata（JSON 透传）
    pub tool_part_metadata: Option<serde_json::Value>,
}

/// Question 选项
#[derive(Debug, Clone)]
pub struct AiQuestionOption {
    pub label: String,
    pub description: String,
}

/// Question 条目
#[derive(Debug, Clone)]
pub struct AiQuestionInfo {
    pub question: String,
    pub header: String,
    pub options: Vec<AiQuestionOption>,
    pub multiple: bool,
    pub custom: bool,
}

/// Question 请求（与工具调用绑定）
#[derive(Debug, Clone)]
pub struct AiQuestionRequest {
    pub id: String,
    pub session_id: String,
    pub questions: Vec<AiQuestionInfo>,
    pub tool_message_id: Option<String>,
    pub tool_call_id: Option<String>,
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

/// AI 图片附件（二进制）
#[derive(Debug, Clone)]
pub struct AiImagePart {
    pub filename: String,
    pub mime: String,
    pub data: Vec<u8>,
}

/// AI 模型选择
#[derive(Debug, Clone)]
pub struct AiModelSelection {
    pub provider_id: String,
    pub model_id: String,
}

/// AI Provider 信息（通用模型）
#[derive(Debug, Clone)]
pub struct AiProviderInfo {
    pub id: String,
    pub name: String,
    pub models: Vec<AiModelInfo>,
}

/// AI 模型信息（通用模型）
#[derive(Debug, Clone)]
pub struct AiModelInfo {
    pub id: String,
    pub name: String,
    pub provider_id: String,
    pub supports_image_input: bool,
}

/// AI Agent 信息（通用模型）
#[derive(Debug, Clone)]
pub struct AiAgentInfo {
    pub name: String,
    pub description: Option<String>,
    pub mode: Option<String>,
    pub color: Option<String>,
    /// agent 默认 provider ID
    pub default_provider_id: Option<String>,
    /// agent 默认 model ID
    pub default_model_id: Option<String>,
}

/// AI 斜杠命令（用于输入框自动补全）
#[derive(Debug, Clone)]
pub struct AiSlashCommand {
    /// 命令名（不含 `/`）
    pub name: String,
    /// 命令描述
    pub description: String,
    /// 执行方式："client" | "agent"
    pub action: String,
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
        image_parts: Option<Vec<AiImagePart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
    ) -> Result<AiEventStream, String>;

    /// 发送斜杠命令（默认回退为普通文本消息）
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
        let command = command.trim();
        let arguments = arguments.trim();
        let message = if arguments.is_empty() {
            format!("/{}", command)
        } else {
            format!("/{} {}", command, arguments)
        };
        self.send_message(
            directory,
            session_id,
            &message,
            file_refs,
            image_parts,
            model,
            agent,
        )
        .await
    }

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

    /// 获取 provider/模型列表（默认返回空）
    async fn list_providers(&self, _directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        Ok(vec![])
    }

    /// 获取 agent 列表（默认返回空）
    async fn list_agents(&self, _directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        Ok(vec![])
    }

    /// 获取斜杠命令列表（默认返回空）
    async fn list_slash_commands(&self, _directory: &str) -> Result<Vec<AiSlashCommand>, String> {
        Ok(vec![])
    }

    /// 回复 question 请求（answers 与 questions 顺序一致）
    async fn reply_question(
        &self,
        _directory: &str,
        _request_id: &str,
        _answers: Vec<Vec<String>>,
    ) -> Result<(), String> {
        Err("Question reply is not supported by current AI backend".to_string())
    }

    /// 拒绝 question 请求
    async fn reject_question(&self, _directory: &str, _request_id: &str) -> Result<(), String> {
        Err("Question reject is not supported by current AI backend".to_string())
    }
}
