use std::net::SocketAddr;

use axum::extract::{ConnectInfo, Query};
use axum::{extract::State, Json};
use serde::Deserialize;
use tracing::{info, warn};

use super::common::ApiError;
use crate::server::context::{send_task_broadcast_event, TaskBroadcastEvent};
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
    match runtime
        .unregister_peer_by_auth_token(payload.auth_token.trim())
        .await
    {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::net::SocketAddr;
    use std::sync::Arc;

    use axum::extract::{ConnectInfo, Query, State};

    use crate::server::context::SharedAppState;
    use crate::server::handlers::ai::AIState;
    use crate::server::node::{
        NodePairRegisterHttpRequest, NodePairUnregisterHttpRequest, PairPeerIdentityPayload,
    };
    use crate::server::remote_sub_registry::RemoteSubRegistry;
    use crate::server::terminal_registry::TerminalRegistry;

    /// 串行执行共享全局 NodeRuntime 的测试
    static NODE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    async fn setup() -> (
        crate::server::ws::transport::bootstrap::AppContext,
        Arc<crate::server::node::NodeRuntime>,
    ) {
        let runtime = crate::server::node::init_test_runtime().await;
        let app_state = runtime.shared_app_state_for_test();
        let ctx = make_test_context_with_state(app_state).await;
        (ctx, runtime)
    }

    async fn make_test_context_with_state(
        app_state: SharedAppState,
    ) -> crate::server::ws::transport::bootstrap::AppContext {
        let (save_tx, _save_rx) = tokio::sync::mpsc::channel(8);
        let (scrollback_tx, _scrollback_rx) = tokio::sync::mpsc::channel(8);
        let (task_broadcast_tx, _task_broadcast_rx) = tokio::sync::broadcast::channel(8);
        crate::server::ws::transport::bootstrap::AppContext {
            app_state,
            save_tx,
            terminal_registry: Arc::new(tokio::sync::Mutex::new(TerminalRegistry::new())),
            scrollback_tx,
            expected_ws_token: Some("required-token".to_string()),
            api_key_registry: Arc::new(tokio::sync::Mutex::new(
                crate::server::ws::auth_keys::new_api_key_registry(&[]),
            )),
            remote_sub_registry: Arc::new(tokio::sync::Mutex::new(RemoteSubRegistry::new())),
            remote_connection_registry: Arc::new(tokio::sync::Mutex::new(
                crate::server::remote_connection_registry::RemoteConnectionRegistry::new(),
            )),
            task_broadcast_tx,
            running_commands: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            running_ai_tasks: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            task_history: Arc::new(tokio::sync::Mutex::new(Vec::new())),
            ai_state: Arc::new(tokio::sync::Mutex::new(AIState::new())),
            state_store: Arc::new(
                crate::workspace::state_store::StateStore::open_in_memory_for_test()
                    .await
                    .expect("test state store"),
            ),
        }
    }

    fn loopback_addr() -> SocketAddr {
        SocketAddr::from(([127, 0, 0, 1], 12345))
    }

    fn remote_addr() -> SocketAddr {
        SocketAddr::from(([192, 168, 1, 100], 54321))
    }

    // ---- node_self_handler ----

    #[tokio::test]
    async fn node_self_should_return_identity_without_pair_key() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, _runtime) = setup().await;
        let response = node_self_handler(
            State(ctx),
            Query(NodeSelfQuery {
                pair_key: None,
                requester_node_id: None,
            }),
        )
        .await
        .expect("handler should succeed");
        assert!(
            response.0.auth_token.is_none(),
            "no pair_key → no auth_token"
        );
        assert!(!response.0.identity.node_id.is_empty());
        assert!(!response.0.identity.bootstrap_pair_key.is_empty());
    }

    #[tokio::test]
    async fn node_self_should_issue_auth_token_for_valid_pair_key() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, runtime) = setup().await;
        let pair_key = runtime.self_info().await.bootstrap_pair_key;
        let response = node_self_handler(
            State(ctx),
            Query(NodeSelfQuery {
                pair_key: Some(pair_key),
                requester_node_id: Some("requester-peer-001".to_string()),
            }),
        )
        .await
        .expect("handler should succeed");
        let token = response.0.auth_token.expect("valid pair_key → auth_token");
        assert!(token.starts_with("tfn_"), "auth token prefix");
        // 验证 token 绑定到 requester_node_id
        assert!(
            runtime
                .validate_auth_token_for_peer(&token, "requester-peer-001")
                .await,
            "auth token should be bound to requester_node_id"
        );
    }

    #[tokio::test]
    async fn node_self_should_reject_invalid_pair_key() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, _runtime) = setup().await;
        let result = node_self_handler(
            State(ctx),
            Query(NodeSelfQuery {
                pair_key: Some("wrong-key-abc".to_string()),
                requester_node_id: None,
            }),
        )
        .await;
        assert!(result.is_err(), "invalid pair_key → Unauthorized");
    }

    // ---- node_network_handler ----

    #[tokio::test]
    async fn node_network_should_allow_loopback_without_token() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, _runtime) = setup().await;
        let response = node_network_handler(
            State(ctx),
            ConnectInfo(loopback_addr()),
            Query(NodeNetworkQuery { auth_token: None }),
        )
        .await
        .expect("loopback should be allowed");
        assert!(!response.0.identity.node_id.is_empty());
    }

    #[tokio::test]
    async fn node_network_should_reject_remote_without_token() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, _runtime) = setup().await;
        let result = node_network_handler(
            State(ctx),
            ConnectInfo(remote_addr()),
            Query(NodeNetworkQuery { auth_token: None }),
        )
        .await;
        assert!(result.is_err(), "remote without token → Unauthorized");
    }

    #[tokio::test]
    async fn node_network_should_reject_remote_with_invalid_token() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, _runtime) = setup().await;
        let result = node_network_handler(
            State(ctx),
            ConnectInfo(remote_addr()),
            Query(NodeNetworkQuery {
                auth_token: Some("bogus-token".to_string()),
            }),
        )
        .await;
        assert!(result.is_err(), "invalid token → Unauthorized");
    }

    #[tokio::test]
    async fn node_network_should_allow_remote_with_valid_token() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, runtime) = setup().await;
        let token = runtime
            .issue_auth_token(Some("net-query-peer".to_string()))
            .await;
        let response = node_network_handler(
            State(ctx),
            ConnectInfo(remote_addr()),
            Query(NodeNetworkQuery {
                auth_token: Some(token),
            }),
        )
        .await
        .expect("valid token should be allowed");
        assert!(!response.0.identity.node_id.is_empty());
    }

    // ---- node_pair_register_handler ----

    #[tokio::test]
    async fn node_pair_register_should_reject_invalid_pair_key() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, _runtime) = setup().await;
        let result = node_pair_register_handler(
            State(ctx),
            ConnectInfo(remote_addr()),
            Json(NodePairRegisterHttpRequest {
                pair_key: "wrong-key-xyz".to_string(),
                peer_identity: PairPeerIdentityPayload {
                    node_id: "reg-reject-peer".to_string(),
                    node_name: Some("Reject Peer".to_string()),
                    port: 8439,
                },
                peer_auth_token: "tfn_reject_token".to_string(),
            }),
        )
        .await;
        assert!(result.is_err(), "invalid pair_key → Unauthorized");
    }

    #[tokio::test]
    async fn node_pair_register_should_persist_peer_address_and_broadcast() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, runtime) = setup().await;
        let pair_key = runtime.self_info().await.bootstrap_pair_key;
        let mut broadcast_rx = ctx.task_broadcast_tx.subscribe();

        let response = node_pair_register_handler(
            State(ctx),
            ConnectInfo(remote_addr()),
            Json(NodePairRegisterHttpRequest {
                pair_key,
                peer_identity: PairPeerIdentityPayload {
                    node_id: "persist-addr-peer".to_string(),
                    node_name: Some("Persist Addr Peer".to_string()),
                    port: 9000,
                },
                peer_auth_token: "tfn_persist_token".to_string(),
            }),
        )
        .await
        .expect("register should succeed");

        assert_eq!(response.0["ok"], true);

        // 验证持久化：远端 IP 来自 ConnectInfo
        let snapshot = runtime.list_network_snapshot(true).await;
        let peer = snapshot
            .peers
            .iter()
            .find(|p| p.peer_node_id == "persist-addr-peer")
            .expect("registered peer should appear in snapshot");
        assert!(
            peer.addresses.contains(&"192.168.1.100".to_string()),
            "persisted address should match ConnectInfo IP"
        );
        assert_eq!(peer.port, 9000);

        // 验证 auth_token 归属
        assert!(
            peer.auth_token.is_some(),
            "snapshot(include_tokens=true) should expose auth_token"
        );

        // 验证广播
        let event = broadcast_rx
            .try_recv()
            .expect("should have received node_network_updated broadcast");
        match event.message {
            ServerMessage::NodeNetworkUpdated { .. } => {}
            other => panic!("expected NodeNetworkUpdated, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn node_pair_register_should_reject_self_pairing() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, runtime) = setup().await;
        let self_info = runtime.self_info().await;

        let result = node_pair_register_handler(
            State(ctx),
            ConnectInfo(remote_addr()),
            Json(NodePairRegisterHttpRequest {
                pair_key: self_info.bootstrap_pair_key,
                peer_identity: PairPeerIdentityPayload {
                    node_id: self_info.node_id.clone(),
                    node_name: Some("Self".to_string()),
                    port: 8439,
                },
                peer_auth_token: "tfn_self_token".to_string(),
            }),
        )
        .await;
        assert!(result.is_err(), "self-pairing should be rejected");
    }

    // ---- node_pair_unregister_handler ----

    #[tokio::test]
    async fn node_pair_unregister_should_reject_invalid_token() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, _runtime) = setup().await;
        let result = node_pair_unregister_handler(
            State(ctx),
            Json(NodePairUnregisterHttpRequest {
                auth_token: "invalid-token-zzz".to_string(),
            }),
        )
        .await;
        assert!(result.is_err(), "invalid token → Unauthorized");
    }

    #[tokio::test]
    async fn node_pair_unregister_should_remove_peer_and_broadcast() {
        let _serial = NODE_TEST_LOCK.lock().unwrap();
        let (ctx, runtime) = setup().await;
        let pair_key = runtime.self_info().await.bootstrap_pair_key;

        // 先通过 self_handler 颁发 auth token
        let self_response = node_self_handler(
            State(ctx.clone()),
            Query(NodeSelfQuery {
                pair_key: Some(pair_key.clone()),
                requester_node_id: Some("unreg-test-peer".to_string()),
            }),
        )
        .await
        .expect("self handler should succeed");
        let issued_token = self_response.0.auth_token.expect("should have auth_token");

        // 注册 peer
        let _ = node_pair_register_handler(
            State(ctx.clone()),
            ConnectInfo(remote_addr()),
            Json(NodePairRegisterHttpRequest {
                pair_key,
                peer_identity: PairPeerIdentityPayload {
                    node_id: "unreg-test-peer".to_string(),
                    node_name: Some("Unreg Test Peer".to_string()),
                    port: 9002,
                },
                peer_auth_token: "tfn_unreg_peer_token".to_string(),
            }),
        )
        .await
        .expect("register should succeed");

        // 订阅广播
        let mut broadcast_rx = ctx.task_broadcast_tx.subscribe();

        // 使用颁发的 token 取消注册
        let response = node_pair_unregister_handler(
            State(ctx),
            Json(NodePairUnregisterHttpRequest {
                auth_token: issued_token,
            }),
        )
        .await
        .expect("unregister should succeed");

        assert_eq!(response.0["ok"], true);
        assert_eq!(response.0["peer_node_id"], "unreg-test-peer");

        // 验证广播
        let event = broadcast_rx
            .try_recv()
            .expect("should have received node_network_updated broadcast");
        match event.message {
            ServerMessage::NodeNetworkUpdated { .. } => {}
            other => panic!("expected NodeNetworkUpdated, got {:?}", other),
        }
    }
}
