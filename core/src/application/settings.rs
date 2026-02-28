use crate::server::context::SharedAppState;
use crate::server::protocol::{
    ai::ModelSelection, CustomCommandInfo, EvolutionStageProfileInfo, ServerMessage,
};
use crate::workspace::state::EvolutionStageProfile;

/// 保存客户端设置参数（应用层输入模型）
pub struct SaveClientSettingsParams {
    pub custom_commands: Vec<CustomCommandInfo>,
    pub workspace_shortcuts: std::collections::HashMap<String, String>,
    pub commit_ai_agent: Option<String>,
    pub merge_ai_agent: Option<String>,
    pub selected_ai_agent: Option<String>,
    pub fixed_port: Option<u16>,
    pub app_language: Option<String>,
    pub remote_access_enabled: Option<bool>,
}

/// 读取客户端设置并转换为协议响应消息。
pub async fn get_client_settings_message(app_state: &SharedAppState) -> ServerMessage {
    let state = app_state.read().await;
    let commands: Vec<CustomCommandInfo> = state
        .client_settings
        .custom_commands
        .iter()
        .map(|c| CustomCommandInfo {
            id: c.id.clone(),
            name: c.name.clone(),
            icon: c.icon.clone(),
            command: c.command.clone(),
        })
        .collect();
    let evolution_agent_profiles = state
        .client_settings
        .evolution_agent_profiles
        .iter()
        .map(|(key, profiles)| (key.clone(), to_protocol_profiles(profiles)))
        .collect();

    ServerMessage::ClientSettingsResult {
        custom_commands: commands,
        workspace_shortcuts: state.client_settings.workspace_shortcuts.clone(),
        commit_ai_agent: state.client_settings.commit_ai_agent.clone(),
        merge_ai_agent: state.client_settings.merge_ai_agent.clone(),
        fixed_port: state.client_settings.fixed_port,
        app_language: state.client_settings.app_language.clone(),
        remote_access_enabled: state.client_settings.remote_access_enabled,
        evolution_agent_profiles,
    }
}

/// 写入客户端设置到应用状态（不触发持久化，调用方决定何时保存）。
pub async fn save_client_settings(app_state: &SharedAppState, params: SaveClientSettingsParams) {
    let mut state = app_state.write().await;
    state.client_settings.custom_commands = params
        .custom_commands
        .iter()
        .map(|c| crate::workspace::state::CustomCommand {
            id: c.id.clone(),
            name: c.name.clone(),
            icon: c.icon.clone(),
            command: c.command.clone(),
        })
        .collect();
    state.client_settings.workspace_shortcuts = params.workspace_shortcuts;

    // 优先使用新字段；若新字段为空则回退兼容旧客户端的 selected_ai_agent
    if params.commit_ai_agent.is_some() || params.merge_ai_agent.is_some() {
        state.client_settings.commit_ai_agent = params.commit_ai_agent;
        state.client_settings.merge_ai_agent = params.merge_ai_agent;
    } else if let Some(old) = params.selected_ai_agent {
        state.client_settings.commit_ai_agent = Some(old.clone());
        state.client_settings.merge_ai_agent = Some(old);
    }

    if let Some(port) = params.fixed_port {
        state.client_settings.fixed_port = port;
    }
    if let Some(lang) = params.app_language {
        state.client_settings.app_language = lang;
    }
    if let Some(enabled) = params.remote_access_enabled {
        state.client_settings.remote_access_enabled = enabled;
    }
}

fn to_protocol_profiles(input: &[EvolutionStageProfile]) -> Vec<EvolutionStageProfileInfo> {
    input
        .iter()
        .map(|profile| EvolutionStageProfileInfo {
            stage: profile.stage.clone(),
            ai_tool: profile.ai_tool.clone(),
            mode: profile.mode.clone(),
            model: profile.model.as_ref().map(|model| ModelSelection {
                provider_id: model.provider_id.clone(),
                model_id: model.model_id.clone(),
            }),
            config_options: profile.config_options.clone(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::context::SharedAppState;
    use crate::workspace::state::AppState;
    use std::collections::HashMap;
    use std::sync::Arc;
    use tokio::sync::RwLock;

    fn empty_params() -> SaveClientSettingsParams {
        SaveClientSettingsParams {
            custom_commands: Vec::new(),
            workspace_shortcuts: HashMap::new(),
            commit_ai_agent: None,
            merge_ai_agent: None,
            selected_ai_agent: None,
            fixed_port: None,
            app_language: None,
            remote_access_enabled: None,
        }
    }

    #[tokio::test]
    async fn save_client_settings_should_apply_basic_fields() {
        let app_state: SharedAppState = Arc::new(RwLock::new(AppState::default()));
        let mut params = empty_params();
        params.fixed_port = Some(48111);
        params.app_language = Some("zh-Hans".to_string());
        params.remote_access_enabled = Some(true);
        params
            .workspace_shortcuts
            .insert("1".to_string(), "demo/default".to_string());

        save_client_settings(&app_state, params).await;

        let state = app_state.read().await;
        assert_eq!(state.client_settings.fixed_port, 48111);
        assert_eq!(state.client_settings.app_language, "zh-Hans");
        assert!(state.client_settings.remote_access_enabled);
        assert_eq!(
            state
                .client_settings
                .workspace_shortcuts
                .get("1")
                .map(|v| v.as_str()),
            Some("demo/default")
        );
    }
}
