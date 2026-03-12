use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::{oneshot, Mutex};

pub struct RevokedRemoteConnection {
    pub shutdown_tx: oneshot::Sender<String>,
    pub subscriber_id: String,
}

struct RemoteConnectionControl {
    conn_id: String,
    subscriber_id: String,
    shutdown_tx: oneshot::Sender<String>,
}

pub struct RemoteConnectionRegistry {
    by_key: HashMap<String, HashMap<String, RemoteConnectionControl>>,
    key_by_conn: HashMap<String, String>,
}

impl RemoteConnectionRegistry {
    pub fn new() -> Self {
        Self {
            by_key: HashMap::new(),
            key_by_conn: HashMap::new(),
        }
    }

    pub fn register(
        &mut self,
        key_id: &str,
        conn_id: &str,
        subscriber_id: &str,
        shutdown_tx: oneshot::Sender<String>,
    ) {
        self.key_by_conn
            .insert(conn_id.to_string(), key_id.to_string());
        self.by_key
            .entry(key_id.to_string())
            .or_default()
            .insert(
                conn_id.to_string(),
                RemoteConnectionControl {
                    conn_id: conn_id.to_string(),
                    subscriber_id: subscriber_id.to_string(),
                    shutdown_tx,
                },
            );
    }

    pub fn unregister(&mut self, conn_id: &str) {
        let Some(key_id) = self.key_by_conn.remove(conn_id) else {
            return;
        };
        if let Some(connections) = self.by_key.get_mut(&key_id) {
            connections.remove(conn_id);
            if connections.is_empty() {
                self.by_key.remove(&key_id);
            }
        }
    }

    pub fn revoke_key(&mut self, key_id: &str) -> Vec<RevokedRemoteConnection> {
        self.by_key
            .remove(key_id)
            .into_iter()
            .flat_map(|connections| connections.into_values())
            .map(|control| {
                self.key_by_conn.remove(&control.conn_id);
                RevokedRemoteConnection {
                    shutdown_tx: control.shutdown_tx,
                    subscriber_id: control.subscriber_id,
                }
            })
            .collect()
    }
}

pub type SharedRemoteConnectionRegistry = Arc<Mutex<RemoteConnectionRegistry>>;
