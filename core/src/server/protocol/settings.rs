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
        merge_ai_agent: Option<String>,
        #[serde(default)]
        fixed_port: Option<u16>,
        #[serde(default)]
        remote_access_enabled: Option<bool>,
        #[serde(default)]
        workspace_todos: Option<std::collections::HashMap<String, Vec<super::WorkspaceTodoInfo>>>,
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
        merge_ai_agent: Option<String>,
        fixed_port: u16,
        remote_access_enabled: bool,
        #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
        evolution_agent_profiles:
            std::collections::HashMap<String, Vec<super::EvolutionStageProfileInfo>>,
        #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
        workspace_todos: std::collections::HashMap<String, Vec<super::WorkspaceTodoInfo>>,
    },
    ClientSettingsSaved {
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
}
