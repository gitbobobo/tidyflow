use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::{ConnectInfo, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{SecondsFormat, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex, Notify};
use tracing::{debug, error, info, trace, warn};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::process::parent_id;

use crate::server::handlers::ai::AIState;
use crate::server::handlers::ai::SharedAIState;

use crate::server::context::{
    ConnectionMeta, FlowControl, HandlerContext, SharedAppState, SharedRunningAITasks,
    SharedRunningCommands, SharedTaskHistory, TaskBroadcastTx, TermSubscription,
};
use crate::server::git::status::invalidate_git_status_cache;
use crate::server::handlers;
use crate::server::lsp::LspSupervisor;
use crate::server::protocol::{
    v1_capabilities, ClientMessage, RequestEnvelope, ServerMessage, PROTOCOL_VERSION,
};
use crate::server::remote_sub_registry::{RemoteSubRegistry, SharedRemoteSubRegistry};
use crate::server::terminal_registry::{
    spawn_scrollback_writer, SharedTerminalRegistry, TerminalRegistry,
};
use crate::server::watcher::{WatchEvent, WorkspaceWatcher};
use crate::workspace::state::AppState;
use crate::workspace::state::PersistedTokenEntry;
use crate::workspace::state_saver::spawn_state_saver;

/// 流控高水位（100KB）：未确认字节数超过此值时暂停转发
const FLOW_CONTROL_HIGH_WATER: u64 = 100 * 1024;
/// 入站 WS 帧大小上限（2MB）
const MAX_WS_FRAME_SIZE: usize = 2 * 1024 * 1024;
/// 入站 WS 消息大小上限（2MB）
const MAX_WS_MESSAGE_SIZE: usize = 2 * 1024 * 1024;
/// 配对码有效期（秒）
const PAIR_CODE_TTL_SECS: u64 = 120;
/// 移动端 WS token 有效期（秒）— 30 天
const PAIR_TOKEN_TTL_SECS: u64 = 30 * 24 * 60 * 60;
/// 待兑换配对码最大数量
const MAX_PENDING_PAIR_CODES: usize = 64;
/// 已签发移动端 token 最大数量
const MAX_ISSUED_PAIR_TOKENS: usize = 256;

#[derive(Debug, Deserialize)]
struct WsAuthQuery {
    token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ClientMessageTypeProbe {
    #[serde(rename = "type")]
    message_type: Option<String>,
}

#[derive(Debug, Default)]
struct PairingRegistry {
    /// key: 6 位配对码
    pending_codes: HashMap<String, PairCodeEntry>,
    /// key: ws_token
    issued_tokens: HashMap<String, PairTokenEntry>,
}

#[derive(Debug, Clone)]
struct PairCodeEntry {
    expires_at_unix: u64,
}

#[derive(Debug, Clone)]
struct PairTokenEntry {
    token_id: String,
    device_name: String,
    issued_at_unix: u64,
    expires_at_unix: u64,
}

type SharedPairingRegistry = Arc<Mutex<PairingRegistry>>;

#[derive(Debug, Serialize)]
struct PairStartResponse {
    pair_code: String,
    expires_at: String,
    expires_at_unix: u64,
}

#[derive(Debug, Deserialize)]
struct PairExchangeRequest {
    pair_code: String,
    #[serde(default)]
    device_name: Option<String>,
}

#[derive(Debug, Serialize)]
struct PairExchangeResponse {
    token_id: String,
    ws_token: String,
    device_name: String,
    issued_at: String,
    issued_at_unix: u64,
    expires_at: String,
    expires_at_unix: u64,
}

#[derive(Debug, Deserialize)]
struct PairRevokeRequest {
    #[serde(default)]
    token_id: Option<String>,
    #[serde(default)]
    ws_token: Option<String>,
}

#[derive(Debug, Serialize)]
struct PairRevokeResponse {
    ok: bool,
    revoked: usize,
}

#[derive(Debug, Serialize)]
struct PairErrorResponse {
    error: String,
    message: String,
}

/// WebSocket 服务器上下文，包含共享状态和防抖保存通道
#[derive(Clone)]
struct AppContext {
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    terminal_registry: SharedTerminalRegistry,
    scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    expected_ws_token: Option<String>,
    pairing_registry: SharedPairingRegistry,
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

    let ctx = AppContext {
        app_state: shared_state.clone(),
        save_tx,
        terminal_registry,
        scrollback_tx,
        expected_ws_token,
        pairing_registry: Arc::new(Mutex::new(PairingRegistry {
            pending_codes: HashMap::new(),
            issued_tokens: load_tokens_from_state(&shared_state.read().await.paired_tokens),
        })),
        remote_sub_registry: Arc::new(Mutex::new(RemoteSubRegistry::new())),
        task_broadcast_tx,
        running_commands,
        running_ai_tasks,
        task_history,
        ai_state,
    };

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .route("/pair/start", post(pair_start_handler))
        .route("/pair/exchange", post(pair_exchange_handler))
        .route("/pair/revoke", post(pair_revoke_handler))
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
    query: Option<Query<WsAuthQuery>>,
) -> impl IntoResponse {
    let provided_token = query.and_then(|q| q.0.token);
    if !is_ws_token_authorized(
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
            let reg = ctx.pairing_registry.lock().await;
            reg.issued_tokens
                .get(token)
                .map(|e| (e.token_id.clone(), e.device_name.clone()))
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
            handle_socket(
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

fn probe_client_message_type(data: &[u8]) -> String {
    rmp_serde::from_slice::<ClientMessageTypeProbe>(data)
        .ok()
        .and_then(|probe| probe.message_type)
        .unwrap_or_else(|| "unknown".to_string())
}

fn is_request_from_loopback(addr: SocketAddr) -> bool {
    addr.ip().is_loopback()
}

fn now_unix_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_secs()
}

fn unix_ts_to_rfc3339(ts: u64) -> String {
    Utc.timestamp_opt(ts as i64, 0)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn cleanup_expired_pairing_entries(reg: &mut PairingRegistry, now_ts: u64) {
    reg.pending_codes
        .retain(|_, entry| entry.expires_at_unix > now_ts);
    reg.issued_tokens
        .retain(|_, entry| entry.expires_at_unix > now_ts);
}

// ── Token 持久化（基于 AppState） ──

/// 从 AppState 的 paired_tokens 加载到内存 HashMap
fn load_tokens_from_state(entries: &[PersistedTokenEntry]) -> HashMap<String, PairTokenEntry> {
    let now_ts = now_unix_ts();
    entries
        .iter()
        .filter(|e| e.expires_at_unix > now_ts)
        .map(|e| {
            (
                e.ws_token.clone(),
                PairTokenEntry {
                    token_id: e.token_id.clone(),
                    device_name: e.device_name.clone(),
                    issued_at_unix: e.issued_at_unix,
                    expires_at_unix: e.expires_at_unix,
                },
            )
        })
        .collect()
}

/// 将内存 token 写回 AppState.paired_tokens 并触发保存
async fn persist_tokens_to_state(
    tokens: &HashMap<String, PairTokenEntry>,
    app_state: &SharedAppState,
    save_tx: &tokio::sync::mpsc::Sender<()>,
) {
    let entries: Vec<PersistedTokenEntry> = tokens
        .iter()
        .map(|(ws_token, entry)| PersistedTokenEntry {
            token_id: entry.token_id.clone(),
            ws_token: ws_token.clone(),
            device_name: entry.device_name.clone(),
            issued_at_unix: entry.issued_at_unix,
            expires_at_unix: entry.expires_at_unix,
        })
        .collect();
    {
        let mut state = app_state.write().await;
        state.paired_tokens = entries;
    }
    let _ = save_tx.send(()).await;
}

fn generate_pair_code() -> String {
    let raw = Uuid::new_v4().as_u128() % 1_000_000;
    format!("{raw:06}")
}

async fn is_ws_token_authorized(
    expected: Option<&str>,
    provided: Option<&str>,
    pairing_registry: &SharedPairingRegistry,
) -> bool {
    match expected {
        // 未配置 token 时保持兼容：放行连接（通常只用于本机调试）
        None => true,
        // 当 Core 配置了 token 时，客户端必须携带并匹配
        Some(expected_token) => {
            let Some(token) = provided else {
                return false;
            };
            if token == expected_token {
                return true;
            }

            let mut reg = pairing_registry.lock().await;
            let now_ts = now_unix_ts();
            cleanup_expired_pairing_entries(&mut reg, now_ts);
            if let Some(entry) = reg.issued_tokens.get(token) {
                trace!(
                    token_id = %entry.token_id,
                    device = %entry.device_name,
                    issued_at = entry.issued_at_unix,
                    "Authorized by paired token"
                );
                true
            } else {
                false
            }
        }
    }
}

async fn pair_start_handler(
    State(ctx): State<AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return (
            StatusCode::FORBIDDEN,
            Json(PairErrorResponse {
                error: "forbidden".to_string(),
                message: "pair/start only accepts loopback requests".to_string(),
            }),
        )
            .into_response();
    }

    let now_ts = now_unix_ts();
    let expires_at_unix = now_ts + PAIR_CODE_TTL_SECS;
    let expires_at = unix_ts_to_rfc3339(expires_at_unix);

    let mut reg = ctx.pairing_registry.lock().await;
    cleanup_expired_pairing_entries(&mut reg, now_ts);
    while reg.pending_codes.len() >= MAX_PENDING_PAIR_CODES {
        let oldest = reg
            .pending_codes
            .iter()
            .min_by_key(|(_, entry)| entry.expires_at_unix)
            .map(|(code, _)| code.clone());
        if let Some(code) = oldest {
            reg.pending_codes.remove(&code);
        } else {
            break;
        }
    }

    let pair_code = loop {
        let code = generate_pair_code();
        if !reg.pending_codes.contains_key(&code) {
            break code;
        }
    };
    reg.pending_codes
        .insert(pair_code.clone(), PairCodeEntry { expires_at_unix });

    (
        StatusCode::OK,
        Json(PairStartResponse {
            pair_code,
            expires_at,
            expires_at_unix,
        }),
    )
        .into_response()
}

async fn pair_exchange_handler(
    State(ctx): State<AppContext>,
    Json(payload): Json<PairExchangeRequest>,
) -> Response {
    let pair_code = payload.pair_code.trim().to_string();
    if pair_code.len() != 6 || !pair_code.chars().all(|c| c.is_ascii_digit()) {
        return (
            StatusCode::BAD_REQUEST,
            Json(PairErrorResponse {
                error: "invalid_pair_code".to_string(),
                message: "pair_code must be 6 digits".to_string(),
            }),
        )
            .into_response();
    }

    let device_name = payload
        .device_name
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "iOS Device".to_string());

    let mut reg = ctx.pairing_registry.lock().await;
    let now_ts = now_unix_ts();
    cleanup_expired_pairing_entries(&mut reg, now_ts);

    let Some(code_entry) = reg.pending_codes.remove(&pair_code) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(PairErrorResponse {
                error: "pair_code_not_found".to_string(),
                message: "pair_code is invalid or expired".to_string(),
            }),
        )
            .into_response();
    };
    if code_entry.expires_at_unix <= now_ts {
        return (
            StatusCode::UNAUTHORIZED,
            Json(PairErrorResponse {
                error: "pair_code_expired".to_string(),
                message: "pair_code is expired".to_string(),
            }),
        )
            .into_response();
    }

    while reg.issued_tokens.len() >= MAX_ISSUED_PAIR_TOKENS {
        let oldest = reg
            .issued_tokens
            .iter()
            .min_by_key(|(_, entry)| entry.expires_at_unix)
            .map(|(token, _)| token.clone());
        if let Some(token) = oldest {
            reg.issued_tokens.remove(&token);
        } else {
            break;
        }
    }

    let ws_token = Uuid::new_v4().to_string();
    let token_id = Uuid::new_v4().to_string();
    let issued_at_unix = now_ts;
    let expires_at_unix = now_ts + PAIR_TOKEN_TTL_SECS;
    reg.issued_tokens.insert(
        ws_token.clone(),
        PairTokenEntry {
            token_id: token_id.clone(),
            device_name: device_name.clone(),
            issued_at_unix,
            expires_at_unix,
        },
    );

    // 持久化到 AppState
    let tokens_ref = reg.issued_tokens.clone();
    let app_state = ctx.app_state.clone();
    let save_tx = ctx.save_tx.clone();
    tokio::spawn(async move {
        persist_tokens_to_state(&tokens_ref, &app_state, &save_tx).await;
    });

    (
        StatusCode::OK,
        Json(PairExchangeResponse {
            token_id,
            ws_token,
            device_name,
            issued_at: unix_ts_to_rfc3339(issued_at_unix),
            issued_at_unix,
            expires_at: unix_ts_to_rfc3339(expires_at_unix),
            expires_at_unix,
        }),
    )
        .into_response()
}

async fn pair_revoke_handler(
    State(ctx): State<AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<PairRevokeRequest>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return (
            StatusCode::FORBIDDEN,
            Json(PairErrorResponse {
                error: "forbidden".to_string(),
                message: "pair/revoke only accepts loopback requests".to_string(),
            }),
        )
            .into_response();
    }

    if payload.token_id.is_none() && payload.ws_token.is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(PairErrorResponse {
                error: "invalid_request".to_string(),
                message: "token_id or ws_token is required".to_string(),
            }),
        )
            .into_response();
    }

    let mut reg = ctx.pairing_registry.lock().await;
    let now_ts = now_unix_ts();
    cleanup_expired_pairing_entries(&mut reg, now_ts);

    let mut revoked = 0usize;
    let mut revoked_subscriber_ids = HashSet::new();
    if let Some(ws_token) = payload.ws_token {
        if let Some(entry) = reg.issued_tokens.remove(ws_token.trim()) {
            revoked += 1;
            revoked_subscriber_ids.insert(entry.token_id);
        }
    }
    if let Some(token_id) = payload.token_id {
        let token_id = token_id.trim();
        let matches: Vec<String> = reg
            .issued_tokens
            .iter()
            .filter_map(|(token, entry)| {
                if entry.token_id == token_id {
                    Some(token.clone())
                } else {
                    None
                }
            })
            .collect();
        for token in matches {
            if let Some(entry) = reg.issued_tokens.remove(&token) {
                revoked += 1;
                revoked_subscriber_ids.insert(entry.token_id);
            }
        }
    }

    // 撤销后持久化
    if revoked > 0 {
        let tokens_ref = reg.issued_tokens.clone();
        let app_state = ctx.app_state.clone();
        let save_tx = ctx.save_tx.clone();
        tokio::spawn(async move {
            persist_tokens_to_state(&tokens_ref, &app_state, &save_tx).await;
        });
    }
    drop(reg);

    // 撤销配对后，清理该设备对应的远程终端订阅
    if !revoked_subscriber_ids.is_empty() {
        let mut rsub = ctx.remote_sub_registry.lock().await;
        for subscriber_id in revoked_subscriber_ids {
            rsub.unsubscribe_all(&subscriber_id);
        }
    }

    (
        StatusCode::OK,
        Json(PairRevokeResponse { ok: true, revoked }),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::{
        cleanup_expired_pairing_entries, is_request_from_loopback, is_ws_token_authorized,
        now_unix_ts, PairCodeEntry, PairTokenEntry, PairingRegistry, SharedPairingRegistry,
    };
    use std::collections::HashMap;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::sync::Arc;
    use tokio::sync::Mutex;

    fn test_registry() -> SharedPairingRegistry {
        Arc::new(Mutex::new(PairingRegistry {
            pending_codes: HashMap::new(),
            issued_tokens: HashMap::new(),
        }))
    }

    #[tokio::test]
    async fn token_auth_allows_when_token_not_configured() {
        let reg = test_registry();
        assert!(is_ws_token_authorized(None, None, &reg).await);
        assert!(is_ws_token_authorized(None, Some("anything"), &reg).await);
    }

    #[tokio::test]
    async fn token_auth_requires_exact_or_paired_token_when_configured() {
        let now_ts = now_unix_ts();
        let reg = test_registry();
        {
            let mut guard = reg.lock().await;
            guard.issued_tokens.insert(
                "paired-token".to_string(),
                PairTokenEntry {
                    token_id: "id-1".to_string(),
                    device_name: "iPhone".to_string(),
                    issued_at_unix: now_ts,
                    expires_at_unix: now_ts + 60,
                },
            );
        }
        assert!(is_ws_token_authorized(Some("bootstrap"), Some("bootstrap"), &reg).await);
        assert!(is_ws_token_authorized(Some("bootstrap"), Some("paired-token"), &reg).await);
        assert!(!is_ws_token_authorized(Some("bootstrap"), None, &reg).await);
        assert!(!is_ws_token_authorized(Some("bootstrap"), Some("bad"), &reg).await);
    }

    #[tokio::test]
    async fn token_auth_rejects_expired_paired_token() {
        let now_ts = now_unix_ts();
        let reg = test_registry();
        {
            let mut guard = reg.lock().await;
            guard.issued_tokens.insert(
                "expired-token".to_string(),
                PairTokenEntry {
                    token_id: "id-1".to_string(),
                    device_name: "iPhone".to_string(),
                    issued_at_unix: now_ts.saturating_sub(100),
                    expires_at_unix: now_ts.saturating_sub(1),
                },
            );
        }

        assert!(!is_ws_token_authorized(Some("bootstrap"), Some("expired-token"), &reg).await);
        let guard = reg.lock().await;
        assert!(guard.issued_tokens.is_empty());
    }

    #[test]
    fn cleanup_drops_expired_items() {
        let now_ts = now_unix_ts();
        let mut reg = PairingRegistry {
            pending_codes: HashMap::from([
                (
                    "111111".to_string(),
                    PairCodeEntry {
                        expires_at_unix: now_ts + 10,
                    },
                ),
                (
                    "222222".to_string(),
                    PairCodeEntry {
                        expires_at_unix: now_ts.saturating_sub(1),
                    },
                ),
            ]),
            issued_tokens: HashMap::from([
                (
                    "token-a".to_string(),
                    PairTokenEntry {
                        token_id: "id-a".to_string(),
                        device_name: "A".to_string(),
                        issued_at_unix: now_ts,
                        expires_at_unix: now_ts + 10,
                    },
                ),
                (
                    "token-b".to_string(),
                    PairTokenEntry {
                        token_id: "id-b".to_string(),
                        device_name: "B".to_string(),
                        issued_at_unix: now_ts,
                        expires_at_unix: now_ts.saturating_sub(1),
                    },
                ),
            ]),
        };

        cleanup_expired_pairing_entries(&mut reg, now_ts);
        assert_eq!(reg.pending_codes.len(), 1);
        assert!(reg.pending_codes.contains_key("111111"));
        assert_eq!(reg.issued_tokens.len(), 1);
        assert!(reg.issued_tokens.contains_key("token-a"));
    }

    #[test]
    fn loopback_check_matches_only_loopback_ip() {
        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1234);
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 2)), 1234);
        assert!(is_request_from_loopback(local));
        assert!(!is_request_from_loopback(remote));
    }
}

