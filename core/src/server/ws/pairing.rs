use axum::extract::{ConnectInfo, State};
use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};
use chrono::{SecondsFormat, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;
use tracing::trace;
use uuid::Uuid;

use crate::server::context::SharedAppState;
use crate::server::ws;
use crate::workspace::state::PersistedTokenEntry;

#[derive(Debug, Deserialize)]
pub(super) struct WsAuthQuery {
    pub(super) token: Option<String>,
}

#[derive(Debug, Default)]
pub(super) struct PairingRegistry {
    /// key: 6 位配对码
    pending_codes: HashMap<String, PairCodeEntry>,
    /// key: ws_token
    issued_tokens: HashMap<String, PairTokenEntry>,
}

#[derive(Debug, Clone)]
pub(super) struct PairCodeEntry {
    expires_at_unix: u64,
}

#[derive(Debug, Clone)]
pub(super) struct PairTokenEntry {
    token_id: String,
    device_name: String,
    issued_at_unix: u64,
    expires_at_unix: u64,
}

pub(super) type SharedPairingRegistry = Arc<Mutex<PairingRegistry>>;

#[derive(Debug, Serialize)]
struct PairStartResponse {
    pair_code: String,
    expires_at: String,
    expires_at_unix: u64,
}

#[derive(Debug, Deserialize)]
pub(super) struct PairExchangeRequest {
    pair_code: String,
    #[serde(default)]
    device_name: Option<String>,
}

#[derive(Debug, Serialize)]
struct PairExchangeResponse {
    token_id: String,
    ws_token: String,
    device_name: String,
    issued_at: String,
    issued_at_unix: u64,
    expires_at: String,
    expires_at_unix: u64,
}

#[derive(Debug, Deserialize)]
pub(super) struct PairRevokeRequest {
    #[serde(default)]
    token_id: Option<String>,
    #[serde(default)]
    ws_token: Option<String>,
}

#[derive(Debug, Serialize)]
struct PairRevokeResponse {
    ok: bool,
    revoked: usize,
}

#[derive(Debug, Serialize)]
struct PairErrorResponse {
    error: String,
    message: String,
}

const PAIR_CODE_TTL_SECS: u64 = 120;
const PAIR_TOKEN_TTL_SECS: u64 = 30 * 24 * 60 * 60;
const MAX_PENDING_PAIR_CODES: usize = 64;
const MAX_ISSUED_PAIR_TOKENS: usize = 256;

fn now_unix_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_secs()
}

