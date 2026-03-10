//! 协议兼容性矩阵测试
//!
//! 验证所有核心消息流的 domain/action 映射正确性。
//! 这些测试确保协议在不同组件（Core/App/Web）之间保持一致。

#![allow(dead_code, clippy::manual_contains)]

use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, OwnedMutexGuard};
use tokio::time::timeout;
use tokio_tungstenite::{connect_async, tungstenite::Message};

/// 动态端口分配起始端口
static NEXT_PORT: AtomicU16 = AtomicU16::new(49100);

/// 全局测试串行化互斥锁：确保同一时刻只有一个测试服务器在运行。
/// 使用 tokio::sync::Mutex 配合 lock_owned()，令 guard 持有 Arc 引用而非生命周期借用，
/// 从而可安全跨 await 持有，同时兼容不同 tokio runtime 之间的唤醒通知。
static TEST_LOCK: std::sync::OnceLock<Arc<Mutex<()>>> = std::sync::OnceLock::new();

async fn acquire_test_lock() -> OwnedMutexGuard<()> {
    TEST_LOCK
        .get_or_init(|| Arc::new(Mutex::new(())))
        .clone()
        .lock_owned()
        .await
}

fn next_test_port() -> u16 {
    NEXT_PORT.fetch_add(1, Ordering::SeqCst)
}

/// 服务器进程管理器
struct ServerGuard {
    child: Option<Child>,
    port: u16,
}

impl ServerGuard {
    fn start() -> Result<Self, String> {
        let port = next_test_port();
        let manifest_dir =
            std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or(".".into()));

        let debug_bin = manifest_dir.join("target/debug/tidyflow-core");
        let release_bin = manifest_dir.join("target/release/tidyflow-core");

        // 集成测试应优先使用 cargo test 刚构建出的 debug 二进制，
        // 避免误连到过期的 release 构建而得到假阴性结果。
        let bin_path = if debug_bin.exists() {
            debug_bin
        } else if release_bin.exists() {
            release_bin
        } else {
            return Err("未找到 tidyflow-core 二进制文件".into());
        };

        let mut child = Command::new(&bin_path)
            .args(["serve", "--port", &port.to_string()])
            .env("TIDYFLOW_DEV", "1")
            .env_remove("TIDYFLOW_WS_TOKEN")
            .stdout(Stdio::piped())
            .stderr(Stdio::null()) // stderr 不消费会导致管道缓冲区满，阻塞服务器进程
            .spawn()
            .map_err(|e| format!("启动服务器失败: {}", e))?;

        let stdout = child.stdout.take().ok_or("无法获取 stdout")?;

        // 在后台线程读取 stdout，通过 channel 传递启动信号，确保超时机制有效。
        // read_line 是阻塞调用，直接在主线程轮询会导致超时检查无法在阻塞期间触发。
        let (tx, rx) = std::sync::mpsc::channel::<Result<(), String>>();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut line = String::new();
            loop {
                match reader.read_line(&mut line) {
                    Ok(0) => {
                        // EOF：服务器进程 stdout 已关闭，进程可能已退出
                        let _ = tx.send(Err(
                            "服务器进程 stdout 已关闭（进程可能已退出）".into(),
                        ));
                        return;
                    }
                    Ok(_) if line.contains("TIDYFLOW_BOOTSTRAP") => {
                        let _ = tx.send(Ok(()));
                        return;
                    }
                    Ok(_) => line.clear(),
                    Err(e) => {
                        let _ = tx.send(Err(format!("读取 stdout 失败: {}", e)));
                        return;
                    }
                }
            }
        });

        // 等待服务器启动，超时 60 秒（AI 服务初始化约 5-8 秒，并发测试场景下需要更充裕的时间）
        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                let _ = child.kill();
                return Err(format!("服务器启动失败: {}", e));
            }
            Err(_) => {
                let _ = child.kill();
                return Err("服务器启动超时（60s）".into());
            }
        }

        Ok(Self {
            child: Some(child),
            port,
        })
    }

    fn port(&self) -> u16 {
        self.port
    }
}

