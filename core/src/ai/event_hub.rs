//! OpenCode 全局事件枢纽（单 SSE 连接，多订阅者）。
//!
//! 目标：
//! - Core 只维护一个 `/global/event` SSE 连接。
//! - 将事件广播给多个并发的 AIChatSend 流（按 directory/sessionID 过滤）。

use std::sync::Arc;
use tokio::sync::{broadcast, Mutex};
use tokio_stream::StreamExt;
use tracing::{debug, info, warn};

use super::opencode::http_client::OpenCodeClient;
use super::opencode::protocol::{BusEvent, GlobalBusEventEnvelope};
use super::OpenCodeManager;

/// 广播给上层的事件（包含 directory + payload）
#[derive(Debug, Clone)]
pub struct HubEvent {
    pub directory: Option<String>,
    pub event: BusEvent,
}

#[derive(Clone)]
pub struct OpenCodeEventHub {
    sender: broadcast::Sender<HubEvent>,
    started: Arc<Mutex<bool>>,
    manager: Arc<OpenCodeManager>,
}

impl OpenCodeEventHub {
    pub fn new(manager: Arc<OpenCodeManager>) -> Self {
        // 广播缓冲：足够大以覆盖短暂 UI 卡顿；丢消息时 receiver 会看到 Lagged 错误。
        let (sender, _) = broadcast::channel::<HubEvent>(2048);
        Self {
            sender,
            started: Arc::new(Mutex::new(false)),
            manager,
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.sender.subscribe()
    }

    /// 确保后台 SSE 任务已启动（幂等）。
    pub async fn ensure_started(&self) -> Result<(), String> {
        let mut started = self.started.lock().await;
        if *started {
            return Ok(());
        }

        // 先确保 opencode serve 处于健康状态
        self.manager.ensure_server_running().await?;

        let sender = self.sender.clone();
        let manager = self.manager.clone();

        tokio::spawn(async move {
            // 无限循环：断线重连
            let mut backoff_ms: u64 = 200;
            loop {
                if let Err(e) = manager.ensure_server_running().await {
                    warn!("OpenCodeEventHub: ensure_server_running failed: {}", e);
                    tokio::time::sleep(std::time::Duration::from_millis(backoff_ms)).await;
                    backoff_ms = (backoff_ms * 2).min(5000);
                    continue;
                }

                let base_url = manager.get_base_url();
                let client = OpenCodeClient::new(base_url);

                info!("OpenCodeEventHub: subscribing /global/event ...");
                match client.subscribe_global_events().await {
                    Ok(mut stream) => {
                        backoff_ms = 200;
                        while let Some(item) = stream.next().await {
                            match item {
                                Ok(GlobalBusEventEnvelope { directory, payload }) => {
                                    // payload 为空（解析失败）时直接跳过
                                    let ev = HubEvent {
                                        directory,
                                        event: payload,
                                    };
                                    let _ = sender.send(ev);
                                }
                                Err(e) => {
                                    warn!("OpenCodeEventHub: SSE stream error: {}", e);
                                    break;
                                }
                            }
                        }
                        debug!("OpenCodeEventHub: SSE ended, will reconnect");
                    }
                    Err(e) => {
                        warn!("OpenCodeEventHub: subscribe_global_events failed: {}", e);
                    }
                }

                tokio::time::sleep(std::time::Duration::from_millis(backoff_ms)).await;
                backoff_ms = (backoff_ms * 2).min(5000);
            }
        });

        *started = true;
        Ok(())
    }
}
