# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> CLAUDE.md 是 AGENTS.md 的符号链接，始终保持同步。

1. 使用中文交流、编写代码注释、文档
2. 经验总结：仅记录“跨任务可复用且可执行”的工程规则；一次性修复细节不记录，新增前必须满足下文“记录规则”

## Project Overview

TidyFlow is a macOS-native multi-project development tool with VS Code-level terminal experience and Git worktree-based workspace isolation.

**Architecture**: Hybrid native + web
- **Frontend**: SwiftUI + AppKit (macOS app in `/app/`)
- **Backend**: Rust core engine (in `/core/`)
- **Terminal**: xterm.js in WKWebView
- **Communication**: WebSocket(MessagePack) + HTTP(JSON, pairing endpoints) (protocol v2, default port 47999)

## 经验总结

### 记录规则（新增经验前必须满足）
- 只记录“跨任务可复用”的工程规则，不记录一次性修复细节。
- 每条必须同时包含：触发条件、必做动作、忽略后的风险。
- 仅在满足以下任一条件时新增：30 天内重复出现 >= 2 次；影响 >= 2 个模块；影响发布/稳定性/数据一致性。
- 单条不超过 2 句，优先抽象原则，避免写死临时参数、日志现象或供应商偶发行为。
- 默认不新增；若无法明确复用价值，宁可不记。

### 不再记录的内容
- 单次故障的时间线复盘或临时排障命令。
- UI 像素级微调、特定页面布局细节、一次性交互文案结论。
- 强依赖某个外部服务瞬时行为的字段级兼容细节（除非已上升为稳定协议约束）。

### 保留的高复用经验
- 发布新版本时严格按 `docs/RELEASE_CHECKLIST.md` 执行，版本号（`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`core/Cargo.toml`）必须同步递增。
- 升级/重启链路中，“端口已释放”是再次启动的硬条件；超时必须中止并输出占用 PID。
- 同一业务状态若有多个写入口，必须抽取统一写路径或补齐兜底写入，避免状态分叉。
- 对外返回列表不可依赖 `HashMap` 迭代顺序，服务端必须显式排序。
- 解析 AI/CLI 结构化输出时需兼容 `stdout`/`stderr` 混合，先取外层包络字段再解析业务 JSON。
- 拆分 Swift 文件时，除移动源码外必须同步更新 `app/TidyFlow.xcodeproj/project.pbxproj`（`PBXFileReference`/`PBXBuildFile`/`PBXGroup`/`PBXSourcesBuildPhase`）。
- 拆分 Rust 大型 handler 时先做“零行为变化”重构：保持入口签名不变，按能力域拆子模块并由 `mod.rs` 分发。
- 网络暴露默认仅监听 loopback；开放局域网访问必须走显式开关与配对鉴权，`pair/start`、`pair/revoke` 仅允许本机调用。
- 连接地址/端口展示必须来自 Core `running` 态的运行时值，不可硬编码固定端口，也不能使用 `starting` 态端口。
- 涉及 Core 重启的设置变更要先确认 `stop` 完成再 `start`；异步回调（stop 完成、terminationHandler、延迟状态）必须校验“仍是当前进程实例”。
- WebSocket 重连链路必须保证 `connect` 幂等；`receive/didOpen/didClose/didComplete` 回调需校验“仍是当前 task”，防止旧连接回调污染新状态。
- MessagePack + AnyCodable 需要显式支持 `Data`（bin）；编码 `[UInt8]` 时优先转 `Data`，避免二进制字段被错误编码。
- 启动链路禁止主线程同步执行外部命令并 `waitUntilExit`；排障先看 `~/.tidyflow/logs/*-dev.log`，需要细粒度日志时显式设置 `RUST_LOG`。
- AI 聊天跨项目/工作空间/工具（如 OpenCode、Codex）必须按 `project/workspace/ai_tool` 分桶存储与过滤，禁止混用状态。
- 流式聊天状态必须绑定 `message_id`：`done` 只能收敛到对应气泡；同批次有 `message.updated` 与 `part.*` 时先建角色映射再处理增量。
- 聊天 Markdown 渲染采用“流式纯文本 + 完成后一次性 Markdown 化”，避免增量阶段频繁重排。
- `handle_client_message` 内不得同步阻塞长生命周期流任务；应转后台 task，并保持同连接控制消息（如 abort）可及时处理。

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
TIDYFLOW_BIND_ADDR=0.0.0.0 cargo run # Expose WS/Pairing service to LAN
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
  - `protocol/mod.rs` - Protocol v2 (MessagePack) 消息定义
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