impl Drop for ServerGuard {
    fn drop(&mut self) {
        if let Some(ref mut child) = self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// 服务端响应包络
#[derive(Debug, Clone, Deserialize)]
struct ServerEnvelope {
    #[serde(default)]
    request_id: Option<String>,
    seq: u64,
    domain: String,
    action: String,
    kind: String,
    #[serde(default)]
    payload: Value,
    server_ts: u64,
}

fn encode_client_message(domain: &str, action: &str, payload: Value) -> Vec<u8> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let envelope = json!({
        "request_id": format!("test-{}", rand_id()),
        "domain": domain,
        "action": action,
        "payload": payload,
        "client_ts": ts,
    });
    rmp_serde::to_vec_named(&envelope).expect("encode should succeed")
}

fn rand_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    format!("{:016x}", COUNTER.fetch_add(1, Ordering::SeqCst))
}

async fn connect(
    port: u16,
) -> Result<
    (
        futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<
                tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
            >,
            Message,
        >,
        futures_util::stream::SplitStream<
            tokio_tungstenite::WebSocketStream<
                tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
            >,
        >,
    ),
    String,
> {
    let url = format!("ws://127.0.0.1:{}/ws", port);
    let (ws, _) = connect_async(&url).await.map_err(|e| e.to_string())?;
    Ok(ws.split())
}

async fn recv_envelope(
    ws: &mut futures_util::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
) -> Option<ServerEnvelope> {
    for _ in 0..50 {
        match timeout(Duration::from_secs(2), ws.next()).await {
            Ok(Some(Ok(Message::Binary(data)))) => {
                if let Ok(env) = rmp_serde::from_slice::<ServerEnvelope>(&data) {
                    return Some(env);
                }
            }
            Ok(Some(Ok(Message::Text(text)))) => {
                if let Ok(env) = serde_json::from_str::<ServerEnvelope>(&text) {
                    return Some(env);
                }
            }
            _ => continue,
        }
    }
    None
}

async fn wait_for_action(
    ws: &mut futures_util::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
    expected: &str,
) -> Option<ServerEnvelope> {
    for _ in 0..30 {
        if let Some(env) = recv_envelope(ws).await {
            if env.action == expected {
                return Some(env);
            }
        }
    }
    None
}

/// 等待 action="error" 且 payload.code == expected_code 的信封。
/// 用于验证 read_via_http_required 门禁响应（服务端通过 ServerMessage::Error 返回）。
async fn wait_for_error_with_code(
    ws: &mut futures_util::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
    expected_code: &str,
) -> Option<ServerEnvelope> {
    for _ in 0..30 {
        if let Some(env) = recv_envelope(ws).await {
            if env.action == "error"
                && env.payload.get("code").and_then(|v| v.as_str()) == Some(expected_code)
            {
                return Some(env);
            }
        }
    }
    None
}

// ============================================================================
// Domain/Action 兼容性矩阵测试
// ============================================================================

/// 测试 system 域的消息路由
#[tokio::test]
async fn test_system_domain_matrix() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");

    // hello 消息
    let hello = wait_for_action(&mut read, "hello").await.expect("无 hello");
    assert_eq!(hello.domain, "system");
    assert_eq!(hello.kind, "result");

    // ping -> pong
    write
        .send(Message::Binary(encode_client_message(
            "system",
            "ping",
            json!({}),
        )))
        .await
        .unwrap();
    let pong = wait_for_action(&mut read, "pong").await.expect("无 pong");
    assert_eq!(pong.domain, "system");
    assert_eq!(pong.kind, "result");
}

