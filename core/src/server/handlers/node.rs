use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::{send_message, OutboundTx as WebSocket};
use tracing::{info, warn};

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
            let current_settings = {
                let state = ctx.app_state.read().await;
                (
                    state.client_settings.workspace_shortcuts.clone(),
                    state.client_settings.merge_ai_agent.clone(),
                )
            };
            crate::application::settings::save_client_settings(
                &ctx.app_state,
                crate::application::settings::SaveClientSettingsParams {
                    workspace_shortcuts: current_settings.0,
                    merge_ai_agent: current_settings.1,
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
            crate::application::settings::persist_node_profile_immediately(
                &ctx.app_state,
                &ctx.state_store,
            )
            .await?;
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
            info!(
                target_host = %host,
                target_port = %port,
                pair_key_len = pair_key.trim().len(),
                "received node_pair_peer websocket request"
            );
            let result = runtime.pair_peer(host, *port, pair_key).await;
            match &result {
                Ok(peer) => info!(
                    target_host = %host,
                    target_port = %port,
                    peer_node_id = %peer.peer_node_id,
                    "node_pair_peer websocket request succeeded"
                ),
                Err(err) => warn!(
                    target_host = %host,
                    target_port = %port,
                    error = %err,
                    "node_pair_peer websocket request failed"
                ),
            }
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
            if matches!(message, ServerMessage::NodePairingResult { ok: true, .. }) {
                let runtime = runtime.clone();
                tokio::spawn(async move {
                    info!("starting post-pair background network refresh");
                    match runtime.refresh_network().await {
                        Ok(()) => info!("post-pair background network refresh completed"),
                        Err(err) => warn!(error = %err, "post-pair background network refresh failed"),
                    }
                });
            }
            Ok(true)
        }
        ClientMessage::NodeUnpairPeer { peer_node_id } => {
            info!(peer_node_id = %peer_node_id, "received node_unpair_peer websocket request");
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
            info!(peer_node_id = %peer_node_id, "node_unpair_peer websocket request completed");
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
