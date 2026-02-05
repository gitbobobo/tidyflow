use axum::extract::ws::WebSocket;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::info;

use crate::server::protocol::{ClientMessage, CustomCommandInfo, ServerMessage};
use crate::server::ws::{send_message, SharedAppState, TerminalManager};

/// 处理设置相关的客户端消息
pub async fn handle_settings_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    _manager: &Arc<Mutex<TerminalManager>>,
    app_state: &SharedAppState,
    _tx_output: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    _tx_exit: tokio::sync::mpsc::Sender<(String, i32)>,
) -> Result<bool, String> {
    match client_msg {
        // v1.21: Get client settings
        ClientMessage::GetClientSettings => {
            let state = app_state.lock().await;
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
                    workspace_shortcuts: state.client_settings.workspace_shortcuts.clone(),
                },
            )
            .await?;
            Ok(true)
        }

        // v1.21: Save client settings
        ClientMessage::SaveClientSettings {
            custom_commands,
            workspace_shortcuts,
        } => {
            info!("SaveClientSettings request");
            let mut state = app_state.lock().await;
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

            match state.save() {
                Ok(_) => {
                    info!("Client settings saved successfully");
                    send_message(
                        socket,
                        &ServerMessage::ClientSettingsSaved {
                            ok: true,
                            message: None,
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    info!("Failed to save client settings: {}", e);
                    send_message(
                        socket,
                        &ServerMessage::ClientSettingsSaved {
                            ok: false,
                            message: Some(format!("保存设置失败: {}", e)),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        _ => Ok(false), // 不处理的消息返回 false
    }
}
