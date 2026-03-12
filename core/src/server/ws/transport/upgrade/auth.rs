use axum::{
    extract::Query,
    http::StatusCode,
    response::{IntoResponse, Response},
};

pub(in crate::server::ws) fn extract_auth_query(
    query: Option<Query<crate::server::ws::auth_keys::WsAuthQuery>>,
) -> crate::server::ws::auth_keys::WsAuthQuery {
    query.map(|value| value.0).unwrap_or_default()
}

pub(in crate::server::ws) async fn ensure_authorized_or_response(
    expected_ws_token: Option<&str>,
    query: &crate::server::ws::auth_keys::WsAuthQuery,
    api_key_registry: &crate::server::ws::auth_keys::SharedRemoteAPIKeyRegistry,
) -> Result<(), Response> {
    if crate::server::ws::transport::handshake::authorize_ws_upgrade(
        expected_ws_token,
        query,
        api_key_registry,
    )
    .await
    .is_err()
    {
        return Err((StatusCode::UNAUTHORIZED, "unauthorized").into_response());
    }
    Ok(())
}
