# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> CLAUDE.md 是 AGENTS.md 的符号链接，始终保持同步。

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
- 用户要发布新版本时，严格按 `docs/RELEASE_CHECKLIST.md` 执行；版本号递增（如 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`core/Cargo.toml`）由代理自动处理并同步。
- 同一业务状态若在多个入口写入（如终端创建时间），应抽取统一路径或至少补齐兜底写入，避免分支遗漏导致 UI 状态不一致。
- 对外返回列表数据时，不要依赖 `HashMap` 迭代顺序；应在服务端显式排序，确保启动与刷新顺序稳定可预期。
- 在 git worktree 场景调用 Codex CLI 执行提交时，若需要写 `.git/worktrees/*` 元数据（如 `index.lock`），应使用 `--dangerously-bypass-approvals-and-sandbox`，避免 `workspace-write` 沙箱拦截。
- 同一 AI 代理在不同业务入口（如 AI 提交/AI 合并）应复用完全一致的 CLI 参数模板；业务差异仅通过 prompt 表达，避免入口分叉导致行为不一致。

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
cargo test                         # Run all tests
cargo test test_name               # Run specific test by name
cargo test git::status::           # Run tests in a module
RUST_LOG=debug cargo test          # Run with debug logging
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
./scripts/build_dmg.sh                    # Unsigned DMG
SIGN_IDENTITY="Developer ID..." ./scripts/build_dmg.sh --sign  # Signed
./scripts/notarize.sh --profile tidyflow-notary  # Notarize
./scripts/tools/gen_sha256.sh dist/<dmg-name>.dmg # Generate SHA256 (optional if using build_dmg.sh)
./scripts/release_local.sh --upload-release # Local one-click release and upload assets to GitHub Release
./scripts/release_local.sh --dry-run # Preview all release actions without side effects
```

## Testing

```bash
cargo test --manifest-path core/Cargo.toml    # Core 自动化测试
./scripts/run-app.sh                            # 本地启动 App 做手工验证
./scripts/build_dmg.sh --sign                   # 发布构建（需签名证书）
./scripts/notarize.sh --profile tidyflow-notary # 发布公证
```

发布手工检查清单见 `docs/RELEASE_CHECKLIST.md`。

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
│   └─ State Persistence (JSON)      │
└─────────────────────────────────────┘
```

### Rust Core (`/core/src/`)
- `main.rs` - CLI entry point (clap)
- `pty/` - PTY session management
- `server/` - WebSocket server and协议处理
  - `ws.rs` - WebSocket handler，tokio select! 循环处理消息/PTY输出/文件监控事件
  - `protocol.rs` - Protocol v2 (MessagePack) 消息定义
  - `handlers/` - 模块化消息处理器（terminal, file, git, project, settings），每个返回 `Result<bool, String>`
  - `git/` - Git 操作模块（status, operations, branches, commit, integration, utils）
  - `file_api.rs` - 文件操作，`file_index.rs` - Quick Open 索引，`watcher.rs` - 文件监控
- `workspace/` - Project/workspace management, config, state persistence
- `util/` - 日志等通用工具

### macOS App (`/app/TidyFlow/`)
- `TidyFlowApp.swift` - App entry point
- `ContentView.swift` - Main view composition
- `LocalizationManager.swift` - 运行时语言切换（system/en/zh-Hans），使用 `"key".localized` 模式
- `Views/` - SwiftUI views (sidebar, toolbar, tabs, git panel, command palette, settings)
  - `Models.swift` - 核心数据模型（最大文件，修改需谨慎）
  - `KeybindingHandler.swift` - 键盘快捷键处理
- `WebView/` - WKWebView container and Swift-JS bridge
- `Networking/` - WebSocket client (MessagePacker 库), protocol models, AnyCodable
- `Web/` - HTML/JS for xterm.js terminal, CodeMirror diff view
- `Process/` - 进程管理
- `en.lproj/`, `zh-Hans.lproj/` - 本地化字符串文件

### Design Documentation (`/design/`)
目前仅存放图标资源；协议和发布文档在 `docs/` 目录。

## Key Patterns

- **Workspace isolation**: Each workspace is a separate git worktree
- **Protocol versioning**: v2 (MessagePack binary, `rmp-serde`) with feature versions v1.0-v1.25
- **State persistence**: `~/.tidyflow/state.json`（JSON 格式，非 SQLite）
- **Per-project config**: `.tidyflow.toml` for setup scripts
- **WebSocket 消息流**: Client 发送 MessagePack 编码的 `ClientMessage` → Server 通过 `handlers/` 模块化处理 → 返回 `ServerMessage`
- **父进程监控**: Core 监控 Swift app 进程，父进程退出时自动终止
- **本地化**: 运行时语言切换，使用 `"key".localized` 扩展，字符串文件在 `en.lproj/` 和 `zh-Hans.lproj/`

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
- v1.23: 文件重命名/删除（macOS Trash）
- v1.24: 文件复制（跨项目绝对路径）
- v1.25: 文件移动（拖拽）

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
- `Cmd+Option+T` - Close other tabs
- `Ctrl+Tab` / `Ctrl+Shift+Tab` - Next/Previous tab
- `Ctrl+1-9` - Switch to tab by index
- `Cmd+1-9` - Switch to workspace by shortcut key (user-configurable)
