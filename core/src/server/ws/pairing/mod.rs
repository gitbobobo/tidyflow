mod auth;
mod handlers;
mod model;
mod store;

pub(in crate::server::ws) use auth::is_ws_token_authorized;
pub(in crate::server::ws) use handlers::{
    pair_exchange_handler, pair_revoke_handler, pair_start_handler,
};
pub(in crate::server::ws) use model::{SharedPairingRegistry, WsAuthQuery};
pub(in crate::server::ws) use store::{lookup_paired_info, new_pairing_registry};

#[cfg(test)]
mod tests {
    use super::auth::{is_request_from_loopback, is_ws_token_authorized};
    use super::model::{PairCodeEntry, PairTokenEntry, PairingRegistry, SharedPairingRegistry};
    use super::store::{cleanup_expired_pairing_entries, now_unix_ts};
    use std::collections::HashMap;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::sync::Arc;
    use tokio::sync::Mutex;

    fn test_registry() -> SharedPairingRegistry {
        Arc::new(Mutex::new(PairingRegistry {
            pending_codes: HashMap::new(),
            issued_tokens: HashMap::new(),
        }))
    }

    #[tokio::test]
    async fn token_auth_allows_when_token_not_configured() {
        let reg = test_registry();
        assert!(is_ws_token_authorized(None, None, &reg).await);
        assert!(is_ws_token_authorized(None, Some("anything"), &reg).await);
    }

    #[tokio::test]
    async fn token_auth_requires_exact_or_paired_token_when_configured() {
        let now_ts = now_unix_ts();
        let reg = test_registry();
        {
            let mut guard = reg.lock().await;
            guard.issued_tokens.insert(
                "paired-token".to_string(),
                PairTokenEntry {
                    token_id: "id-1".to_string(),
                    device_name: "iPhone".to_string(),
                    issued_at_unix: now_ts,
                    expires_at_unix: now_ts + 60,
                },
            );
        }
        assert!(is_ws_token_authorized(Some("bootstrap"), Some("bootstrap"), &reg).await);
        assert!(is_ws_token_authorized(Some("bootstrap"), Some("paired-token"), &reg).await);
        assert!(!is_ws_token_authorized(Some("bootstrap"), None, &reg).await);
        assert!(!is_ws_token_authorized(Some("bootstrap"), Some("bad"), &reg).await);
    }

    #[tokio::test]
    async fn token_auth_rejects_expired_paired_token() {
        let now_ts = now_unix_ts();
        let reg = test_registry();
        {
            let mut guard = reg.lock().await;
            guard.issued_tokens.insert(
                "expired-token".to_string(),
                PairTokenEntry {
                    token_id: "id-1".to_string(),
                    device_name: "iPhone".to_string(),
                    issued_at_unix: now_ts.saturating_sub(100),
                    expires_at_unix: now_ts.saturating_sub(1),
                },
            );
        }

        assert!(!is_ws_token_authorized(Some("bootstrap"), Some("expired-token"), &reg).await);
        let guard = reg.lock().await;
        assert!(guard.issued_tokens.is_empty());
    }

    #[test]
    fn cleanup_drops_expired_items() {
        let now_ts = now_unix_ts();
        let mut reg = PairingRegistry {
            pending_codes: HashMap::from([
                (
                    "111111".to_string(),
                    PairCodeEntry {
                        expires_at_unix: now_ts + 10,
                    },
                ),
                (
                    "222222".to_string(),
                    PairCodeEntry {
                        expires_at_unix: now_ts.saturating_sub(1),
                    },
                ),
            ]),
            issued_tokens: HashMap::from([
                (
                    "token-a".to_string(),
                    PairTokenEntry {
                        token_id: "id-a".to_string(),
                        device_name: "A".to_string(),
                        issued_at_unix: now_ts,
                        expires_at_unix: now_ts + 10,
                    },
                ),
                (
                    "token-b".to_string(),
                    PairTokenEntry {
                        token_id: "id-b".to_string(),
                        device_name: "B".to_string(),
                        issued_at_unix: now_ts,
                        expires_at_unix: now_ts.saturating_sub(1),
                    },
                ),
            ]),
        };

        cleanup_expired_pairing_entries(&mut reg, now_ts);
        assert_eq!(reg.pending_codes.len(), 1);
        assert!(reg.pending_codes.contains_key("111111"));
        assert_eq!(reg.issued_tokens.len(), 1);
        assert!(reg.issued_tokens.contains_key("token-a"));
    }

    #[test]
    fn loopback_check_matches_only_loopback_ip() {
        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1234);
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 2)), 1234);
        assert!(is_request_from_loopback(local));
        assert!(!is_request_from_loopback(remote));
    }
}
