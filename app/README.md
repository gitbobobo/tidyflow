# TidyFlow macOS App

SwiftUI + WKWebView terminal application that connects to the TidyFlow Rust core via WebSocket.

## Quick Start

```bash
# Option 1: Run via script (starts core automatically)
./scripts/run-app.sh

# Option 2: Manual
# Terminal 1: Start core
cd core && cargo run

# Terminal 2: Open in Xcode
open app/TidyFlow.xcodeproj
# Then press Cmd+R to run
```

## Architecture

```
┌─────────────────────────────────────────┐
│           TidyFlow.app (Swift)          │
│  ┌───────────────────────────────────┐  │
│  │         WKWebView                 │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │   xterm.js + WebGL addon    │  │  │
│  │  └─────────────────────────────┘  │  │
│  │              │                    │  │
│  │         WebSocket                 │  │
│  └──────────────│────────────────────┘  │
└─────────────────│───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│     Rust Core (ws://127.0.0.1:47999)    │
│              PTY + Shell                │
└─────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `TidyFlowApp.swift` | App entry point |
| `ContentView.swift` | Main view with WKWebView |
| `Web/index.html` | Terminal HTML container |
| `Web/main/*.js` | WebSocket 协议处理、终端 UI、Tab/项目状态管理 |
| `Web/vendor/` | xterm.js and addons |
| `Info.plist` | ATS configuration for localhost |
| `TidyFlow.entitlements` | Network permissions |

## Configuration

Set `TIDYFLOW_PORT` environment variable to change the WebSocket port (default: 47999).

## Protocol

使用 WebSocket + MessagePack（Protocol v2），协议说明见 `../docs/PROTOCOL.md`。
