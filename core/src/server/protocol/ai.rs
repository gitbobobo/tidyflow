//! AI Chat 协议数据类型（MessagePack v2）
//!
//! 说明：
//! - 本文件仅放置数据结构（DTO），具体消息枚举在 `protocol/mod.rs` 中定义。
//! - AI Chat 采用结构化 message/part 事件流，避免“最后一条气泡拼字符串”导致的串台与收敛问题。

use serde::{Deserialize, Serialize};

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
    /// "text" | "reasoning" | "tool"
    pub part_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_state: Option<serde_json::Value>,
}

/// AI 历史消息（对齐 OpenCode message）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageInfo {
    pub id: String,
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
    pub parts: Vec<PartInfo>,
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

/// 图片附件（base64 编码）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImagePart {
    pub filename: String,
    pub mime: String,
    pub data: String,
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
