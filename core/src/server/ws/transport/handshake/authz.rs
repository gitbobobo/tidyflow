use axum::http::StatusCode;
use tracing::warn;

pub(in crate::server::ws) async fn authorize_ws_upgrade(
    expected_ws_token: Option<&str>,
    query: &crate::server::ws::auth_keys::WsAuthQuery,
    api_key_registry: &crate::server::ws::auth_keys::SharedRemoteAPIKeyRegistry,
) -> Result<(), StatusCode> {
    if crate::server::ws::auth_keys::is_ws_token_authorized(
        expected_ws_token,
        query,
        api_key_registry,
    )
    .await
    {
        Ok(())
    } else {
        warn!("Rejected unauthorized WebSocket upgrade request");
        Err(StatusCode::UNAUTHORIZED)
    }
}
