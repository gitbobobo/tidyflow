# TidyFlow - 系统架构 (Architecture)

> 版本: 1.0 (Frozen)
> 最后更新: 2026-01-31

## 架构概览

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        macOS Application Layer                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    SwiftUI / AppKit Shell                        │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │   │
│  │  │  Sidebar     │  │  Toolbar     │  │  Window Management   │   │   │
│  │  │  (Projects)  │  │  (Actions)   │  │  (Tabs, Split View)  │   │   │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    │ Native Bridge (Swift ↔ Rust FFI)  │
│                                    ▼                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                      WebView Layer (WKWebView)                   │   │
│  │  ┌─────────────────────────────┐  ┌─────────────────────────┐   │   │
│  │  │      Terminal View          │  │     Editor View         │   │   │
│  │  │  ┌───────────────────────┐  │  │  (Monaco / CodeMirror)  │   │   │
│  │  │  │      xterm.js         │  │  │                         │   │   │
│  │  │  │  + fit addon          │  │  │  [Optional in M0-M2]    │   │   │
│  │  │  │  + webgl addon        │  │  │                         │   │   │
│  │  │  │  + search addon       │  │  └─────────────────────────┘   │   │
│  │  │  │  + unicode11 addon    │  │                                │   │
│  │  │  └───────────────────────┘  │                                │   │
│  │  └─────────────────────────────┘                                │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ IPC (JSON-RPC over WebSocket)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           Rust Core Engine                              │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                        API Layer (JSON-RPC)                      │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │   │
│  │  │  Sync APIs   │  │  Async APIs  │  │   Event Stream       │   │   │
│  │  │  (Request/   │  │  (Long-      │  │   (Server → Client)  │   │   │
│  │  │   Response)  │  │   running)   │  │                      │   │   │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                       Service Layer                              │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │   │
│  │  │  Project     │  │  Workspace   │  │  Terminal            │   │   │
│  │  │  Service     │  │  Service     │  │  Service             │   │   │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │   │
│  │  │  Git         │  │  Config      │  │  Setup               │   │   │
│  │  │  Service     │  │  Service     │  │  Service             │   │   │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                     Infrastructure Layer                         │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │   │
│  │  │  PTY Manager │  │  SQLite      │  │  File Watcher        │   │   │
│  │  │  (portable-  │  │  (rusqlite)  │  │  (notify-rs)         │   │   │
│  │  │   pty)       │  │              │  │                      │   │   │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │   │
│  │  ┌──────────────┐  ┌──────────────┐                             │   │
│  │  │  Git Ops     │  │  Process     │                             │   │
│  │  │  (git2-rs +  │  │  Manager     │                             │   │
│  │  │   CLI)       │  │              │                             │   │
│  │  └──────────────┘  └──────────────┘                             │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         Data Persistence Layer                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │  SQLite DB       │  │  Config Files    │  │  Worktree FS         │  │
│  │  ~/Library/      │  │  .tidyflow.toml  │  │  ~/Library/          │  │
│  │  Application     │  │  (per project)   │  │  Application         │  │
│  │  Support/        │  │                  │  │  Support/            │  │
│  │  TidyFlow/       │  │                  │  │  TidyFlow/           │  │
│  │  tidyflow.db     │  │                  │  │  worktrees/          │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 层级职责

### 1. macOS Application Layer

**职责**:
- 窗口管理、菜单栏、Dock 集成
- 原生 UI 组件（侧边栏、工具栏、状态栏）
- 系统事件处理（快捷键、拖放、通知）
- WebView 容器管理

**技术**: SwiftUI + AppKit

**不负责**: 业务逻辑、数据处理

### 2. WebView Layer

**职责**:
- 终端渲染（xterm.js）
- 可选的编辑器渲染（Monaco/CodeMirror）
- 与 Rust Core 的 WebSocket 通信
- 用户输入捕获与转发

**技术**: WKWebView + TypeScript/JavaScript

**不负责**: PTY 管理、文件操作、git 操作

### 3. Rust Core Engine

**职责**:
- 所有业务逻辑
- PTY 创建与管理
- Git 操作
- 文件系统操作
- 配置管理
- 数据持久化

**技术**: Rust + Tokio async runtime

**不负责**: UI 渲染

### 4. Data Persistence Layer

