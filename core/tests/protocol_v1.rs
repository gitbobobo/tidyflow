//! Protocol v7 Integration Tests
//!
//! Tests the WebSocket control plane protocol (v7: MessagePack binary encoding + domain/action envelope).
//!
//! 服务器进程由测试框架自动启停，无需手动干预。

#![allow(dead_code, clippy::useless_format)]

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
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
static NEXT_PORT: AtomicU16 = AtomicU16::new(49000);

/// 获取下一个可用端口
fn next_test_port() -> u16 {
    NEXT_PORT.fetch_add(1, Ordering::SeqCst)
}

/// 服务器进程管理器
struct ServerGuard {
    child: Option<Child>,
    port: u16,
}

impl ServerGuard {
    /// 启动服务器并等待就绪
    fn start() -> Result<Self, String> {
        let port = next_test_port();
        Self::start_on_port(port)
    }

    fn start_on_port(port: u16) -> Result<Self, String> {
        // 获取 manifest 目录（core/）
        let manifest_dir = std::path::PathBuf::from(
            std::env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| ".".to_string()),
        );

        // 优先使用已编译的 release 二进制
        let release_bin = manifest_dir.join("target/release/tidyflow-core");
        let debug_bin = manifest_dir.join("target/debug/tidyflow-core");

        let bin_path = if release_bin.exists() {
            release_bin
        } else if debug_bin.exists() {
            debug_bin
        } else {
            return Err(format!(
                "未找到 tidyflow-core 二进制文件，请先运行: cargo build --manifest-path core/Cargo.toml --release"
            ));
        };

