use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use crate::server::context::TermSubscription;

/// 处理前端 ACK，释放流控背压
pub async fn ack_terminal_output(
    term_id: &str,
    bytes: u64,
    subscribed_terms: &Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
) {
    let subs = subscribed_terms.lock().await;
    if let Some((_handle, fc, _flow_gate)) = subs.get(term_id) {
        // 减少未确认字节数（使用饱和减法避免下溢）
        let prev = fc.unacked.load(Ordering::Relaxed);
        let new_val = prev.saturating_sub(bytes);
        fc.unacked.store(new_val, Ordering::Relaxed);
        // 如果降至高水位以下，唤醒转发 task
        if prev > super::super::FLOW_CONTROL_HIGH_WATER
            && new_val <= super::super::FLOW_CONTROL_HIGH_WATER
        {
            fc.notify.notify_one();
        }
    }
}
