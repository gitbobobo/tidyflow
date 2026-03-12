use std::net::SocketAddr;

pub(in crate::server::ws) async fn build_conn_meta(
    addr: SocketAddr,
    query: &crate::server::ws::auth_keys::WsAuthQuery,
    api_key_registry: &crate::server::ws::auth_keys::SharedRemoteAPIKeyRegistry,
) -> crate::server::context::ConnectionMeta {
    crate::server::ws::transport::handshake::build_connection_meta(
        addr,
        query,
        api_key_registry,
    )
    .await
}
