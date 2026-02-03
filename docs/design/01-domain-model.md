# TidyFlow - 领域模型 (Domain Model)

> 版本: 1.0 (Frozen)
> 最后更新: 2026-01-31

## 概念定义

### 1. Project

**定义**: 一个独立的代码仓库，是用户管理的最高层级单位。

| 属性 | 说明 |
|------|------|
| **职责** | 管理仓库元信息、配置、所有 workspace |
| **不负责** | 具体的代码执行、终端管理（由 workspace 负责） |
| **持久化** | 是 - SQLite + 配置文件 |

**关键字段**:
```
Project {
  id: UUID
  name: String                    // 显示名称
  root_path: PathBuf              // 主仓库路径（bare repo 或 main worktree）
  remote_url: Option<String>      // 远程仓库 URL
  config_path: Option<PathBuf>    // 项目配置文件路径 (.tidyflow.toml)
  created_at: DateTime
  updated_at: DateTime
}
```

---

### 2. Workspace

**定义**: 一个隔离的开发环境，对应一个 git worktree，包含独立的文件系统视图和终端会话。

| 属性 | 说明 |
|------|------|
| **职责** | 管理 worktree、终端 session、环境变量、setup 执行 |
| **不负责** | 项目级配置、跨 workspace 共享状态 |
| **持久化** | 是 - SQLite + 文件系统（worktree 目录） |

**关键字段**:
```
Workspace {
  id: UUID
  project_id: UUID                // 所属 project
  name: String                    // 显示名称（通常是 branch 名）
  worktree_path: PathBuf          // worktree 目录路径
  branch: String                  // 关联的 git branch
  state: WorkspaceState           // 状态机
  setup_status: SetupStatus       // setup 执行状态
  env_overrides: HashMap<String, String>  // 环境变量覆盖
  created_at: DateTime
  last_accessed_at: DateTime
}
```

**状态机 (WorkspaceState)**:
```
┌─────────────┐
│   Creating  │ ──────────────────────────────────────┐
└──────┬──────┘                                       │
       │ worktree created                             │ error
       ▼                                              ▼
┌─────────────┐     setup success     ┌─────────────┐
│ Initializing│ ───────────────────▶  │    Ready    │
└──────┬──────┘                       └──────┬──────┘
       │ setup failed                        │ user action
       ▼                                     ▼
┌─────────────┐                       ┌─────────────┐
│   Failed    │                       │  Destroying │
└─────────────┘                       └──────┬──────┘
       │ retry                               │ cleanup done
       └─────────────────────────────────────┼──────────────▶ [Destroyed]
                                             ▼
                                      (removed from DB)
```

**状态说明**:
| 状态 | 含义 | 允许的操作 |
|------|------|-----------|
| Creating | 正在创建 worktree | 无（等待） |
| Initializing | 正在执行 setup script | 查看日志、取消 |
| Ready | 可用状态 | 打开终端、编辑、销毁 |
| Failed | setup 失败 | 查看日志、重试、销毁 |
| Destroying | 正在清理资源 | 无（等待） |

---

### 3. Terminal Session

**定义**: 一个 PTY 实例及其关联的 xterm.js 渲染器，提供完整的终端交互能力。

| 属性 | 说明 |
|------|------|
| **职责** | PTY 生命周期、I/O 转发、resize 处理 |
| **不负责** | 渲染（由 xterm.js 负责）、shell 配置 |
| **持久化** | 否 - 仅运行时状态（可选：scrollback 持久化） |

**关键字段**:
```
TerminalSession {
  id: UUID
  workspace_id: UUID              // 所属 workspace
  pty_pid: u32                    // PTY master 进程 ID
  shell: String                   // shell 路径 (e.g., /bin/zsh)
  cols: u16                       // 列数
  rows: u16                       // 行数
  cwd: PathBuf                    // 当前工作目录
  state: TerminalState            // running/exited
  exit_code: Option<i32>          // 退出码（如果已退出）
  created_at: DateTime
}
```

**状态机 (TerminalState)**:
```
┌─────────────┐
│   Starting  │
└──────┬──────┘
       │ PTY ready
       ▼
┌─────────────┐     process exit      ┌─────────────┐
│   Running   │ ───────────────────▶  │   Exited    │
└─────────────┘                       └─────────────┘
```

---

### 4. Editor Session

**定义**: 一个文件编辑会话，可以是内嵌 WebView 编辑器或外部编辑器的引用。

| 属性 | 说明 |
|------|------|
| **职责** | 文件打开/保存、脏状态追踪、外部编辑器集成 |
| **不负责** | 语法高亮、自动补全（由外部编辑器或简单实现） |
| **持久化** | 部分 - 打开的文件列表持久化，内容不持久化 |

