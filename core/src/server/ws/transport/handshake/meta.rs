use std::net::SocketAddr;

use uuid::Uuid;

use crate::server::context::ConnectionMeta;

pub(in crate::server::ws) async fn build_connection_meta(
    addr: SocketAddr,
    provided_token: Option<&str>,
    pairing_registry: &crate::server::ws::pairing::SharedPairingRegistry,
) -> ConnectionMeta {
    // 判断是否为远程连接：使用配对 token 的连接始终视为远程（覆盖 iOS 模拟器等 loopback 场景）
    let (is_remote, token_id, device_name) = {
        let paired_info = if let Some(token) = provided_token {
            crate::server::ws::pairing::lookup_paired_info(pairing_registry, token).await
        } else {
            None
        };
        if let Some((token_id, device_name)) = paired_info {
            // 配对 token 认证 -> 一定是远程设备
            (true, Some(token_id), Some(device_name))
        } else {
            (!addr.ip().is_loopback(), None, None)
        }
    };

    ConnectionMeta {
        conn_id: Uuid::new_v4().to_string(),
        token_id,
        is_remote,
        device_name,
    }
}
