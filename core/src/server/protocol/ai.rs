//! AI Chat 协议数据类型（MessagePack v2）
//!
//! 说明：
//! - 本文件仅放置数据结构（DTO），具体消息枚举在 `protocol/mod.rs` 中定义。
//! - AI Chat 采用结构化 message/part 事件流，避免“最后一条气泡拼字符串”导致的串台与收敛问题。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// AI 会话状态信息（用于协议传输）
///
/// 状态值（v2，用于标签栏可感知化）：
/// - "idle": 空闲，无任务执行
/// - "running": 正在执行任务
/// - "awaiting_input": 等待用户输入（如 question tool）
/// - "success": 任务执行成功
/// - "failure": 任务执行失败
/// - "cancelled": 任务被取消
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSessionStatusInfo {
    /// 状态字符串："idle" | "running" | "awaiting_input" | "success" | "failure" | "cancelled"
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_remaining_percent: Option<f64>,
}

/// 查询 AI 会话状态请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSessionStatusRequest {
    pub project_name: String,
    pub workspace_name: String,
    pub ai_tool: String,
    pub session_id: String,
}

/// 查询 AI 会话状态响应
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSessionStatusResult {
    pub project_name: String,
    pub workspace_name: String,
    pub ai_tool: String,
    pub session_id: String,
    pub status: AiSessionStatusInfo,
}

/// AI 会话状态变更推送事件
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSessionStatusUpdate {
    pub project_name: String,
    pub workspace_name: String,
    pub ai_tool: String,
    pub session_id: String,
    pub status: AiSessionStatusInfo,
}

/// AI 会话信息（归属到某个 project/workspace）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub project_name: String,
    pub workspace_name: String,
    pub id: String,
    pub title: String,
    /// 毫秒时间戳
    pub updated_at: i64,
}

/// AI Part（对齐 OpenCode part，tool_state 透传 JSON）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PartInfo {
    pub id: String,
    /// "text" | "reasoning" | "tool" | "file" | "plan"
    pub part_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub synthetic: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ignored: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// OpenCode tool callID（若为 tool）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// ACP tool-calls kind（若为 tool）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_kind: Option<String>,
    /// ACP tool-calls title（若为 tool）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_title: Option<String>,
    /// ACP tool-calls rawInput（若为 tool）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_raw_input: Option<serde_json::Value>,
    /// ACP tool-calls rawOutput（若为 tool）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_raw_output: Option<serde_json::Value>,
    /// ACP tool-calls locations（若为 tool）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_locations: Option<Vec<ToolCallLocationInfo>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_state: Option<serde_json::Value>,
    /// OpenCode tool part metadata（若为 tool）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_part_metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCallLocationInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uri: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_column: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

/// AI 历史消息（对齐 OpenCode message）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageInfo {
    pub id: String,
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_provider_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_id: Option<String>,
    pub parts: Vec<PartInfo>,
}

/// AI 会话缓存增量操作（用于 ai_session_messages_update 的 ops 模式）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AiSessionCacheOpInfo {
    MessageUpdated {
        message_id: String,
        role: String,
    },
    PartUpdated {
        message_id: String,
        part: PartInfo,
    },
    PartDelta {
        message_id: String,
        part_id: String,
        part_type: String,
        field: String,
        delta: String,
    },
}

/// 历史会话最近一次输入选择提示（用于前端恢复输入框的 model/agent）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSelectionHint {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_provider_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config_options: Option<HashMap<String, serde_json::Value>>,
}

/// 会话配置项候选值
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionConfigOptionChoice {
    pub value: serde_json::Value,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// 会话配置项候选值分组
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionConfigOptionGroup {
    pub label: String,
    pub options: Vec<SessionConfigOptionChoice>,
}

/// 会话配置项
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionConfigOptionInfo {
    pub option_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_value: Option<serde_json::Value>,
    #[serde(default)]
    pub options: Vec<SessionConfigOptionChoice>,
    #[serde(default)]
    pub option_groups: Vec<SessionConfigOptionGroup>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw: Option<serde_json::Value>,
}

/// AI Provider 信息（模型列表按 provider 分组）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderInfo {
    pub id: String,
    pub name: String,
    pub models: Vec<ModelInfo>,
}

