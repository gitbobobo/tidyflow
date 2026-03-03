use axum::extract::ws::WebSocket;
use tracing::info;

use crate::application::settings::{save_client_settings, SaveClientSettingsParams};
use crate::server::context::SharedAppState;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub async fn handle_mutate_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    save_tx: &tokio::sync::mpsc::Sender<()>,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::SaveClientSettings {
            custom_commands,
            workspace_shortcuts,
            merge_ai_agent,
            fixed_port,
            app_language,
            remote_access_enabled,
        } => {
            info!("SaveClientSettings request");
            save_client_settings(
                app_state,
                SaveClientSettingsParams {
                    custom_commands: custom_commands.clone(),
                    workspace_shortcuts: workspace_shortcuts.clone(),
                    merge_ai_agent: merge_ai_agent.clone(),
                    fixed_port: *fixed_port,
                    app_language: app_language.clone(),
                    remote_access_enabled: *remote_access_enabled,
                },
            )
            .await;

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
        _ => Ok(false),
    }
}
