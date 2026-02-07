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
- 使用 Cursor Agent 执行自动提交时，建议固定携带 `--sandbox disabled -f`（配合 `-p`），避免沙箱/审批导致 git 命令被拒绝。
- 解析 AI CLI 的结构化 JSON 输出时，应兼容 `stdout` 与 `stderr` 混合场景：优先抽取外层 JSON 包络字段（如 `response`/`result`），再解析业务 JSON，避免日志噪音导致解析失败。
- 拆分 Swift 大文件时，除移动源码外还必须同步更新 `app/TidyFlow.xcodeproj/project.pbxproj` 的 `PBXFileReference`、`PBXBuildFile`、`PBXGroup` 和 `PBXSourcesBuildPhase`，否则新文件不会参与编译。
- 拆分 Rust 超长 handler 时，优先保持对外入口函数签名不变，在目录模块内按能力域拆 `try_handle` 子模块并由 `mod.rs` 串行分发，先做“零行为变化”重构再谈逻辑优化。
- OpenCode 的 `--format json` 输出是事件流，最终结果应从最后一个 `type=text` 事件的 `part.text` 提取，而不是取最后一条事件（通常是 `step_finish`）。
- Git 面板展示分支领先/落后时，应复用 `git_status` 返回并基于项目 `default_branch` 做本地分支比较，避免硬编码 `main` 或依赖远端 `fetch` 导致慢/不稳定。
- 多项目共存时，工作空间名（如 `"default"`）不具备全局唯一性；需要关联项目的场景必须显式传递 `projectName`，禁止通过遍历 `projects` 按工作空间名反查项目（会命中第一个匹配项而非实际所属项目）。

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
  - `Models/` - 核心模型与 `AppState` 拆分目录（按领域与扩展分文件维护）
  - `Models.swift` - 兼容占位文件（避免一次性迁移冲击）
  - `KeybindingHandler.swift` - 键盘快捷键处理
- `WebView/` - WKWebView container and Swift-JS bridge
- `Networking/` - WebSocket client (MessagePacker 库), protocol models, AnyCodable
- `Web/` - HTML/JS for xterm.js terminal, CodeMirror diff view
- `Process/` - 进程管理
- `en.lproj/`, `zh-Hans.lproj/` - 本地化字符串文件

## Key Patterns

- **Workspace isolation**: Each workspace is a separate git worktree
- **Protocol versioning**: v2 (MessagePack binary, `rmp-serde`) with feature versions v1.0-v1.25
- **State persistence**: `~/.tidyflow/state.json`（JSON 格式，非 SQLite）
- **Per-project config**: `.tidyflow.toml` for setup scripts
- **WebSocket 消息流**: Client 发送 MessagePack 编码的 `ClientMessage` → Server 通过 `handlers/` 模块化处理 → 返回 `ServerMessage`
- **父进程监控**: Core 监控 Swift app 进程，父进程退出时自动终止
- **本地化**: 运行时语言切换，使用 `"key".localized` 扩展，字符串文件在 `en.lproj/` 和 `zh-Hans.lproj/`

## CLI Commands

```bash
cargo run -- import --name my-project --path /path/to/repo
cargo run -- ws create --project my-project --workspace feature-1
cargo run -- list projects
cargo run -- list workspaces --project my-project
```
