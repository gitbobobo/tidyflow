# TidyFlow - 里程碑规划 (Milestones)

> 版本: 1.0 (Frozen)
> 最后更新: 2026-01-31

## 里程碑概览

| 里程碑 | 目标 | 核心能力 |
|--------|------|----------|
| **M0** | 可运行骨架 | 基础架构、单终端、IPC 通信 |
| **M1** | 单项目 + Workspace | 完整 workspace 生命周期、多终端 |
| **M2** | 多 Workspace 并行 | 多项目、并行 workspace、完整体验 |

---

## Milestone 0: 可运行骨架

### 目标

构建最小可运行的应用骨架，验证技术栈可行性，打通所有层级的通信链路。

### 能力列表

| 能力 | 描述 |
|------|------|
| macOS App 启动 | SwiftUI 应用可以正常启动和退出 |
| WebView 加载 | WKWebView 可以加载本地 HTML/JS |
| Rust Core 启动 | Rust 二进制可以作为子进程启动 |
| WebSocket 通信 | WebView ↔ Rust Core 双向通信 |
| 单个 PTY | 可以创建一个 PTY 并运行 shell |
| xterm.js 渲染 | 终端输出可以在 xterm.js 中显示 |
| 基本输入 | 键盘输入可以发送到 PTY |

### 验收标准

| 标准 | 验收条件 | 通过 |
|------|----------|------|
| 应用启动 | 双击 app 可以启动，显示主窗口 | ☐ Yes / ☐ No |
| 终端显示 | 窗口中显示 xterm.js 终端 | ☐ Yes / ☐ No |
| Shell 运行 | 终端中运行用户默认 shell | ☐ Yes / ☐ No |
| 命令执行 | 可以输入 `ls` 并看到输出 | ☐ Yes / ☐ No |
| 颜色支持 | `ls --color` 显示彩色输出 | ☐ Yes / ☐ No |
| 退出正常 | 关闭窗口后进程完全退出 | ☐ Yes / ☐ No |

### 技术验证点

- [ ] Swift ↔ Rust FFI 或子进程通信可行
- [ ] WKWebView 可以与本地 WebSocket 通信
- [ ] portable-pty 在 macOS 上正常工作
- [ ] xterm.js 在 WKWebView 中正常渲染

### 不包含

- 项目/Workspace 概念
- 配置文件
- 持久化
- 多终端
- Git 集成

---

## Milestone 1: 单项目 + Workspace

### 目标

实现完整的单项目工作流，包括 workspace 创建、setup 执行、多终端管理。

### 能力列表

| 能力 | 描述 |
|------|------|
| 项目导入 | 可以导入本地 git 仓库作为项目 |
| Workspace 创建 | 可以基于 branch 创建 workspace (worktree) |
| Setup 执行 | 读取 .tidyflow.toml 并执行 setup steps |
| 多终端 | 单个 workspace 内可以创建多个终端 |
| 终端完整功能 | vim/tmux/htop 正常工作 |
| Resize | 终端 resize 正常工作 |
| Git 状态 | 显示基本 git 状态 (branch, dirty) |
| 数据持久化 | 项目和 workspace 信息持久化到 SQLite |
| Workspace 销毁 | 可以销毁 workspace 并清理资源 |

### 验收标准

| 标准 | 验收条件 | 通过 |
|------|----------|------|
| 项目导入 | 可以选择本地目录导入为项目 | ☐ Yes / ☐ No |
| Workspace 创建 | 选择 branch 后创建 workspace | ☐ Yes / ☐ No |
| Worktree 创建 | workspace 对应独立的 git worktree | ☐ Yes / ☐ No |
| Setup 执行 | .tidyflow.toml 中的 steps 按顺序执行 | ☐ Yes / ☐ No |
| Setup 进度 | UI 显示 setup 执行进度 | ☐ Yes / ☐ No |
| Setup 失败处理 | 失败时显示错误，可重试 | ☐ Yes / ☐ No |
| 多终端 | 可以在 workspace 中打开 3+ 终端 | ☐ Yes / ☐ No |
| vim 测试 | vim 打开文件、编辑、保存、退出正常 | ☐ Yes / ☐ No |
| tmux 测试 | tmux 创建 session、分屏正常 | ☐ Yes / ☐ No |
| Resize 测试 | 拖动窗口边缘，终端内容正确调整 | ☐ Yes / ☐ No |
| Git 状态 | 显示当前 branch 和是否有未提交更改 | ☐ Yes / ☐ No |
| 重启恢复 | 重启应用后项目和 workspace 列表恢复 | ☐ Yes / ☐ No |
| Workspace 销毁 | 销毁后 worktree 目录被删除 | ☐ Yes / ☐ No |
| 进程清理 | 销毁后所有终端进程被终止 | ☐ Yes / ☐ No |

