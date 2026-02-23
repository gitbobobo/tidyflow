use axum::{
    extract::Query,
    http::StatusCode,
    response::{IntoResponse, Response},
};

pub(in crate::server::ws) fn extract_provided_token(
    query: Option<Query<crate::server::ws::pairing::WsAuthQuery>>,
) -> Option<String> {
    query.and_then(|q| q.0.token)
}

pub(in crate::server::ws) async fn ensure_authorized_or_response(
    expected_ws_token: Option<&str>,
    provided_token: Option<&str>,
    pairing_registry: &crate::server::ws::pairing::SharedPairingRegistry,
) -> Result<(), Response> {
    if crate::server::ws::transport::handshake::authorize_ws_upgrade(
        expected_ws_token,
        provided_token,
        pairing_registry,
    )
    .await
    .is_err()
    {
        return Err((StatusCode::UNAUTHORIZED, "unauthorized").into_response());
    }
    Ok(())
}
