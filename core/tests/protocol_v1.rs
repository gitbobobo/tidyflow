//! Protocol v1 Integration Tests
//!
//! Tests the WebSocket control plane protocol.
//!
//! To run these tests:
//! 1. Start the server: ./target/release/tidyflow-core serve --port 47997
//! 2. Run tests: cargo test --test protocol_v1 -- --ignored --nocapture

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::time::timeout;
use tokio_tungstenite::{connect_async, tungstenite::Message};

const TEST_PORT: u16 = 47997;
const TIMEOUT_SECS: u64 = 1;

async fn recv_json_skip_output(
    ws: &mut futures_util::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
    expected_type: &str,
) -> Option<Value> {
    for _ in 0..100 {
        match timeout(Duration::from_secs(TIMEOUT_SECS), ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
                if let Ok(msg) = serde_json::from_str::<Value>(&text) {
                    let msg_type = msg["type"].as_str().unwrap_or("");
                    if msg_type == expected_type {
                        return Some(msg);
                    }
                    // Skip output messages
                    if msg_type != "output" {
                        println!("  Received: {}", msg_type);
                    }
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

async fn connect_to_server() -> Result<
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
    let url = format!("ws://127.0.0.1:{}/ws", TEST_PORT);
    let (ws_stream, _) = connect_async(&url)
        .await
        .map_err(|e| format!("Connection failed (is server running on port {}?): {}", TEST_PORT, e))?;
    Ok(ws_stream.split())
}

/// Run all tests in sequence
#[tokio::test]
#[ignore]
async fn test_protocol_v1() {
    println!("\n=== TidyFlow Protocol v1 Tests ===\n");

    // Test 1: Hello with v1 capabilities
    println!("[Test 1] Hello message...");
    {
        let (_, mut read) = connect_to_server().await.expect("Failed to connect");
        let msg = recv_json_skip_output(&mut read, "hello").await.expect("No hello message");

        assert_eq!(msg["type"], "hello");
        assert_eq!(msg["version"], 1, "Expected protocol version 1");
        assert!(msg["session_id"].is_string());
        assert!(msg["shell"].is_string());
        assert!(msg["capabilities"].is_array());

        let caps = msg["capabilities"].as_array().unwrap();
        assert!(caps.iter().any(|c| c == "workspace_management"), "Missing workspace_management capability");
        assert!(caps.iter().any(|c| c == "cwd_spawn"), "Missing cwd_spawn capability");

        println!("  ✓ Hello: version={}, caps={:?}", msg["version"], caps);
    }

    // Test 2: Ping/Pong
    println!("[Test 2] Ping/Pong...");
    {
        let (mut write, mut read) = connect_to_server().await.expect("Failed to connect");
        let _ = recv_json_skip_output(&mut read, "hello").await;

        write.send(Message::Text(json!({"type": "ping"}).to_string())).await.unwrap();
        let msg = recv_json_skip_output(&mut read, "pong").await.expect("No pong");
        assert_eq!(msg["type"], "pong");
        println!("  ✓ Pong received");
    }

    // Test 3: List Projects
    println!("[Test 3] List Projects...");
    {
        let (mut write, mut read) = connect_to_server().await.expect("Failed to connect");
        let _ = recv_json_skip_output(&mut read, "hello").await;

        write.send(Message::Text(json!({"type": "list_projects"}).to_string())).await.unwrap();
        let msg = recv_json_skip_output(&mut read, "projects").await.expect("No projects response");

        assert_eq!(msg["type"], "projects");
        assert!(msg["items"].is_array());
        let count = msg["items"].as_array().unwrap().len();
        println!("  ✓ Projects: {} found", count);
    }

    // Test 4: List Workspaces (nonexistent project)
    println!("[Test 4] List Workspaces (error case)...");
    {
        let (mut write, mut read) = connect_to_server().await.expect("Failed to connect");
        let _ = recv_json_skip_output(&mut read, "hello").await;

        write.send(Message::Text(json!({"type": "list_workspaces", "project": "nonexistent_xyz"}).to_string())).await.unwrap();
        let msg = recv_json_skip_output(&mut read, "error").await.expect("No error response");

        assert_eq!(msg["type"], "error");
        assert_eq!(msg["code"], "project_not_found");
        println!("  ✓ Error: {}", msg["message"]);
    }

    // Test 5: Spawn Terminal with CWD
    println!("[Test 5] Spawn Terminal with CWD...");
    {
        let (mut write, mut read) = connect_to_server().await.expect("Failed to connect");
        let _ = recv_json_skip_output(&mut read, "hello").await;

        write.send(Message::Text(json!({"type": "spawn_terminal", "cwd": "/tmp"}).to_string())).await.unwrap();
        let msg = recv_json_skip_output(&mut read, "terminal_spawned").await.expect("No terminal_spawned response");

        assert_eq!(msg["type"], "terminal_spawned");
        assert_eq!(msg["cwd"], "/tmp");
        assert!(msg["session_id"].is_string());
        println!("  ✓ Terminal spawned in /tmp, session={}", &msg["session_id"].as_str().unwrap()[..8]);
    }

    // Test 6: Spawn Terminal with invalid path
    println!("[Test 6] Spawn Terminal (invalid path)...");
    {
        let (mut write, mut read) = connect_to_server().await.expect("Failed to connect");
        let _ = recv_json_skip_output(&mut read, "hello").await;

        write.send(Message::Text(json!({"type": "spawn_terminal", "cwd": "/nonexistent/path/xyz"}).to_string())).await.unwrap();
        let msg = recv_json_skip_output(&mut read, "error").await.expect("No error response");

        assert_eq!(msg["type"], "error");
        assert_eq!(msg["code"], "invalid_path");
        println!("  ✓ Error: {}", msg["message"]);
    }

    // Test 7: Terminal I/O
    println!("[Test 7] Terminal I/O...");
    {
        let (mut write, mut read) = connect_to_server().await.expect("Failed to connect");
        let _ = recv_json_skip_output(&mut read, "hello").await;

        // Send resize
        write.send(Message::Text(json!({"type": "resize", "cols": 80, "rows": 24}).to_string())).await.unwrap();

        // Send echo command
        let cmd = "echo TIDYFLOW_V1_TEST\n";
        let data_b64 = BASE64.encode(cmd.as_bytes());
        write.send(Message::Text(json!({"type": "input", "data_b64": data_b64}).to_string())).await.unwrap();

        // Look for output containing our test string
        let mut found = false;
        for _ in 0..30 {
            match timeout(Duration::from_secs(1), read.next()).await {
                Ok(Some(Ok(Message::Text(text)))) => {
                    if let Ok(msg) = serde_json::from_str::<Value>(&text) {
                        if msg["type"] == "output" {
                            if let Some(data_b64) = msg["data_b64"].as_str() {
                                let data = BASE64.decode(data_b64).unwrap_or_default();
                                let text = String::from_utf8_lossy(&data);
                                if text.contains("TIDYFLOW_V1_TEST") {
                                    found = true;
                                    break;
                                }
                            }
                        }
                    }
                }
                _ => break,
            }
        }
        assert!(found, "Did not receive expected output");
        println!("  ✓ Terminal I/O working");
    }

    // Test 8: Kill Terminal
    println!("[Test 8] Kill Terminal...");
    {
        let (mut write, mut read) = connect_to_server().await.expect("Failed to connect");
        let hello = recv_json_skip_output(&mut read, "hello").await.expect("No hello");
        let session_id = hello["session_id"].as_str().unwrap().to_string();

        write.send(Message::Text(json!({"type": "kill_terminal"}).to_string())).await.unwrap();
        let msg = recv_json_skip_output(&mut read, "terminal_killed").await.expect("No terminal_killed response");

        assert_eq!(msg["type"], "terminal_killed");
        assert_eq!(msg["session_id"], session_id);
        println!("  ✓ Terminal killed: {}", &session_id[..8]);
    }

    println!("\n=== All Protocol v1 Tests Passed! ===\n");
}