        let mut child = Command::new(&bin_path)
            .args(["serve", "--port", &port.to_string()])
            .env("TIDYFLOW_DEV", "1")
            .env_remove("TIDYFLOW_WS_TOKEN") // 禁用 token 认证以便测试
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("启动服务器失败: {}", e))?;

        // 读取 stdout 等待 TIDYFLOW_BOOTSTRAP 信号
        let stdout = child.stdout.take().ok_or("无法获取 stdout")?;
        let mut reader = BufReader::new(stdout);

        let mut bootstrap_line = String::new();
        let start = std::time::Instant::now();
        let timeout_secs = 10;

        loop {
            if start.elapsed() > Duration::from_secs(timeout_secs) {
                let _ = child.kill();
                return Err(format!(
                    "服务器启动超时（{}秒），未收到 TIDYFLOW_BOOTSTRAP 信号",
                    timeout_secs
                ));
            }

            // 非阻塞检查
            match reader.read_line(&mut bootstrap_line) {
                Ok(0) => {
                    // EOF，进程可能已退出
                    let status = child.try_wait();
                    if let Ok(Some(status)) = status {
                        return Err(format!("服务器进程意外退出: {}", status));
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                Ok(_) => {
                    if bootstrap_line.contains("TIDYFLOW_BOOTSTRAP") {
                        // 解析 bootstrap 信息
                        if let Some(json_str) = bootstrap_line
                            .strip_prefix("TIDYFLOW_BOOTSTRAP ")
                            .map(|s| s.trim())
                        {
                            if let Ok(bootstrap) = serde_json::from_str::<Value>(json_str) {
                                let port_val = bootstrap["port"].as_u64().unwrap_or(port as u64);
                                let ver_val = bootstrap["protocol_version"].as_u64().unwrap_or(7);
                                println!(
                                    "[test] 服务器已启动: port={}, protocol_version={}",
                                    port_val, ver_val
                                );
                                break;
                            }
                        }
                        // 即使解析失败，只要有 TIDYFLOW_BOOTSTRAP 就认为启动成功
                        println!("[test] 服务器已启动: port={}", port);
                        break;
                    }
                    bootstrap_line.clear();
                }
                Err(e) => {
                    if e.kind() != std::io::ErrorKind::WouldBlock {
                        let _ = child.kill();
                        return Err(format!("读取服务器输出失败: {}", e));
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        }

        // 把 stdout 放回去，避免管道破裂
        child.stdout = Some(reader.into_inner());

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
            println!("[test] 正在停止服务器 (pid={})", child.id());
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

const TIMEOUT_SECS: u64 = 2;

/// 服务端响应包络（与 Core 协议结构对应）
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

/// 接收并解析服务端消息（MessagePack 编码）
async fn recv_envelope(
    ws: &mut futures_util::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
) -> Option<ServerEnvelope> {
    for _ in 0..100 {
        match timeout(Duration::from_secs(TIMEOUT_SECS), ws.next()).await {
            Ok(Some(Ok(Message::Binary(data)))) => {
                // 解码 MessagePack 信封
                match rmp_serde::from_slice::<ServerEnvelope>(&data) {
                    Ok(envelope) => {
                        // 跳过 output_batch 事件（太多）
                        if envelope.action != "output_batch" {
                            println!(
                                "  Received: domain={}, action={}, kind={}",
                                envelope.domain, envelope.action, envelope.kind
                            );
                        }
                        return Some(envelope);
                    }
                    Err(e) => {
                        println!("  解码消息失败: {}", e);
                    }
                }
            }
            Ok(Some(Ok(Message::Text(text)))) => {
                // 处理可能的文本消息（向后兼容）
                println!("  Received text: {}", &text[..text.len().min(100)]);
                if let Ok(env) = serde_json::from_str::<ServerEnvelope>(&text) {
                    return Some(env);
                }
            }
            Ok(Some(Ok(_))) => continue,
            Ok(Some(Err(e))) => {
                println!("  WebSocket error: {}", e);
                return None;
            }
            Ok(None) => return None,
            Err(_) => return None, // Timeout
        }
    }
    None
}

/// 等待特定 action 的消息
async fn wait_for_action(
    ws: &mut futures_util::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
    expected_action: &str,
) -> Option<ServerEnvelope> {
    for _ in 0..50 {
        if let Some(env) = recv_envelope(ws).await {
            if env.action == expected_action {
                return Some(env);
            }
        }
    }
    None
}

/// 编码客户端消息为 MessagePack（简化版，用于测试）
fn encode_client_message(domain: &str, action: &str, payload: Value) -> Vec<u8> {
    let envelope = json!({
        "request_id": format!("test-{}", uuid::Uuid::new_v4()),
        "domain": domain,
        "action": action,
        "payload": payload,
        "client_ts": chrono::Utc::now().timestamp_millis() as u64,
    });
    rmp_serde::to_vec_named(&envelope).expect("encode should succeed")
}

async fn connect_to_server(
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
    let (ws_stream, _) = connect_async(&url).await.map_err(|e| {
        format!(
            "Connection failed (is server running on port {}?): {}",
            port, e
        )
    })?;
    Ok(ws_stream.split())
}

// ============================================================================
// 测试用例
// ============================================================================

/// Test 1: Hello with capabilities
#[tokio::test]
async fn test_hello_capabilities() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();

    let (_, mut read) = connect_to_server(port).await.expect("Failed to connect");
    let env = wait_for_action(&mut read, "hello")
        .await
        .expect("No hello message");

    assert_eq!(env.domain, "system");
    // hello 消息的 kind 由服务器实现决定（当前为 "result"）
    assert!(env.payload["version"].is_number());
    assert!(env.payload["session_id"].is_string());
    assert!(env.payload["shell"].is_string());
    assert!(env.payload["capabilities"].is_array());

    let caps = env.payload["capabilities"].as_array().unwrap();
    assert!(
        caps.iter().any(|c| c == "workspace_management"),
        "Missing workspace_management capability"
    );
    assert!(
        caps.iter().any(|c| c == "cwd_spawn"),
        "Missing cwd_spawn capability"
    );

    println!(
        "  ✓ Hello: version={}, caps={:?}",
        env.payload["version"], caps
    );
}

/// Test 2: Ping/Pong
#[tokio::test]
async fn test_ping_pong() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();

    let (mut write, mut read) = connect_to_server(port).await.expect("Failed to connect");
    let _ = wait_for_action(&mut read, "hello").await;

    // 发送 ping（使用 system 域）
    let msg = encode_client_message("system", "ping", json!({}));
    write.send(Message::Binary(msg)).await.unwrap();

    let env = wait_for_action(&mut read, "pong").await.expect("No pong");
    assert_eq!(env.domain, "system");
    assert_eq!(env.kind, "result");
    println!("  ✓ Pong received");
}

/// Test 3: List Projects
#[tokio::test]
async fn test_list_projects() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();

    let (mut write, mut read) = connect_to_server(port).await.expect("Failed to connect");
    let _ = wait_for_action(&mut read, "hello").await;

    let msg = encode_client_message("project", "list_projects", json!({}));
    write.send(Message::Binary(msg)).await.unwrap();

    let env = wait_for_action(&mut read, "projects")
        .await
        .expect("No projects response");

    assert_eq!(env.domain, "project");
    assert_eq!(env.kind, "event");
    assert!(env.payload["items"].is_array());
    let count = env.payload["items"].as_array().unwrap().len();
    println!("  ✓ Projects: {} found", count);
}

/// Test 4: List Workspaces (nonexistent project)
#[tokio::test]
async fn test_list_workspaces_error_case() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();

    let (mut write, mut read) = connect_to_server(port).await.expect("Failed to connect");
    let _ = wait_for_action(&mut read, "hello").await;

    let msg = encode_client_message(
        "project",
        "list_workspaces",
        json!({"project": "nonexistent_xyz"}),
    );
    write.send(Message::Binary(msg)).await.unwrap();

    let env = wait_for_action(&mut read, "error")
        .await
        .expect("No error response");

    assert_eq!(env.kind, "error");
    assert_eq!(env.payload["code"], "project_not_found");
    println!("  ✓ Error: {}", env.payload["message"]);
}

/// Test 5: Spawn Terminal with CWD
#[tokio::test]
async fn test_spawn_terminal_with_cwd() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();

    let (mut write, mut read) = connect_to_server(port).await.expect("Failed to connect");
    let _ = wait_for_action(&mut read, "hello").await;

    let msg = encode_client_message("terminal", "spawn_terminal", json!({"cwd": "/tmp"}));
    write.send(Message::Binary(msg)).await.unwrap();

    let env = wait_for_action(&mut read, "terminal_spawned")
        .await
        .expect("No terminal_spawned response");

    assert_eq!(env.domain, "terminal");
    assert_eq!(env.kind, "result");
    assert_eq!(env.payload["cwd"], "/tmp");
    assert!(env.payload["session_id"].is_string());
    println!(
        "  ✓ Terminal spawned in /tmp, session={}",
        &env.payload["session_id"].as_str().unwrap()[..8]
    );
}

