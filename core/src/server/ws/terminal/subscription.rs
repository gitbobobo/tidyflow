use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use tokio::sync::Notify;
use tracing::warn;

use crate::server::context::{FlowControl, TermSubscription};
use crate::server::terminal_registry::{PtyFlowGate, SharedTerminalRegistry};

async fn wait_flow_control_window(
    term_id: &str,
    flow_control: &Arc<FlowControl>,
    flow_gate: &PtyFlowGate,
    is_paused: &mut bool,
) {
    while flow_control.unacked.load(Ordering::Relaxed) > super::super::FLOW_CONTROL_HIGH_WATER {
        if !*is_paused {
            *is_paused = true;
            flow_gate.mark_paused();
        }

        // 带超时等待，防止前端 ACK 丢失导致永久阻塞
        tokio::select! {
            _ = flow_control.notify.notified() => {}
            _ = tokio::time::sleep(tokio::time::Duration::from_secs(3)) => {
                // 超时后渐进衰减 unacked，避免完全失效
                let prev = flow_control.unacked.load(Ordering::Relaxed);
                warn!(
                    "Terminal {} flow control timeout, decaying unacked {} -> {}",
                    term_id,
                    prev,
                    prev / 2
                );
                crate::server::perf::record_terminal_unacked_timeout(term_id, prev);
                flow_control.unacked.store(prev / 2, Ordering::Relaxed);
            }
        }
    }

    if *is_paused {
        *is_paused = false;
        flow_gate.mark_resumed();
    }
}

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
            wait_flow_control_window(&tid, &fc_clone, &fg_clone, &mut is_paused).await;

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

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;

    use crate::server::terminal_registry::PtyFlowGate;
    use crate::server::ws::terminal::subscription::unsubscribe_terminal;

    // CHK-003: 取消订阅后 flow_gate 订阅者减少，孤儿订阅不残留
    #[tokio::test]
    async fn cleanup_terminal_subscription_decrements_flow_gate() {
        let gate = Arc::new(PtyFlowGate::new());
        gate.add_subscriber();
        assert_eq!(gate.subscriber_count(), 1);

        // 模拟已注册的订阅 entry
        let subscribed_terms: Arc<tokio::sync::Mutex<HashMap<String, _>>> =
            Arc::new(tokio::sync::Mutex::new(HashMap::new()));

        // 构造一个 no-op task 作为 handle
        let handle = tokio::spawn(async {});
        let fc = Arc::new(crate::server::context::FlowControl {
            unacked: std::sync::atomic::AtomicU64::new(0),
            notify: tokio::sync::Notify::new(),
        });
        {
            let mut subs = subscribed_terms.lock().await;
            subs.insert("term-1".to_string(), (handle, fc, gate.clone()));
        }

        unsubscribe_terminal("term-1", &subscribed_terms).await;

        // 订阅者计数应减回 0
        assert_eq!(gate.subscriber_count(), 0);
        // subscribed_terms 中应无残留
        let subs = subscribed_terms.lock().await;
        assert!(!subs.contains_key("term-1"));
    }

    // CHK-003: 对不存在的 term_id 调用 unsubscribe_terminal 不会 panic
    #[tokio::test]
    async fn cleanup_nonexistent_terminal_is_noop() {
        let subscribed_terms: Arc<tokio::sync::Mutex<HashMap<String, _>>> =
            Arc::new(tokio::sync::Mutex::new(HashMap::new()));
        // 不应 panic
        unsubscribe_terminal("nonexistent", &subscribed_terms).await;
        let subs = subscribed_terms.lock().await;
        assert!(subs.is_empty());
    }
}