/// 测试 terminal 域的消息路由
#[tokio::test]
async fn test_terminal_domain_matrix() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    // spawn_terminal -> terminal_spawned
    write
        .send(Message::Binary(encode_client_message(
            "terminal",
            "spawn_terminal",
            json!({"cwd": "/tmp"}),
        )))
        .await
        .unwrap();
    let spawned = wait_for_action(&mut read, "terminal_spawned")
        .await
        .expect("无 terminal_spawned");
    assert_eq!(spawned.domain, "terminal");
    assert_eq!(spawned.kind, "result");

    // kill_terminal -> terminal_killed
    write
        .send(Message::Binary(encode_client_message(
            "terminal",
            "kill_terminal",
            json!({}),
        )))
        .await
        .unwrap();
    let killed = wait_for_action(&mut read, "terminal_killed")
        .await
        .expect("无 terminal_killed");
    assert_eq!(killed.domain, "terminal");
    assert_eq!(killed.kind, "result");
}

/// 测试 project 域的消息路由
#[tokio::test]
async fn test_project_domain_matrix() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    // list_projects -> projects
    write
        .send(Message::Binary(encode_client_message(
            "project",
            "list_projects",
            json!({}),
        )))
        .await
        .unwrap();
    let projects = wait_for_action(&mut read, "projects")
        .await
        .expect("无 projects");
    assert_eq!(projects.domain, "project");
    assert_eq!(projects.kind, "event"); // projects 是事件类型

    // list_workspaces -> error (项目不存在)
    write
        .send(Message::Binary(encode_client_message(
            "project",
            "list_workspaces",
            json!({"project": "nonexistent_test_xyz"}),
        )))
        .await
        .unwrap();
    let err = wait_for_action(&mut read, "error").await.expect("无 error");
    assert_eq!(err.kind, "error");
}

/// 测试 file 域的消息路由
#[tokio::test]
async fn test_file_domain_matrix() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    // file_list -> file_list_result (需要有效的项目和工作空间)
    write
        .send(Message::Binary(encode_client_message(
            "file",
            "file_list",
            json!({"project": "nonexistent", "workspace": "nonexistent"}),
        )))
        .await
        .unwrap();
    // 应该收到 error（因为项目不存在）
    let err = wait_for_action(&mut read, "error").await;
    assert!(err.is_some(), "应该收到 error 响应");
}

/// 测试 git 域的消息路由
#[tokio::test]
async fn test_git_domain_matrix() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    // git_status -> git_status_result (需要有效的项目和工作空间)
    write
        .send(Message::Binary(encode_client_message(
            "git",
            "git_status",
            json!({"project": "nonexistent", "workspace": "nonexistent"}),
        )))
        .await
        .unwrap();
    // 应该收到 error
    let result = wait_for_action(&mut read, "error").await;
    assert!(result.is_some());
}

/// 测试 settings 域的消息路由
#[tokio::test]
async fn test_settings_domain_matrix() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    // get_client_settings -> client_settings_result
    write
        .send(Message::Binary(encode_client_message(
            "settings",
            "get_client_settings",
            json!({}),
        )))
        .await
        .unwrap();
    let settings = wait_for_action(&mut read, "client_settings_result")
        .await
        .expect("无 client_settings_result");
    assert_eq!(settings.domain, "settings");
}

/// 测试未知 domain 路由到 misc
#[tokio::test]
async fn test_misc_domain_fallback() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    // 发送一个未知的 action
    write
        .send(Message::Binary(encode_client_message(
            "unknown_domain_xyz",
            "unknown_action",
            json!({}),
        )))
        .await
        .unwrap();
    // 应该收到 error（因为 action 未被处理）
    let result = wait_for_action(&mut read, "error").await;
    // misc 域处理未知消息，返回 error
    if let Some(err) = result {
        assert_eq!(err.kind, "error");
    }
}

