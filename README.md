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

## UI 布局

TidyFlow 采用 Cursor 风格的三栏布局：

```
+------------------+------------------------+------------------+
|                  |                        |                  |
|  LEFT SIDEBAR    |      MAIN AREA         |   RIGHT PANEL    |
|  (220px)         |      (flex: 1)         |   (280px)        |
|                  |                        |                  |
|  Projects/       |  [Tab Bar]             |  [Tool Icons]    |
|  Workspaces      |  +------------------+  |  Explorer|Search |
|  Tree            |  | Tab Content      |  |  |Git            |
|                  |  | (Editor/Terminal)|  |                  |
|                  |  +------------------+  |  [Tool Content]  |
|                  |                        |                  |
+------------------+------------------------+------------------+
```

### 核心特性

1. **Workspace 作用域 Tabs** - 每个 Workspace 拥有独立的 Tab 集合，切换 Workspace 时自动切换整个 Tab 集合
2. **统一 Tab 栏** - Editor 和 Terminal 混合在同一个 Tab 栏中
3. **右侧工具面板** - Explorer/Search/Git 三个视图，通过图标切换

### 操作说明

| 操作 | 说明 |
|------|------|
| 选择 Workspace | 点击左侧边栏的 Workspace 节点 |
| 新建 Terminal | 点击 Tab 栏右侧的 ⌘ 按钮 |
| 打开文件 | 在右侧 Explorer 中点击文件 |
| 保存文件 | `Cmd+S` (macOS) / `Ctrl+S` |
| 关闭 Tab | 点击 Tab 上的 × 按钮 |
| 切换工具视图 | 点击右侧面板顶部的图标 |

### 设计文档

- `design/15-workspace-ui-contract.md` - Workspace UI 契约
- `design/16-right-panel-tools.md` - 右侧工具面板规范

## Editor 编辑器

### 概述

TidyFlow 内置了一个轻量级文本编辑器，用于在 Workspace 内快速查看和编辑文件。编辑器通过 WebSocket 协议与 Rust Core 通信，支持基本的文件操作。

### 功能特性

- **文件列表** - 显示当前 Workspace 的文件树
- **打开文件** - 点击文件名即可在编辑器中打开
- **编辑内容** - 支持基本的文本编辑功能
- **保存文件** - 修改后可保存回磁盘

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+S` (macOS) / `Ctrl+S` (其他) | 保存当前文件 |

### 命令面板快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+P` | Quick Open - 快速打开文件 |
| `Cmd+Shift+P` | Command Palette - 命令面板 |
| `Cmd+1/2/3` | 切换右侧工具面板 (Explorer/Search/Git) |
| `Cmd+T` | 新建终端 Tab |
| `Cmd+W` | 关闭当前 Tab |
| `Ctrl+Tab` | 下一个 Tab |
| `Ctrl+Shift+Tab` | 上一个 Tab |

### Quick Open 文件索引 (Cmd+P)

Quick Open 使用服务端文件索引 API，提供完整的 Workspace 文件列表：

- **首次打开**: 自动从服务端请求文件索引，显示 loading 状态
- **后续打开**: 使用缓存的索引，即时响应
- **刷新索引**: 在命令面板 (Cmd+Shift+P) 中执行 "Refresh File Index"

**过滤规则**:
- 忽略目录: `.git`, `target`, `node_modules`, `dist`, `build`, `.build`, `.swiftpm` 等
- 忽略隐藏文件: 以 `.` 开头的文件
- 最大文件数: 50,000 (超过时显示 truncated 警告)

详见 `design/18-file-index.md`。

详见 `design/17-command-palette.md`。

### 限制

- **文件大小** - 最大支持 1MB 文件
- **编码格式** - 仅支持 UTF-8 编码
- **文件类型** - 不支持二进制文件（如图片、视频等）

## Git 面板

### 概述

右侧 Git 面板显示当前 Workspace 的 git status，点击文件可在中间区域打开 Diff Tab 查看差异。

### 功能特性

- **Git Status 列表** - 显示 M/A/D/??/R/C 状态的文件
- **Diff Tab** - 点击文件打开 diff 视图，支持 Unified / Split 切换
- **Diff 模式切换** - 支持查看 Working (未暂存) 和 Staged (已暂存) 两种模式的差异
- **刷新按钮** - 重新获取 git diff

### Git Diff 查看器

Diff Tab 提供两种模式查看文件变更：

- **Working 模式**: 显示未暂存的变更 (工作区 vs 暂存区)
- **Staged 模式**: 显示已暂存的变更 (暂存区 vs HEAD)

在 Diff Tab 工具栏中点击 Working/Staged 按钮即可切换模式。

### 状态码说明

| 状态码 | 含义 | 颜色 |
|--------|------|------|
| M | 已修改 | 黄色 |
| A | 已添加 | 绿色 |
| D | 已删除 | 红色 |
| ?? | 未跟踪 | 灰色 |
| R | 重命名 | 蓝色 |
| C | 复制 | 蓝色 |

### 测试

```bash
./scripts/git-tools-smoke.sh
```

详见 `design/19-git-tools.md`。

### 测试

运行编辑器冒烟测试：

```bash
./scripts/editor-smoke.sh
```

测试内容包括：
- 文件列表获取
- 文件打开
- 文件编辑
- 文件保存
- 错误处理（大文件、二进制文件等）

## 联系方式

如有问题，请在项目 Issue 中讨论。
