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
}
