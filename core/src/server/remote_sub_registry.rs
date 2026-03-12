//! 全局远程订阅注册表
//!
//! 追踪远程连接（iOS 等移动端）对终端的订阅关系，
//! 并在变更时通知本地连接刷新 UI。

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{broadcast, Mutex};

/// 远程订阅者信息
#[derive(Debug, Clone)]
pub struct RemoteSubscriberInfo {
    /// 订阅者稳定标识：优先使用 `<key_id>:<client_id>`，本地连接退回 conn_id
    pub conn_id: String,
    pub device_name: String,
}

/// 远程终端变更事件（通知本地连接）
#[derive(Debug, Clone)]
pub enum RemoteTermEvent {
    /// 订阅关系发生变化，本地连接应重新请求 TermList
    Changed,
}

/// 全局远程订阅注册表
pub struct RemoteSubRegistry {
    /// term_id -> Vec<RemoteSubscriberInfo>
    subscribers: HashMap<String, Vec<RemoteSubscriberInfo>>,
    /// 变更通知广播
    notify_tx: broadcast::Sender<RemoteTermEvent>,
}

impl RemoteSubRegistry {
    pub fn new() -> Self {
        let (notify_tx, _) = broadcast::channel(16);
        Self {
            subscribers: HashMap::new(),
            notify_tx,
        }
    }

    /// 远程连接订阅终端
    pub fn subscribe(&mut self, term_id: &str, subscriber_id: &str, device_name: &str) {
        let subs = self.subscribers.entry(term_id.to_string()).or_default();
        // 避免重复订阅
        if !subs.iter().any(|s| s.conn_id == subscriber_id) {
            subs.push(RemoteSubscriberInfo {
                conn_id: subscriber_id.to_string(),
                device_name: device_name.to_string(),
            });
            let _ = self.notify_tx.send(RemoteTermEvent::Changed);
        }
    }

    /// 取消远程连接对某终端的订阅
    pub fn unsubscribe(&mut self, term_id: &str, subscriber_id: &str) {
        let mut changed = false;
        if let Some(subs) = self.subscribers.get_mut(term_id) {
            let before = subs.len();
            subs.retain(|s| s.conn_id != subscriber_id);
            changed = subs.len() != before;
        }
        // 清理空条目
        if self
            .subscribers
            .get(term_id)
            .map_or(false, |s| s.is_empty())
        {
            self.subscribers.remove(term_id);
        }
        if changed {
            let _ = self.notify_tx.send(RemoteTermEvent::Changed);
        }
    }

    /// 清理该订阅者（subscriber_id/conn_id）的所有订阅
    pub fn unsubscribe_all(&mut self, subscriber_id: &str) {
        let mut changed = false;
        self.subscribers.retain(|_, subs| {
            let before = subs.len();
            subs.retain(|s| s.conn_id != subscriber_id);
            if subs.len() != before {
                changed = true;
            }
            !subs.is_empty()
        });
        if changed {
            let _ = self.notify_tx.send(RemoteTermEvent::Changed);
        }
    }

    /// 终端关闭时清理该终端的所有远程订阅
    pub fn unsubscribe_term(&mut self, term_id: &str) {
        if self.subscribers.remove(term_id).is_some() {
            let _ = self.notify_tx.send(RemoteTermEvent::Changed);
        }
    }

    /// 获取某终端的远程订阅者列表
    pub fn get_subscribers(&self, term_id: &str) -> Vec<RemoteSubscriberInfo> {
        self.subscribers.get(term_id).cloned().unwrap_or_default()
    }

    /// 订阅变更事件（本地连接用于接收推送通知）
    pub fn subscribe_events(&self) -> broadcast::Receiver<RemoteTermEvent> {
        self.notify_tx.subscribe()
    }

    /// 健康探针：返回当前订阅状态摘要（订阅者总数）
    pub fn subscriber_count(&self) -> usize {
        self.subscribers.values().map(|v| v.len()).sum()
    }
}

/// 共享远程订阅注册表类型
pub type SharedRemoteSubRegistry = Arc<Mutex<RemoteSubRegistry>>;
