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
- **Communication**: WebSocket(MessagePack) + HTTP(JSON, pairing endpoints) (protocol v2, default port 47999)

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
- 跨分支入口触发但实际写入默认分支的操作（如 AI 合并到默认分支），其后台阻塞任务归属应绑定默认工作空间，避免错误地落在来源分支队列。
- 引入移动端远程访问时，Core 应默认仅监听 loopback，并通过显式开关切换到 `0.0.0.0`；远程连接统一走“本机生成配对码 -> 移动端换取短期 token”链路，且 `pair/start`/`pair/revoke` 保持仅本机可调用。
- 编辑 `app/TidyFlow.xcodeproj/project.pbxproj` 时，带条件的 build setting 键（如 `[sdk=iphone*]`）必须写成带引号的完整键名（如 `"INFOPLIST_FILE[sdk=iphone*]"`），否则工程会因 plist 解析失败而无法打开。
- 移动端连接入口展示的地址/端口必须来自运行时状态（局域网 IP + Core 当前监听端口），不要假设固定端口（如 47999），避免重启后动态端口变化导致连接失败。
- 移动端展示/配对使用的端口必须取 Core `running` 态端口；不要使用 `starting` 态端口（尚未监听），并确保 `AppState` 转发 `CoreProcessManager` 变更以避免 UI 端口文案滞后。
- 涉及 Core 重启（如切换远程访问开关）时，不要用固定延时后直接 `start()`；应等待 `stop` 确认完成后再启动，否则会被运行态守卫拦截并出现“端口不可用”卡死。
- `CoreProcessManager` 的异步回调（`stop` 完成、`terminationHandler`、延迟置 `running`）必须校验“是否仍是当前 process 实例”；否则旧进程回调会覆盖新状态，导致 UI 误判为“端口不可用”。
- 对“监听地址/网络暴露”这类 socket 绑定配置，若产品要求不中断进行中任务，应采用“仅落盘配置、下次启动生效”策略，不在设置页切换时重启 Core。
- 使用 MessagePack + AnyCodable 解析协议时，动态值模型必须显式支持 `Data`（bin）；否则终端输出/scrollback 等二进制字段会解码失败并表现为黑屏或无输出。
- 使用 AnyCodable 编码请求体时，`[UInt8]` 必须优先转为 `Data`（MessagePack bin）或显式映射为整数；否则会被默认分支转成字符串数组，导致 `input`/`file_write` 等二进制字段在 Core 端解析失败。
- 排查启动卡顿/卡死时先确认日志归属：Debug 构建主要看 `~/.tidyflow/logs/*-dev.log` / `*.dev.log`，应用包运行主要看 `~/.tidyflow/logs/YYYY-MM-DD.log`，避免错看时间段。
- 应用启动链路（首屏前）禁止在主线程同步执行外部命令并 `waitUntilExit`；此类探测应放后台并加超时兜底，否则会出现 Dock 图标持续跳动但窗口不出现。
- 排查开发环境问题时应优先查看 `~/.tidyflow/logs/*-dev.log`（或 `*.dev.log`）；仅排查打包产物/生产行为时再看纯日期日志。
- 启动期若要延迟展示主窗口，隐藏动作应放在 `AppDelegate.applicationDidFinishLaunching`（窗口首帧前）而非 `ContentView.onAppear`，否则会出现窗口闪一下。
- iOS 侧若在 `List` 等容器内使用 SwiftUI `Menu` 触发 UIKit “`_UIReparentingView` 加到 `UIHostingController.view`”告警/层级异常，可优先尝试给 `Menu`（或其 label）加 `.compositingGroup()`；若仍存在再考虑将入口移到 `toolbar` 的 `Menu`（避免在 `List` cell 内弹出）。
- iOS 终端若改为原生输入代理，不能同时关闭 xterm stdin 作为唯一输入路径；至少保留 xterm `onData` 兜底，并确保触摸手势可触发 `term.focus()`，否则会出现“无法输入/键盘不弹出”。
- 远程终端订阅归属必须使用稳定设备标识（如配对 `token_id`），不要绑定瞬时 `conn_id`；移动端进程被系统回收后重连应可继续看到并附着原会话。
- iOS 虚拟键盘输入链路应采用 `onData` 主路径 + `textarea input/composition` 兜底；仅依赖 `onData` 会在部分键盘布局下丢失空格或特殊符号。
- iOS 终端工具栏提供 `Ctrl` 时，不能只在工具栏按键内做组合映射；必须把 `Ctrl` 锁定态接入 `onData` 主输入链路，并在消费后同步回写工具栏状态，确保 `Ctrl+C` 等“Ctrl + 虚拟键盘字符”可用。
- iOS 终端从 `WKWebView + xterm.js` 迁移到 `SwiftTerm` 时，应以 `TerminalViewDelegate.send` 作为统一输入路径，并通过 `TerminalView.inputAccessoryView` 挂接原生工具栏，避免继续依赖 `WKContentView` 的 runtime 替换。
- iOS 多终端切换时，客户端必须按 `term_id` 隔离本地渲染状态；切换前先重置/清空 `TerminalView`（含 scrollback），避免 SwiftUI 复用视图导致不同终端输出“串台”。
- iOS SwiftTerm 远程终端场景下，zle 出现 `3R` 乱码的根因是 SwiftTerm 使用 8-bit C1 引导符（`0x9b`）而 shell 不识别，并非网络延迟；正确做法是在 `TerminalViewDelegate.send` 中做 C1→7-bit 规范化（`0x9b`→`ESC[`），而非丢弃 CPR 应答——丢弃会导致依赖 DSR/CPR 的 TUI 应用（helix、lazygit 等）无法获取光标位置而报错。

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
