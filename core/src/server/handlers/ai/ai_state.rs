use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::mpsc::Sender;

use crate::ai::AiAgent;

pub struct AIState {
    /// 全局唯一的 AI 代理（单 opencode serve child + directory 路由）
    pub agent: Option<Arc<dyn AiAgent>>,
    /// 活跃流的中止通道：key = "{directory}::{session_id}"
    pub active_streams: HashMap<String, Sender<()>>,
    /// directory 使用情况：用于 idle dispose
    pub directory_last_used_ms: HashMap<String, i64>,
    pub directory_active_streams: HashMap<String, usize>,
    pub maintenance_started: bool,
}

impl AIState {
    pub fn new() -> Self {
        Self {
            active_streams: HashMap::new(),
            agent: None,
            directory_last_used_ms: HashMap::new(),
            directory_active_streams: HashMap::new(),
            maintenance_started: false,
        }
    }
}

impl Default for AIState {
    fn default() -> Self {
        Self::new()
    }
}
