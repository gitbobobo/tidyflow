use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64_URL_SAFE_NO_PAD;
use mdns_sd::{DaemonEvent, ResolvedService, ServiceDaemon, ServiceEvent, ServiceInfo};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::server::protocol::{
    NodeActiveLockInfo, NodeDiscoveryItemInfo, NodePeerInfo, NodeSelfInfo, PROTOCOL_VERSION,
};
use crate::workspace::state::{
    NodeAuthTokenEntry, NodeDiscoverySettings, NodeIdentity, PairedNodeEntry,
};

use super::context::SharedAppState;

const DISCOVERY_SERVICE_TYPE: &str = "_tidyflow-node._tcp.local.";
const DISCOVERY_HOST_PREFIX: &str = "tidyflow-node-";

static NODE_RUNTIME: OnceLock<Arc<NodeRuntime>> = OnceLock::new();

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
    fullname: String,
    node_id: String,
    node_name: String,
    host: String,
    port: u16,
    protocol_version: u32,
    last_seen_at_unix: u64,
}

#[derive(Debug, Clone)]
struct DiscoveryAdvertisement {
    service_info: ServiceInfo,
    state: AdvertisedServiceState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AdvertisedServiceState {
    fullname: String,
    host_name: String,
    instance_name: String,
    port: u16,
}

#[derive(Debug, Clone)]
struct DiscoverySnapshot {
    node_id: String,
    node_name: Option<String>,
    remote_access_enabled: bool,
    discovery_enabled: bool,
    bind_addr: String,
    port: Option<u16>,
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
    discovery_daemon: Option<Arc<ServiceDaemon>>,
    advertised_service: Arc<Mutex<Option<AdvertisedServiceState>>>,
    background_started: AtomicBool,
}

impl NodeRuntime {
    fn new(
        app_state: SharedAppState,
        save_tx: tokio::sync::mpsc::Sender<()>,
        bind_addr: String,
    ) -> Self {
        let discovery_daemon = match ServiceDaemon::new() {
            Ok(daemon) => Some(Arc::new(daemon)),
            Err(err) => {
                warn!(error = %err, "failed to start node discovery daemon");
                None
            }
        };
        Self {
            app_state,
            save_tx,
            bind_addr: Arc::new(Mutex::new(bind_addr)),
            port: Arc::new(Mutex::new(None)),
            discovered: Arc::new(Mutex::new(HashMap::new())),
            active_locks: Arc::new(Mutex::new(HashMap::new())),
            client: reqwest::Client::new(),
            discovery_daemon,
            advertised_service: Arc::new(Mutex::new(None)),
            background_started: AtomicBool::new(false),
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
                state.node_discovery = NodeDiscoverySettings { discovery_enabled };
                changed = true;
            }
        }
        if changed {
            let _ = self.save_tx.send(()).await;
        }
        self.reconcile_discovery_advertisement().await;
    }

    pub async fn set_server_endpoint(&self, bind_addr: String, port: u16) {
        *self.bind_addr.lock().await = bind_addr;
        *self.port.lock().await = Some(port);
        self.reconcile_discovery_advertisement().await;
    }

    pub async fn self_info(&self) -> NodeSelfInfo {
        self.ensure_identity().await;
        let state = self.app_state.read().await;
        let identity = state.node_identity.clone().unwrap_or_else(|| NodeIdentity {
            node_id: String::new(),
            node_name: state.client_settings.node_name.clone(),
            bootstrap_pair_key: String::new(),
            created_at_unix: 0,
        });
        NodeSelfInfo {
            node_id: identity.node_id,
            node_name: state
                .client_settings
                .node_name
                .clone()
                .or(identity.node_name),
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
            if let Some(entry) = state
                .node_auth_tokens
                .iter_mut()
                .find(|entry| entry.token == token)
            {
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
        items.sort_by(|lhs, rhs| {
            lhs.node_name
                .cmp(&rhs.node_name)
                .then(lhs.node_id.cmp(&rhs.node_id))
        });
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
        let active_locks = self
            .active_locks
            .lock()
            .await
            .values()
            .cloned()
            .map(|lock| NodeActiveLockInfo {
                repo_coordination_key: lock.repo_coordination_key,
                lock_kind: lock.lock_kind,
                node_id: lock.node_id,
                node_name: lock.node_name,
                project: lock.project,
                workspace: lock.workspace,
                acquired_at_unix: lock.acquired_at_unix,
            })
            .collect();
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
        let self_node_id = self.self_info().await.node_id;
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
            state.paired_nodes.retain(|peer| {
                peer.peer_node_id != peer_node_id
                    && peer.introduced_by.as_deref() != Some(peer_node_id)
            });
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
                    self.mark_peer_seen(&peer.peer_node_id, None, "unreachable")
                        .await;
                }
            }
        }

