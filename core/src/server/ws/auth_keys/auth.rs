use std::net::SocketAddr;

use tracing::trace;

use super::model::{AuthorizedAPIKeyInfo, SharedRemoteAPIKeyRegistry, WsAuthQuery};
use super::store::lookup_api_key_info;

pub(in crate::server::ws) async fn authorize_token(
    expected: Option<&str>,
    provided: Option<&str>,
    query: &WsAuthQuery,
    api_key_registry: &SharedRemoteAPIKeyRegistry,
) -> Option<AuthorizedAPIKeyInfo> {
    let token = provided?.trim();
    if token.is_empty() {
        return None;
    }
    if expected.is_some_and(|expected_token| expected_token == token) {
        return Some(AuthorizedAPIKeyInfo {
            key_id: String::new(),
        });
    }

    let client_id = query
        .client_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    let info = lookup_api_key_info(api_key_registry, token).await?;
    trace!(
        key_id = %info.key_id,
        client_id = %client_id,
        device_name = ?query.device_name,
        "Authorized by remote API key"
    );
    Some(info)
}

pub(in crate::server::ws) async fn is_ws_token_authorized(
    expected: Option<&str>,
    query: &WsAuthQuery,
    api_key_registry: &SharedRemoteAPIKeyRegistry,
) -> bool {
    match expected {
        None => true,
        Some(_) => authorize_token(expected, query.token.as_deref(), query, api_key_registry)
            .await
            .is_some(),
    }
}

pub(in crate::server::ws) fn is_request_from_loopback(addr: SocketAddr) -> bool {
    addr.ip().is_loopback()
}