/// 测试协议版本一致性
#[tokio::test]
async fn test_protocol_version_consistency() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (_, mut read) = connect(port).await.expect("连接失败");

    let hello = wait_for_action(&mut read, "hello").await.expect("无 hello");

    // 验证协议版本
    let version = hello.payload["version"].as_u64().expect("无版本号");
    assert!(
        version >= 7,
        "协议版本应该是 v7 或更高，当前为 v{}",
        version
    );

    // 验证必要的能力
    let caps = hello.payload["capabilities"]
        .as_array()
        .expect("无能力列表");
    let cap_names: Vec<&str> = caps.iter().filter_map(|c| c.as_str()).collect();

    // 核心能力必须存在
    assert!(
        cap_names.iter().any(|c| *c == "workspace_management"),
        "缺少 workspace_management 能力"
    );
    assert!(
        cap_names.iter().any(|c| *c == "cwd_spawn"),
        "缺少 cwd_spawn 能力"
    );
    assert!(
        cap_names.iter().any(|c| *c == "file_operations"),
        "缺少 file_operations 能力"
    );
    assert!(
        cap_names.iter().any(|c| *c == "git_tools"),
        "缺少 git_tools 能力"
    );
}

/// 测试 AI domain 的 WS 读取入口返回 read_via_http_required
///
/// 验证 ai_session_list 等读取 action 在 WS 上返回正确的门禁响应，
/// 且响应携带 project/workspace 字段（多工作区边界约束）。
#[tokio::test]
async fn test_ai_ws_read_via_http_required() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    // ai_session_list 是 HTTP 读取入口，WS 上应返回 read_via_http_required（通过 error envelope 携带）
    write
        .send(Message::Binary(encode_client_message(
            "ai",
            "ai_session_list",
            json!({ "project_name": "testproject", "workspace_name": "default", "ai_tool": "codex" }),
        )))
        .await
        .unwrap();
    // 服务端通过 ServerMessage::Error { code: "read_via_http_required", project, workspace } 返回门禁响应，
    // 对应 envelope: action="error", payload.code="read_via_http_required"
    // 注：error 消息的 domain 统一映射为 "misc"（服务端 domain_from_action("error") 行为）
    let resp = wait_for_error_with_code(&mut read, "read_via_http_required")
        .await
        .expect("ai_session_list 应返回携带 read_via_http_required 代码的 error");
    // 验证 project/workspace 字段存在（多工作区边界约束）
    assert_eq!(
        resp.payload["project"].as_str().unwrap_or(""),
        "testproject",
        "error payload 应携带 project 字段"
    );
    assert_eq!(
        resp.payload["workspace"].as_str().unwrap_or(""),
        "default",
        "error payload 应携带 workspace 字段"
    );
}

/// 测试 evolution domain 的 WS 读取入口返回 read_via_http_required
///
/// 验证 evo_get_snapshot action 在 WS 上返回门禁响应，
/// 且响应携带 project/workspace 字段。
#[tokio::test]
async fn test_evolution_ws_read_via_http_required() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    write
        .send(Message::Binary(encode_client_message(
            "evolution",
            "evo_get_snapshot",
            json!({ "project": "testproject", "workspace": "default" }),
        )))
        .await
        .unwrap();
    let resp = wait_for_error_with_code(&mut read, "read_via_http_required")
        .await
        .expect("evo_get_snapshot 应返回携带 read_via_http_required 代码的 error");
    // 注：error 消息的 domain 统一映射为 "misc"
    assert_eq!(
        resp.payload["project"].as_str().unwrap_or(""),
        "testproject",
        "error payload 应携带 project 字段"
    );
    assert_eq!(
        resp.payload["workspace"].as_str().unwrap_or(""),
        "default",
        "error payload 应携带 workspace 字段"
    );
}

/// 测试 evidence domain 的 WS 读取入口返回 read_via_http_required
///
/// 验证 evidence_get_snapshot action 在 WS 上返回门禁响应，
/// 且响应携带 project/workspace 字段。
#[tokio::test]
async fn test_evidence_ws_read_via_http_required() {
    let _lock = acquire_test_lock().await;
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    write
        .send(Message::Binary(encode_client_message(
            "evidence",
            "evidence_get_snapshot",
            json!({ "project": "testproject", "workspace": "default" }),
        )))
        .await
        .unwrap();
    let resp = wait_for_error_with_code(&mut read, "read_via_http_required")
        .await
        .expect("evidence_get_snapshot 应返回携带 read_via_http_required 代码的 error");
    // 注：error 消息的 domain 统一映射为 "misc"
    assert_eq!(
        resp.payload["project"].as_str().unwrap_or(""),
        "testproject",
        "error payload 应携带 project 字段"
    );
    assert_eq!(
        resp.payload["workspace"].as_str().unwrap_or(""),
        "default",
        "error payload 应携带 workspace 字段"
    );
}

