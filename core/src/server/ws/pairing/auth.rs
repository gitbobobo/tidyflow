use std::net::SocketAddr;

use tracing::trace;

use super::model::SharedPairingRegistry;
use super::store::{cleanup_expired_pairing_entries, now_unix_ts};

pub(in crate::server::ws) async fn is_ws_token_authorized(
    expected: Option<&str>,
    provided: Option<&str>,
    pairing_registry: &SharedPairingRegistry,
) -> bool {
    match expected {
        // 未配置 token 时保持兼容：放行连接（通常只用于本机调试）
        None => true,
        // 当 Core 配置了 token 时，客户端必须携带并匹配
        Some(expected_token) => {
            let Some(token) = provided else {
                return false;
            };
            if token == expected_token {
                return true;
            }

            let mut reg = pairing_registry.lock().await;
            let now_ts = now_unix_ts();
            cleanup_expired_pairing_entries(&mut reg, now_ts);
            if let Some(entry) = reg.issued_tokens.get(token) {
                trace!(
                    token_id = %entry.token_id,
                    device = %entry.device_name,
                    issued_at = entry.issued_at_unix,
                    "Authorized by paired token"
                );
                true
            } else {
                false
            }
        }
    }
}

pub(in crate::server::ws) fn is_request_from_loopback(addr: SocketAddr) -> bool {
    addr.ip().is_loopback()
}
