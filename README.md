# TidyFlow 设计文档

本目录包含 TidyFlow 的完整设计文档和任务规划，用于指导从零开始的实现工作。

## 文档结构

```
tidyflow/
├── design/                    # 设计文档
│   ├── 00-brief.md           # 产品简报：目标、非目标、技术选型
│   ├── 01-domain-model.md    # 领域模型：核心概念定义与关系
│   ├── 02-architecture.md    # 系统架构：层级、通信、错误处理
│   ├── 03-workspace-lifecycle.md  # Workspace 生命周期详解
│   ├── 04-terminal-design.md # 终端设计：xterm.js + PTY
│   ├── 05-project-config-schema.md  # 配置文件 Schema
│   ├── 06-milestones.md      # 里程碑规划与验收标准
│   ├── 07-decisions.md       # 关键决策记录 (ADR)
│   ├── 08-open-questions.md  # 开放问题清单
│   └── 12-ws-control-protocol.md  # WebSocket 协议规范 (v1.1 多终端)
├── docs/
│   └── M1_IMPLEMENTATION.md  # M1 实现指南
├── scripts/
│   ├── run-core.sh           # 启动 Rust Core
│   ├── run-app.sh            # 启动 macOS App
│   ├── smoke-test.sh         # 基础冒烟测试
│   ├── verify_protocol.py    # 协议验证测试
│   ├── workspace-demo.sh     # Workspace 功能演示
│   ├── term-multi-smoke.sh   # 多终端冒烟测试
│   └── multi-workspace-smoke.sh  # 多 Workspace 并行测试 (M2-2)
├── tasks/
│   └── tasks.json            # 可执行任务池
└── README.md                 # 本文件
```

## 快速开始

### 1. 阅读顺序

建议按以下顺序阅读设计文档：

1. **00-brief.md** - 了解产品目标和技术选型
2. **01-domain-model.md** - 理解核心概念
3. **02-architecture.md** - 掌握系统架构
4. **06-milestones.md** - 了解里程碑规划
5. 其他文档按需阅读

### 2. 开始实现

实现工作按 `tasks/tasks.json` 中的任务顺序进行：

```bash
# 查看任务列表
cat tasks/tasks.json | jq '.tasks[] | {id, title, status, depends_on}'

# 查看 M0 任务
cat tasks/tasks.json | jq '.tasks[] | select(.milestone == "M0")'
```

### 3. 任务依赖

任务之间存在依赖关系，必须按依赖顺序执行：

```
T001 (设计评审)
  ├── T002 (Rust Core 初始化)
  │     ├── T006 (WebSocket 服务端)
  │     └── T008 (PTY 基础)
  ├── T003 (macOS App 初始化)
  │     ├── T004 (WebView 集成)
  │     └── T010 (进程管理)
  └── T005 (xterm.js 前端)
        └── T007 (WebSocket 客户端)

T007 + T008 → T009 (终端 I/O 转发)
T004 + T009 + T010 → T011 (M0 集成测试)
```

## 里程碑概览

| 里程碑 | 目标 | 关键能力 |
|--------|------|----------|
| **M0** | 可运行骨架 | App 启动、单终端、基本 I/O |
| **M1** | 单项目 + Workspace | 完整生命周期、多终端、Setup |
| **M2** | 多 Workspace 并行 | 多项目、并行开发、完整体验 |

> **M2-2 已实现**: 支持多 Workspace 并行运行，每个 Tab 绑定独立 Workspace，PTY cwd 严格隔离。

## 关键技术栈

| 组件 | 技术 |
|------|------|
| Core Engine | Rust + Tokio |
| UI Shell | SwiftUI + AppKit |
| Terminal | xterm.js + WebGL |
| WebView | WKWebView |
| PTY | portable-pty |
| IPC | JSON-RPC over WebSocket |
| 持久化 | SQLite |
| 配置 | TOML |

## 开发规范

### 任务状态

```json
{
  "status": "pending"    // 未开始
  "status": "in_progress" // 进行中
  "status": "completed"   // 已完成
  "status": "blocked"     // 被阻塞
}
```

### 更新任务状态

完成任务后，更新 `tasks/tasks.json` 中对应任务的 status 字段。

### 设计变更

如需修改已冻结的设计：

1. 在 `07-decisions.md` 中记录变更决策
2. 更新相关设计文档
3. 评估对任务的影响

## 风险提示

1. **WKWebView 限制** - 需验证 localhost WebSocket 连接
2. **PTY 兼容性** - macOS 特定行为需测试
3. **Worktree 限制** - 某些 git 操作受限

详见 `08-open-questions.md`。

## 联系方式

如有问题，请在项目 Issue 中讨论。