/// Handle a WebSocket connection
async fn handle_socket(
    mut socket: WebSocket,
    app_state: SharedAppState,
    save_tx: tokio::sync::mpsc::Sender<()>,
    registry: SharedTerminalRegistry,
    scrollback_tx: tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    conn_meta: ConnectionMeta,
    remote_sub_registry: SharedRemoteSubRegistry,
    task_broadcast_tx: TaskBroadcastTx,
    running_commands: SharedRunningCommands,
    running_ai_tasks: SharedRunningAITasks,
    task_history: SharedTaskHistory,
    ai_state: SharedAIState,
) {
    info!(
        "New WebSocket connection established (conn_id={}, remote={})",
        conn_meta.conn_id, conn_meta.is_remote
    );

    // 聚合输出通道：所有订阅终端的输出汇聚到这里
    let (agg_tx, mut agg_rx) = tokio::sync::mpsc::channel::<(String, Vec<u8>)>(256);

    // 跟踪当前 WS 连接订阅的终端及其转发 task + 流控状态
    let subscribed_terms: Arc<Mutex<HashMap<String, TermSubscription>>> =
        Arc::new(Mutex::new(HashMap::new()));

    // Create channel for file watcher events
    let (tx_watch, mut rx_watch) = tokio::sync::mpsc::channel::<WatchEvent>(100);

    // Create file watcher
    let watcher = Arc::new(Mutex::new(WorkspaceWatcher::new(tx_watch)));

    // 项目命令输出通道：后台 task 逐行推送 → 主循环转发到 WebSocket
    let (cmd_output_tx, mut cmd_output_rx) = tokio::sync::mpsc::channel::<ServerMessage>(256);
    let lsp_supervisor = LspSupervisor::new(cmd_output_tx.clone());

    // 订阅任务广播通道（接收其他连接发起的任务事件）
    let mut task_broadcast_rx = task_broadcast_tx.subscribe();

    // 构造 HandlerContext，收拢所有共享依赖
    let handler_ctx = HandlerContext {
        app_state: app_state.clone(),
        terminal_registry: registry.clone(),
        save_tx: save_tx.clone(),
        scrollback_tx: scrollback_tx.clone(),
        subscribed_terms: subscribed_terms.clone(),
        agg_tx: agg_tx.clone(),
        running_commands: running_commands.clone(),
        running_ai_tasks: running_ai_tasks.clone(),
        cmd_output_tx: cmd_output_tx.clone(),
        task_broadcast_tx: task_broadcast_tx.clone(),
        task_history: task_history.clone(),
        lsp_supervisor: lsp_supervisor.clone(),
        conn_meta: conn_meta.clone(),
        remote_sub_registry: remote_sub_registry.clone(),
        ai_state: ai_state.clone(),
    };

    // Send Hello message with v1 capabilities
    let hello_msg = ServerMessage::Hello {
        version: PROTOCOL_VERSION,
        session_id: String::new(),
        shell: String::new(),
        capabilities: Some(v1_capabilities()),
    };

    if let Err(e) = send_message(&mut socket, &hello_msg).await {
        error!("Failed to send Hello message: {}", e);
        return;
    }

    // 远程终端变更事件接收器（仅本地连接使用）
    let mut remote_term_rx = if !conn_meta.is_remote {
        Some(remote_sub_registry.lock().await.subscribe_events())
    } else {
        None
    };

    // Main loop: handle WebSocket messages and PTY output
    info!("Entering main WebSocket loop");
    crate::util::flush_logs();
    let mut loop_count: u64 = 0;
    let mut last_log_time = std::time::Instant::now();
    loop {
        loop_count += 1;

        if loop_count == 1 {
            debug!("First loop iteration, about to call tokio::select!");
            crate::util::flush_logs();
        } else if last_log_time.elapsed().as_secs() >= 5 {
            trace!("Main loop still running, iteration {}", loop_count);
            crate::util::flush_logs();
            last_log_time = std::time::Instant::now();
        }

        tokio::select! {
            biased;  // 优先处理 WebSocket 消息

            // Handle WebSocket messages (优先)
            msg_result = socket.recv() => {
                trace!("socket.recv() returned: {:?}", msg_result.as_ref().map(|r| r.as_ref().map(|m| match m {
                    Message::Text(t) => format!("Text({}...)", &t[..t.len().min(50)]),
                    Message::Binary(b) => format!("Binary({} bytes)", b.len()),
                    Message::Ping(_) => "Ping".to_string(),
                    Message::Pong(_) => "Pong".to_string(),
                    Message::Close(_) => "Close".to_string(),
                })));
                match msg_result {
                    Some(Ok(Message::Binary(data))) => {
                        trace!("Received binary client message: {} bytes", data.len());
                        let client_message_type = probe_client_message_type(&data);
                        if let Err(e) = handle_client_message(
                            &data,
                            &mut socket,
                            &handler_ctx,
                            &watcher,
                        ).await {
                            warn!(
                                "Error handling client message: conn_id={}, message_type={}, error={}",
                                conn_meta.conn_id, client_message_type, e
                            );
                            if let Err(send_err) = send_message(&mut socket, &ServerMessage::Error {
                                code: "message_error".to_string(),
                                message: e.clone(),
                            }).await {
                                error!(
                                    "Failed to send error message: conn_id={}, message_type={}, error={}",
                                    conn_meta.conn_id, client_message_type, send_err
                                );
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) => {
                        info!(
                            "WebSocket connection closed by client (conn_id={})",
                            conn_meta.conn_id
                        );
                        break;
                    }
                    Some(Ok(Message::Text(_))) => {
                        warn!("Received deprecated text message, binary MessagePack expected");
                    }
                    Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => {
                        // Handled automatically by axum
                    }
                    Some(Err(e)) => {
                        error!("WebSocket error: conn_id={}, error={}", conn_meta.conn_id, e);
                        break;
                    }
                    None => {
                        info!(
                            "WebSocket connection closed (recv returned None, conn_id={})",
                            conn_meta.conn_id
                        );
                        break;
                    }
                }
            }

            // Handle aggregated PTY output from subscribed terminals
            // 批量合并：一次性取出多条消息，合并同一终端的输出为单个 WS 帧
            Some((term_id, output)) = agg_rx.recv() => {
                const MAX_BATCH_SIZE: usize = 256 * 1024; // 256KB
                let mut batched: HashMap<String, Vec<u8>> = HashMap::new();
                let first_len = output.len();
                batched.entry(term_id).or_default().extend(output);
                let mut total = first_len;

                // 继续 try_recv 直到通道为空或达到预算上限
                while total < MAX_BATCH_SIZE {
                    match agg_rx.try_recv() {
                        Ok((id, data)) => {
                            total += data.len();
                            batched.entry(id).or_default().extend(data);
                        }
                        Err(_) => break,
                    }
                }

                trace!("Batched PTY output: {} terminals, {} bytes total", batched.len(), total);

                // 逐终端发送合并后的数据
                let mut send_failed = false;
                for (id, data) in batched {
                    let msg = ServerMessage::Output {
                        data,
                        term_id: Some(id),
                    };
                    if let Err(e) = send_message(&mut socket, &msg).await {
                        error!("Failed to send output message: {}", e);
                        send_failed = true;
                        break;
                    }
                }
                if send_failed {
                    break;
                }
            }

            // Handle file watcher events
            Some(watch_event) = rx_watch.recv() => {
                match watch_event {
                    WatchEvent::FileChanged { project, workspace, paths, kind } => {
                        debug!("File changed: project={}, workspace={}, paths={:?}", project, workspace, paths);

                        handler_ctx
                            .lsp_supervisor
                            .handle_paths_changed(&project, &workspace, &paths)
                            .await;

                        // 文件变化可能影响 git status，主动失效缓存
                        {
                            let ws_ctx = crate::server::context::resolve_workspace(
                                &app_state, &project, &workspace,
                            ).await;
                            if let Ok(ctx) = ws_ctx {
                                invalidate_git_status_cache(&ctx.root_path);
                            }
                        }

                        let msg = ServerMessage::FileChanged {
                            project,
                            workspace,
                            paths,
                            kind,
                        };
                        if let Err(e) = send_message(&mut socket, &msg).await {
                            error!("Failed to send file changed message: {}", e);
                        }
                    }
                    WatchEvent::GitStatusChanged { project, workspace } => {
                        debug!("Git status changed: project={}, workspace={}", project, workspace);

                        // Git 元数据变化（index/HEAD/refs），主动失效缓存
                        {
                            let ws_ctx = crate::server::context::resolve_workspace(
                                &app_state, &project, &workspace,
                            ).await;
                            if let Ok(ctx) = ws_ctx {
                                invalidate_git_status_cache(&ctx.root_path);
                            }
                        }

                        let msg = ServerMessage::GitStatusChanged {
                            project,
                            workspace,
                        };
                        if let Err(e) = send_message(&mut socket, &msg).await {
                            error!("Failed to send git status changed message: {}", e);
                        }
                    }
                }
            }

            // 项目命令后台 task 的输出/完成消息
            Some(msg) = cmd_output_rx.recv() => {
                if let Err(e) = send_message(&mut socket, &msg).await {
                    error!("Failed to send command output message: {}", e);
                }
            }

            // 任务广播：接收其他连接发起的任务事件
            result = task_broadcast_rx.recv() => {
                match result {
                    Ok(event) => {
                        if event.origin_conn_id != conn_meta.conn_id {
                            if let Err(e) = send_message(&mut socket, &event.message).await {
                                error!("Failed to send broadcast task event: {}", e);
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!("Task broadcast lagged by {} messages", n);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        debug!("Task broadcast channel closed");
                    }
                }
            }

            // 远程终端订阅变更通知（仅本地连接接收）
            result = async {
                match remote_term_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                match result {
                    Ok(_event) => {
                        info!("Received RemoteTermEvent::Changed, sending remote_term_changed to local conn {}", conn_meta.conn_id);
                        if let Err(e) = send_message(&mut socket, &ServerMessage::RemoteTermChanged).await {
                            error!("Failed to send remote_term_changed: {}", e);
                        }
                    }
                    Err(e) => {
                        warn!("remote_term_rx recv error (lagged?): {:?}", e);
                    }
                }
            }

            else => {
                debug!("All channels closed, exiting");
                break;
            }
        }
    }

    // WS 断开：只清理订阅关系，不杀终端
    {
        let mut subs = subscribed_terms.lock().await;
        for (term_id, (handle, _fc, flow_gate)) in subs.drain() {
            info!("Unsubscribing from terminal {} on WS disconnect", term_id);
            handle.abort();
            flow_gate.remove_subscriber();
        }
    }

    // WS 断开：配对设备订阅长期保留，未配对远程连接仍按 conn_id 清理
    if conn_meta.is_remote {
        if conn_meta.token_id.is_some() {
            info!(
                conn_id = %conn_meta.conn_id,
                subscriber_id = %conn_meta.remote_subscriber_id(),
                "Remote WebSocket disconnected; keeping remote terminal subscriptions"
            );
        } else {
            let mut reg = remote_sub_registry.lock().await;
            reg.unsubscribe_all(&conn_meta.conn_id);
        }
    }

    // WS 断开：关闭该连接托管的 LSP 会话
    handler_ctx.lsp_supervisor.shutdown_all().await;

    info!("WebSocket connection handler finished");
}

/// Send a server message over WebSocket
pub async fn send_message(socket: &mut WebSocket, msg: &ServerMessage) -> Result<(), String> {
    // 使用 to_vec_named 确保输出字典格式（带字段名），而不是数组格式
    let bytes = rmp_serde::to_vec_named(msg).map_err(|e| e.to_string())?;
    socket
        .send(Message::Binary(bytes))
        .await
        .map_err(|e| e.to_string())
}

/// 订阅终端输出：从 registry 的 broadcast 接收数据，转发到聚合通道
/// 带流控：当 unacked 超过高水位时暂停转发，等待前端 ACK
pub async fn subscribe_terminal(
    term_id: &str,
    registry: &SharedTerminalRegistry,
    subscribed_terms: &Arc<Mutex<HashMap<String, TermSubscription>>>,
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
        unacked: AtomicU64::new(0),
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
            while fc_clone.unacked.load(Ordering::Relaxed) > FLOW_CONTROL_HIGH_WATER {
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
                        warn!("Terminal {} flow control timeout, decaying unacked {} -> {}", tid, prev, prev / 2);
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
    subscribed_terms: &Arc<Mutex<HashMap<String, TermSubscription>>>,
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
    subscribed_terms: &Arc<Mutex<HashMap<String, TermSubscription>>>,
) {
    let subs = subscribed_terms.lock().await;
    if let Some((_handle, fc, _flow_gate)) = subs.get(term_id) {
        // 减少未确认字节数（使用饱和减法避免下溢）
        let prev = fc.unacked.load(Ordering::Relaxed);
        let new_val = prev.saturating_sub(bytes);
        fc.unacked.store(new_val, Ordering::Relaxed);
        // 如果降至高水位以下，唤醒转发 task
        if prev > FLOW_CONTROL_HIGH_WATER && new_val <= FLOW_CONTROL_HIGH_WATER {
            fc.notify.notify_one();
        }
    }
}

/// Handle a client message — 统一调度层
///
/// 支持两种消息格式：
/// 1. 带 `id` 的 RequestEnvelope（客户端希望关联响应时附带 request_id）
/// 2. 裸 ClientMessage（向后兼容）
async fn handle_client_message(
    data: &[u8],
    socket: &mut WebSocket,
    ctx: &HandlerContext,
    watcher: &Arc<Mutex<WorkspaceWatcher>>,
) -> Result<(), String> {
    trace!(
        "handle_client_message called with data length: {}",
        data.len()
    );

    // 尝试先按 RequestEnvelope 解析（带可选 id 字段）
    // RequestEnvelope 使用 #[serde(flatten)] 所以裸 ClientMessage 也能匹配（id 为 None）
    let envelope: RequestEnvelope = rmp_serde::from_slice(data).map_err(|e| {
        error!("Failed to parse client message: {}", e);
        format!("Parse error: {}", e)
    })?;

    let _request_id = envelope.id; // 预留：未来可在响应中回显
    let client_msg = envelope.body;
    trace!(
        "Parsed client message: {:?}",
        std::mem::discriminant(&client_msg)
    );

    // 按领域分发，handler 返回 Option<ServerMessage>，由此处统一发送
    // 终端消息需要特殊处理（可能返回多条消息），沿用旧模式
    if handlers::terminal::handle_terminal_message(&client_msg, socket, ctx).await? {
        return Ok(());
    }

    // 文件消息
    if handlers::file::handle_file_message(&client_msg, socket, &ctx.app_state).await? {
        return Ok(());
    }

    // Git 消息
    if handlers::git::handle_git_message(&client_msg, socket, &ctx.app_state, ctx).await? {
        return Ok(());
    }

    // 项目/工作空间消息
    if handlers::project::handle_project_message(&client_msg, socket, ctx).await? {
        return Ok(());
    }

    // LSP 诊断消息
    if handlers::lsp::handle_lsp_message(&client_msg, socket, ctx).await? {
        return Ok(());
    }

    // 设置消息
    if handlers::settings::handle_settings_message(
        &client_msg,
        socket,
        &ctx.app_state,
        &ctx.save_tx,
    )
    .await?
    {
        return Ok(());
    }

    // 日志消息
    if handlers::log::handle_log_message(&client_msg)? {
        return Ok(());
    }

    // AI 消息
    if handlers::ai::handle_ai_message(
        &client_msg,
        socket,
        &ctx.app_state,
        &ctx.ai_state,
        &ctx.cmd_output_tx,
        &ctx.task_broadcast_tx,
    )
    .await?
    {
        return Ok(());
    }

    // 内置消息处理
    match client_msg {
        ClientMessage::Ping => {
            send_message(socket, &ServerMessage::Pong).await?;
        }

        // v1.22: File watcher
        ClientMessage::WatchSubscribe { project, workspace } => {
            info!(
                "WatchSubscribe: project={}, workspace={}",
                project, workspace
            );

            match crate::server::context::resolve_workspace(&ctx.app_state, &project, &workspace)
                .await
            {
                Ok(ws_ctx) => {
                    let mut w = watcher.lock().await;
                    match w.subscribe(project.clone(), workspace.clone(), ws_ctx.root_path) {
                        Ok(_) => {
                            send_message(
                                socket,
                                &ServerMessage::WatchSubscribed { project, workspace },
                            )
                            .await?;
                        }
                        Err(e) => {
                            send_message(
                                socket,
                                &ServerMessage::Error {
                                    code: "watch_subscribe_failed".to_string(),
                                    message: e,
                                },
                            )
                            .await?;
                        }
                    }
                }
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                }
            }
        }

        ClientMessage::WatchUnsubscribe => {
            info!("WatchUnsubscribe");
            let mut w = watcher.lock().await;
            w.unsubscribe();
            send_message(socket, &ServerMessage::WatchUnsubscribed).await?;
        }

        // 所有其他消息类型已在上方 handler 链中处理，此处兜底
        _ => {
            warn!(
                "Unhandled message type: {:?}",
                std::mem::discriminant(&client_msg)
            );
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "unhandled_message".to_string(),
                    message: "Message type not recognized".to_string(),
                },
            )
            .await?;
        }
    }

    Ok(())
}
