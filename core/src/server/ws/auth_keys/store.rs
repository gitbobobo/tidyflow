use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64_URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{SecondsFormat, TimeZone, Utc};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

use crate::server::context::SharedAppState;
use crate::workspace::state::RemoteAPIKeyEntry;

use super::model::{
    APIKeyPayload, AuthorizedAPIKeyInfo, RemoteAPIKeyRegistry, SharedRemoteAPIKeyRegistry,
    MAX_REMOTE_API_KEYS,
};

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

fn normalize_name(name: &str) -> String {
    name.trim().to_lowercase()
}

pub(in crate::server::ws) fn new_api_key_registry(
    entries: &[RemoteAPIKeyEntry],
) -> RemoteAPIKeyRegistry {
    let mut keys_by_id = std::collections::HashMap::new();
    let mut key_ids_by_value = std::collections::HashMap::new();
    for entry in entries {
        keys_by_id.insert(entry.key_id.clone(), entry.clone());
        key_ids_by_value.insert(entry.api_key.clone(), entry.key_id.clone());
    }
    RemoteAPIKeyRegistry {
        keys_by_id,
        key_ids_by_value,
    }
}

pub(in crate::server::ws) fn list_api_key_payloads(registry: &RemoteAPIKeyRegistry) -> Vec<APIKeyPayload> {
    let mut items: Vec<_> = registry
        .keys_by_id
        .values()
        .cloned()
        .map(api_key_payload_from_entry)
        .collect();
    items.sort_by(|lhs, rhs| rhs.created_at_unix.cmp(&lhs.created_at_unix));
    items
}

pub(in crate::server::ws) fn api_key_payload_from_entry(entry: RemoteAPIKeyEntry) -> APIKeyPayload {
    APIKeyPayload {
        key_id: entry.key_id,
        name: entry.name,
        api_key: entry.api_key,
        created_at: unix_ts_to_rfc3339(entry.created_at_unix),
        created_at_unix: entry.created_at_unix,
        last_used_at: entry.last_used_at_unix.map(unix_ts_to_rfc3339),
        last_used_at_unix: entry.last_used_at_unix,
    }
}

pub(in crate::server::ws) fn create_api_key_entry(
    registry: &mut RemoteAPIKeyRegistry,
    raw_name: &str,
) -> Result<RemoteAPIKeyEntry, (&'static str, &'static str)> {
    let name = raw_name.trim();
    if name.is_empty() {
        return Err(("invalid_name", "name is required"));
    }
    if registry.keys_by_id.len() >= MAX_REMOTE_API_KEYS {
        return Err(("too_many_keys", "remote API key limit reached"));
    }
    let normalized = normalize_name(name);
    if registry
        .keys_by_id
        .values()
        .any(|entry| normalize_name(&entry.name) == normalized)
    {
        return Err(("duplicate_name", "name must be unique"));
    }

    let entry = RemoteAPIKeyEntry {
        key_id: Uuid::new_v4().to_string(),
        name: name.to_string(),
        api_key: generate_api_key(),
        created_at_unix: now_unix_ts(),
        last_used_at_unix: None,
    };
    registry
        .key_ids_by_value
        .insert(entry.api_key.clone(), entry.key_id.clone());
    registry.keys_by_id.insert(entry.key_id.clone(), entry.clone());
    Ok(entry)
}

pub(in crate::server::ws) fn delete_api_key_entry(
    registry: &mut RemoteAPIKeyRegistry,
    key_id: &str,
) -> Option<RemoteAPIKeyEntry> {
    let entry = registry.keys_by_id.remove(key_id)?;
    registry.key_ids_by_value.remove(&entry.api_key);
    Some(entry)
}

pub(in crate::server::ws) async fn lookup_api_key_info(
    registry: &SharedRemoteAPIKeyRegistry,
    api_key: &str,
) -> Option<AuthorizedAPIKeyInfo> {
    let reg = registry.lock().await;
    let key_id = reg.key_ids_by_value.get(api_key)?;
    let entry = reg.keys_by_id.get(key_id)?;
    Some(AuthorizedAPIKeyInfo {
        key_id: entry.key_id.clone(),
    })
}

pub(in crate::server::ws) async fn touch_api_key_last_used(
    registry: &SharedRemoteAPIKeyRegistry,
    api_key: &str,
    app_state: &SharedAppState,
    save_tx: &tokio::sync::mpsc::Sender<()>,
) -> Option<AuthorizedAPIKeyInfo> {
    let (info, snapshot) = {
        let mut reg = registry.lock().await;
        let key_id = reg.key_ids_by_value.get(api_key)?.clone();
        let entry = reg.keys_by_id.get_mut(&key_id)?;
        let now = now_unix_ts();
        entry.last_used_at_unix = Some(now);
        let info = AuthorizedAPIKeyInfo {
            key_id: entry.key_id.clone(),
        };
        let snapshot: Vec<_> = reg.keys_by_id.values().cloned().collect();
        (info, snapshot)
    };
    persist_api_keys_to_state(&snapshot, app_state, save_tx).await;
    Some(info)
}

pub(in crate::server::ws) async fn persist_api_keys_to_state(
    entries: &[RemoteAPIKeyEntry],
    app_state: &SharedAppState,
    save_tx: &tokio::sync::mpsc::Sender<()>,
) {
    {
        let mut state = app_state.write().await;
        state.remote_api_keys = entries.to_vec();
    }
    let _ = save_tx.send(()).await;
}

fn generate_api_key() -> String {
    let mut bytes = [0u8; 32];
    bytes[..16].copy_from_slice(Uuid::new_v4().as_bytes());
    bytes[16..].copy_from_slice(Uuid::new_v4().as_bytes());
    format!("tfk_{}", BASE64_URL_SAFE_NO_PAD.encode(bytes))
}
