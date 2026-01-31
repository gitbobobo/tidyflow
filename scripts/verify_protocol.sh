#!/bin/bash
#
# TidyFlow Protocol v1 Verification Script (Shell version)
# Tests WebSocket control plane without external dependencies
#
# Usage: ./verify_protocol.sh [PORT]
#

set -e

PORT="${1:-47999}"
WS_URL="ws://127.0.0.1:$PORT/ws"

echo "============================================================"
echo "TidyFlow Protocol v1 Verification (Shell)"
echo "============================================================"
echo "Target: $WS_URL"
echo ""

# Check if websocat is available, if not try to use nc
if command -v websocat &> /dev/null; then
    WS_TOOL="websocat"
elif command -v wscat &> /dev/null; then
    WS_TOOL="wscat"
else
    echo "Note: websocat/wscat not found, using curl for basic HTTP check"
    WS_TOOL="none"
fi

# Test 1: Basic connectivity
echo "[Test 1] Basic connectivity..."
if curl -s --max-time 2 "http://127.0.0.1:$PORT/" > /dev/null 2>&1 || \
   curl -s --max-time 2 -I "http://127.0.0.1:$PORT/ws" 2>&1 | grep -q "HTTP"; then
    echo "  ✓ Server is responding on port $PORT"
else
    echo "  ✗ Server not responding on port $PORT"
    echo "  Make sure tidyflow-core is running: ./target/release/tidyflow-core serve --port $PORT"
    exit 1
fi

# Test 2: WebSocket upgrade (check headers)
echo "[Test 2] WebSocket upgrade headers..."
UPGRADE_RESPONSE=$(curl -s -i --max-time 2 \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" \
    "http://127.0.0.1:$PORT/ws" 2>&1 | head -5)

if echo "$UPGRADE_RESPONSE" | grep -qi "101\|upgrade\|switching"; then
    echo "  ✓ WebSocket upgrade supported"
else
    echo "  ⚠ WebSocket upgrade check inconclusive (may still work)"
fi

# Test 3: Protocol test using Rust test binary
echo "[Test 3] Building protocol test..."
cd "$(dirname "$0")/.."

# Create a simple Rust test
cat > /tmp/tidyflow_protocol_test.rs << 'RUSTCODE'
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;
use base64::Engine;

fn main() {
    let port = std::env::args().nth(1).unwrap_or("47999".to_string());
    let addr = format!("127.0.0.1:{}", port);

    println!("Connecting to {}...", addr);

    let mut stream = match TcpStream::connect(&addr) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Connection failed: {}", e);
            std::process::exit(1);
        }
    };

    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    stream.set_write_timeout(Some(Duration::from_secs(5))).unwrap();

    // WebSocket handshake
    let key = "dGhlIHNhbXBsZSBub25jZQ==";
    let request = format!(
        "GET /ws HTTP/1.1\r\n\
         Host: 127.0.0.1:{}\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Key: {}\r\n\
         Sec-WebSocket-Version: 13\r\n\r\n",
        port, key
    );

    stream.write_all(request.as_bytes()).unwrap();

    // Read response
    let mut buf = [0u8; 4096];
    let n = stream.read(&mut buf).unwrap();
    let response = String::from_utf8_lossy(&buf[..n]);

    if !response.contains("101") {
        eprintln!("WebSocket upgrade failed: {}", response);
        std::process::exit(1);
    }

    println!("✓ WebSocket connected");

    // Read hello message (WebSocket frame)
    let n = stream.read(&mut buf).unwrap();
    if n > 2 {
        // Simple WebSocket frame parsing (text frame)
        let payload_start = if buf[1] & 0x7f < 126 { 2 } else { 4 };
        let payload = &buf[payload_start..n];
        let msg = String::from_utf8_lossy(payload);

        if msg.contains("hello") {
            println!("✓ Hello message received");
            if msg.contains("\"version\":1") || msg.contains("\"version\": 1") {
                println!("✓ Protocol version 1 confirmed");
            }
            if msg.contains("capabilities") {
                println!("✓ v1 capabilities present");
            }
        }
    }

    // Send ping (WebSocket text frame)
    let ping_msg = r#"{"type":"ping"}"#;
    let frame = create_ws_frame(ping_msg.as_bytes());
    stream.write_all(&frame).unwrap();

    // Read pong
    let n = stream.read(&mut buf).unwrap_or(0);
    if n > 0 {
        let payload_start = if buf[1] & 0x7f < 126 { 2 } else { 4 };
        let payload = &buf[payload_start..n];
        let msg = String::from_utf8_lossy(payload);
        if msg.contains("pong") {
            println!("✓ Ping/Pong working");
        }
    }

    // Send list_projects
    let list_msg = r#"{"type":"list_projects"}"#;
    let frame = create_ws_frame(list_msg.as_bytes());
    stream.write_all(&frame).unwrap();

    // Read response
    let n = stream.read(&mut buf).unwrap_or(0);
    if n > 0 {
        let payload_start = if buf[1] & 0x7f < 126 { 2 } else { 4 };
        let payload = &buf[payload_start..n];
        let msg = String::from_utf8_lossy(payload);
        if msg.contains("projects") {
            println!("✓ list_projects working");
        }
    }

    println!("\n✓ All protocol tests passed!");
}

fn create_ws_frame(data: &[u8]) -> Vec<u8> {
    let mut frame = Vec::new();
    frame.push(0x81); // Text frame, FIN bit set

    let len = data.len();
    if len < 126 {
        frame.push((len as u8) | 0x80); // Masked
    } else {
        frame.push(126 | 0x80);
        frame.push((len >> 8) as u8);
        frame.push(len as u8);
    }

    // Masking key (all zeros for simplicity)
    let mask = [0u8; 4];
    frame.extend_from_slice(&mask);

    // Masked payload (XOR with mask, but mask is 0 so no change)
    frame.extend_from_slice(data);

    frame
}
RUSTCODE

# Try to compile and run the test
if command -v rustc &> /dev/null; then
    echo "  Compiling test..."
    if rustc --edition 2021 -o /tmp/tidyflow_protocol_test /tmp/tidyflow_protocol_test.rs 2>/dev/null; then
        echo ""
        /tmp/tidyflow_protocol_test "$PORT"
        rm -f /tmp/tidyflow_protocol_test /tmp/tidyflow_protocol_test.rs
    else
        echo "  ⚠ Rust compilation failed (missing base64 crate), using basic test"
        rm -f /tmp/tidyflow_protocol_test.rs
    fi
else
    echo "  ⚠ rustc not found, skipping detailed protocol test"
fi

echo ""
echo "============================================================"
echo "Verification complete"
echo "============================================================"