### 不包含

- 多项目
- 多 workspace 并行
- 远程仓库克隆
- PR/Issue 集成
- 内嵌编辑器

---

## Milestone 2: 多 Workspace 并行

### 目标

实现完整的多项目、多 workspace 并行开发体验，达到日常可用状态。

### 能力列表

| 能力 | 描述 |
|------|------|
| 多项目 | 可以管理多个独立项目 |
| 多 Workspace | 同一项目可以有多个并行 workspace |
| 远程克隆 | 可以从 URL 克隆远程仓库 |
| Shallow Clone | 支持浅克隆加速 |
| 侧边栏导航 | 项目/workspace 树形导航 |
| Tab 管理 | 多 workspace 以 tab 形式切换 |
| 分屏视图 | 支持左右/上下分屏 |
| 外部编辑器 | 可以用外部编辑器打开文件 |
| 完整 Git 状态 | ahead/behind、staged/unstaged 文件列表 |
| 全局搜索 | 跨终端搜索 |
| 快捷键 | 常用操作快捷键 |
| 通知 | 系统通知 (setup 完成、git 状态变化) |

### 验收标准

| 标准 | 验收条件 | 通过 |
|------|----------|------|
| 多项目 | 可以同时管理 3+ 个项目 | ☐ Yes / ☐ No |
| 多 Workspace | 同一项目可以有 3+ 个 workspace | ☐ Yes / ☐ No |
| 并行运行 | 多个 workspace 的终端可以同时运行命令 | ☐ Yes / ☐ No |
| 远程克隆 | 输入 GitHub URL 可以克隆仓库 | ☐ Yes / ☐ No |
| 克隆速度 | 浅克隆中等大小仓库 < 30s | ☐ Yes / ☐ No |
| 侧边栏 | 显示项目/workspace 树，可展开/折叠 | ☐ Yes / ☐ No |
| Tab 切换 | 点击 tab 切换 workspace | ☐ Yes / ☐ No |
| 分屏 | 可以左右分屏显示两个终端 | ☐ Yes / ☐ No |
| 外部编辑器 | 双击文件用配置的编辑器打开 | ☐ Yes / ☐ No |
| Git ahead/behind | 显示与 upstream 的 commit 差异 | ☐ Yes / ☐ No |
| Git 文件列表 | 显示 staged/unstaged/untracked 文件 | ☐ Yes / ☐ No |
| 快捷键 | Cmd+T 新终端, Cmd+W 关闭, Cmd+1/2/3 切换 | ☐ Yes / ☐ No |
| 通知 | setup 完成时显示系统通知 | ☐ Yes / ☐ No |
| 性能 | 5 个 workspace 各 2 个终端，响应流畅 | ☐ Yes / ☐ No |
| 内存 | 上述场景内存占用 < 500MB | ☐ Yes / ☐ No |

### 不包含

- AI 功能
- 插件系统
- 云同步
- 团队协作
- 内嵌代码编辑器 (仅外部编辑器)
- PR/Issue 深度集成 (仅基本支持)

---

## 里程碑依赖关系

```
M0: 可运行骨架
│
├── macOS App Shell
├── WebView 集成
├── Rust Core 框架
├── WebSocket IPC
├── PTY 基础
└── xterm.js 集成
     │
     ▼
M1: 单项目 + Workspace
│
├── 项目管理
├── Workspace 生命周期
├── Git Worktree 集成
├── Setup Script 执行
├── 多终端管理
├── 配置文件解析
└── SQLite 持久化
     │
     ▼
M2: 多 Workspace 并行
│
├── 多项目支持
├── 并行 Workspace
├── 远程仓库克隆
├── UI 完善 (侧边栏/Tab/分屏)
├── 外部编辑器集成
├── 完整 Git 状态
└── 快捷键/通知
```

---

## 风险与缓解

### M0 风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| WKWebView 限制 | 可能无法访问本地 WebSocket | 使用 localhost + 端口，或 WKURLSchemeHandler |
| PTY 兼容性 | macOS 特定问题 | 使用成熟的 portable-pty crate |
| xterm.js 性能 | WKWebView 中可能较慢 | 启用 WebGL addon，优化批处理 |

### M1 风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| Worktree 限制 | 某些 git 操作在 worktree 中受限 | 文档说明，提供 workaround |
| Setup 超时 | 复杂项目 setup 时间长 | 可配置超时，支持后台执行 |
| 资源泄漏 | 终端进程未正确清理 | 严格的生命周期管理，定期清理 |

### M2 风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 内存占用 | 多 workspace 内存增长 | 限制最大数量，懒加载 |
| 并发冲突 | 多 workspace 操作同一仓库 | 锁机制，操作队列 |
| UI 复杂度 | 多窗口/Tab 管理复杂 | 参考 VS Code/iTerm2 设计 |
