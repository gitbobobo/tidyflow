use std::net::SocketAddr;

pub(in crate::server::ws) async fn build_conn_meta(
    addr: SocketAddr,
    provided_token: Option<&str>,
    pairing_registry: &crate::server::ws::pairing::SharedPairingRegistry,
) -> crate::server::context::ConnectionMeta {
    crate::server::ws::transport::handshake::build_connection_meta(addr, provided_token, pairing_registry)
        .await
}