        {
            let mut state = self.app_state.write().await;
            state
                .paired_nodes
                .retain(|peer| peer.trust_source != "network");
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

    async fn fetch_peer_network(
        &self,
        peer: &PairedNodeEntry,
    ) -> Result<NodeNetworkHttpResponse, String> {
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
        let existing_remote = self
            .find_remote_lock(repo_coordination_key, lock_kind)
            .await?;
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
        self.active_locks.lock().await.insert(
            (repo_coordination_key.to_string(), lock_kind.to_string()),
            local_lock,
        );
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
                    lock.repo_coordination_key == repo_coordination_key
                        && lock.lock_kind == lock_kind
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
        if self.background_started.swap(true, Ordering::AcqRel) {
            return;
        }
        let Some(daemon) = self.discovery_daemon.clone() else {
            return;
        };
        let browser_runtime = self.clone();
        match daemon.browse(DISCOVERY_SERVICE_TYPE) {
            Ok(receiver) => {
                tokio::spawn(async move {
                    while let Ok(event) = receiver.recv_async().await {
                        browser_runtime.handle_discovery_event(event).await;
                    }
                    warn!("node discovery browser stopped");
                });
            }
            Err(err) => {
                warn!(error = %err, "failed to start node discovery browser");
            }
        }

        let monitor_runtime = self.clone();
        match daemon.monitor() {
            Ok(receiver) => {
                tokio::spawn(async move {
                    while let Ok(event) = receiver.recv_async().await {
                        monitor_runtime.handle_discovery_daemon_event(event).await;
                    }
                    warn!("node discovery monitor stopped");
                });
            }
            Err(err) => {
                warn!(error = %err, "failed to start node discovery monitor");
            }
        }

        self.reconcile_discovery_advertisement().await;
    }

    pub async fn reconcile_discovery_advertisement(&self) {
        let Some(daemon) = self.discovery_daemon.clone() else {
            return;
        };

        let snapshot = self.capture_discovery_snapshot().await;
        let desired = match build_discovery_advertisement(snapshot) {
            Ok(desired) => desired,
            Err(err) => {
                warn!(error = %err, "failed to build node discovery advertisement");
                self.unregister_advertised_service(&daemon).await;
                return;
            }
        };

        let current = self.advertised_service.lock().await.clone();
        let Some(advertisement) = desired else {
            if current.is_some() {
                self.unregister_advertised_service(&daemon).await;
            }
            return;
        };

        if current.as_ref() == Some(&advertisement.state) {
            debug!(
                fullname = %advertisement.state.fullname,
                "node discovery service advertisement already up to date"
            );
            return;
        }

        if let Some(current) = current.as_ref() {
            if !current
                .fullname
                .eq_ignore_ascii_case(&advertisement.state.fullname)
                || current != &advertisement.state
            {
                self.unregister_advertised_service(&daemon).await;
            }
        }

        match daemon.register(advertisement.service_info) {
            Ok(()) => {
                let mut current = self.advertised_service.lock().await;
                let changed = current.as_ref() != Some(&advertisement.state);
                *current = Some(advertisement.state.clone());
                if changed {
                    info!(
                        fullname = %advertisement.state.fullname,
                        "node discovery service registered"
                    );
                } else {
                    debug!(
                        fullname = %advertisement.state.fullname,
                        "node discovery service refreshed"
                    );
                }
            }
            Err(err) => {
                warn!(
                    fullname = %advertisement.state.fullname,
                    error = %err,
                    "failed to register node discovery service"
                );
            }
        }
    }

    async fn capture_discovery_snapshot(&self) -> DiscoverySnapshot {
        let state = self.app_state.read().await;
        let identity = state.node_identity.clone().unwrap_or_default();
        DiscoverySnapshot {
            node_id: identity.node_id,
            node_name: state
                .client_settings
                .node_name
                .clone()
                .or(identity.node_name),
            remote_access_enabled: state.client_settings.remote_access_enabled,
            discovery_enabled: state.client_settings.node_discovery_enabled,
            bind_addr: self.bind_addr.lock().await.clone(),
            port: *self.port.lock().await,
        }
    }

    async fn unregister_advertised_service(&self, daemon: &ServiceDaemon) {
        let state = self.advertised_service.lock().await.take();
        let Some(state) = state else {
            return;
        };
        let fullname = state.fullname;
        match daemon.unregister(&fullname) {
            Ok(_) => info!(fullname = %fullname, "node discovery service unregistered"),
            Err(err) => {
                warn!(fullname = %fullname, error = %err, "failed to unregister node discovery service")
            }
        }
    }

    async fn handle_discovery_event(&self, event: ServiceEvent) {
        match event {
            ServiceEvent::ServiceResolved(resolved) => {
                self.handle_resolved_service(*resolved).await;
            }
            ServiceEvent::ServiceRemoved(_, fullname) => {
                let removed = self.remove_discovered_by_fullname(&fullname).await;
                if removed {
                    debug!(fullname = %fullname, "node discovery service removed");
                }
            }
            ServiceEvent::SearchStarted(service_type) => {
                debug!(service_type = %service_type, "node discovery browse started");
            }
            ServiceEvent::SearchStopped(service_type) => {
                warn!(service_type = %service_type, "node discovery browse stopped");
            }
            ServiceEvent::ServiceFound(_, fullname) => {
                debug!(fullname = %fullname, "node discovery service found");
            }
            _ => {
                debug!("node discovery browser emitted an unhandled event");
            }
        }
    }

    async fn handle_resolved_service(&self, resolved: ResolvedService) {
        let fullname = resolved.get_fullname().to_string();
        let self_node_id = self.capture_discovery_snapshot().await.node_id;
        match map_resolved_service_to_discovered_node(&resolved, &self_node_id) {
            Ok(Some(node)) => {
                self.discovered
                    .lock()
                    .await
                    .insert(node.node_id.clone(), node.clone());
                debug!(
                    node_id = %node.node_id,
                    host = %node.host,
                    port = node.port,
                    "node discovery service resolved"
                );
            }
            Ok(None) => {
                self.remove_discovered_by_fullname(&fullname).await;
            }
            Err(err) => {
                warn!(fullname = %fullname, error = %err, "failed to map node discovery service");
                self.remove_discovered_by_fullname(&fullname).await;
            }
        }
    }

    async fn remove_discovered_by_fullname(&self, fullname: &str) -> bool {
        let mut discovered = self.discovered.lock().await;
        let before = discovered.len();
        discovered.retain(|_, item| !item.fullname.eq_ignore_ascii_case(fullname));
        before != discovered.len()
    }

    async fn handle_discovery_daemon_event(&self, event: DaemonEvent) {
        match event {
            DaemonEvent::Error(error) => {
                warn!(error = %error, "node discovery daemon reported an error");
            }
            DaemonEvent::NameChange(change) => {
                let mut state = self.advertised_service.lock().await;
                if state
                    .as_ref()
                    .map(|value| value.fullname.eq_ignore_ascii_case(&change.original))
                    .unwrap_or(false)
                {
                    if let Some(current) = state.as_mut() {
                        current.fullname = change.new_name.clone();
                    }
                    warn!(
                        original = %change.original,
                        new_name = %change.new_name,
                        "node discovery service name changed due to conflict"
                    );
                }
            }
            DaemonEvent::IpAdd(ip) => {
                debug!(ip = %ip, "node discovery daemon detected IP add");
            }
            DaemonEvent::IpDel(ip) => {
                debug!(ip = %ip, "node discovery daemon detected IP del");
            }
            DaemonEvent::Announce(service, interface) => {
                debug!(service = %service, interface = %interface, "node discovery service announced");
            }
            DaemonEvent::Respond(name) => {
                debug!(name = %name, "node discovery daemon responded");
            }
            _ => {
                debug!("node discovery daemon emitted an unhandled event");
            }
        }
    }
}

pub async fn init_global(
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    bind_addr: String,
) -> Arc<NodeRuntime> {
    let runtime =
        NODE_RUNTIME.get_or_init(|| Arc::new(NodeRuntime::new(app_state, save_tx, bind_addr)));
    runtime.ensure_identity().await;
    runtime.start_background_tasks().await;
    runtime.clone()
}

pub fn maybe_runtime() -> Option<Arc<NodeRuntime>> {
    NODE_RUNTIME.get().cloned()
}

fn build_discovery_advertisement(
    snapshot: DiscoverySnapshot,
) -> Result<Option<DiscoveryAdvertisement>, String> {
    if !snapshot.remote_access_enabled || !snapshot.discovery_enabled {
        return Ok(None);
    }
    let Some(port) = snapshot.port else {
        return Ok(None);
    };
    if is_loopback_bind_addr(&snapshot.bind_addr) {
        return Ok(None);
    }
    let Some(node_name) = snapshot
        .node_name
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };
    let host_name = discovery_hostname(&snapshot.node_id);
    let properties = HashMap::from([
        ("node_id".to_string(), snapshot.node_id.clone()),
        ("node_name".to_string(), node_name.clone()),
        ("protocol_version".to_string(), PROTOCOL_VERSION.to_string()),
    ]);
    let service_info = ServiceInfo::new(
        DISCOVERY_SERVICE_TYPE,
        &node_name,
        &host_name,
        "",
        port,
        properties,
    )
    .map_err(|err| format!("创建节点 DNS-SD 服务失败: {err}"))?
    .enable_addr_auto();
    let fullname = service_info.get_fullname().to_string();
    Ok(Some(DiscoveryAdvertisement {
        service_info,
        state: AdvertisedServiceState {
            fullname,
            host_name,
            instance_name: node_name,
            port,
        },
    }))
}

