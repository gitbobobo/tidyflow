use crate::server::context::SharedAppState;
use crate::server::protocol::{
    ai::ModelSelection, CustomCommandInfo, EvolutionImplementAgentProfileInfo,
    EvolutionImplementAgentProfilesInfo, EvolutionStageProfileInfo, ServerMessage,
};
use crate::workspace::state::{
    EvolutionImplementAgentProfile, EvolutionImplementAgentProfiles, EvolutionStageProfile,
};

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
    pub evolution_implement_agent_profiles: Option<EvolutionImplementAgentProfilesInfo>,
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
    let evolution_implement_agent_profiles = to_protocol_implement_profiles(
        &state.client_settings.evolution_implement_agent_profiles,
    );

    ServerMessage::ClientSettingsResult {
        custom_commands: commands,
        workspace_shortcuts: state.client_settings.workspace_shortcuts.clone(),
        commit_ai_agent: state.client_settings.commit_ai_agent.clone(),
        merge_ai_agent: state.client_settings.merge_ai_agent.clone(),
        fixed_port: state.client_settings.fixed_port,
        app_language: state.client_settings.app_language.clone(),
        remote_access_enabled: state.client_settings.remote_access_enabled,
        evolution_agent_profiles,
        evolution_implement_agent_profiles,
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
    if let Some(profiles) = params.evolution_implement_agent_profiles {
        state.client_settings.evolution_implement_agent_profiles =
            from_protocol_implement_profiles(profiles);
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

fn to_protocol_implement_profile(
    input: &EvolutionImplementAgentProfile,
) -> EvolutionImplementAgentProfileInfo {
    EvolutionImplementAgentProfileInfo {
        ai_tool: input.ai_tool.clone(),
        mode: input.mode.clone(),
        model: input.model.as_ref().map(|model| ModelSelection {
            provider_id: model.provider_id.clone(),
            model_id: model.model_id.clone(),
        }),
        config_options: input.config_options.clone(),
    }
}

fn to_protocol_implement_profiles(
    input: &EvolutionImplementAgentProfiles,
) -> EvolutionImplementAgentProfilesInfo {
    EvolutionImplementAgentProfilesInfo {
        general: to_protocol_implement_profile(&input.general),
        visual: to_protocol_implement_profile(&input.visual),
        advanced: to_protocol_implement_profile(&input.advanced),
    }
}

fn from_protocol_implement_profile(
    input: EvolutionImplementAgentProfileInfo,
) -> EvolutionImplementAgentProfile {
    EvolutionImplementAgentProfile {
        ai_tool: input.ai_tool,
        mode: input.mode,
        model: input.model.map(|model| crate::workspace::state::EvolutionModelSelection {
            provider_id: model.provider_id,
            model_id: model.model_id,
        }),
        config_options: input.config_options,
    }
}

fn from_protocol_implement_profiles(
    input: EvolutionImplementAgentProfilesInfo,
) -> EvolutionImplementAgentProfiles {
    EvolutionImplementAgentProfiles {
        general: from_protocol_implement_profile(input.general),
        visual: from_protocol_implement_profile(input.visual),
        advanced: from_protocol_implement_profile(input.advanced),
    }
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
            evolution_implement_agent_profiles: None,
        }
    }

    #[tokio::test]
    async fn save_client_settings_should_not_override_implement_profiles_when_field_missing() {
        let app_state: SharedAppState = Arc::new(RwLock::new(AppState::default()));
        {
            let mut state = app_state.write().await;
            state
                .client_settings
                .evolution_implement_agent_profiles
                .advanced
                .ai_tool = "opencode".to_string();
        }

        save_client_settings(&app_state, empty_params()).await;

        let state = app_state.read().await;
        assert_eq!(
            state
                .client_settings
                .evolution_implement_agent_profiles
                .advanced
                .ai_tool,
            "opencode"
        );
    }

    #[tokio::test]
    async fn save_client_settings_should_persist_implement_profiles_when_provided() {
        let app_state: SharedAppState = Arc::new(RwLock::new(AppState::default()));
        let mut params = empty_params();
        params.evolution_implement_agent_profiles = Some(EvolutionImplementAgentProfilesInfo {
            general: EvolutionImplementAgentProfileInfo {
                ai_tool: "codex".to_string(),
                mode: Some("primary".to_string()),
                model: Some(ModelSelection {
                    provider_id: "openai".to_string(),
                    model_id: "gpt-5".to_string(),
                }),
                config_options: HashMap::new(),
            },
            visual: EvolutionImplementAgentProfileInfo {
                ai_tool: "opencode".to_string(),
                mode: None,
                model: None,
                config_options: HashMap::new(),
            },
            advanced: EvolutionImplementAgentProfileInfo {
                ai_tool: "copilot".to_string(),
                mode: None,
                model: None,
                config_options: HashMap::new(),
            },
        });

        save_client_settings(&app_state, params).await;

        let state = app_state.read().await;
        let saved = &state.client_settings.evolution_implement_agent_profiles;
        assert_eq!(saved.general.ai_tool, "codex");
        assert_eq!(saved.general.mode.as_deref(), Some("primary"));
        assert_eq!(
            saved.general.model.as_ref().map(|m| m.provider_id.as_str()),
            Some("openai")
        );
        assert_eq!(saved.visual.ai_tool, "opencode");
        assert_eq!(saved.advanced.ai_tool, "copilot");
    }
}
