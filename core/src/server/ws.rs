use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::{ConnectInfo, Query, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{info, warn};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::process::parent_id;

use crate::server::handlers::ai::{preload_agents_on_startup, AIState, SharedAIState};

use crate::server::context::{
    ConnectionMeta, SharedAppState, SharedRunningAITasks, SharedRunningCommands, SharedTaskHistory,
    TaskBroadcastTx,
};
use crate::server::protocol::{ServerMessage, PROTOCOL_VERSION};
use crate::server::remote_sub_registry::{RemoteSubRegistry, SharedRemoteSubRegistry};
use crate::server::terminal_registry::{
    spawn_scrollback_writer, SharedTerminalRegistry, TerminalRegistry,
};
use crate::workspace::state::AppState;
use crate::workspace::state_saver::spawn_state_saver;

mod connection;
mod dispatch;
mod pairing;
mod terminal;

/// 流控高水位（100KB）：未确认字节数超过此值时暂停转发
const FLOW_CONTROL_HIGH_WATER: u64 = 100 * 1024;
/// 入站 WS 帧大小上限（2MB）
const MAX_WS_FRAME_SIZE: usize = 2 * 1024 * 1024;
/// 入站 WS 消息大小上限（2MB）
const MAX_WS_MESSAGE_SIZE: usize = 2 * 1024 * 1024;

/// WebSocket 服务器上下文，包含共享状态和防抖保存通道
#[derive(Clone)]
struct AppContext {
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    terminal_registry: SharedTerminalRegistry,
    scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    expected_ws_token: Option<String>,
    pairing_registry: pairing::SharedPairingRegistry,
    remote_sub_registry: SharedRemoteSubRegistry,
    task_broadcast_tx: TaskBroadcastTx,
    running_commands: SharedRunningCommands,
    running_ai_tasks: SharedRunningAITasks,
    task_history: SharedTaskHistory,
    ai_state: SharedAIState,
}

/// Run the WebSocket server on the specified port
pub async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WebSocket server on port {}", port);

    // Start parent process monitor to auto-exit when parent dies (e.g., Xcode force stop)
    #[cfg(unix)]
    spawn_parent_monitor();

    // Load application state
    let app_state = AppState::load().unwrap_or_default();
    let shared_state: SharedAppState = Arc::new(tokio::sync::RwLock::new(app_state));

    // 启动防抖保存 actor
    let save_tx = spawn_state_saver(shared_state.clone());

    // 创建全局终端注册表
    let terminal_registry: SharedTerminalRegistry = Arc::new(Mutex::new(TerminalRegistry::new()));

    // 启动 scrollback 写入 task
    let scrollback_tx = spawn_scrollback_writer(terminal_registry.clone());
    let expected_ws_token = std::env::var("TIDYFLOW_WS_TOKEN")
        .ok()
        .filter(|token| !token.trim().is_empty());
    let bind_addr = std::env::var("TIDYFLOW_BIND_ADDR")
        .ok()
        .map(|addr| addr.trim().to_string())
        .filter(|addr| !addr.is_empty())
        .unwrap_or_else(|| "0.0.0.0".to_string());

    if expected_ws_token.is_some() {
        info!("WebSocket token auth enabled");
    } else {
        warn!("WebSocket token auth disabled (TIDYFLOW_WS_TOKEN not set)");
    }
    info!("Binding on {} (LAN clients can connect)", bind_addr);

    // 创建全局任务广播通道
    let (task_broadcast_tx, _) = tokio::sync::broadcast::channel(256);

    // 全局共享的运行中命令注册表
    let running_commands: SharedRunningCommands = Arc::new(Mutex::new(HashMap::new()));

    // 全局共享的运行中 AI 任务注册表
    let running_ai_tasks: SharedRunningAITasks = Arc::new(Mutex::new(HashMap::new()));

    // 全局共享的任务历史注册表（iOS 重连恢复用）
    let task_history: SharedTaskHistory = Arc::new(Mutex::new(Vec::new()));

    // 全局共享的 AI 状态
    let ai_state: SharedAIState = Arc::new(Mutex::new(AIState::new()));
    preload_agents_on_startup(&ai_state).await;

    let ctx = AppContext {
        app_state: shared_state.clone(),
        save_tx,
        terminal_registry,
        scrollback_tx,
        expected_ws_token,
        pairing_registry: Arc::new(Mutex::new(pairing::new_pairing_registry(
            &shared_state.read().await.paired_tokens,
        ))),
        remote_sub_registry: Arc::new(Mutex::new(RemoteSubRegistry::new())),
        task_broadcast_tx,
        running_commands,
        running_ai_tasks,
        task_history,
        ai_state,
    };

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .route("/pair/start", post(pairing::pair_start_handler))
        .route("/pair/exchange", post(pairing::pair_exchange_handler))
        .route("/pair/revoke", post(pairing::pair_revoke_handler))
        .with_state(ctx);

    let addr = format!("{}:{}", bind_addr, port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;

    info!(
        "Listening on ws://{}/ws (protocol v{})",
        addr, PROTOCOL_VERSION
    );

    let shutdown_tx = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let shutdown_tx_for_signal = shutdown_tx.clone();

    #[cfg(unix)]
    {
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sigterm = signal(SignalKind::terminate()).unwrap();
            let mut sigint = signal(SignalKind::interrupt()).unwrap();
            tokio::select! {
                _ = sigterm.recv() => {
                    info!("Received SIGTERM, shutting down gracefully");
                }
                _ = sigint.recv() => {
                    info!("Received SIGINT, shutting down gracefully");
                }
            }
            shutdown_tx_for_signal.store(true, std::sync::atomic::Ordering::SeqCst);
        });
    }

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        while !shutdown_tx.load(std::sync::atomic::Ordering::SeqCst) {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
        }
        info!("Graceful shutdown initiated");
    })
    .await?;

    Ok(())
}