/// AI 模型信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub provider_id: String,
    #[serde(default)]
    pub supports_image_input: bool,
}

/// AI Agent 信息（动态获取的 agent 列表）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentInfo {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// "primary" | "subagent" | "all"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// agent 默认 provider ID
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_provider_id: Option<String>,
    /// agent 默认 model ID
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_model_id: Option<String>,
}

/// 图片附件（二进制）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImagePart {
    pub filename: String,
    pub mime: String,
    #[serde(with = "serde_bytes")]
    pub data: Vec<u8>,
}

/// 音频附件（二进制）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioPart {
    pub filename: String,
    pub mime: String,
    #[serde(with = "serde_bytes")]
    pub data: Vec<u8>,
}

/// 模型选择
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelSelection {
    pub provider_id: String,
    pub model_id: String,
}

/// AI 斜杠命令信息（由后端动态返回）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlashCommandInfo {
    /// 命令名（不含 `/` 前缀），如 "clear"
    pub name: String,
    /// 命令描述
    pub description: String,
    /// 命令执行方式："client"（前端本地执行）| "agent"（发送给 AI 代理）
    pub action: String,
    /// 输入提示（可选），用于补全时插入参数模板
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_hint: Option<String>,
}

/// Question 选项
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionOptionInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub option_id: Option<String>,
    pub label: String,
    pub description: String,
}

/// Question 条目
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionInfo {
    pub question: String,
    pub header: String,
    pub options: Vec<QuestionOptionInfo>,
    #[serde(default)]
    pub multiple: bool,
    #[serde(default = "default_question_custom")]
    pub custom: bool,
}

/// Question 请求（与工具调用绑定）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionRequestInfo {
    pub id: String,
    pub session_id: String,
    pub questions: Vec<QuestionInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_message_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

fn default_question_custom() -> bool {
    true
}

// ============================================================================
// AI 代码补全协议（Code Completion）
// ============================================================================

/// 代码补全支持的编程语言
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CodeCompletionLanguage {
    Swift,
    Rust,
    JavaScript,
    TypeScript,
    Python,
    Go,
    /// 其余语言或未知语言
    #[serde(other)]
    Other,
}

impl CodeCompletionLanguage {
    /// 从文件扩展名推断语言
    pub fn from_extension(ext: &str) -> Self {
        match ext.to_lowercase().as_str() {
            "swift" => Self::Swift,
            "rs" => Self::Rust,
            "js" | "jsx" | "mjs" | "cjs" => Self::JavaScript,
            "ts" | "tsx" | "mts" | "cts" => Self::TypeScript,
            "py" | "pyw" => Self::Python,
            "go" => Self::Go,
            _ => Self::Other,
        }
    }

    /// 返回语言的显示名称
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Swift => "Swift",
            Self::Rust => "Rust",
            Self::JavaScript => "JavaScript",
            Self::TypeScript => "TypeScript",
            Self::Python => "Python",
            Self::Go => "Go",
            Self::Other => "Unknown",
        }
    }
}

/// 代码补全请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodeCompletionRequest {
    /// 客户端生成的请求 ID（用于取消和关联响应）
    pub request_id: String,
    /// 代码语言
    pub language: CodeCompletionLanguage,
    /// 当前文件的完整内容（可选，用于上下文）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_content: Option<String>,
    /// 光标前的文本内容（上文）
    pub prefix: String,
    /// 光标后的文本内容（下文）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suffix: Option<String>,
    /// 文件路径（可选，提供语言上下文）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
    /// 光标行号（0-indexed）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_line: Option<u32>,
    /// 光标列号（0-indexed）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_column: Option<u32>,
    /// 触发方式："auto"（输入停顿）| "manual"（快捷键）
    #[serde(default = "default_trigger_kind")]
    pub trigger_kind: String,
}

fn default_trigger_kind() -> String {
    "auto".to_string()
}

// ============================================================================
// 平铺 AI 会话消息缓存（Flattened AI Session Cache）
// ============================================================================

/// 平铺消息语义类型，覆盖五类 AI 聊天消息
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FlattenedAiMessageKind {
    /// 用户输入消息
    User,
    /// 助手文本/推理回复
    Assistant,
    /// 工具调用请求（tool call）
    ToolCall,
    /// 工具调用结果（tool result）
    ToolResult,
    /// 系统提示消息
    System,
}

