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
| `Web/main.js` | WebSocket + xterm.js integration |
| `Web/vendor/` | xterm.js and addons |
| `Info.plist` | ATS configuration for localhost |
| `TidyFlow.entitlements` | Network permissions |

## Configuration

Set `TIDYFLOW_PORT` environment variable to change the WebSocket port (default: 47999).

## Protocol

Uses WebSocket Protocol v0 as defined in `design/09-m0-contracts.md`:
- `hello`, `output`, `exit`, `pong` (server → client)
- `input`, `resize`, `ping` (client → server)
