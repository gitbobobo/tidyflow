# TidyFlow App

SwiftUI + SwiftTerm 原生终端应用，通过 WebSocket 连接 TidyFlow Rust core。

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
│  │      SwiftUI Native Views       │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │        SwiftTerm PTY        │  │  │
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
| `ContentView.swift` | 主容器视图 |
| `Views/TabContentHostView.swift` | Tab 内容分发（编辑器/终端/AI） |
| `Views/MacSwiftTermTerminalView.swift` | macOS 原生终端视图 |
| `TidyFlow-iOS/Views/SwiftTermTerminalView.swift` | iOS 原生终端视图 |
| `Info.plist` | ATS configuration for localhost |
| `TidyFlow.entitlements` | Network permissions |

## Configuration

Set `TIDYFLOW_PORT` environment variable to change the WebSocket port (default: 47999).

## Protocol

使用 WebSocket + MessagePack（Protocol v9 包络，结构沿用 v6），协议说明见 `../docs/PROTOCOL.md`。
