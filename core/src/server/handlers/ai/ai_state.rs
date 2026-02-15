use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::mpsc::Sender;

use crate::ai::{AiAgent, AiSession};

pub struct AIState {
    /// 每个会话对应的 AI 代理实例（trait 对象）
    pub agents: HashMap<String, Arc<dyn AiAgent>>,
    /// 会话元信息
    pub sessions: HashMap<String, AiSession>,
    /// 活跃流的中止通道
    pub active_streams: HashMap<String, Sender<()>>,
}

impl AIState {
    pub fn new() -> Self {
        Self {
            agents: HashMap::new(),
            sessions: HashMap::new(),
            active_streams: HashMap::new(),
        }
    }
}

impl Default for AIState {
    fn default() -> Self {
        Self::new()
    }
}
