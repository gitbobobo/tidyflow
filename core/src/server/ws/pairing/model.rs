use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct WsAuthQuery {
    pub(in crate::server::ws) token: Option<String>,
}

#[derive(Debug, Default)]
pub(in crate::server::ws) struct PairingRegistry {
    /// key: 6 位配对码
    pub(in crate::server::ws) pending_codes: HashMap<String, PairCodeEntry>,
    /// key: ws_token
    pub(in crate::server::ws) issued_tokens: HashMap<String, PairTokenEntry>,
}

#[derive(Debug, Clone)]
pub(in crate::server::ws) struct PairCodeEntry {
    pub(in crate::server::ws) expires_at_unix: u64,
}

#[derive(Debug, Clone)]
pub(in crate::server::ws) struct PairTokenEntry {
    pub(in crate::server::ws) token_id: String,
    pub(in crate::server::ws) device_name: String,
    pub(in crate::server::ws) issued_at_unix: u64,
    pub(in crate::server::ws) expires_at_unix: u64,
}

pub(in crate::server::ws) type SharedPairingRegistry = Arc<Mutex<PairingRegistry>>;

#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct PairStartResponse {
    pub(in crate::server::ws) pair_code: String,
    pub(in crate::server::ws) expires_at: String,
    pub(in crate::server::ws) expires_at_unix: u64,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct PairExchangeRequest {
    pub(in crate::server::ws) pair_code: String,
    #[serde(default)]
    pub(in crate::server::ws) device_name: Option<String>,
}

#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct PairExchangeResponse {
    pub(in crate::server::ws) token_id: String,
    pub(in crate::server::ws) ws_token: String,
    pub(in crate::server::ws) device_name: String,
    pub(in crate::server::ws) issued_at: String,
    pub(in crate::server::ws) issued_at_unix: u64,
    pub(in crate::server::ws) expires_at: String,
    pub(in crate::server::ws) expires_at_unix: u64,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct PairRevokeRequest {
    #[serde(default)]
    pub(in crate::server::ws) token_id: Option<String>,
    #[serde(default)]
    pub(in crate::server::ws) ws_token: Option<String>,
}

#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct PairRevokeResponse {
    pub(in crate::server::ws) ok: bool,
    pub(in crate::server::ws) revoked: usize,
}

#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct PairErrorResponse {
    pub(in crate::server::ws) error: String,
    pub(in crate::server::ws) message: String,
}

pub(in crate::server::ws) const PAIR_CODE_TTL_SECS: u64 = 120;
pub(in crate::server::ws) const PAIR_TOKEN_TTL_SECS: u64 = 30 * 24 * 60 * 60;
pub(in crate::server::ws) const MAX_PENDING_PAIR_CODES: usize = 64;
pub(in crate::server::ws) const MAX_ISSUED_PAIR_TOKENS: usize = 256;
