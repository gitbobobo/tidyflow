use std::net::SocketAddr;

use axum::extract::{ConnectInfo, Query};
use axum::{extract::State, Json};
use serde::Deserialize;
use tracing::{info, warn};

use super::common::ApiError;
use crate::server::context::{TaskBroadcastEvent, send_task_broadcast_event};
use crate::server::protocol::ServerMessage;

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct NodeSelfQuery {
    pub pair_key: Option<String>,
    pub requester_node_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct NodeNetworkQuery {
    pub auth_token: Option<String>,
}

pub(in crate::server::ws) async fn node_self_handler(
    State(_ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    Query(query): Query<NodeSelfQuery>,
) -> Result<Json<crate::server::node::NodeSelfHttpResponse>, ApiError> {
    let Some(runtime) = crate::server::node::maybe_runtime() else {
        return Err(ApiError::Internal("node runtime unavailable".to_string()));
    };
    let identity = runtime.self_info().await;
    let auth_token = match query.pair_key {
        Some(pair_key) if pair_key == identity.bootstrap_pair_key => {
            let peer_node_id = query
                .requester_node_id
                .clone()
                .filter(|value| !value.trim().is_empty())
                .or_else(|| Some(identity.node_id.clone()));
            info!(
                self_node_id = %identity.node_id,
                requester_node_id = ?peer_node_id,
                "node self handshake authorized for pairing"
            );
            Some(runtime.issue_auth_token(peer_node_id).await)
        }
        Some(_) => {
            warn!(self_node_id = %identity.node_id, "node self handshake rejected due to invalid pair key");
            return Err(ApiError::Unauthorized);
        }
        None => None,
    };
    Ok(Json(crate::server::node::NodeSelfHttpResponse {
        identity,
        auth_token,
    }))
}

pub(in crate::server::ws) async fn node_discovery_handler(
    State(_ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let Some(runtime) = crate::server::node::maybe_runtime() else {
        return Err(ApiError::Internal("node runtime unavailable".to_string()));
    };
    let items = runtime.list_discovery_items().await;
    Ok(Json(serde_json::json!({
        "type": "node_discovery",
        "items": items,
    })))
}

pub(in crate::server::ws) async fn node_network_handler(
    State(_ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(query): Query<NodeNetworkQuery>,
) -> Result<Json<crate::server::node::NodeNetworkHttpResponse>, ApiError> {
    let Some(runtime) = crate::server::node::maybe_runtime() else {
        return Err(ApiError::Internal("node runtime unavailable".to_string()));
    };
    let include_tokens = if addr.ip().is_loopback() {
        true
    } else if let Some(token) = query.auth_token.as_deref() {
        runtime.validate_auth_token(token).await
    } else {
        false
    };
    if !addr.ip().is_loopback() && !include_tokens {
        return Err(ApiError::Unauthorized);
    }
    Ok(Json(runtime.list_network_snapshot(include_tokens).await))
}

pub(in crate::server::ws) async fn node_pair_register_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<crate::server::node::NodePairRegisterHttpRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let Some(runtime) = crate::server::node::maybe_runtime() else {
        return Err(ApiError::Internal("node runtime unavailable".to_string()));
    };
    let identity = runtime.self_info().await;
    if payload.pair_key.trim() != identity.bootstrap_pair_key {
        warn!(
            self_node_id = %identity.node_id,
            remote_ip = %addr.ip(),
            peer_node_id = %payload.peer_identity.node_id,
            "node pair register rejected due to invalid pair key"
        );
        return Err(ApiError::Unauthorized);
    }
    info!(
        self_node_id = %identity.node_id,
        remote_ip = %addr.ip(),
        peer_node_id = %payload.peer_identity.node_id,
        peer_port = payload.peer_identity.port,
        "received node pair register request"
    );

    let peer = runtime
        .register_peer_from_remote(addr.ip(), payload.peer_identity, payload.peer_auth_token)
        .await
        .map_err(ApiError::BadRequest)?;
    broadcast_node_network_updated(&ctx, &runtime).await;
    info!(
        self_node_id = %identity.node_id,
        peer_node_id = %peer.peer_node_id,
        "node pair register completed and network update broadcasted"
    );
    Ok(Json(serde_json::json!({
        "ok": true,
        "peer": peer,
    })))
}

pub(in crate::server::ws) async fn node_pair_unregister_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    Json(payload): Json<crate::server::node::NodePairUnregisterHttpRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let Some(runtime) = crate::server::node::maybe_runtime() else {
        return Err(ApiError::Internal("node runtime unavailable".to_string()));
    };
    info!("received node pair unregister request");
    match runtime.unregister_peer_by_auth_token(payload.auth_token.trim()).await {
        Ok(peer_node_id) => {
            broadcast_node_network_updated(&ctx, &runtime).await;
            info!(peer_node_id = %peer_node_id, "node pair unregister completed and network update broadcasted");
            Ok(Json(serde_json::json!({
                "ok": true,
                "peer_node_id": peer_node_id,
            })))
        }
        Err(err) if err.contains("auth_token 无效") => {
            warn!(error = %err, "node pair unregister rejected due to invalid auth token");
            Err(ApiError::Unauthorized)
        }
        Err(err) => {
            warn!(error = %err, "node pair unregister failed");
            Err(ApiError::BadRequest(err))
        }
    }
}

async fn broadcast_node_network_updated(
    ctx: &crate::server::ws::transport::bootstrap::AppContext,
    runtime: &std::sync::Arc<crate::server::node::NodeRuntime>,
) {
    let snapshot = runtime.list_network_snapshot(true).await;
    info!(
        self_node_id = %snapshot.identity.node_id,
        peer_count = snapshot.peers.len(),
        "broadcasting node_network_updated after pair sync"
    );
    let _ = send_task_broadcast_event(
        &ctx.task_broadcast_tx,
        TaskBroadcastEvent {
            origin_conn_id: "http_node_pair_sync".to_string(),
            message: ServerMessage::NodeNetworkUpdated {
                identity: snapshot.identity,
                peers: snapshot.peers,
                active_locks: snapshot.active_locks,
            },
            target_conn_ids: None,
            skip_when_single_receiver: false,
        },
    );
}
