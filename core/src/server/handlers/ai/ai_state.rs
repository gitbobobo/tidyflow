use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tokio::sync::mpsc::Sender;

use super::utils::AiStreamSnapshot;
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
    /// tool+directory 使用情况：用于 idle dispose
    pub directory_last_used_ms: HashMap<String, i64>,
    pub directory_active_streams: HashMap<String, usize>,
    pub maintenance_started: bool,
    /// 状态推送回调是否已初始化（避免每个连接重复 set）
    pub status_push_initialized: bool,
    /// 连接订阅的会话集合：key = conn_id，value = session_keys 集合
    /// session_key 格式与 active_streams 相同："{tool}::{directory}::{session_id}"
    pub session_subscriptions: HashMap<String, HashSet<String>>,
}

impl AIState {
    pub fn new() -> Self {
        Self {
            active_streams: HashMap::new(),
            stream_snapshots: HashMap::new(),
            agents: HashMap::new(),
            session_statuses: AiSessionStateStore::new_shared(),
            directory_last_used_ms: HashMap::new(),
            directory_active_streams: HashMap::new(),
            maintenance_started: false,
            status_push_initialized: false,
            session_subscriptions: HashMap::new(),
        }
    }
}

impl Default for AIState {
    fn default() -> Self {
        Self::new()
    }
}
