use crate::server::context::SharedAppState;
use crate::server::protocol::{
    ai::ModelSelection, CustomCommandInfo, EvolutionStageProfileInfo, KeybindingConfigInfo,
    ServerMessage, WorkspaceTodoInfo,
};
use crate::workspace::state::{EvolutionStageProfile, KeybindingConfig, WorkspaceTodoItem};

/// 保存客户端设置参数（应用层输入模型）
pub struct SaveClientSettingsParams {
    pub custom_commands: Vec<CustomCommandInfo>,
    pub workspace_shortcuts: std::collections::HashMap<String, String>,
    pub merge_ai_agent: Option<String>,
    pub fixed_port: Option<u16>,
    pub remote_access_enabled: Option<bool>,
    /// None: 保持现值；Some: 覆盖全局 Evolution 默认配置。
    pub evolution_default_profiles: Option<Vec<EvolutionStageProfileInfo>>,
    /// None: 保持现值；Some: 覆盖整个 workspace_todos。
    pub workspace_todos: Option<std::collections::HashMap<String, Vec<WorkspaceTodoInfo>>>,
    /// None: 保持现值；Some: 覆盖全部快捷键绑定。
    pub keybindings: Option<Vec<KeybindingConfigInfo>>,
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
    let workspace_todos = state
        .client_settings
        .workspace_todos
        .iter()
        .map(|(key, items)| (key.clone(), to_protocol_todos(items)))
        .collect();
    let keybindings = state
        .client_settings
        .keybindings
        .iter()
        .map(|kb| KeybindingConfigInfo {
            command_id: kb.command_id.clone(),
            key_combination: kb.key_combination.clone(),
            context: kb.context.clone(),
        })
        .collect();

