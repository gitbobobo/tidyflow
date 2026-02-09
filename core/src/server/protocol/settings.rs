//! 设置领域协议类型

use serde::{Deserialize, Serialize};

/// 设置相关的客户端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SettingsRequest {
    GetClientSettings,
    SaveClientSettings {
        custom_commands: Vec<super::CustomCommandInfo>,
        #[serde(default)]
        workspace_shortcuts: std::collections::HashMap<String, String>,
        #[serde(default)]
        commit_ai_agent: Option<String>,
        #[serde(default)]
        merge_ai_agent: Option<String>,
        #[serde(default)]
        selected_ai_agent: Option<String>,
    },
}

/// 设置相关的服务端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SettingsResponse {
    ClientSettingsResult {
        custom_commands: Vec<super::CustomCommandInfo>,
        workspace_shortcuts: std::collections::HashMap<String, String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        commit_ai_agent: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        merge_ai_agent: Option<String>,
    },
    ClientSettingsSaved {
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
}
