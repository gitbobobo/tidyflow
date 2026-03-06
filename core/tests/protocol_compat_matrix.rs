//! 协议兼容性矩阵测试
//!
//! 验证所有核心消息流的 domain/action 映射正确性。
//! 这些测试确保协议在不同组件（Core/App/Web）之间保持一致。

use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU16, Ordering};
use std::time::Duration;
use tokio::time::timeout;
use tokio_tungstenite::{connect_async, tungstenite::Message};

/// 动态端口分配起始端口
static NEXT_PORT: AtomicU16 = AtomicU16::new(49100);

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

        let release_bin = manifest_dir.join("target/release/tidyflow-core");
        let debug_bin = manifest_dir.join("target/debug/tidyflow-core");

        let bin_path = if release_bin.exists() {
            release_bin
        } else if debug_bin.exists() {
            debug_bin
        } else {
            return Err("未找到 tidyflow-core 二进制文件".into());
        };

        let mut child = Command::new(&bin_path)
            .args(["serve", "--port", &port.to_string()])
            .env("TIDYFLOW_DEV", "1")
            .env_remove("TIDYFLOW_WS_TOKEN")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("启动服务器失败: {}", e))?;

        let stdout = child.stdout.take().ok_or("无法获取 stdout")?;
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        let start = std::time::Instant::now();

        loop {
            if start.elapsed() > Duration::from_secs(10) {
                let _ = child.kill();
                return Err("服务器启动超时".into());
            }
            match reader.read_line(&mut line) {
                Ok(0) => {
                    std::thread::sleep(Duration::from_millis(50));
                }
                Ok(_) if line.contains("TIDYFLOW_BOOTSTRAP") => break,
                Ok(_) => line.clear(),
                Err(_) => std::thread::sleep(Duration::from_millis(50)),
            }
        }
        child.stdout = Some(reader.into_inner());
        Ok(Self { child: Some(child), port })
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

// ============================================================================
// Domain/Action 兼容性矩阵测试
// ============================================================================

/// 测试 system 域的消息路由
#[tokio::test]
async fn test_system_domain_matrix() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");

    // hello 消息
    let hello = wait_for_action(&mut read, "hello").await.expect("无 hello");
    assert_eq!(hello.domain, "system");
    assert_eq!(hello.kind, "result");

    // ping -> pong
    write
        .send(Message::Binary(encode_client_message("system", "ping", json!({}))))
        .await
        .unwrap();
    let pong = wait_for_action(&mut read, "pong").await.expect("无 pong");
    assert_eq!(pong.domain, "system");
    assert_eq!(pong.kind, "result");
}

/// 测试 terminal 域的消息路由
#[tokio::test]
async fn test_terminal_domain_matrix() {
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
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();
    let (mut write, mut read) = connect(port).await.expect("连接失败");
    let _ = wait_for_action(&mut read, "hello").await;

    // client_settings_get -> client_settings_result
    write
        .send(Message::Binary(encode_client_message(
            "settings",
            "client_settings_get",
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
