use std::net::SocketAddr;

use axum::extract::{ConnectInfo, Query};
use axum::{extract::State, Json};
use serde::Deserialize;

use super::common::ApiError;

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct NodeSelfQuery {
    pub pair_key: Option<String>,
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
            Some(runtime.issue_auth_token(Some(identity.node_id.clone())).await)
        }
        Some(_) => return Err(ApiError::Unauthorized),
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