**关键字段**:
```
EditorSession {
  id: UUID
  workspace_id: UUID              // 所属 workspace
  file_path: PathBuf              // 文件路径
  is_dirty: bool                  // 是否有未保存修改
  editor_type: EditorType         // Internal / External(app_name)
  cursor_position: Option<(u32, u32)>  // 行/列
  created_at: DateTime
}
```

**M0-M2 策略**: 优先支持外部编辑器（VS Code / Cursor / Vim），内嵌编辑器为可选增强。

---

### 5. Setup Script

**定义**: workspace 初始化时执行的脚本序列，用于安装依赖、构建项目等。

| 属性 | 说明 |
|------|------|
| **职责** | 定义执行步骤、环境要求、超时策略 |
| **不负责** | 实际执行（由 Rust core 负责） |
| **持久化** | 是 - 作为项目配置的一部分 |

**关键字段**:
```
SetupScript {
  steps: Vec<SetupStep>           // 执行步骤列表
  timeout_seconds: u32            // 总超时时间
  env: HashMap<String, String>    // 环境变量
  working_dir: Option<PathBuf>    // 工作目录（默认 worktree root）
}

SetupStep {
  name: String                    // 步骤名称（用于显示）
  command: String                 // 执行命令
  timeout_seconds: Option<u32>    // 单步超时
  continue_on_error: bool         // 失败是否继续
  condition: Option<String>       // 条件表达式（如 "file_exists:package.json"）
}
```

---

### 6. Git State (Change Set)

**定义**: workspace 中 git 仓库的当前状态快照，包括未提交更改、分支信息等。

| 属性 | 说明 |
|------|------|
| **职责** | 追踪文件变更、分支状态、提供 git 操作入口 |
| **不负责** | 复杂 git 操作（由用户通过终端执行） |
| **持久化** | 否 - 实时从 git 读取 |

**关键字段**:
```
GitState {
  workspace_id: UUID
  branch: String                  // 当前分支
  upstream: Option<String>        // 上游分支
  ahead: u32                      // 领先 commit 数
  behind: u32                     // 落后 commit 数
  staged: Vec<FileChange>         // 已暂存更改
  unstaged: Vec<FileChange>       // 未暂存更改
  untracked: Vec<PathBuf>         // 未追踪文件
  conflicts: Vec<PathBuf>         // 冲突文件
  last_updated: DateTime          // 最后更新时间
}

FileChange {
  path: PathBuf
  status: ChangeStatus            // Added/Modified/Deleted/Renamed
  old_path: Option<PathBuf>       // 重命名时的原路径
}
```

---

## 概念关系

### 关系图

```
┌─────────────────────────────────────────────────────────────┐
│                         Project                              │
│  (1 project = 1 git repository)                             │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ 1:N
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        Workspace                             │
│  (1 workspace = 1 git worktree = 1 branch)                  │
└─────────────────────────────────────────────────────────────┘
          │                   │                    │
          │ 1:N               │ 1:N                │ 1:1
          ▼                   ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ Terminal Session│  │  Editor Session │  │    Git State    │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

### 关系表

| 关系 | 类型 | 说明 |
|------|------|------|
| Project → Workspace | 1:N | 一个项目可有多个 workspace（多分支并行） |
| Workspace → Terminal Session | 1:N | 一个 workspace 可有多个终端 |
| Workspace → Editor Session | 1:N | 一个 workspace 可打开多个文件 |
| Workspace → Git State | 1:1 | 每个 workspace 有独立的 git 状态 |
| Workspace → Setup Script | N:1 | 多个 workspace 可共享同一 setup 配置 |
| Project → Setup Script | 1:1 | 每个项目有一个默认 setup 配置 |

### 生命周期依赖

```
Project 创建
    └── Workspace 创建
            ├── Git Worktree 创建
            ├── Setup Script 执行
            ├── Terminal Session 创建（按需）
            ├── Editor Session 创建（按需）
            └── Git State 初始化

Workspace 销毁
    ├── 所有 Terminal Session 终止
    ├── 所有 Editor Session 关闭（提示保存）
    ├── Git Worktree 删除
    └── 清理缓存/临时文件

Project 删除
    ├── 所有 Workspace 销毁
    └── 项目配置/元数据删除
```

---

## 持久化策略

| 概念 | 存储位置 | 格式 | 备注 |
|------|----------|------|------|
| Project | SQLite | 结构化 | 主数据库 |
| Workspace | SQLite | 结构化 | 主数据库 |
| Terminal Session | 内存 | - | 可选 scrollback 文件 |
| Editor Session | SQLite | 结构化 | 仅元数据 |
| Setup Script | 文件系统 | TOML | .tidyflow.toml |
| Git State | 实时读取 | - | 不持久化 |

**数据库位置**: `~/Library/Application Support/TidyFlow/tidyflow.db`

**Worktree 位置**: `~/Library/Application Support/TidyFlow/worktrees/{project_id}/{workspace_id}/`
