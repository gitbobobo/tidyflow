use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64_URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::net::UdpSocket;
use tokio::sync::Mutex;
use tracing::warn;
use uuid::Uuid;

use crate::server::protocol::{
    NodeActiveLockInfo, NodeDiscoveryItemInfo, NodePeerInfo, NodeSelfInfo, PROTOCOL_VERSION,
};
use crate::workspace::state::{
    NodeAuthTokenEntry, NodeDiscoverySettings, NodeIdentity, PairedNodeEntry,
};

use super::context::SharedAppState;

const DISCOVERY_PORT: u16 = 48681;
const DISCOVERY_MAGIC: &str = "tidyflow-node-v1";
const DISCOVERY_INTERVAL_SECS: u64 = 3;

static NODE_RUNTIME: OnceLock<Arc<NodeRuntime>> = OnceLock::new();

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DiscoveryPacket {
    magic: String,
    node_id: String,
    node_name: String,
    host: String,
    port: u16,
    protocol_version: u32,
    ts_unix: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeSelfHttpResponse {
    pub identity: NodeSelfInfo,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auth_token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeNetworkHttpResponse {
    pub identity: NodeSelfInfo,
    pub peers: Vec<NodePeerInfo>,
    #[serde(default)]
    pub active_locks: Vec<NodeActiveLockInfo>,
}

#[derive(Debug, Clone)]
struct DiscoveredNode {
    node_id: String,
    node_name: String,
    host: String,
    port: u16,
    protocol_version: u32,
    last_seen_at_unix: u64,
}

#[derive(Debug, Clone)]
struct ActiveLock {
    repo_coordination_key: String,
    lock_kind: String,
    node_id: String,
    node_name: Option<String>,
    project: String,
    workspace: String,
    acquired_at_unix: u64,
}

pub struct NodeRuntime {
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    bind_addr: Arc<Mutex<String>>,
    port: Arc<Mutex<Option<u16>>>,
    discovered: Arc<Mutex<HashMap<String, DiscoveredNode>>>,
    active_locks: Arc<Mutex<HashMap<(String, String), ActiveLock>>>,
    client: reqwest::Client,
}

impl NodeRuntime {
    fn new(
        app_state: SharedAppState,
        save_tx: tokio::sync::mpsc::Sender<()>,
        bind_addr: String,
    ) -> Self {
        Self {
            app_state,
            save_tx,
            bind_addr: Arc::new(Mutex::new(bind_addr)),
            port: Arc::new(Mutex::new(None)),
            discovered: Arc::new(Mutex::new(HashMap::new())),
            active_locks: Arc::new(Mutex::new(HashMap::new())),
            client: reqwest::Client::new(),
        }
    }

    pub async fn ensure_identity(&self) {
        let mut changed = false;
        {
            let mut state = self.app_state.write().await;
            let next_name = state.client_settings.node_name.clone();
            let discovery_enabled = state.client_settings.node_discovery_enabled;
            if state.node_identity.is_none() {
                state.node_identity = Some(NodeIdentity {
                    node_id: Uuid::new_v4().to_string(),
                    node_name: next_name,
                    bootstrap_pair_key: generate_secret("tfpair"),
                    created_at_unix: now_unix_ts(),
                });
                changed = true;
            } else if let Some(identity) = state.node_identity.as_mut() {
                if identity.node_name != next_name {
                    identity.node_name = next_name;
                    changed = true;
                }
            }
            if state.node_discovery.discovery_enabled != discovery_enabled {
                state.node_discovery = NodeDiscoverySettings {
                    discovery_enabled,
                };
                changed = true;
            }
        }
        if changed {
            let _ = self.save_tx.send(()).await;
        }
    }

    pub async fn set_server_endpoint(&self, bind_addr: String, port: u16) {
        *self.bind_addr.lock().await = bind_addr;
        *self.port.lock().await = Some(port);
    }

    pub async fn self_info(&self) -> NodeSelfInfo {
        self.ensure_identity().await;
        let state = self.app_state.read().await;
        let identity = state
            .node_identity
            .clone()
            .unwrap_or_else(|| NodeIdentity {
                node_id: String::new(),
                node_name: state.client_settings.node_name.clone(),
                bootstrap_pair_key: String::new(),
                created_at_unix: 0,
            });
        NodeSelfInfo {
            node_id: identity.node_id,
            node_name: state.client_settings.node_name.clone().or(identity.node_name),
            bootstrap_pair_key: identity.bootstrap_pair_key,
            discovery_enabled: state.client_settings.node_discovery_enabled,
            remote_access_enabled: state.client_settings.remote_access_enabled,
            bind_addr: Some(self.bind_addr.lock().await.clone()),
            port: *self.port.lock().await,
        }
    }

    pub async fn issue_auth_token(&self, peer_node_id: Option<String>) -> String {
        let token_value = {
            let mut state = self.app_state.write().await;
            if let Some(existing) = peer_node_id.as_ref().and_then(|peer_id| {
                state
                    .node_auth_tokens
                    .iter()
                    .find(|entry| entry.peer_node_id.as_deref() == Some(peer_id.as_str()))
                    .cloned()
            }) {
                existing.token
            } else {
                let token = NodeAuthTokenEntry {
                    token_id: Uuid::new_v4().to_string(),
                    token: generate_secret("tfn"),
                    peer_node_id,
                    created_at_unix: now_unix_ts(),
                    last_used_at_unix: None,
                };
                let token_value = token.token.clone();
                state.node_auth_tokens.push(token);
                token_value
            }
        };
        let _ = self.save_tx.send(()).await;
        token_value
    }

    pub async fn validate_auth_token(&self, token: &str) -> bool {
        let mut matched = false;
        {
            let mut state = self.app_state.write().await;
            if let Some(entry) = state.node_auth_tokens.iter_mut().find(|entry| entry.token == token) {
                entry.last_used_at_unix = Some(now_unix_ts());
                matched = true;
            }
        }
        if matched {
            let _ = self.save_tx.send(()).await;
        }
        matched
    }

    pub async fn list_discovery_items(&self) -> Vec<NodeDiscoveryItemInfo> {
        let discovered = self.discovered.lock().await.clone();
        let state = self.app_state.read().await;
        let paired_ids: std::collections::HashSet<String> = state
            .paired_nodes
            .iter()
            .map(|peer| peer.peer_node_id.clone())
            .collect();
        let mut items: Vec<_> = discovered
            .values()
            .map(|item| NodeDiscoveryItemInfo {
                node_id: item.node_id.clone(),
                node_name: item.node_name.clone(),
                host: item.host.clone(),
                port: item.port,
                protocol_version: item.protocol_version,
                last_seen_at_unix: Some(item.last_seen_at_unix),
                paired: paired_ids.contains(&item.node_id),
            })
            .collect();
        items.sort_by(|lhs, rhs| lhs.node_name.cmp(&rhs.node_name).then(lhs.node_id.cmp(&rhs.node_id)));
        items
    }

    pub async fn list_network_snapshot(&self, include_tokens: bool) -> NodeNetworkHttpResponse {
        let identity = self.self_info().await;
        let state = self.app_state.read().await;
        let peers = state
            .paired_nodes
            .iter()
            .cloned()
            .map(|peer| NodePeerInfo {
                peer_node_id: peer.peer_node_id,
                peer_name: peer.peer_name,
                addresses: peer.addresses,
                port: peer.port,
                trust_source: peer.trust_source,
                introduced_by: peer.introduced_by,
                last_seen_at_unix: peer.last_seen_at_unix,
                status: peer.status,
                auth_token: include_tokens.then_some(peer.auth_token),
            })
            .collect();
        let active_locks = self.active_locks.lock().await.values().cloned().map(|lock| {
            NodeActiveLockInfo {
                repo_coordination_key: lock.repo_coordination_key,
                lock_kind: lock.lock_kind,
                node_id: lock.node_id,
                node_name: lock.node_name,
                project: lock.project,
                workspace: lock.workspace,
                acquired_at_unix: lock.acquired_at_unix,
            }
        }).collect();
        NodeNetworkHttpResponse {
            identity,
            peers,
            active_locks,
        }
    }

    pub async fn pair_peer(
        &self,
        host: &str,
        port: u16,
        pair_key: &str,
    ) -> Result<NodePeerInfo, String> {
        self.ensure_identity().await;
        let url = format!(
            "http://{}:{}/api/v1/node/self?pair_key={}",
            host.trim(),
            port,
            url::form_urlencoded::byte_serialize(pair_key.trim().as_bytes()).collect::<String>()
        );
        let response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(|e| format!("节点握手失败: {}", e))?;
        if !response.status().is_success() {
            return Err(format!("节点握手失败: HTTP {}", response.status()));
        }
        let payload: NodeSelfHttpResponse = response
            .json()
            .await
            .map_err(|e| format!("解析节点响应失败: {}", e))?;
        let auth_token = payload
            .auth_token
            .clone()
            .ok_or_else(|| "对端未返回 auth_token".to_string())?;
        let self_node_id = self
            .self_info()
            .await
            .node_id;
        if payload.identity.node_id == self_node_id {
            return Err("不允许与自身节点配对".to_string());
        }

        let peer_info = {
            let mut state = self.app_state.write().await;
            let entry = PairedNodeEntry {
                peer_node_id: payload.identity.node_id.clone(),
                peer_name: payload
                    .identity
                    .node_name
                    .clone()
                    .unwrap_or_else(|| payload.identity.node_id.clone()),
                addresses: vec![host.trim().to_string()],
                port,
                auth_token: auth_token.clone(),
                trust_source: "paired".to_string(),
                introduced_by: None,
                last_seen_at_unix: Some(now_unix_ts()),
                status: "paired".to_string(),
            };
            upsert_peer(&mut state.paired_nodes, entry.clone());
            NodePeerInfo {
                peer_node_id: entry.peer_node_id,
                peer_name: entry.peer_name,
                addresses: entry.addresses,
                port: entry.port,
                trust_source: entry.trust_source,
                introduced_by: entry.introduced_by,
                last_seen_at_unix: entry.last_seen_at_unix,
                status: entry.status,
                auth_token: Some(entry.auth_token),
            }
        };
        let _ = self.save_tx.send(()).await;
        let _ = self.refresh_network().await;
        Ok(peer_info)
    }

    pub async fn unpair_peer(&self, peer_node_id: &str) -> Result<(), String> {
        {
            let mut state = self.app_state.write().await;
            state
                .paired_nodes
                .retain(|peer| peer.peer_node_id != peer_node_id && peer.introduced_by.as_deref() != Some(peer_node_id));
            state
                .node_auth_tokens
                .retain(|token| token.peer_node_id.as_deref() != Some(peer_node_id));
        }
        let _ = self.save_tx.send(()).await;
        self.refresh_network().await?;
        Ok(())
    }

    pub async fn refresh_network(&self) -> Result<(), String> {
        let manual_peers = {
            let state = self.app_state.read().await;
            state
                .paired_nodes
                .iter()
                .filter(|peer| peer.trust_source != "network")
                .cloned()
                .collect::<Vec<_>>()
        };

        let mut imported: Vec<PairedNodeEntry> = Vec::new();
        for peer in manual_peers {
            match self.fetch_peer_network(&peer).await {
                Ok(snapshot) => {
                    self.mark_peer_seen(&peer.peer_node_id, Some(now_unix_ts()), "paired")
                        .await;
                    for nested in snapshot.peers {
                        if nested.peer_node_id == peer.peer_node_id {
                            continue;
                        }
                        let Some(auth_token) = nested.auth_token.clone() else {
                            continue;
                        };
                        imported.push(PairedNodeEntry {
                            peer_node_id: nested.peer_node_id,
                            peer_name: nested.peer_name,
                            addresses: nested.addresses,
                            port: nested.port,
                            auth_token,
                            trust_source: "network".to_string(),
                            introduced_by: Some(peer.peer_node_id.clone()),
                            last_seen_at_unix: nested.last_seen_at_unix.or(Some(now_unix_ts())),
                            status: nested.status,
                        });
                    }
                }
                Err(err) => {
                    warn!(peer = %peer.peer_node_id, error = %err, "refresh peer network failed");
                    self.mark_peer_seen(&peer.peer_node_id, None, "unreachable").await;
                }
            }
        }

        {
            let mut state = self.app_state.write().await;
            state.paired_nodes.retain(|peer| peer.trust_source != "network");
            let self_node_id = state
                .node_identity
                .as_ref()
                .map(|identity| identity.node_id.clone())
                .unwrap_or_default();
            for peer in imported {
                if peer.peer_node_id == self_node_id {
                    continue;
                }
                if state
                    .paired_nodes
                    .iter()
                    .any(|existing| existing.peer_node_id == peer.peer_node_id)
                {
                    continue;
                }
                state.paired_nodes.push(peer);
            }
        }
        let _ = self.save_tx.send(()).await;
        Ok(())
    }

    async fn fetch_peer_network(&self, peer: &PairedNodeEntry) -> Result<NodeNetworkHttpResponse, String> {
        let host = peer
            .addresses
            .first()
            .cloned()
            .ok_or_else(|| "peer address missing".to_string())?;
        let url = format!(
            "http://{}:{}/api/v1/node/network?auth_token={}",
            host,
            peer.port,
            url::form_urlencoded::byte_serialize(peer.auth_token.as_bytes()).collect::<String>()
        );
        let response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(|e| format!("读取对端网络失败: {}", e))?;
        if !response.status().is_success() {
            return Err(format!("读取对端网络失败: HTTP {}", response.status()));
        }
        response
            .json()
            .await
            .map_err(|e| format!("解析对端网络失败: {}", e))
    }

    async fn mark_peer_seen(&self, peer_node_id: &str, seen_at: Option<u64>, status: &str) {
        let mut changed = false;
        {
            let mut state = self.app_state.write().await;
            if let Some(peer) = state
                .paired_nodes
                .iter_mut()
                .find(|peer| peer.peer_node_id == peer_node_id)
            {
                peer.last_seen_at_unix = seen_at.or(peer.last_seen_at_unix);
                peer.status = status.to_string();
                changed = true;
            }
        }
        if changed {
            let _ = self.save_tx.send(()).await;
        }
    }

    pub async fn try_acquire_network_lock(
        &self,
        repo_coordination_key: &str,
        lock_kind: &str,
        project: &str,
        workspace: &str,
    ) -> Result<Option<NodeActiveLockInfo>, String> {
        let self_info = self.self_info().await;
        let now = now_unix_ts();
        let existing_remote = self.find_remote_lock(repo_coordination_key, lock_kind).await?;
        if let Some(remote) = existing_remote {
            if remote.node_id != self_info.node_id {
                return Ok(Some(remote));
            }
        }

        let local_lock = ActiveLock {
            repo_coordination_key: repo_coordination_key.to_string(),
            lock_kind: lock_kind.to_string(),
            node_id: self_info.node_id.clone(),
            node_name: self_info.node_name.clone(),
            project: project.to_string(),
            workspace: workspace.to_string(),
            acquired_at_unix: now,
        };
        self.active_locks
            .lock()
            .await
            .insert((repo_coordination_key.to_string(), lock_kind.to_string()), local_lock);
        Ok(None)
    }

    pub async fn release_network_lock(&self, repo_coordination_key: &str, lock_kind: &str) {
        self.active_locks
            .lock()
            .await
            .remove(&(repo_coordination_key.to_string(), lock_kind.to_string()));
    }

    async fn find_remote_lock(
        &self,
        repo_coordination_key: &str,
        lock_kind: &str,
    ) -> Result<Option<NodeActiveLockInfo>, String> {
        let peers = {
            let state = self.app_state.read().await;
            state
                .paired_nodes
                .iter()
                .filter(|peer| peer.status == "paired")
                .cloned()
                .collect::<Vec<_>>()
        };
        let mut active: Vec<NodeActiveLockInfo> = Vec::new();
        for peer in peers {
            if let Ok(snapshot) = self.fetch_peer_network(&peer).await {
                active.extend(snapshot.active_locks.into_iter().filter(|lock| {
                    lock.repo_coordination_key == repo_coordination_key && lock.lock_kind == lock_kind
                }));
            }
        }
        active.sort_by(|lhs, rhs| {
            lhs.acquired_at_unix
                .cmp(&rhs.acquired_at_unix)
                .then(lhs.node_id.cmp(&rhs.node_id))
        });
        Ok(active.into_iter().next())
    }

    pub async fn start_background_tasks(self: &Arc<Self>) {
        let listener_runtime = self.clone();
        tokio::spawn(async move {
            if let Err(err) = listener_runtime.discovery_listener_loop().await {
                warn!(error = %err, "node discovery listener stopped");
            }
        });
        let broadcaster_runtime = self.clone();
        tokio::spawn(async move {
            broadcaster_runtime.discovery_broadcast_loop().await;
        });
    }

    async fn discovery_listener_loop(&self) -> Result<(), String> {
        let socket = UdpSocket::bind(("0.0.0.0", DISCOVERY_PORT))
            .await
            .map_err(|e| format!("bind discovery listener failed: {}", e))?;
        let mut buf = [0u8; 2048];
        loop {
            let (len, _addr) = socket
                .recv_from(&mut buf)
                .await
                .map_err(|e| format!("recv discovery packet failed: {}", e))?;
            let Ok(packet) = serde_json::from_slice::<DiscoveryPacket>(&buf[..len]) else {
                continue;
            };
            if packet.magic != DISCOVERY_MAGIC || packet.protocol_version != PROTOCOL_VERSION {
                continue;
            }
            let self_node_id = self.self_info().await.node_id;
            if packet.node_id == self_node_id {
                continue;
            }
            self.discovered.lock().await.insert(
                packet.node_id.clone(),
                DiscoveredNode {
                    node_id: packet.node_id.clone(),
                    node_name: packet.node_name.clone(),
                    host: packet.host.clone(),
                    port: packet.port,
                    protocol_version: packet.protocol_version,
                    last_seen_at_unix: packet.ts_unix,
                },
            );
            self.mark_peer_seen(&packet.node_id, Some(packet.ts_unix), "paired")
                .await;
        }
    }

    async fn discovery_broadcast_loop(&self) {
        let Ok(socket) = UdpSocket::bind(("0.0.0.0", 0)).await else {
            return;
        };
        if socket.set_broadcast(true).is_err() {
            return;
        }
        loop {
            tokio::time::sleep(Duration::from_secs(DISCOVERY_INTERVAL_SECS)).await;
            let (enabled, packet) = match self.discovery_packet().await {
                Some(packet) => (true, packet),
                None => (false, DiscoveryPacket {
                    magic: String::new(),
                    node_id: String::new(),
                    node_name: String::new(),
                    host: String::new(),
                    port: 0,
                    protocol_version: PROTOCOL_VERSION,
                    ts_unix: 0,
                }),
            };
            if !enabled {
                continue;
            }
            let Ok(payload) = serde_json::to_vec(&packet) else {
                continue;
            };
            let _ = socket
                .send_to(&payload, format!("255.255.255.255:{}", DISCOVERY_PORT))
                .await;
        }
    }

    async fn discovery_packet(&self) -> Option<DiscoveryPacket> {
        let self_info = self.self_info().await;
        if !self_info.remote_access_enabled || !self_info.discovery_enabled {
            return None;
        }
        let node_name = self_info.node_name.filter(|value| !value.trim().is_empty())?;
        let port = self_info.port?;
        let host = discover_primary_ipv4().unwrap_or_else(|| "127.0.0.1".to_string());
        Some(DiscoveryPacket {
            magic: DISCOVERY_MAGIC.to_string(),
            node_id: self_info.node_id,
            node_name,
            host,
            port,
            protocol_version: PROTOCOL_VERSION,
            ts_unix: now_unix_ts(),
        })
    }
}

pub async fn init_global(
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    bind_addr: String,
) -> Arc<NodeRuntime> {
    let runtime = NODE_RUNTIME.get_or_init(|| Arc::new(NodeRuntime::new(app_state, save_tx, bind_addr)));
    runtime.ensure_identity().await;
    runtime.start_background_tasks().await;
    runtime.clone()
}

pub fn maybe_runtime() -> Option<Arc<NodeRuntime>> {
    NODE_RUNTIME.get().cloned()
}

fn upsert_peer(peers: &mut Vec<PairedNodeEntry>, entry: PairedNodeEntry) {
    if let Some(existing) = peers
        .iter_mut()
        .find(|peer| peer.peer_node_id == entry.peer_node_id)
    {
        *existing = entry;
    } else {
        peers.push(entry);
    }
}

fn generate_secret(prefix: &str) -> String {
    let mut bytes = [0u8; 32];
    bytes[..16].copy_from_slice(Uuid::new_v4().as_bytes());
    bytes[16..].copy_from_slice(Uuid::new_v4().as_bytes());
    format!("{}_{}", prefix, BASE64_URL_SAFE_NO_PAD.encode(bytes))
}

pub fn now_unix_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_secs()
}

fn discover_primary_ipv4() -> Option<String> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    let _ = socket.connect("8.8.8.8:80");
    socket.local_addr().ok().map(|addr| addr.ip().to_string())
}
