use axum::extract::{ConnectInfo, Path, State};
use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};
use std::net::SocketAddr;

use crate::server::ws::auth_keys::auth::is_request_from_loopback;
use crate::server::ws::auth_keys::model::{APIKeyDeleteResponse, APIKeyErrorResponse};
use crate::server::ws::auth_keys::store::{delete_api_key_entry, persist_api_keys_to_state};

use super::common::forbidden_response;

pub(in crate::server::ws) async fn delete_api_key_handler(
    State(ctx): State<super::super::super::transport::bootstrap::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Path(key_id): Path<String>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return forbidden_response("auth/keys only accepts loopback requests");
    }

    let (deleted, snapshot) = {
        let mut reg = ctx.api_key_registry.lock().await;
        let deleted = delete_api_key_entry(&mut reg, key_id.trim());
        let snapshot: Vec<_> = reg.keys_by_id.values().cloned().collect();
        (deleted, snapshot)
    };

    let Some(deleted_entry) = deleted else {
        return (
            StatusCode::NOT_FOUND,
            Json(APIKeyErrorResponse {
                error: "not_found".to_string(),
                message: "remote API key not found".to_string(),
            }),
        )
            .into_response();
    };

    persist_api_keys_to_state(&snapshot, &ctx.app_state, &ctx.save_tx).await;

    let revoked_connections = {
        let mut reg = ctx.remote_connection_registry.lock().await;
        reg.revoke_key(&deleted_entry.key_id)
    };

    if !revoked_connections.is_empty() {
        let mut remote_sub_registry = ctx.remote_sub_registry.lock().await;
        for revoked in revoked_connections {
            remote_sub_registry.unsubscribe_all(&revoked.subscriber_id);
            let _ = revoked
                .shutdown_tx
                .send("API key 已被删除，请重新输入有效的 API key。".to_string());
        }
    }

    (
        StatusCode::OK,
        Json(APIKeyDeleteResponse { ok: true, deleted: 1 }),
    )
        .into_response()
}
