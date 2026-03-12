use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::workspace::state::RemoteAPIKeyEntry;

#[derive(Debug, Default, Deserialize, Clone)]
pub(in crate::server::ws) struct WsAuthQuery {
    pub(in crate::server::ws) token: Option<String>,
    pub(in crate::server::ws) client_id: Option<String>,
    pub(in crate::server::ws) device_name: Option<String>,
}

#[derive(Debug, Default)]
pub(in crate::server::ws) struct RemoteAPIKeyRegistry {
    pub(in crate::server::ws) keys_by_id: HashMap<String, RemoteAPIKeyEntry>,
    pub(in crate::server::ws) key_ids_by_value: HashMap<String, String>,
}

pub(in crate::server::ws) type SharedRemoteAPIKeyRegistry = Arc<Mutex<RemoteAPIKeyRegistry>>;

#[derive(Debug, Clone)]
pub(in crate::server::ws) struct AuthorizedAPIKeyInfo {
    pub(in crate::server::ws) key_id: String,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct CreateAPIKeyRequest {
    pub(in crate::server::ws) name: String,
}

#[derive(Debug, Serialize, Clone)]
pub(in crate::server::ws) struct APIKeyPayload {
    pub(in crate::server::ws) key_id: String,
    pub(in crate::server::ws) name: String,
    pub(in crate::server::ws) api_key: String,
    pub(in crate::server::ws) created_at: String,
    pub(in crate::server::ws) created_at_unix: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(in crate::server::ws) last_used_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(in crate::server::ws) last_used_at_unix: Option<u64>,
}

#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct APIKeyListResponse {
    pub(in crate::server::ws) items: Vec<APIKeyPayload>,
}

#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct APIKeyDeleteResponse {
    pub(in crate::server::ws) ok: bool,
    pub(in crate::server::ws) deleted: usize,
}

#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct APIKeyErrorResponse {
    pub(in crate::server::ws) error: String,
    pub(in crate::server::ws) message: String,
}

pub(in crate::server::ws) const MAX_REMOTE_API_KEYS: usize = 256;
