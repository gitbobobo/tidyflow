use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tokio::sync::mpsc::Sender;

use super::utils::AiStreamSnapshot;
use super::AiSessionIndexStore;
use crate::ai::session_status::AiSessionStateStore;
use crate::ai::AiAgent;

pub struct AIState {
    /// AI 代理池（按工具区分）
    pub agents: HashMap<String, Arc<dyn AiAgent>>,
    /// 活跃流的中止通道：key = "{tool}::{directory}::{session_id}"
    pub active_streams: HashMap<String, Sender<()>>,
    /// 会话流式快照：key = "{tool}::{directory}::{session_id}"
    pub(crate) stream_snapshots: HashMap<String, AiStreamSnapshot>,
    /// AI 会话状态存储（跨工具统一）
    pub session_statuses: Arc<AiSessionStateStore>,
    /// AI 会话索引存储（会话列表仅依赖此索引）
    pub session_index_store: Arc<AiSessionIndexStore>,
    /// tool+directory 使用情况：用于 idle dispose
    pub directory_last_used_ms: HashMap<String, i64>,
    pub directory_active_streams: HashMap<String, usize>,
    pub maintenance_started: bool,
    /// 状态推送回调是否已初始化（避免每个连接重复 set）
    pub status_push_initialized: bool,
    /// 连接订阅的会话集合：key = conn_id，value = session_keys 集合
    /// session_key 格式与 active_streams 相同："{tool}::{directory}::{session_id}"
    pub session_subscriptions: HashMap<String, HashSet<String>>,
    /// 会话反向订阅索引：key = session_key，value = conn_id 集合
    pub session_subscribers_by_key: HashMap<String, HashSet<String>>,
}

impl AIState {
    pub fn new() -> Self {
        let session_index_store = Arc::new(
            AiSessionIndexStore::open_default()
                .unwrap_or_else(|e| panic!("failed to initialize ai session index store: {}", e)),
        );
        Self {
            active_streams: HashMap::new(),
            stream_snapshots: HashMap::new(),
            agents: HashMap::new(),
            session_statuses: AiSessionStateStore::new_shared(),
            session_index_store,
            directory_last_used_ms: HashMap::new(),
            directory_active_streams: HashMap::new(),
            maintenance_started: false,
            status_push_initialized: false,
            session_subscriptions: HashMap::new(),
            session_subscribers_by_key: HashMap::new(),
        }
    }
}

impl AIState {
    pub fn subscribe_session(&mut self, conn_id: &str, session_key: &str) {
        self.session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert(session_key.to_string());
        self.session_subscribers_by_key
            .entry(session_key.to_string())
            .or_default()
            .insert(conn_id.to_string());
    }

    pub fn unsubscribe_session(&mut self, conn_id: &str, session_key: &str) {
        if let Some(keys) = self.session_subscriptions.get_mut(conn_id) {
            keys.remove(session_key);
            if keys.is_empty() {
                self.session_subscriptions.remove(conn_id);
            }
        }
        if let Some(conn_ids) = self.session_subscribers_by_key.get_mut(session_key) {
            conn_ids.remove(conn_id);
            if conn_ids.is_empty() {
                self.session_subscribers_by_key.remove(session_key);
            }
        }
    }

    pub fn unsubscribe_all_sessions_for_connection(&mut self, conn_id: &str) -> usize {
        let Some(keys) = self.session_subscriptions.remove(conn_id) else {
            return 0;
        };
        let count = keys.len();
        for key in keys {
            if let Some(conn_ids) = self.session_subscribers_by_key.get_mut(&key) {
                conn_ids.remove(conn_id);
                if conn_ids.is_empty() {
                    self.session_subscribers_by_key.remove(&key);
                }
            }
        }
        count
    }
}

impl Default for AIState {
    fn default() -> Self {
        Self::new()
    }
}
