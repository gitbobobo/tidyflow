//! StateSaver — 后台防抖持久化 actor
//!
//! 通过 channel 接收保存信号，500ms 防抖窗口内合并多次请求为一次 SQLite 写入。

use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};
use tracing::{error, info};

use super::state::AppState;
use super::state_store::StateStore;

/// 启动 StateSaver 后台 actor，返回用于触发保存的 Sender。
///
/// 每次向返回的 `Sender` 发送 `()` 即表示"状态已变更，请持久化"。
/// actor 内部以 500ms 防抖窗口合并多次信号，最终异步写入 SQLite。
///
/// channel 关闭时会执行最后一次保存。
pub fn spawn_state_saver(
    app_state: Arc<RwLock<AppState>>,
    state_store: Arc<StateStore>,
) -> mpsc::Sender<()> {
    let (tx, mut rx) = mpsc::channel::<()>(32);

    tokio::spawn(async move {
        loop {
            // 等待第一个保存信号
            if rx.recv().await.is_none() {
                // channel 已关闭，执行最终保存后退出
                do_save(&app_state, &state_store).await;
                info!("StateSaver: channel closed, final save done");
                return;
            }

            // 进入 500ms 防抖窗口：窗口内收到新信号则重置计时器
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(std::time::Duration::from_millis(500)) => {
                        // 超时，执行保存
                        break;
                    }
                    result = rx.recv() => {
                        match result {
                            Some(()) => {
                                // 窗口内收到新信号，重置计时器（继续循环）
                                continue;
                            }
                            None => {
                                // channel 关闭，执行最终保存后退出
                                do_save(&app_state, &state_store).await;
                                info!("StateSaver: channel closed during debounce, final save done");
                                return;
                            }
                        }
                    }
                }
            }

            do_save(&app_state, &state_store).await;
        }
    });

    tx
}

/// 短暂持锁 clone 状态，然后写入 SQLite
async fn do_save(app_state: &Arc<RwLock<AppState>>, state_store: &Arc<StateStore>) {
    let mut state = app_state.write().await;
    // clone 后立即释放锁，最小化持锁时间
    let mut snapshot = state.clone();
    // 更新 last_updated 到原始状态和快照中，保持一致
    let now = chrono::Utc::now();
    state.last_updated = Some(now);
    snapshot.last_updated = Some(now);
    drop(state);

    match state_store.save(&snapshot).await {
        Ok(()) => {
            info!("State saved to disk (debounced)");
        }
        Err(e) => {
            error!("StateSaver: failed to write state: {}", e);
        }
    }
}