fn map_resolved_service_to_discovered_node(
    resolved: &ResolvedService,
    self_node_id: &str,
) -> Result<Option<DiscoveredNode>, String> {
    let node_id = resolved
        .get_property_val_str("node_id")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "缺少 node_id".to_string())?
        .to_string();
    if node_id == self_node_id {
        return Ok(None);
    }

    let protocol_version = resolved
        .get_property_val_str("protocol_version")
        .ok_or_else(|| "缺少 protocol_version".to_string())?
        .parse::<u32>()
        .map_err(|_| "protocol_version 非法".to_string())?;
    if protocol_version != PROTOCOL_VERSION {
        warn!(
            fullname = %resolved.get_fullname(),
            expected = PROTOCOL_VERSION,
            actual = protocol_version,
            "ignoring discovery service due to protocol version mismatch"
        );
        return Ok(None);
    }

    let host = select_discovery_host(resolved).ok_or_else(|| "未解析到可用地址".to_string())?;
    let node_name = resolved
        .get_property_val_str("node_name")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(&node_id)
        .to_string();
    Ok(Some(DiscoveredNode {
        fullname: resolved.get_fullname().to_string(),
        node_id,
        node_name,
        host,
        port: resolved.get_port(),
        protocol_version,
        last_seen_at_unix: now_unix_ts(),
    }))
}

