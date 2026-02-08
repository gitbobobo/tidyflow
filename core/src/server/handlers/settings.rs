use axum::extract::ws::WebSocket;
use tracing::info;

use crate::server::protocol::{ClientMessage, CustomCommandInfo, ServerMessage};
use crate::server::ws::{send_message, SharedAppState};

/// 处理设置相关的客户端消息
pub async fn handle_settings_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    save_tx: &tokio::sync::mpsc::Sender<()>,
) -> Result<bool, String> {
    match client_msg {
        // v1.21: Get client settings
        ClientMessage::GetClientSettings => {
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
            send_message(
                socket,
                &ServerMessage::ClientSettingsResult {
                    custom_commands: commands,
                    workspace_shortcuts: state
                        .client_settings
                        .workspace_shortcuts
                        .clone(),
                    commit_ai_agent: state
                        .client_settings
                        .commit_ai_agent
                        .clone(),
                    merge_ai_agent: state
                        .client_settings
                        .merge_ai_agent
                        .clone(),
                },
            )
            .await?;
            Ok(true)
        }

        // v1.21: Save client settings（内存更新 + 防抖异步保存）
        ClientMessage::SaveClientSettings {
            custom_commands,
            workspace_shortcuts,
            commit_ai_agent,
            merge_ai_agent,
            selected_ai_agent,
        } => {
            info!("SaveClientSettings request");
            {
                let mut state = app_state.write().await;
                state.client_settings.custom_commands = custom_commands
                    .iter()
                    .map(|c| crate::workspace::state::CustomCommand {
                        id: c.id.clone(),
                        name: c.name.clone(),
                        icon: c.icon.clone(),
                        command: c.command.clone(),
                    })
                    .collect();
                state.client_settings.workspace_shortcuts = workspace_shortcuts.clone();
                // 优先使用新字段；若新字段为空则回退兼容旧客户端的 selected_ai_agent
                if commit_ai_agent.is_some() || merge_ai_agent.is_some() {
                    state.client_settings.commit_ai_agent = commit_ai_agent.clone();
                    state.client_settings.merge_ai_agent = merge_ai_agent.clone();
                } else if let Some(old) = selected_ai_agent {
                    state.client_settings.commit_ai_agent = Some(old.clone());
                    state.client_settings.merge_ai_agent = Some(old.clone());
                }
            }

            // 触发防抖保存，不等待磁盘写入完成
            let _ = save_tx.send(()).await;

            send_message(
                socket,
                &ServerMessage::ClientSettingsSaved {
                    ok: true,
                    message: None,
                },
            )
            .await?;
            Ok(true)
        }

        _ => Ok(false), // 不处理的消息返回 false
    }
}
