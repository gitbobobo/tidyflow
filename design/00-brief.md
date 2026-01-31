# TidyFlow - 产品简报 (Product Brief)

> 版本: 1.0 (Frozen)
> 最后更新: 2026-01-31

## 产品目标

TidyFlow 是一款面向专业开发者的 macOS 原生多项目开发工具，核心价值主张：

1. **多项目并行开发** - 同时管理多个独立项目，每个项目可拥有多个并行 workspace
2. **Git Worktree 原生支持** - 基于 worktree 实现真正的分支隔离，无需 stash/切换
3. **VS Code 级终端体验** - xterm.js + 真实 PTY，完整支持 vim/tmux/htop 等复杂 TUI
4. **零配置快速启动** - 克隆即用，自动检测项目类型并执行 setup

### 目标用户

- 同时维护多个项目的全栈开发者
- 需要频繁在多个 feature branch / PR 间切换的团队成员
- 偏好原生 macOS 体验但需要强大终端的开发者

## 非目标 (Explicit Non-Goals)

以下功能明确不在本产品范围内：

| 非目标 | 理由 |
|--------|------|
| 完整 IDE 功能 | 不做语法高亮/自动补全/调试器，用户可用外部编辑器 |
| 跨平台支持 | 专注 macOS 原生体验，不考虑 Windows/Linux |
| AI 代码助手 | 不内置 AI 功能，可通过终端使用外部 AI CLI |
| 插件系统 | M0-M2 不做插件，保持核心简洁 |
| 云同步/协作 | 纯本地工具，不做账号/云端功能 |
| 代码审查 UI | 不做 diff viewer，用户使用 git diff / 外部工具 |
| 项目模板 | 不做脚手架/模板生成 |

## 核心体验原则

### 1. 终端体验对齐 VS Code

- 必须使用 xterm.js + 真实 PTY（非伪终端模拟）
- 完整支持：ANSI 256/TrueColor、Unicode、鼠标事件、alternate screen
- vim/neovim/tmux/htop/top/less 必须正常工作
- resize 不能导致显示错乱
- 支持多终端 session 并行

### 2. Workspace 隔离

- 每个 workspace 对应一个 git worktree
- workspace 间完全隔离：文件系统、终端进程、环境变量
- 支持同一项目多个 workspace 并行（如同时开发 feature-A 和 fix-B）

### 3. 快速启动

- 从 URL/branch 创建 workspace 应在秒级完成（浅克隆）
- setup script 自动执行，失败有清晰提示
- 支持 workspace 预热/缓存

### 4. 原生 macOS 体验

- 使用 AppKit/SwiftUI 原生 UI 壳
- 遵循 macOS HIG（Human Interface Guidelines）
- 支持 Spotlight 搜索、Dock 集成、通知中心

## 技术选型冻结

以下技术选型已冻结，不再讨论：

| 层级 | 技术选型 | 理由 |
|------|----------|------|
| **Core Engine** | Rust | 性能、安全、跨平台潜力、优秀的 async 生态 |
| **UI Shell** | SwiftUI + AppKit | macOS 原生体验，系统集成 |
| **Terminal Renderer** | xterm.js (WebView) | 业界标准，VS Code 验证，生态完善 |
| **WebView** | WKWebView | macOS 原生，性能好，与 Safari 同引擎 |
| **PTY** | Rust portable-pty | 跨平台 PTY 抽象，活跃维护 |
| **Git 操作** | git2-rs + CLI fallback | libgit2 绑定，复杂操作 fallback 到 git CLI |
| **Worktree** | Git Worktree | 原生 git 功能，无需额外依赖 |
| **IPC** | JSON-RPC over stdio/WebSocket | 简单、可调试、语言无关 |
| **持久化** | SQLite + 文件系统 | 轻量、可靠、无需外部服务 |
| **配置格式** | TOML | 人类可读、Rust 生态友好 |

## 成功指标

| 指标 | 目标值 |
|------|--------|
| Workspace 创建时间（本地 branch） | < 2s |
| Workspace 创建时间（远程 shallow clone） | < 10s (取决于网络) |
| 终端首字节延迟 | < 50ms |
| 终端吞吐量 | > 10MB/s |
| 内存占用（单 workspace） | < 100MB |
| 冷启动时间 | < 1s |