/// 平铺 AI 消息结构，单层，不嵌套，覆盖五类消息语义
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlattenedAiMessage {
    /// 消息/part 唯一 ID
    pub id: String,
    /// 所属会话 ID（稳定索引键）
    pub session_id: String,
    /// 消息语义类型
    pub kind: FlattenedAiMessageKind,
    /// 文本内容（user/assistant/system 时有效）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    /// 工具名称（tool_call/tool_result 时有效）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// 工具调用 ID（tool_call/tool_result 关联键）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// 创建时间戳（毫秒）
    pub created_at: i64,
}

/// AI 会话平铺消息缓存，按 session_id 索引，revision 单调递增可重复消费
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AiSessionFlatCache {
    /// 会话 ID（稳定索引键）
    pub session_id: String,
    /// 缓存修订号，每次追加消息时单调递增
    pub revision: u64,
    /// 平铺后的消息列表
    pub messages: Vec<FlattenedAiMessage>,
}

impl AiSessionFlatCache {
    pub fn new(session_id: String) -> Self {
        Self {
            session_id,
            revision: 0,
            messages: Vec::new(),
        }
    }

    /// 追加一条平铺消息，revision 单调递增
    pub fn append(&mut self, message: FlattenedAiMessage) {
        self.revision += 1;
        self.messages.push(message);
    }

    /// 从 MessageInfo 列表构建平铺缓存（将嵌套 message/part 展开为单层）
    pub fn from_message_infos(session_id: String, messages: &[MessageInfo]) -> Self {
        let mut cache = Self::new(session_id.clone());
        for msg in messages {
            let base_kind = match msg.role.as_str() {
                "user" => FlattenedAiMessageKind::User,
                "system" => FlattenedAiMessageKind::System,
                _ => FlattenedAiMessageKind::Assistant,
            };
            let created_at = msg.created_at.unwrap_or(0);
            for part in &msg.parts {
                let (kind, tool_name, tool_call_id) = match part.part_type.as_str() {
                    "tool" => (
                        FlattenedAiMessageKind::ToolCall,
                        part.tool_name.clone(),
                        part.tool_call_id.clone(),
                    ),
                    _ => (base_kind.clone(), None, None),
                };
                cache.append(FlattenedAiMessage {
                    id: part.id.clone(),
                    session_id: session_id.clone(),
                    kind,
                    content: part.text.clone(),
                    tool_name,
                    tool_call_id,
                    created_at,
                });
            }
        }
        cache
    }

    /// 按修订号判断是否可接受（单调检查，拒绝回滚）
    pub fn can_apply_revision(&self, incoming_revision: u64) -> bool {
        incoming_revision >= self.revision
    }
}

/// 流式补全分片（服务端推送）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodeCompletionChunk {
    /// 对应请求 ID
    pub request_id: String,
    /// 本次分片内容（增量）
    pub delta: String,
    /// 是否为最终分片
    #[serde(default)]
    pub is_final: bool,
}

