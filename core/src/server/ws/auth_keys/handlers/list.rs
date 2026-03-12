use axum::extract::{ConnectInfo, State};
use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};
use std::net::SocketAddr;

use crate::server::ws::auth_keys::auth::is_request_from_loopback;
use crate::server::ws::auth_keys::model::APIKeyListResponse;
use crate::server::ws::auth_keys::store::list_api_key_payloads;

use super::common::forbidden_response;

pub(in crate::server::ws) async fn list_api_keys_handler(
    State(ctx): State<super::super::super::transport::bootstrap::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return forbidden_response("auth/keys only accepts loopback requests");
    }

    let reg = ctx.api_key_registry.lock().await;
    (
        StatusCode::OK,
        Json(APIKeyListResponse {
            items: list_api_key_payloads(&reg),
        }),
    )
        .into_response()
}