fn unix_ts_to_rfc3339(ts: u64) -> String {
    Utc.timestamp_opt(ts as i64, 0)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn cleanup_expired_pairing_entries(reg: &mut PairingRegistry, now_ts: u64) {
    reg.pending_codes
        .retain(|_, entry| entry.expires_at_unix > now_ts);
    reg.issued_tokens
        .retain(|_, entry| entry.expires_at_unix > now_ts);
}

pub(super) fn load_tokens_from_state(
    entries: &[PersistedTokenEntry],
) -> HashMap<String, PairTokenEntry> {
    let now_ts = now_unix_ts();
    entries
        .iter()
        .filter(|e| e.expires_at_unix > now_ts)
        .map(|e| {
            (
                e.ws_token.clone(),
                PairTokenEntry {
                    token_id: e.token_id.clone(),
                    device_name: e.device_name.clone(),
                    issued_at_unix: e.issued_at_unix,
                    expires_at_unix: e.expires_at_unix,
                },
            )
        })
        .collect()
}

pub(super) fn new_pairing_registry(entries: &[PersistedTokenEntry]) -> PairingRegistry {
    PairingRegistry {
        pending_codes: HashMap::new(),
        issued_tokens: load_tokens_from_state(entries),
    }
}

pub(super) async fn lookup_paired_info(
    registry: &SharedPairingRegistry,
    token: &str,
) -> Option<(String, String)> {
    let reg = registry.lock().await;
    reg.issued_tokens
        .get(token)
        .map(|entry| (entry.token_id.clone(), entry.device_name.clone()))
}

async fn persist_tokens_to_state(
    tokens: &HashMap<String, PairTokenEntry>,
    app_state: &SharedAppState,
    save_tx: &tokio::sync::mpsc::Sender<()>,
) {
    let entries: Vec<PersistedTokenEntry> = tokens
        .iter()
        .map(|(ws_token, entry)| PersistedTokenEntry {
            token_id: entry.token_id.clone(),
            ws_token: ws_token.clone(),
            device_name: entry.device_name.clone(),
            issued_at_unix: entry.issued_at_unix,
            expires_at_unix: entry.expires_at_unix,
        })
        .collect();
    {
        let mut state = app_state.write().await;
        state.paired_tokens = entries;
    }
    let _ = save_tx.send(()).await;
}

fn generate_pair_code() -> String {
    let raw = Uuid::new_v4().as_u128() % 1_000_000;
    format!("{raw:06}")
}

pub(super) async fn is_ws_token_authorized(
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

pub(super) fn is_request_from_loopback(addr: SocketAddr) -> bool {
    addr.ip().is_loopback()
}

pub(super) async fn pair_start_handler(
    State(ctx): State<ws::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return (
            StatusCode::FORBIDDEN,
            Json(PairErrorResponse {
                error: "forbidden".to_string(),
                message: "pair/start only accepts loopback requests".to_string(),
            }),
        )
            .into_response();
    }

    let now_ts = now_unix_ts();
    let expires_at_unix = now_ts + PAIR_CODE_TTL_SECS;
    let expires_at = unix_ts_to_rfc3339(expires_at_unix);

    let mut reg = ctx.pairing_registry.lock().await;
    cleanup_expired_pairing_entries(&mut reg, now_ts);
    while reg.pending_codes.len() >= MAX_PENDING_PAIR_CODES {
        let oldest = reg
            .pending_codes
            .iter()
            .min_by_key(|(_, entry)| entry.expires_at_unix)
            .map(|(code, _)| code.clone());
        if let Some(code) = oldest {
            reg.pending_codes.remove(&code);
        } else {
            break;
        }
    }

    let pair_code = loop {
        let code = generate_pair_code();
        if !reg.pending_codes.contains_key(&code) {
            break code;
        }
    };
    reg.pending_codes
        .insert(pair_code.clone(), PairCodeEntry { expires_at_unix });

    (
        StatusCode::OK,
        Json(PairStartResponse {
            pair_code,
            expires_at,
            expires_at_unix,
        }),
    )
        .into_response()
}

pub(super) async fn pair_exchange_handler(
    State(ctx): State<ws::AppContext>,
    Json(payload): Json<PairExchangeRequest>,
) -> Response {
    let pair_code = payload.pair_code.trim().to_string();
    if pair_code.len() != 6 || !pair_code.chars().all(|c| c.is_ascii_digit()) {
        return (
            StatusCode::BAD_REQUEST,
            Json(PairErrorResponse {
                error: "invalid_pair_code".to_string(),
                message: "pair_code must be 6 digits".to_string(),
            }),
        )
            .into_response();
    }

    let device_name = payload
        .device_name
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "iOS Device".to_string());

    let mut reg = ctx.pairing_registry.lock().await;
    let now_ts = now_unix_ts();
    cleanup_expired_pairing_entries(&mut reg, now_ts);

    let Some(code_entry) = reg.pending_codes.remove(&pair_code) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(PairErrorResponse {
                error: "pair_code_not_found".to_string(),
                message: "pair_code is invalid or expired".to_string(),
            }),
        )
            .into_response();
    };
    if code_entry.expires_at_unix <= now_ts {
        return (
            StatusCode::UNAUTHORIZED,
            Json(PairErrorResponse {
                error: "pair_code_expired".to_string(),
                message: "pair_code is expired".to_string(),
            }),
        )
            .into_response();
    }

    while reg.issued_tokens.len() >= MAX_ISSUED_PAIR_TOKENS {
        let oldest = reg
            .issued_tokens
            .iter()
            .min_by_key(|(_, entry)| entry.expires_at_unix)
            .map(|(token, _)| token.clone());
        if let Some(token) = oldest {
            reg.issued_tokens.remove(&token);
        } else {
            break;
        }
    }

    let ws_token = Uuid::new_v4().to_string();
    let token_id = Uuid::new_v4().to_string();
    let issued_at_unix = now_ts;
    let expires_at_unix = now_ts + PAIR_TOKEN_TTL_SECS;
    reg.issued_tokens.insert(
        ws_token.clone(),
        PairTokenEntry {
            token_id: token_id.clone(),
            device_name: device_name.clone(),
            issued_at_unix,
            expires_at_unix,
        },
    );

    // 持久化到 AppState
    let tokens_ref = reg.issued_tokens.clone();
    let app_state = ctx.app_state.clone();
    let save_tx = ctx.save_tx.clone();
    tokio::spawn(async move {
        persist_tokens_to_state(&tokens_ref, &app_state, &save_tx).await;
    });

    (
        StatusCode::OK,
        Json(PairExchangeResponse {
            token_id,
            ws_token,
            device_name,
            issued_at: unix_ts_to_rfc3339(issued_at_unix),
            issued_at_unix,
            expires_at: unix_ts_to_rfc3339(expires_at_unix),
            expires_at_unix,
        }),
    )
        .into_response()
}

