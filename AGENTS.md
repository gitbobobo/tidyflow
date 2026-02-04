# AGENTS.md

1. 使用中文交流、编写代码注释、文档
2. 经验总结：获取到经验教训后，如果它属于可复用的项目开发流程，就用简洁的语言记录到 AGENTS.md 中

## Project Overview

TidyFlow is a macOS-native multi-project development tool with VS Code-level terminal experience and Git worktree-based workspace isolation.

**Architecture**: Hybrid native + web
- **Frontend**: SwiftUI + AppKit (macOS app in `/app/`)
- **Backend**: Rust core engine (in `/core/`)
- **Terminal**: xterm.js in WKWebView
- **Communication**: JSON-RPC 2.0 over WebSocket (default port 47999)

## 经验总结

## Build Commands

### Quick Start (Recommended)
```bash
./scripts/run-app.sh  # Builds core + app, launches TidyFlow
```

### Rust Core
```bash
cd core
cargo build --release
cargo run                          # Start WebSocket server
TIDYFLOW_PORT=8080 cargo run       # Custom port
cargo test                         # Run tests
```

### macOS App
```bash
# Via Xcode (recommended for development)
open app/TidyFlow.xcodeproj        # Then Cmd+R to run

# Via command line
xcodebuild -project app/TidyFlow.xcodeproj -scheme TidyFlow -configuration Debug build
```

### Release Build
```bash
./scripts/release/build_dmg.sh                    # Unsigned DMG
SIGN_IDENTITY="Developer ID..." ./scripts/release/build_dmg.sh --sign  # Signed
./scripts/release/notarize.sh --profile tidyflow-notary  # Notarize
```

## Testing

```bash
./scripts/smoke-test.sh            # Basic functionality
./scripts/verify_protocol.sh       # WebSocket protocol
./scripts/workspace-demo.sh        # End-to-end workspace
./scripts/git-tools-smoke.sh       # Git operations
```

Manual verification checklists are in `scripts/*-check.md`.

## Architecture

```
┌─────────────────────────────────────┐
│   macOS App (SwiftUI + AppKit)     │
│   ┌─────────────────────────────┐   │
│   │  WKWebView (xterm.js)       │   │
│   └──────────┬──────────────────┘   │
└──────────────┼──────────────────────┘
               │ WebSocket (JSON-RPC)
               ▼
┌─────────────────────────────────────┐
│   Rust Core Engine                  │
│   ├─ PTY Manager (portable-pty)    │
│   ├─ Workspace Engine (git worktree)│
│   ├─ WebSocket Server (axum)       │
│   └─ State Persistence (SQLite)    │
└─────────────────────────────────────┘
```

### Rust Core (`/core/src/`)
- `main.rs` - CLI entry point (clap)
- `pty/` - PTY session management
- `server/` - WebSocket server, protocol, file API, git tools
- `workspace/` - Project/workspace management, config, state persistence

### macOS App (`/app/TidyFlow/`)
- `TidyFlowApp.swift` - App entry point
- `ContentView.swift` - Main view composition
- `Views/` - SwiftUI views (sidebar, toolbar, tabs, git panel, command palette)
- `WebView/` - WKWebView container and Swift-JS bridge
- `Networking/` - WebSocket client and protocol models
- `Web/` - HTML/JS for xterm.js integration

### Design Documentation (`/design/`)
50+ design docs covering architecture, protocols, and feature specs. Reference these when implementing new features.

## Key Patterns

- **Workspace isolation**: Each workspace is a separate git worktree
- **Protocol versioning**: v0 (basic terminal) + v1 (workspace management)
- **State persistence**: `~/.tidyflow/state.json`
- **Per-project config**: `.tidyflow.toml` for setup scripts

## CLI Commands

```bash
cargo run -- import --name my-project --path /path/to/repo
cargo run -- ws create --project my-project --workspace feature-1
cargo run -- list projects
cargo run -- list workspaces --project my-project
```

## Keyboard Shortcuts (App)

- `Cmd+Shift+P` - Command Palette
- `Cmd+P` - Quick Open File
- `Cmd+1/2/3` - Switch right panel (Explorer/Search/Git)
- `Cmd+T` - New terminal tab
- `Cmd+W` - Close tab