/// 补全完成响应
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodeCompletionResponse {
    /// 对应请求 ID
    pub request_id: String,
    /// 最终完整建议文本
    pub completion_text: String,
    /// 停止原因："done" | "cancelled" | "error"
    pub stop_reason: String,
    /// 错误信息（仅 stop_reason="error" 时有值）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_info_roundtrip() {
        let s = SessionInfo {
            project_name: "p".to_string(),
            workspace_name: "w".to_string(),
            id: "s1".to_string(),
            title: "t".to_string(),
            updated_at: 123,
        };
        let json = serde_json::to_string(&s).unwrap();
        let parsed: SessionInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.project_name, "p");
        assert_eq!(parsed.workspace_name, "w");
        assert_eq!(parsed.id, "s1");
    }

    #[test]
    fn test_code_completion_language_from_extension() {
        assert_eq!(CodeCompletionLanguage::from_extension("swift"), CodeCompletionLanguage::Swift);
        assert_eq!(CodeCompletionLanguage::from_extension("rs"), CodeCompletionLanguage::Rust);
        assert_eq!(CodeCompletionLanguage::from_extension("js"), CodeCompletionLanguage::JavaScript);
        assert_eq!(CodeCompletionLanguage::from_extension("ts"), CodeCompletionLanguage::TypeScript);
        assert_eq!(CodeCompletionLanguage::from_extension("tsx"), CodeCompletionLanguage::TypeScript);
        assert_eq!(CodeCompletionLanguage::from_extension("py"), CodeCompletionLanguage::Python);
        assert_eq!(CodeCompletionLanguage::from_extension("go"), CodeCompletionLanguage::Go);
        assert_eq!(CodeCompletionLanguage::from_extension("rb"), CodeCompletionLanguage::Other);
    }

    #[test]
    fn test_code_completion_request_roundtrip() {
        let req = CodeCompletionRequest {
            request_id: "req-1".to_string(),
            language: CodeCompletionLanguage::Rust,
            file_content: None,
            prefix: "fn main() {".to_string(),
            suffix: Some("}".to_string()),
            file_path: Some("src/main.rs".to_string()),
            cursor_line: Some(0),
            cursor_column: Some(11),
            trigger_kind: "manual".to_string(),
        };
        let json = serde_json::to_string(&req).unwrap();
        let parsed: CodeCompletionRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.request_id, "req-1");
        assert_eq!(parsed.language, CodeCompletionLanguage::Rust);
        assert_eq!(parsed.prefix, "fn main() {");
    }

    #[test]
    fn test_code_completion_chunk_roundtrip() {
        let chunk = CodeCompletionChunk {
            request_id: "req-1".to_string(),
            delta: "\n    println!(\"Hello, world!\");".to_string(),
            is_final: false,
        };
        let json = serde_json::to_string(&chunk).unwrap();
        let parsed: CodeCompletionChunk = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.request_id, "req-1");
        assert!(!parsed.is_final);
    }

    // ========================================================================
    // 平铺 AI 会话消息缓存回归测试（flattened_ai_session）
    // ========================================================================

    #[test]
    fn flattened_ai_session_new_cache_starts_with_zero_revision() {
        let cache = AiSessionFlatCache::new("session-1".to_string());
        assert_eq!(cache.session_id, "session-1");
        assert_eq!(cache.revision, 0);
        assert!(cache.messages.is_empty());
    }

    #[test]
    fn flattened_ai_session_append_increments_revision_monotonically() {
        let mut cache = AiSessionFlatCache::new("s1".to_string());
        cache.append(FlattenedAiMessage {
            id: "m1".to_string(),
            session_id: "s1".to_string(),
            kind: FlattenedAiMessageKind::User,
            content: Some("hello".to_string()),
            tool_name: None,
            tool_call_id: None,
            created_at: 1000,
        });
        assert_eq!(cache.revision, 1);
        cache.append(FlattenedAiMessage {
            id: "m2".to_string(),
            session_id: "s1".to_string(),
            kind: FlattenedAiMessageKind::Assistant,
            content: Some("hi there".to_string()),
            tool_name: None,
            tool_call_id: None,
            created_at: 2000,
        });
        assert_eq!(cache.revision, 2);
        assert_eq!(cache.messages.len(), 2);
    }

    #[test]
    fn flattened_ai_session_from_message_infos_covers_five_kinds() {
        let messages = vec![
            MessageInfo {
                id: "msg-user".to_string(),
                role: "user".to_string(),
                created_at: Some(1000),
                agent: None,
                model_provider_id: None,
                model_id: None,
                parts: vec![PartInfo {
                    id: "p-user".to_string(),
                    part_type: "text".to_string(),
                    text: Some("what does this do?".to_string()),
                    tool_name: None,
                    tool_call_id: None,
                    tool_kind: None,
                    tool_title: None,
                    tool_raw_input: None,
                    tool_raw_output: None,
                    tool_locations: None,
                    tool_state: None,
                    tool_part_metadata: None,
                    mime: None,
                    filename: None,
                    url: None,
                    synthetic: None,
                    ignored: None,
                    source: None,
                }],
            },
            MessageInfo {
                id: "msg-assistant".to_string(),
                role: "assistant".to_string(),
                created_at: Some(2000),
                agent: None,
                model_provider_id: None,
                model_id: None,
                parts: vec![
                    PartInfo {
                        id: "p-tool-call".to_string(),
                        part_type: "tool".to_string(),
                        text: None,
                        tool_name: Some("bash".to_string()),
                        tool_call_id: Some("call-1".to_string()),
                        tool_kind: None,
                        tool_title: None,
                        tool_raw_input: None,
                        tool_raw_output: None,
                        tool_locations: None,
                        tool_state: None,
                        tool_part_metadata: None,
                        mime: None,
                        filename: None,
                        url: None,
                        synthetic: None,
                        ignored: None,
                        source: None,
                    },
                    PartInfo {
                        id: "p-assistant-text".to_string(),
                        part_type: "text".to_string(),
                        text: Some("done".to_string()),
                        tool_name: None,
                        tool_call_id: None,
                        tool_kind: None,
                        tool_title: None,
                        tool_raw_input: None,
                        tool_raw_output: None,
                        tool_locations: None,
                        tool_state: None,
                        tool_part_metadata: None,
                        mime: None,
                        filename: None,
                        url: None,
                        synthetic: None,
                        ignored: None,
                        source: None,
                    },
                ],
            },
        ];

        let cache = AiSessionFlatCache::from_message_infos("s1".to_string(), &messages);
        assert_eq!(cache.session_id, "s1");
        // user text part + tool part + assistant text part = 3 flat messages
        assert_eq!(cache.messages.len(), 3);
        assert_eq!(cache.messages[0].kind, FlattenedAiMessageKind::User);
        assert_eq!(cache.messages[0].content.as_deref(), Some("what does this do?"));
        assert_eq!(cache.messages[1].kind, FlattenedAiMessageKind::ToolCall);
        assert_eq!(cache.messages[1].tool_name.as_deref(), Some("bash"));
        assert_eq!(cache.messages[1].tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(cache.messages[2].kind, FlattenedAiMessageKind::Assistant);
        assert_eq!(cache.messages[2].content.as_deref(), Some("done"));
    }

    #[test]
    fn flattened_ai_session_revision_rejects_rollback() {
        let mut cache = AiSessionFlatCache::new("s1".to_string());
        cache.append(FlattenedAiMessage {
            id: "m1".to_string(),
            session_id: "s1".to_string(),
            kind: FlattenedAiMessageKind::User,
            content: Some("q".to_string()),
            tool_name: None,
            tool_call_id: None,
            created_at: 0,
        });
        // revision is now 1
        assert!(cache.can_apply_revision(1));
        assert!(cache.can_apply_revision(2));
        assert!(!cache.can_apply_revision(0)); // 旧 revision 应被拒绝
    }

    #[test]
    fn flattened_ai_session_roundtrip_serialization() {
        let mut cache = AiSessionFlatCache::new("s42".to_string());
        cache.append(FlattenedAiMessage {
            id: "flat-1".to_string(),
            session_id: "s42".to_string(),
            kind: FlattenedAiMessageKind::System,
            content: Some("you are a helpful assistant".to_string()),
            tool_name: None,
            tool_call_id: None,
            created_at: 999,
        });
        let json = serde_json::to_string(&cache).unwrap();
        let parsed: AiSessionFlatCache = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.session_id, "s42");
        assert_eq!(parsed.revision, 1);
        assert_eq!(parsed.messages[0].kind, FlattenedAiMessageKind::System);
        assert_eq!(parsed.messages[0].content.as_deref(), Some("you are a helpful assistant"));
    }

    #[test]
    fn flattened_ai_session_system_role_maps_to_system_kind() {
        let messages = vec![MessageInfo {
            id: "sys-msg".to_string(),
            role: "system".to_string(),
            created_at: Some(0),
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: vec![PartInfo {
                id: "sys-part".to_string(),
                part_type: "text".to_string(),
                text: Some("you are a coder".to_string()),
                tool_name: None,
                tool_call_id: None,
                tool_kind: None,
                tool_title: None,
                tool_raw_input: None,
                tool_raw_output: None,
                tool_locations: None,
                tool_state: None,
                tool_part_metadata: None,
                mime: None,
                filename: None,
                url: None,
                synthetic: None,
                ignored: None,
                source: None,
            }],
        }];
        let cache = AiSessionFlatCache::from_message_infos("s1".to_string(), &messages);
        assert_eq!(cache.messages.len(), 1);
        assert_eq!(cache.messages[0].kind, FlattenedAiMessageKind::System);
    }
}
