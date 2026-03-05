use axum::extract::ws::WebSocket;
use tracing::info;

use crate::application::settings::{
    get_client_settings_message, save_client_settings, SaveClientSettingsParams,
};
use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub async fn handle_mutate_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::SaveClientSettings {
            custom_commands,
            workspace_shortcuts,
            merge_ai_agent,
            fixed_port,
            remote_access_enabled,
            workspace_todos,
        } => {
            info!("SaveClientSettings request");
            save_client_settings(
                &ctx.app_state,
                SaveClientSettingsParams {
                    custom_commands: custom_commands.clone(),
                    workspace_shortcuts: workspace_shortcuts.clone(),
                    merge_ai_agent: merge_ai_agent.clone(),
                    fixed_port: *fixed_port,
                    remote_access_enabled: *remote_access_enabled,
                    workspace_todos: workspace_todos.clone(),
                },
            )
            .await;

            let _ = ctx.save_tx.send(()).await;

            send_message(
                socket,
                &ServerMessage::ClientSettingsSaved {
                    ok: true,
                    message: None,
                },
            )
            .await?;

            let snapshot = get_client_settings_message(&ctx.app_state).await;
            let _ = crate::server::context::send_task_broadcast_message(
                &ctx.task_broadcast_tx,
                &ctx.conn_meta.conn_id,
                snapshot,
            );
            Ok(true)
        }
        _ => Ok(false),
    }
}