/// Monitor parent process and exit if it dies (becomes orphaned)
/// This handles the case where the Swift app is force-killed by Xcode
#[cfg(unix)]
fn spawn_parent_monitor() {
    let initial_ppid = parent_id();
    info!("Parent process monitor started, PPID: {}", initial_ppid);

    // If already orphaned (PPID is 1/launchd), don't start monitor
    if initial_ppid <= 1 {
        info!("Running without parent process, skipping monitor");
        return;
    }

    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(1));
        loop {
            interval.tick().await;

            let current_ppid = parent_id();
            // On macOS/Unix, when parent dies, PPID becomes 1 (init/launchd)
            if current_ppid != initial_ppid {
                warn!(
                    "Parent process died (PPID changed from {} to {}), shutting down",
                    initial_ppid, current_ppid
                );
                std::process::exit(0);
            }
        }
    });
}

/// WebSocket upgrade handler
async fn ws_handler(
    ws: WebSocketUpgrade,
    State(ctx): State<AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    query: Option<Query<pairing::WsAuthQuery>>,
) -> impl IntoResponse {
    let provided_token = query.and_then(|q| q.0.token);
    if !pairing::is_ws_token_authorized(
        ctx.expected_ws_token.as_deref(),
        provided_token.as_deref(),
        &ctx.pairing_registry,
    )
    .await
    {
        warn!("Rejected unauthorized WebSocket upgrade request");
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    // 构建连接元数据
    // 判断是否为远程连接：使用配对 token 的连接始终视为远程（覆盖 iOS 模拟器等 loopback 场景）
    let (is_remote, token_id, device_name) = {
        let paired_info = if let Some(token) = provided_token.as_deref() {
            pairing::lookup_paired_info(&ctx.pairing_registry, token).await
        } else {
            None
        };
        if let Some((token_id, device_name)) = paired_info {
            // 配对 token 认证 → 一定是远程设备
            (true, Some(token_id), Some(device_name))
        } else {
            (!addr.ip().is_loopback(), None, None)
        }
    };
    let conn_meta = ConnectionMeta {
        conn_id: Uuid::new_v4().to_string(),
        token_id,
        is_remote,
        device_name,
    };

    ws.max_frame_size(MAX_WS_FRAME_SIZE)
        .max_message_size(MAX_WS_MESSAGE_SIZE)
        .on_upgrade(move |socket| {
            connection::handle_socket(
                socket,
                ctx.app_state,
                ctx.save_tx,
                ctx.terminal_registry,
                ctx.scrollback_tx,
                conn_meta,
                ctx.remote_sub_registry,
                ctx.task_broadcast_tx,
                ctx.running_commands,
                ctx.running_ai_tasks,
                ctx.task_history,
                ctx.ai_state,
            )
        })
        .into_response()
}

pub use terminal::{ack_terminal_output, subscribe_terminal, unsubscribe_terminal};

/// Send a server message over WebSocket
pub async fn send_message(socket: &mut WebSocket, msg: &ServerMessage) -> Result<(), String> {
    let bytes = rmp_serde::to_vec_named(msg).map_err(|e| e.to_string())?;
    socket
        .send(Message::Binary(bytes))
        .await
        .map_err(|e| e.to_string())
}