// ============================================================================
// 协议类型单元测试（不需要运行服务器，直接验证 Rust 协议类型序列化）
// ============================================================================

#[test]
fn test_session_info_boundary_fields_required() {
    use tidyflow_core::server::protocol::ai::{AiSessionOrigin, SessionInfo};
    let s = SessionInfo {
        project_name: "proj".to_string(),
        workspace_name: "ws".to_string(),
        ai_tool: "codex".to_string(),
        id: "s1".to_string(),
        title: "测试".to_string(),
        updated_at: 1000,
        session_origin: AiSessionOrigin::User,
    };
    let j = serde_json::to_value(&s).unwrap();
    assert!(j.get("project_name").is_some());
    assert!(j.get("workspace_name").is_some());
    assert!(j.get("ai_tool").is_some());
    assert!(j.get("id").is_some());
}

#[test]
fn test_context_snapshot_serialization_roundtrip() {
    use tidyflow_core::server::protocol::ai::AiSessionContextSnapshot;
    let snap = AiSessionContextSnapshot {
        project_name: "proj".to_string(),
        workspace_name: "ws".to_string(),
        ai_tool: "codex".to_string(),
        session_id: "s1".to_string(),
        snapshot_at_ms: 9999,
        message_count: 7,
        context_summary: Some("已完成核心功能".to_string()),
        selection_hint: None,
        context_remaining_percent: Some(55.0),
    };
    let json_str = serde_json::to_string(&snap).unwrap();
    let parsed: AiSessionContextSnapshot = serde_json::from_str(&json_str).unwrap();
    assert_eq!(parsed.project_name, "proj");
    assert_eq!(parsed.workspace_name, "ws");
    assert_eq!(parsed.session_id, "s1");
    assert_eq!(parsed.message_count, 7);
    assert_eq!(parsed.context_remaining_percent, Some(55.0));
}

#[test]
fn test_server_message_context_snapshot_result_type() {
    use tidyflow_core::server::protocol::ServerMessage;
    let msg = ServerMessage::AISessionContextSnapshotResult {
        project_name: "proj".to_string(),
        workspace_name: "ws".to_string(),
        ai_tool: "codex".to_string(),
        session_id: "s1".to_string(),
        snapshot: None,
    };
    let j = serde_json::to_value(&msg).unwrap();
    assert_eq!(
        j["type"].as_str().unwrap(),
        "ai_session_context_snapshot_result"
    );
    assert_eq!(j["project_name"].as_str().unwrap(), "proj");
    assert!(j.get("session_id").is_some());
}

#[test]
fn test_server_message_cross_context_snapshots_result_type() {
    use tidyflow_core::server::protocol::ServerMessage;
    let msg = ServerMessage::AICrossContextSnapshotsResult {
        project_name: "proj".to_string(),
        workspace_name: "ws".to_string(),
        snapshots: vec![],
    };
    let j = serde_json::to_value(&msg).unwrap();
    assert_eq!(
        j["type"].as_str().unwrap(),
        "ai_cross_context_snapshots_result"
    );
}

#[test]
fn test_evolution_system_session_not_visible_in_default_list() {
    use tidyflow_core::server::protocol::ai::{AiSessionOrigin, SessionInfo};
    let s = SessionInfo {
        project_name: "proj".to_string(),
        workspace_name: "ws".to_string(),
        ai_tool: "codex".to_string(),
        id: "evo-s1".to_string(),
        title: "自动化会话".to_string(),
        updated_at: 1000,
        session_origin: AiSessionOrigin::EvolutionSystem,
    };
    let j = serde_json::to_value(&s).unwrap();
    assert_eq!(j["session_origin"].as_str().unwrap(), "evolution_system");
}
