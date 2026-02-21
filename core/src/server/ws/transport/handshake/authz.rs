use axum::http::StatusCode;
use tracing::warn;

pub(in crate::server::ws) async fn authorize_ws_upgrade(
    expected_ws_token: Option<&str>,
    provided_token: Option<&str>,
    pairing_registry: &crate::server::ws::pairing::SharedPairingRegistry,
) -> Result<(), StatusCode> {
    if crate::server::ws::pairing::is_ws_token_authorized(
        expected_ws_token,
        provided_token,
        pairing_registry,
    )
    .await
    {
        Ok(())
    } else {
        warn!("Rejected unauthorized WebSocket upgrade request");
        Err(StatusCode::UNAUTHORIZED)
    }
}
