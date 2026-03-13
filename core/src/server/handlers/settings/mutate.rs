use crate::server::ws::OutboundTx as WebSocket;
use tracing::info;

use crate::application::settings::{
    get_client_settings_message, save_client_settings, SaveClientSettingsParams,
};
use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub async fn handle_mutate_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::SaveClientSettings {
            custom_commands,
            workspace_shortcuts,
            merge_ai_agent,
            fixed_port,
            remote_access_enabled,
            node_name,
            node_discovery_enabled,
            evolution_default_profiles,
            workspace_todos,
            keybindings,
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
                    node_name: node_name.clone(),
                    node_discovery_enabled: *node_discovery_enabled,
                    evolution_default_profiles: evolution_default_profiles.clone(),
                    workspace_todos: workspace_todos.clone(),
                    keybindings: keybindings.clone(),
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
