use chrono::{SecondsFormat, TimeZone, Utc};
use std::collections::HashMap;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

use crate::server::context::SharedAppState;
use crate::workspace::state::PersistedTokenEntry;

use super::model::{PairTokenEntry, PairingRegistry, SharedPairingRegistry};

pub(in crate::server::ws) fn now_unix_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_secs()
}

pub(in crate::server::ws) fn unix_ts_to_rfc3339(ts: u64) -> String {
    Utc.timestamp_opt(ts as i64, 0)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub(in crate::server::ws) fn cleanup_expired_pairing_entries(reg: &mut PairingRegistry, now_ts: u64) {
    reg.pending_codes
        .retain(|_, entry| entry.expires_at_unix > now_ts);
    reg.issued_tokens
        .retain(|_, entry| entry.expires_at_unix > now_ts);
}

pub(in crate::server::ws) fn load_tokens_from_state(
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

pub(in crate::server::ws) fn new_pairing_registry(entries: &[PersistedTokenEntry]) -> PairingRegistry {
    PairingRegistry {
        pending_codes: HashMap::new(),
        issued_tokens: load_tokens_from_state(entries),
    }
}

pub(in crate::server::ws) async fn lookup_paired_info(
    registry: &SharedPairingRegistry,
    token: &str,
) -> Option<(String, String)> {
    let reg = registry.lock().await;
    reg.issued_tokens
        .get(token)
        .map(|entry| (entry.token_id.clone(), entry.device_name.clone()))
}

pub(in crate::server::ws) async fn persist_tokens_to_state(
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

pub(in crate::server::ws) fn generate_pair_code() -> String {
    let raw = Uuid::new_v4().as_u128() % 1_000_000;
    format!("{raw:06}")
}