/// Test 6: Spawn Terminal with invalid path
#[tokio::test]
async fn test_spawn_terminal_invalid_path() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();

    let (mut write, mut read) = connect_to_server(port).await.expect("Failed to connect");
    let _ = wait_for_action(&mut read, "hello").await;

    let msg = encode_client_message(
        "terminal",
        "spawn_terminal",
        json!({"cwd": "/nonexistent/path/xyz"}),
    );
    write.send(Message::Binary(msg)).await.unwrap();

    let env = wait_for_action(&mut read, "error")
        .await
        .expect("No error response");

    assert_eq!(env.kind, "error");
    // 错误码可能是 message_error 或 invalid_path，取决于服务器实现
    println!(
        "  ✓ Error: code={}, message={}",
        env.payload["code"], env.payload["message"]
    );
}

/// Test 7: Terminal I/O
/// 注：此测试涉及终端 I/O 的复杂性，暂时忽略
#[tokio::test]
#[ignore = "终端 I/O 测试需要更复杂的设置，将在 w-2 中完善"]
async fn test_terminal_io() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();

    let (mut write, mut read) = connect_to_server(port).await.expect("Failed to connect");
    let _ = wait_for_action(&mut read, "hello").await;

    // 先创建终端
    let spawn_msg = encode_client_message("terminal", "spawn_terminal", json!({"cwd": "/tmp"}));
    write.send(Message::Binary(spawn_msg)).await.unwrap();
    let _ = wait_for_action(&mut read, "terminal_spawned").await;

    // Send resize
    let resize_msg = encode_client_message("terminal", "resize", json!({"cols": 80, "rows": 24}));
    write.send(Message::Binary(resize_msg)).await.unwrap();

    // Send echo command
    let cmd = "echo TIDYFLOW_V1_TEST\n";
    let data_b64 = BASE64.encode(cmd.as_bytes());
    let input_msg = encode_client_message("terminal", "input", json!({"data_b64": data_b64}));
    write.send(Message::Binary(input_msg)).await.unwrap();

    // Look for output containing our test string
    let mut found = false;
    for _ in 0..30 {
        if let Some(env) = recv_envelope(&mut read).await {
            if env.action == "output_batch" {
                let items = env.payload["items"].as_array().cloned().unwrap_or_default();
                for item in items {
                    if let Some(data_b64) = item["data"].as_str() {
                        let data = BASE64.decode(data_b64).unwrap_or_default();
                        let text = String::from_utf8_lossy(&data);
                        if text.contains("TIDYFLOW_V1_TEST") {
                            found = true;
                            break;
                        }
                    } else if let Some(data_arr) = item["data"].as_array() {
                        let data: Vec<u8> = data_arr
                            .iter()
                            .filter_map(|v| v.as_u64().map(|b| b as u8))
                            .collect();
                        let text = String::from_utf8_lossy(&data);
                        if text.contains("TIDYFLOW_V1_TEST") {
                            found = true;
                            break;
                        }
                    }
                }
            }
        }
        if found {
            break;
        }
    }
    assert!(found, "Did not receive expected output");
    println!("  ✓ Terminal I/O working");
}

/// Test 8: Kill Terminal
/// 注：此测试验证终端的 kill_terminal 功能
#[tokio::test]
async fn test_kill_terminal() {
    let server = ServerGuard::start().expect("启动服务器失败");
    let port = server.port();

    let (mut write, mut read) = connect_to_server(port).await.expect("Failed to connect");
    let _ = wait_for_action(&mut read, "hello").await;

    // 先创建终端以获取正确的 session_id
    let spawn_msg = encode_client_message("terminal", "spawn_terminal", json!({"cwd": "/tmp"}));
    write.send(Message::Binary(spawn_msg)).await.unwrap();
    let spawned = wait_for_action(&mut read, "terminal_spawned")
        .await
        .expect("No terminal_spawned response");
    let session_id = spawned.payload["session_id"].as_str().unwrap().to_string();

    let msg = encode_client_message("terminal", "kill_terminal", json!({}));
    write.send(Message::Binary(msg)).await.unwrap();

    let env = wait_for_action(&mut read, "terminal_killed")
        .await
        .expect("No terminal_killed response");

    assert_eq!(env.domain, "terminal");
    assert_eq!(env.kind, "result");
    assert_eq!(env.payload["session_id"], session_id);
    println!("  ✓ Terminal killed: {}", &session_id[..8]);
}
