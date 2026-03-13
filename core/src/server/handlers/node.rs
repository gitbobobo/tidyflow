use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::{send_message, OutboundTx as WebSocket};

pub async fn handle_node_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    let Some(runtime) = crate::server::node::maybe_runtime() else {
        return Ok(false);
    };
    match client_msg {
        ClientMessage::NodeUpdateProfile {
            node_name,
            discovery_enabled,
        } => {
            crate::application::settings::save_client_settings(
                &ctx.app_state,
                crate::application::settings::SaveClientSettingsParams {
                    custom_commands: ctx.app_state.read().await.client_settings.custom_commands.iter().map(|c| crate::server::protocol::CustomCommandInfo {
                        id: c.id.clone(),
                        name: c.name.clone(),
                        icon: c.icon.clone(),
                        command: c.command.clone(),
                    }).collect(),
                    workspace_shortcuts: ctx.app_state.read().await.client_settings.workspace_shortcuts.clone(),
                    merge_ai_agent: ctx.app_state.read().await.client_settings.merge_ai_agent.clone(),
                    fixed_port: None,
                    remote_access_enabled: None,
                    node_name: Some(node_name.clone()),
                    node_discovery_enabled: Some(*discovery_enabled),
                    evolution_default_profiles: None,
                    workspace_todos: None,
                    keybindings: None,
                },
            )
            .await;
            let _ = ctx.save_tx.send(()).await;
            runtime.ensure_identity().await;
            send_message(
                socket,
                &ServerMessage::NodeSelfUpdated {
                    identity: runtime.self_info().await,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::NodePairPeer { host, port, pair_key } => {
            let result = runtime.pair_peer(host, *port, pair_key).await;
            let message = match result {
                Ok(peer) => ServerMessage::NodePairingResult {
                    ok: true,
                    peer: Some(peer),
                    message: None,
                },
                Err(err) => ServerMessage::NodePairingResult {
                    ok: false,
                    peer: None,
                    message: Some(err),
                },
            };
            send_message(socket, &message).await?;
            Ok(true)
        }
        ClientMessage::NodeUnpairPeer { peer_node_id } => {
            runtime.unpair_peer(peer_node_id).await?;
            send_message(
                socket,
                &ServerMessage::NodeNetworkUpdated {
                    identity: runtime.self_info().await,
                    peers: runtime.list_network_snapshot(true).await.peers,
                    active_locks: runtime.list_network_snapshot(true).await.active_locks,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::NodeRefreshNetwork => {
            runtime.refresh_network().await?;
            let snapshot = runtime.list_network_snapshot(true).await;
            send_message(
                socket,
                &ServerMessage::NodeNetworkUpdated {
                    identity: snapshot.identity,
                    peers: snapshot.peers,
                    active_locks: snapshot.active_locks,
                },
            )
            .await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
