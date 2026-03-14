use std::net::SocketAddr;

use uuid::Uuid;

use crate::server::context::ConnectionMeta;
use crate::server::ws::auth_keys::WsAuthQuery;

pub(in crate::server::ws) async fn build_connection_meta(
    addr: SocketAddr,
    query: &WsAuthQuery,
    api_key_registry: &crate::server::ws::auth_keys::SharedRemoteAPIKeyRegistry,
) -> ConnectionMeta {
    let conn_id = Uuid::new_v4().to_string();
    let provided_token = query
        .token
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let client_id = query
        .client_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let device_name = query
        .device_name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);

    let (is_remote, api_key_id, subscriber_id, device_name) = if let Some(token) = provided_token {
        if let Some(info) = crate::server::ws::auth_keys::authorize_token(
            None,
            Some(token),
            query,
            api_key_registry,
        )
        .await
        {
            if !info.key_id.is_empty() {
                let client_id = client_id.clone().unwrap_or_else(|| conn_id.clone());
                (
                    true,
                    Some(info.key_id.clone()),
                    Some(format!("{}:{}", info.key_id, client_id)),
                    Some(device_name.unwrap_or_else(|| "Remote Client".to_string())),
                )
            } else {
                (!addr.ip().is_loopback(), None, None, None)
            }
        } else {
            (!addr.ip().is_loopback(), None, None, None)
        }
    } else {
        (!addr.ip().is_loopback(), None, None, None)
    };

    ConnectionMeta {
        conn_id,
        api_key_id,
        client_id,
        subscriber_id,
        is_remote,
        device_name,
    }
}