**职责**:
- 结构化数据存储（SQLite）
- 配置文件读写
- Worktree 文件系统管理

---

## 通信模型

### 同步 API vs 事件流

| 类型 | 用途 | 示例 |
|------|------|------|
| **同步 API** (Request/Response) | 短时操作、查询 | 获取项目列表、读取配置、创建终端 |
| **异步 API** (Request/Callback) | 长时操作 | 克隆仓库、执行 setup script |
| **事件流** (Server Push) | 状态变更通知 | 终端输出、git 状态变化、setup 进度 |

### JSON-RPC 协议

**传输层**: WebSocket (ws://localhost:{port})

**请求格式**:
```json
{
  "jsonrpc": "2.0",
  "id": "uuid-string",
  "method": "workspace.create",
  "params": {
    "project_id": "...",
    "branch": "feature/foo"
  }
}
```

**响应格式**:
```json
{
  "jsonrpc": "2.0",
  "id": "uuid-string",
  "result": {
    "workspace_id": "...",
    "state": "creating"
  }
}
```

**事件格式**:
```json
{
  "jsonrpc": "2.0",
  "method": "event.terminal.output",
  "params": {
    "session_id": "...",
    "data": "base64-encoded-bytes"
  }
}
```

### 关键 API 分类

| 类别 | 方法 | 类型 |
|------|------|------|
| **Project** | project.list | Sync |
| | project.create | Sync |
| | project.delete | Async |
| **Workspace** | workspace.list | Sync |
| | workspace.create | Async |
| | workspace.destroy | Async |
| | workspace.getState | Sync |
| **Terminal** | terminal.create | Sync |
| | terminal.write | Sync |
| | terminal.resize | Sync |
| | terminal.destroy | Sync |
| **Git** | git.getState | Sync |
| | git.fetch | Async |
| | git.pull | Async |
| **Events** | event.terminal.output | Event |
| | event.workspace.stateChanged | Event |
| | event.git.stateChanged | Event |
| | event.setup.progress | Event |

---

## Rust Core 定位

### 结论: Rust 是控制面 + 数据面

**理由**:

1. **控制面职责**:
   - 管理所有资源生命周期（workspace、terminal、process）
   - 协调各组件交互
   - 处理业务逻辑和状态机

2. **数据面职责**:
   - PTY I/O 高性能转发（bytes 级别）
   - 文件系统操作
   - Git 数据操作

3. **为什么不分离**:
   - 避免额外的 IPC 开销
   - 简化部署（单一二进制）
   - Rust 的 async 生态足够处理高并发 I/O

### 性能关键路径

```
Terminal Input:  WebView → WebSocket → Rust → PTY
Terminal Output: PTY → Rust → WebSocket → WebView → xterm.js

目标延迟: < 10ms (单向)
```

---

## 错误处理与回退策略

### 错误分类

| 级别 | 示例 | 处理策略 |
|------|------|----------|
| **Fatal** | 数据库损坏、核心服务崩溃 | 显示错误对话框，建议重启 |
| **Recoverable** | 网络超时、git 操作失败 | 重试 + 用户提示 |
| **Degraded** | 文件 watcher 失败 | 降级运行 + 警告 |
| **Ignorable** | 非关键缓存失败 | 静默记录日志 |

### 回退策略

| 场景 | 主方案 | 回退方案 |
|------|--------|----------|
| Git 操作 | git2-rs (libgit2) | 调用 git CLI |
| 配置读取 | 项目 .tidyflow.toml | 全局默认配置 |
| PTY 创建 | portable-pty | 返回错误（无回退） |
| WebSocket 断开 | 自动重连 (3次) | 显示重连 UI |

### 最小可用状态

即使部分功能失败，以下核心功能必须可用：

1. ✅ 打开已有 workspace
2. ✅ 创建新终端
3. ✅ 终端基本 I/O
4. ✅ 查看项目列表

---

## 安全考虑

### 进程隔离

- 每个 PTY 运行在独立进程
- Rust Core 不以 root 运行
- WebView 沙箱启用

### 数据安全

- 敏感配置（如 token）不存储在 SQLite
- 支持 macOS Keychain 集成（M2+）
- 日志不记录终端输出内容

### 网络安全

- WebSocket 仅监听 localhost
- 使用随机端口 + token 认证
- 不暴露任何外部网络接口