    ServerMessage::ClientSettingsResult {
        custom_commands: commands,
        workspace_shortcuts: state.client_settings.workspace_shortcuts.clone(),
        merge_ai_agent: state.client_settings.merge_ai_agent.clone(),
        fixed_port: state.client_settings.fixed_port,
        remote_access_enabled: state.client_settings.remote_access_enabled,
        evolution_default_profiles: to_protocol_profiles(&state.client_settings.evolution_default_profiles),
        evolution_agent_profiles,
        workspace_todos,
        keybindings,
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
    state.client_settings.merge_ai_agent = params.merge_ai_agent;

    if let Some(port) = params.fixed_port {
        state.client_settings.fixed_port = port;
    }
    if let Some(enabled) = params.remote_access_enabled {
        state.client_settings.remote_access_enabled = enabled;
    }
    if let Some(profiles) = params.evolution_default_profiles {
        state.client_settings.evolution_default_profiles = from_protocol_profiles(profiles);
    }
    if let Some(workspace_todos) = params.workspace_todos {
        state.client_settings.workspace_todos = workspace_todos
            .into_iter()
            .map(|(workspace_key, items)| (workspace_key, from_protocol_todos(items)))
            .collect();
    }
    if let Some(kbs) = params.keybindings {
        state.client_settings.keybindings = kbs
            .into_iter()
            .map(|kb| KeybindingConfig {
                command_id: kb.command_id,
                key_combination: kb.key_combination,
                context: kb.context,
            })
            .collect();
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

fn to_protocol_todos(input: &[WorkspaceTodoItem]) -> Vec<WorkspaceTodoInfo> {
    input
        .iter()
        .map(|item| WorkspaceTodoInfo {
            id: item.id.clone(),
            title: item.title.clone(),
            note: item.note.clone(),
            status: item.status.clone(),
            order: item.order,
            created_at_ms: item.created_at_ms,
            updated_at_ms: item.updated_at_ms,
        })
        .collect()
}

fn from_protocol_profiles(input: Vec<EvolutionStageProfileInfo>) -> Vec<EvolutionStageProfile> {
    input
        .into_iter()
        .map(|profile| EvolutionStageProfile {
            stage: profile.stage,
            ai_tool: profile.ai_tool,
            mode: profile.mode,
            model: profile.model.map(|model| crate::workspace::state::EvolutionModelSelection {
                provider_id: model.provider_id,
                model_id: model.model_id,
            }),
            config_options: profile.config_options,
        })
        .collect()
}

fn from_protocol_todos(input: Vec<WorkspaceTodoInfo>) -> Vec<WorkspaceTodoItem> {
    input
        .into_iter()
        .map(|item| WorkspaceTodoItem {
            id: item.id,
            title: item.title,
            note: item.note,
            status: item.status,
            order: item.order,
            created_at_ms: item.created_at_ms,
            updated_at_ms: item.updated_at_ms,
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
            merge_ai_agent: None,
            fixed_port: None,
            remote_access_enabled: None,
            evolution_default_profiles: None,
            workspace_todos: None,
            keybindings: None,
        }
    }

    #[tokio::test]
    async fn save_client_settings_should_apply_basic_fields() {
        let app_state: SharedAppState = Arc::new(RwLock::new(AppState::default()));
        let mut params = empty_params();
        params.fixed_port = Some(48111);
        params.remote_access_enabled = Some(true);
        params
            .workspace_shortcuts
            .insert("1".to_string(), "demo/default".to_string());

        save_client_settings(&app_state, params).await;

        let state = app_state.read().await;
        assert_eq!(state.client_settings.fixed_port, 48111);
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

    #[tokio::test]
    async fn save_client_settings_should_keep_workspace_todos_when_not_provided() {
        let app_state: SharedAppState = Arc::new(RwLock::new(AppState::default()));
        {
            let mut state = app_state.write().await;
            state.client_settings.workspace_todos.insert(
                "demo:default".to_string(),
                vec![WorkspaceTodoItem {
                    id: "todo-1".to_string(),
                    title: "保留".to_string(),
                    note: Some("note".to_string()),
                    status: "pending".to_string(),
                    order: 0,
                    created_at_ms: 1,
                    updated_at_ms: 1,
                }],
            );
        }

        let mut params = empty_params();
        params.fixed_port = Some(19000);
        save_client_settings(&app_state, params).await;

        let state = app_state.read().await;
        assert_eq!(state.client_settings.fixed_port, 19000);
        assert_eq!(
            state.client_settings.workspace_todos["demo:default"].len(),
            1
        );
        assert_eq!(
            state.client_settings.workspace_todos["demo:default"][0].title,
            "保留"
        );
    }

    #[tokio::test]
    async fn save_client_settings_should_replace_workspace_todos_when_provided() {
        let app_state: SharedAppState = Arc::new(RwLock::new(AppState::default()));
        {
            let mut state = app_state.write().await;
            state.client_settings.workspace_todos.insert(
                "demo:default".to_string(),
                vec![WorkspaceTodoItem {
                    id: "todo-old".to_string(),
                    title: "旧项".to_string(),
                    note: None,
                    status: "pending".to_string(),
                    order: 0,
                    created_at_ms: 1,
                    updated_at_ms: 1,
                }],
            );
        }

        let mut params = empty_params();
        params.workspace_todos = Some(HashMap::from([(
            "demo:default".to_string(),
            vec![WorkspaceTodoInfo {
                id: "todo-new".to_string(),
                title: "新项".to_string(),
                note: Some("新备注".to_string()),
                status: "completed".to_string(),
                order: 0,
                created_at_ms: 2,
                updated_at_ms: 3,
            }],
        )]));
        save_client_settings(&app_state, params).await;

        let state = app_state.read().await;
        let todos = &state.client_settings.workspace_todos["demo:default"];
        assert_eq!(todos.len(), 1);
        assert_eq!(todos[0].id, "todo-new");
        assert_eq!(todos[0].status, "completed");
        assert_eq!(todos[0].note.as_deref(), Some("新备注"));
    }
}
