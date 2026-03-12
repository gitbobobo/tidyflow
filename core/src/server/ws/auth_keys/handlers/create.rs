use axum::extract::{ConnectInfo, State};
use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};
use std::net::SocketAddr;

use crate::server::ws::auth_keys::auth::is_request_from_loopback;
use crate::server::ws::auth_keys::model::{APIKeyErrorResponse, CreateAPIKeyRequest};
use crate::server::ws::auth_keys::store::{
    api_key_payload_from_entry, create_api_key_entry, persist_api_keys_to_state,
};

use super::common::forbidden_response;

pub(in crate::server::ws) async fn create_api_key_handler(
    State(ctx): State<super::super::super::transport::bootstrap::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<CreateAPIKeyRequest>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return forbidden_response("auth/keys only accepts loopback requests");
    }

    let (created, snapshot) = {
        let mut reg = ctx.api_key_registry.lock().await;
        match create_api_key_entry(&mut reg, &payload.name) {
            Ok(entry) => {
                let snapshot: Vec<_> = reg.keys_by_id.values().cloned().collect();
                (entry, snapshot)
            }
            Err((error, message)) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(APIKeyErrorResponse {
                        error: error.to_string(),
                        message: message.to_string(),
                    }),
                )
                    .into_response();
            }
        }
    };

    persist_api_keys_to_state(&snapshot, &ctx.app_state, &ctx.save_tx).await;
    (StatusCode::OK, Json(api_key_payload_from_entry(created))).into_response()
}
