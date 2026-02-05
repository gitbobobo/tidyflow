# AGENTS.md

1. 使用中文交流、编写代码注释、文档
2. 经验总结：获取到经验教训后，如果它属于可复用的项目开发流程，就用简洁的语言记录到 AGENTS.md 中

## Project Overview

TidyFlow is a macOS-native multi-project development tool with VS Code-level terminal experience and Git worktree-based workspace isolation.

**Architecture**: Hybrid native + web
- **Frontend**: SwiftUI + AppKit (macOS app in `/app/`)
- **Backend**: Rust core engine (in `/core/`)
- **Terminal**: xterm.js in WKWebView
- **Communication**: WebSocket with MessagePack binary encoding (protocol v2, default port 47999)

## 经验总结
- 多终端场景下，为避免 WebGL 上下文占用过多，建议仅在激活终端启用 WebGL，切换时及时释放。
- 文件缓存策略应采用增量更新，避免全量刷新导致界面闪烁。
- 终端输出需处理 ANSI 转义序列和 UTF-8 字符在缓冲区边界截断的问题，防止花屏。

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
               │ WebSocket (MessagePack)
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
- `server/` - WebSocket server, protocol (v2 MessagePack), file API, git tools, file watcher
- `workspace/` - Project/workspace management, config, state persistence
- `util/` - 日志等通用工具

### macOS App (`/app/TidyFlow/`)
- `TidyFlowApp.swift` - App entry point
- `ContentView.swift` - Main view composition
- `Views/` - SwiftUI views (sidebar, toolbar, tabs, git panel, command palette, settings)
- `WebView/` - WKWebView container and Swift-JS bridge
- `Networking/` - WebSocket client, protocol models (MessagePack), AnyCodable
- `Web/` - HTML/JS for xterm.js integration, Diff view (CodeMirror)
- `Process/` - 进程管理

### Design Documentation (`/design/`)
50+ design docs covering architecture, protocols, and feature specs. Reference these when implementing new features.

## Key Patterns

- **Workspace isolation**: Each workspace is a separate git worktree
- **Protocol versioning**: v2 (MessagePack binary) with feature versions v1.0-v1.22
- **State persistence**: `~/.tidyflow/state.json`
- **Per-project config**: `.tidyflow.toml` for setup scripts

## Protocol Features (v1.x)

主要功能模块：
- v1.0-v1.2: 工作空间管理、多终端支持
- v1.3-v1.4: 文件操作、Quick Open 索引
- v1.5-v1.10: Git 基础操作（status, diff, stage, commit, branch）
- v1.11-v1.15: Git 高级操作（rebase, fetch, merge, integration worktree）
- v1.16-v1.18: 项目/工作空间导入导出
- v1.19-v1.20: Git log 和 commit 详情
- v1.21: 客户端设置同步
- v1.22: 文件监控

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