fn select_discovery_host(resolved: &ResolvedService) -> Option<String> {
    let mut ipv4_addrs: Vec<_> = resolved
        .get_addresses_v4()
        .into_iter()
        .filter(|ip| !ip.is_loopback())
        .collect();
    ipv4_addrs.sort();
    if let Some(ip) = ipv4_addrs.into_iter().next() {
        return Some(ip.to_string());
    }

    let mut addrs: Vec<IpAddr> = resolved
        .get_addresses()
        .iter()
        .map(|addr| addr.to_ip_addr())
        .filter(|ip| !ip.is_loopback())
        .collect();
    addrs.sort_by(|lhs, rhs| lhs.to_string().cmp(&rhs.to_string()));
    addrs.into_iter().next().map(|ip| ip.to_string())
}

fn discovery_hostname(node_id: &str) -> String {
    let suffix = node_id
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>();
    format!("{DISCOVERY_HOST_PREFIX}{suffix}.local.")
}

fn is_loopback_bind_addr(bind_addr: &str) -> bool {
    matches!(bind_addr.trim(), "" | "127.0.0.1" | "::1" | "localhost")
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

#[cfg(test)]
mod tests {
    use super::{
        DISCOVERY_SERVICE_TYPE, DiscoverySnapshot, build_discovery_advertisement,
        discovery_hostname, is_loopback_bind_addr, map_resolved_service_to_discovered_node,
        select_discovery_host,
    };
    use crate::server::protocol::PROTOCOL_VERSION;
    use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
    use std::collections::HashMap;
    use std::time::Duration;

    #[test]
    fn discovery_advertisement_should_require_remote_access() {
        let snapshot = DiscoverySnapshot {
            node_id: "node-1".to_string(),
            node_name: Some("Node 1".to_string()),
            remote_access_enabled: false,
            discovery_enabled: true,
            bind_addr: "0.0.0.0".to_string(),
            port: Some(8439),
        };
        assert!(build_discovery_advertisement(snapshot).unwrap().is_none());
    }

    #[test]
    fn discovery_advertisement_should_require_node_name() {
        let snapshot = DiscoverySnapshot {
            node_id: "node-1".to_string(),
            node_name: Some("   ".to_string()),
            remote_access_enabled: true,
            discovery_enabled: true,
            bind_addr: "0.0.0.0".to_string(),
            port: Some(8439),
        };
        assert!(build_discovery_advertisement(snapshot).unwrap().is_none());
    }

    #[test]
    fn discovery_advertisement_should_require_port() {
        let snapshot = DiscoverySnapshot {
            node_id: "node-1".to_string(),
            node_name: Some("Node 1".to_string()),
            remote_access_enabled: true,
            discovery_enabled: true,
            bind_addr: "0.0.0.0".to_string(),
            port: None,
        };
        assert!(build_discovery_advertisement(snapshot).unwrap().is_none());
    }

    #[test]
    fn discovery_advertisement_should_not_publish_when_bind_addr_is_loopback() {
        let snapshot = DiscoverySnapshot {
            node_id: "node-1".to_string(),
            node_name: Some("Node 1".to_string()),
            remote_access_enabled: true,
            discovery_enabled: true,
            bind_addr: "127.0.0.1".to_string(),
            port: Some(8439),
        };
        assert!(build_discovery_advertisement(snapshot).unwrap().is_none());
        assert!(is_loopback_bind_addr("localhost"));
        assert!(is_loopback_bind_addr("::1"));
    }

    #[test]
    fn discovery_hostname_should_be_stable_and_local() {
        assert_eq!(
            discovery_hostname("A-Node_ID"),
            "tidyflow-node-a-node-id.local."
        );
    }

    #[test]
    fn resolved_service_mapping_should_require_node_id() {
        let properties = HashMap::from([
            ("node_name".to_string(), "Node 1".to_string()),
            ("protocol_version".to_string(), PROTOCOL_VERSION.to_string()),
        ]);
        let resolved = ServiceInfo::new(
            DISCOVERY_SERVICE_TYPE,
            "Node 1",
            "tidyflow-node-1.local.",
            "192.168.31.113",
            8439,
            properties,
        )
        .unwrap()
        .as_resolved_service();
        assert!(map_resolved_service_to_discovered_node(&resolved, "self").is_err());
    }

    #[test]
    fn resolved_service_mapping_should_filter_self_and_protocol() {
        let properties = HashMap::from([
            ("node_id".to_string(), "self".to_string()),
            ("node_name".to_string(), "Node 1".to_string()),
            ("protocol_version".to_string(), PROTOCOL_VERSION.to_string()),
        ]);
        let resolved = ServiceInfo::new(
            DISCOVERY_SERVICE_TYPE,
            "Node 1",
            "tidyflow-node-1.local.",
            "192.168.31.113",
            8439,
            properties,
        )
        .unwrap()
        .as_resolved_service();
        assert!(
            map_resolved_service_to_discovered_node(&resolved, "self")
                .unwrap()
                .is_none()
        );

        let properties = HashMap::from([
            ("node_id".to_string(), "node-2".to_string()),
            ("node_name".to_string(), "Node 2".to_string()),
            ("protocol_version".to_string(), "999".to_string()),
        ]);
        let resolved = ServiceInfo::new(
            DISCOVERY_SERVICE_TYPE,
            "Node 2",
            "tidyflow-node-2.local.",
            "192.168.31.114",
            8439,
            properties,
        )
        .unwrap()
        .as_resolved_service();
        assert!(
            map_resolved_service_to_discovered_node(&resolved, "self")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn resolved_service_mapping_should_select_ipv4_host() {
        let properties = HashMap::from([
            ("node_id".to_string(), "node-2".to_string()),
            ("node_name".to_string(), "Node 2".to_string()),
            ("protocol_version".to_string(), PROTOCOL_VERSION.to_string()),
        ]);
        let resolved = ServiceInfo::new(
            DISCOVERY_SERVICE_TYPE,
            "Node 2",
            "tidyflow-node-2.local.",
            "192.168.31.114,fe80::1",
            8439,
            properties,
        )
        .unwrap()
        .as_resolved_service();
        assert_eq!(
            select_discovery_host(&resolved).as_deref(),
            Some("192.168.31.114")
        );
        let mapped = map_resolved_service_to_discovered_node(&resolved, "self")
            .unwrap()
            .unwrap();
        assert_eq!(mapped.node_id, "node-2");
        assert_eq!(mapped.host, "192.168.31.114");
    }

    #[test]
    fn mdns_sd_should_register_browse_and_remove_service() {
        let port = 55431;
        let server = ServiceDaemon::new_with_port(port).unwrap();
        let client = ServiceDaemon::new_with_port(port).unwrap();
        let properties = HashMap::from([
            ("node_id".to_string(), "node-integration".to_string()),
            ("node_name".to_string(), "Node Integration".to_string()),
            ("protocol_version".to_string(), PROTOCOL_VERSION.to_string()),
        ]);
        let service = ServiceInfo::new(
            DISCOVERY_SERVICE_TYPE,
            "Node Integration",
            "tidyflow-node-integration.local.",
            "127.0.0.1",
            8439,
            properties,
        )
        .unwrap();
        let fullname = service.get_fullname().to_string();

        server.register(service).unwrap();
        let receiver = client.browse(DISCOVERY_SERVICE_TYPE).unwrap();

        let timeout = Duration::from_secs(10);
        let mut resolved_fullname = None;
        while let Ok(event) = receiver.recv_timeout(timeout) {
            if let ServiceEvent::ServiceResolved(info) = event {
                resolved_fullname = Some(info.get_fullname().to_string());
                break;
            }
        }
        assert_eq!(resolved_fullname.as_deref(), Some(fullname.as_str()));

        server.unregister(&fullname).unwrap();

        let mut removed_fullname = None;
        while let Ok(event) = receiver.recv_timeout(timeout) {
            if let ServiceEvent::ServiceRemoved(_, removed) = event {
                removed_fullname = Some(removed);
                break;
            }
        }
        assert_eq!(removed_fullname.as_deref(), Some(fullname.as_str()));
    }
}
