# CLAUDE.md / AGENTS.md

> `CLAUDE.md` 是 `AGENTS.md` 的符号链接，需保持同步。

## 基本约束

1. 全程使用中文交流、代码注释与文档。
2. 经验总结只记录“跨任务可复用且可执行”的规则；一次性修复不记录。

## 项目现状（简版）

- 形态：macOS 原生应用（SwiftUI + AppKit）+ Rust Core 的混合架构。
- 终端：`WKWebView` 承载 `xterm.js`。
- 通信：WebSocket（MessagePack，协议 v2）+ HTTP（pairing JSON）。
- 核心目录：
  - `app/`：macOS 前端。
  - `core/`：Rust 引擎（`ai/`、`server/`、`pty/`、`workspace/` 等）。
  - `scripts/`：构建、发布、升级脚本（含 `run-app.sh`、`build_dmg.sh`、`notarize.sh`、`release_local.sh`、`upgrade.sh`）。

## 常用命令

```bash
# 本地联调（推荐）
./scripts/run-app.sh

# Core
cd core
cargo run
cargo test --manifest-path core/Cargo.toml

# App
xcodebuild -project app/TidyFlow.xcodeproj -scheme TidyFlow -configuration Debug build

# 发布链路
./scripts/build_dmg.sh
./scripts/notarize.sh --profile tidyflow-notary
./scripts/release_local.sh --dry-run
```

发布前必须执行：`docs/RELEASE_CHECKLIST.md`。

## 经验总结：记录规则

- 新增经验前需同时满足“可复用”与“可执行”，并包含：触发条件、必做动作、忽略风险。
- 仅在以下至少一项满足时新增：30 天内重复 >= 2 次；影响 >= 2 个模块；影响发布/稳定性/一致性。
- 默认不新增；拿不准复用价值时不记录。

## 当前保留的高复用规则

- 发布版本时同步递增 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`core/Cargo.toml`，并按清单发布。
- 升级/重启链路必须以“端口已释放”为再次启动前提，超时需中止并输出占用 PID。
- 同一业务状态的多写入口必须收敛到统一写路径（或补兜底写入），防止状态分叉。
- 对外列表返回必须显式排序，禁止依赖 `HashMap` 迭代顺序。
- 解析 AI/CLI 结构化输出要兼容 `stdout/stderr` 混合，先取外层包络再解业务 JSON。
- 拆分 Swift 文件时，必须同步更新 `app/TidyFlow.xcodeproj/project.pbxproj` 的引用与编译项。
- 拆分 Rust 大 handler 先做“零行为变化”重构：入口签名不变，按能力域拆分并由 `mod.rs` 分发。
- 网络默认仅监听 loopback；开放局域网访问必须显式开关 + 配对鉴权，`pair/start` 与 `pair/revoke` 仅允许本机调用。
- 地址/端口展示必须取 Core `running` 态运行时值，禁止硬编码或读取 `starting` 态端口。
- 涉及 Core 重启的设置变更必须先 `stop` 完成再 `start`，并校验回调仍属于当前进程实例。
- WebSocket 重连链路要保证 `connect` 幂等，所有回调需校验“仍是当前 task”。
- MessagePack + AnyCodable 需显式支持 `Data(bin)`；编码 `[UInt8]` 优先转 `Data`。
- 启动链路禁止主线程同步 `waitUntilExit`；优先查看 `~/.tidyflow/logs/*-dev.log`，必要时显式设置 `RUST_LOG`。
- AI 聊天状态按 `project/workspace/ai_tool` 分桶存储与过滤，禁止跨桶混用。
- 流式聊天状态必须绑定 `message_id`；`done` 仅收敛对应气泡，`message.updated` 与 `part.*` 需先建角色映射再增量处理。
- Markdown 聊天渲染采用“流式纯文本 + 完成后一次性 Markdown 化”。
- `handle_client_message` 内不得同步阻塞长生命周期流任务；应转后台 task 并保证控制消息（如 abort）可及时处理。
