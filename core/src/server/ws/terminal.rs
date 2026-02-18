use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use tokio::sync::Notify;
use tracing::warn;

use crate::server::context::{FlowControl, TermSubscription};
use crate::server::terminal_registry::SharedTerminalRegistry;

/// 订阅终端输出：从 registry 的 broadcast 接收数据，转发到聚合通道
/// 带流控：当 unacked 超过高水位时暂停转发，等待前端 ACK
pub async fn subscribe_terminal(
    term_id: &str,
    registry: &SharedTerminalRegistry,
    subscribed_terms: &Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
    agg_tx: &tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
) -> bool {
    let reg = registry.lock().await;
    let (rx, flow_gate) = match reg.subscribe(term_id) {
        Some(pair) => pair,
        None => return false,
    };
    drop(reg);

    let agg_tx = agg_tx.clone();
    let tid = term_id.to_string();

    let fc = Arc::new(FlowControl {
        unacked: std::sync::atomic::AtomicU64::new(0),
        notify: Notify::new(),
    });
    let fc_clone = fc.clone();
    let fg_clone = flow_gate.clone();

    // 注册订阅者到 flow_gate
    flow_gate.add_subscriber();

    let handle = tokio::spawn(async move {
        let mut rx = rx;
        let mut is_paused = false;
        loop {
            // 流控：unacked 超过高水位时暂停，等待 ACK 唤醒
            while fc_clone.unacked.load(Ordering::Relaxed) > super::FLOW_CONTROL_HIGH_WATER {
                if !is_paused {
                    is_paused = true;
                    fg_clone.mark_paused();
                }
                // 带超时等待，防止前端 ACK 丢失导致永久阻塞
                tokio::select! {
                    _ = fc_clone.notify.notified() => {}
                    _ = tokio::time::sleep(tokio::time::Duration::from_secs(3)) => {
                        // 超时后渐进衰减 unacked，避免完全失效
                        let prev = fc_clone.unacked.load(Ordering::Relaxed);
                        warn!(
                            "Terminal {} flow control timeout, decaying unacked {} -> {}",
                            tid,
                            prev,
                            prev / 2
                        );
                        fc_clone.unacked.store(prev / 2, Ordering::Relaxed);
                    }
                }
            }
            if is_paused {
                is_paused = false;
                fg_clone.mark_resumed();
            }

            match rx.recv().await {
                Ok((id, data)) => {
                    if id == tid {
                        let data_len = data.len() as u64;
                        if agg_tx.send((id, data)).await.is_err() {
                            break;
                        }
                        // 记录未确认字节数
                        fc_clone.unacked.fetch_add(data_len, Ordering::Relaxed);
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    warn!("Terminal {} output lagged by {} messages", tid, n);
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break;
                }
            }
        }
        // 任务结束时确保释放暂停状态和订阅者计数
        if is_paused {
            fg_clone.mark_resumed();
        }
        fg_clone.remove_subscriber();
    });

    let mut subs = subscribed_terms.lock().await;
    // 如果已有旧订阅，先取消
    if let Some((old_handle, _old_fc, old_fg)) = subs.remove(term_id) {
        old_handle.abort();
        old_fg.remove_subscriber();
    }
    subs.insert(term_id.to_string(), (handle, fc, flow_gate));
    true
}

/// 取消订阅终端输出
pub async fn unsubscribe_terminal(
    term_id: &str,
    subscribed_terms: &Arc<tokio::sync::Mutex<HashMap<String, TermSubscription>>>,
) {
    let mut subs = subscribed_terms.lock().await;
    if let Some((handle, _fc, flow_gate)) = subs.remove(term_id) {
        handle.abort();
        flow_gate.remove_subscriber();
    }
}

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
        if prev > super::FLOW_CONTROL_HIGH_WATER && new_val <= super::FLOW_CONTROL_HIGH_WATER {
            fc.notify.notify_one();
        }
    }
}