pub(super) async fn pair_revoke_handler(
    State(ctx): State<ws::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<PairRevokeRequest>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return (
            StatusCode::FORBIDDEN,
            Json(PairErrorResponse {
                error: "forbidden".to_string(),
                message: "pair/revoke only accepts loopback requests".to_string(),
            }),
        )
            .into_response();
    }

    if payload.token_id.is_none() && payload.ws_token.is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(PairErrorResponse {
                error: "invalid_request".to_string(),
                message: "token_id or ws_token is required".to_string(),
            }),
        )
            .into_response();
    }

    let mut reg = ctx.pairing_registry.lock().await;
    let now_ts = now_unix_ts();
    cleanup_expired_pairing_entries(&mut reg, now_ts);

    let mut revoked = 0usize;
    let mut revoked_subscriber_ids = HashSet::new();
    if let Some(ws_token) = payload.ws_token {
        if let Some(entry) = reg.issued_tokens.remove(ws_token.trim()) {
            revoked += 1;
            revoked_subscriber_ids.insert(entry.token_id);
        }
    }
    if let Some(token_id) = payload.token_id {
        let token_id = token_id.trim();
        let matches: Vec<String> = reg
            .issued_tokens
            .iter()
            .filter_map(|(token, entry)| {
                if entry.token_id == token_id {
                    Some(token.clone())
                } else {
                    None
                }
            })
            .collect();
        for token in matches {
            if let Some(entry) = reg.issued_tokens.remove(&token) {
                revoked += 1;
                revoked_subscriber_ids.insert(entry.token_id);
            }
        }
    }

    // 撤销后持久化
    if revoked > 0 {
        let tokens_ref = reg.issued_tokens.clone();
        let app_state = ctx.app_state.clone();
        let save_tx = ctx.save_tx.clone();
        tokio::spawn(async move {
            persist_tokens_to_state(&tokens_ref, &app_state, &save_tx).await;
        });
    }
    drop(reg);

    // 撤销配对后，清理该设备对应的远程终端订阅
    if !revoked_subscriber_ids.is_empty() {
        let mut rsub = ctx.remote_sub_registry.lock().await;
        for subscriber_id in revoked_subscriber_ids {
            rsub.unsubscribe_all(&subscriber_id);
        }
    }

    (
        StatusCode::OK,
        Json(PairRevokeResponse { ok: true, revoked }),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::{
        cleanup_expired_pairing_entries, is_request_from_loopback, is_ws_token_authorized,
        now_unix_ts,
    };
    use super::{PairCodeEntry, PairTokenEntry, PairingRegistry, SharedPairingRegistry};
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
