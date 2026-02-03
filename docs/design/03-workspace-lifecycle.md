# TidyFlow - Workspace 生命周期 (Workspace Lifecycle)

> 版本: 1.0 (Frozen)
> 最后更新: 2026-01-31

## Workspace 创建来源

### 1. 本地 Branch

**场景**: 用户想基于现有本地分支创建隔离开发环境

**流程**:
```
用户选择 branch → 创建 worktree → 执行 setup → Ready
```

**特点**:
- 最快的创建方式（无网络操作）
- 直接使用本地 git 对象

### 2. 远程 Repository

**场景**: 用户想克隆一个新仓库并开始开发

**流程**:
```
用户输入 URL → shallow clone → 创建 worktree → 执行 setup → Ready
```

**特点**:
- 支持 shallow clone 加速
- 自动检测默认分支
- 可选：指定特定 branch/tag/commit

### 3. Pull Request / Issue (概念层)

**场景**: 用户想快速查看/修改某个 PR 的代码

**流程**:
```
用户输入 PR URL → 解析 PR 信息 → fetch PR branch → 创建 worktree → 执行 setup → Ready
```

**特点**:
- M0-M2 仅支持 GitHub PR
- 自动设置 upstream 关联
- 可选：自动 checkout PR 的 base branch 用于对比

---

## 详细生命周期流程

### 阶段 1: 创建 (Creating)

```
┌─────────────────────────────────────────────────────────────┐
│                     Creating Phase                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 验证输入参数                                            │
│     ├── project_id 存在且有效                               │
│     ├── branch 名称合法                                     │
│     └── 无同名 workspace 存在                               │
│                                                             │
│  2. 分配资源                                                │
│     ├── 生成 workspace_id (UUID)                            │
│     ├── 计算 worktree 路径                                  │
│     └── 创建数据库记录 (state=Creating)                     │
│                                                             │
│  3. 创建 Git Worktree                                       │
│     ├── git worktree add <path> <branch>                    │
│     ├── 如果 branch 不存在，从 remote 创建                  │
│     └── 设置 worktree 配置                                  │
│                                                             │
│  4. 状态转换                                                │
│     └── state: Creating → Initializing                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**可能的错误**:
| 错误 | 处理 |
|------|------|
| Branch 不存在 | 提示用户，可选从 remote fetch |
| 磁盘空间不足 | 返回错误，清理已分配资源 |
| Git 操作失败 | 返回错误，记录详细日志 |

### 阶段 2: 初始化 (Initializing)

```
┌─────────────────────────────────────────────────────────────┐
│                   Initializing Phase                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 加载配置                                                │
│     ├── 读取 .tidyflow.toml (如果存在)                      │
│     ├── 合并项目级默认配置                                  │
│     └── 合并全局默认配置                                    │
│                                                             │
│  2. 准备环境                                                │
│     ├── 设置环境变量                                        │
│     │   ├── TIDYFLOW_WORKSPACE_ID                           │
│     │   ├── TIDYFLOW_PROJECT_ID                             │
│     │   └── 用户自定义 env                                  │
│     └── 创建临时目录 (如需要)                               │
│                                                             │
│  3. 执行 Setup Script                                       │
│     ├── 按顺序执行每个 step                                 │
│     ├── 发送进度事件 (event.setup.progress)                 │
│     ├── 捕获 stdout/stderr                                  │
│     └── 检查退出码                                          │
│                                                             │
│  4. 状态转换                                                │
│     ├── 成功: state: Initializing → Ready                   │
│     └── 失败: state: Initializing → Failed                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Setup 执行细节**:

```rust
// 伪代码
for step in setup_script.steps {
    // 检查条件
    if let Some(condition) = &step.condition {
        if !evaluate_condition(condition, &workspace) {
            emit_event(SetupProgress::Skipped { step: step.name });
            continue;
        }
    }

    emit_event(SetupProgress::Started { step: step.name });

    let result = execute_command(
        &step.command,
        &workspace.worktree_path,
        &env,
        step.timeout_seconds.unwrap_or(setup_script.timeout_seconds),
    ).await;

    match result {
        Ok(output) => {
            emit_event(SetupProgress::Completed {
                step: step.name,
                output: output.stdout
            });
        }
        Err(e) => {
            emit_event(SetupProgress::Failed {
                step: step.name,
                error: e.to_string()
            });

            if !step.continue_on_error {
                return Err(SetupError::StepFailed(step.name, e));
            }
        }
    }
}
```

### 阶段 3: 就绪 (Ready)

```
┌─────────────────────────────────────────────────────────────┐
│                      Ready Phase                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  可用操作:                                                  │
│  ├── 创建/管理 Terminal Session                             │
│  ├── 打开/编辑文件                                          │
│  ├── 查看 Git 状态                                          │
│  ├── 执行 Git 操作 (通过终端)                               │
│  └── 销毁 Workspace                                         │
│                                                             │
│  后台任务:                                                  │
│  ├── 文件系统监听 (可选)                                    │
│  ├── Git 状态轮询 (每 5s)                                   │
│  └── 终端 I/O 转发                                          │
│                                                             │
│  状态转换触发:                                              │
│  └── 用户请求销毁 → state: Ready → Destroying               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 阶段 4: 失败 (Failed)

```
┌─────────────────────────────────────────────────────────────┐
│                      Failed Phase                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  可用操作:                                                  │
│  ├── 查看失败日志                                           │
│  ├── 重试 Setup (state → Initializing)                      │
│  ├── 打开终端手动修复                                       │
│  └── 销毁 Workspace                                         │
│                                                             │
│  UI 显示:                                                   │
│  ├── 失败原因摘要                                           │
│  ├── 完整日志链接                                           │
│  └── 重试/销毁按钮                                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 阶段 5: 销毁 (Destroying)

```
┌─────────────────────────────────────────────────────────────┐
│                    Destroying Phase                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 终止所有终端进程                                        │
│     ├── 发送 SIGTERM                                        │
│     ├── 等待 5s                                             │
│     └── 发送 SIGKILL (如果仍存活)                           │
│                                                             │
│  2. 关闭所有 Editor Session                                 │
│     ├── 检查未保存更改                                      │
│     ├── 提示用户保存 (如有)                                 │
│     └── 关闭编辑器                                          │
│                                                             │
│  3. 删除 Git Worktree                                       │
│     ├── git worktree remove <path>                          │
│     └── 如果失败，强制删除目录                              │
│                                                             │
│  4. 清理资源                                                │
│     ├── 删除缓存文件                                        │
│     ├── 停止文件 watcher                                    │
│     └── 释放内存资源                                        │
│                                                             │
│  5. 更新数据库                                              │
│     └── 删除 workspace 记录                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 失败策略

### Setup 失败

| 失败类型 | 检测方式 | 处理策略 |
|----------|----------|----------|
| 命令不存在 | exit code 127 | 提示安装依赖，可重试 |
| 权限不足 | exit code 1 + stderr | 提示权限问题，可手动修复 |
| 超时 | 超过配置时间 | 终止进程，可调整超时重试 |
| 网络失败 | 特定错误模式 | 提示检查网络，可重试 |
| 依赖冲突 | 包管理器错误 | 显示详细日志，需手动修复 |

**重试机制**:
```
最大重试次数: 3
重试间隔: 指数退避 (1s, 2s, 4s)
重试范围: 仅失败的 step 及后续 steps
```

### Git 操作失败

| 失败类型 | 处理策略 |
|----------|----------|
| 认证失败 | 提示配置 credential helper |
| 合并冲突 | 标记 workspace 状态，用户手动解决 |
| 网络超时 | 重试 3 次，然后提示用户 |
| 仓库损坏 | 提示重新克隆 |

### 权限失败

| 场景 | 处理策略 |
|------|----------|
| 无法创建 worktree 目录 | 检查父目录权限，提示用户 |
| 无法写入配置文件 | 使用内存配置，警告用户 |
| 无法访问 git 仓库 | 检查 .git 权限，提示修复 |

---

## 资源清理清单

### Workspace 销毁时必须清理

| 资源类型 | 清理方式 | 优先级 |
|----------|----------|--------|
| **终端进程** | SIGTERM → SIGKILL | P0 (必须) |
| **PTY 文件描述符** | close() | P0 (必须) |
| **Worktree 目录** | git worktree remove / rm -rf | P0 (必须) |
| **数据库记录** | DELETE FROM workspaces | P0 (必须) |
| **文件 Watcher** | 停止监听 | P1 (重要) |
| **WebSocket 连接** | 关闭连接 | P1 (重要) |
| **内存缓存** | 释放引用 | P2 (可选) |
| **日志文件** | 保留 7 天后自动清理 | P2 (可选) |
| **Scrollback 缓存** | 删除文件 | P2 (可选) |

### 清理顺序

```
1. 停止所有活动操作 (setup, git ops)
2. 终止终端进程
3. 关闭文件 watcher
4. 删除 worktree
5. 清理缓存
6. 更新数据库
7. 通知 UI 更新
```

### 清理失败处理

| 失败场景 | 处理方式 |
|----------|----------|
| 进程无法终止 | 记录 PID，下次启动时清理 |
| Worktree 删除失败 | 标记为 orphan，后台清理 |
| 数据库更新失败 | 重试 3 次，失败则记录日志 |

---

## 并发控制

### Workspace 操作锁

```rust
// 每个 workspace 有独立的操作锁
struct WorkspaceLock {
    state_lock: RwLock<()>,      // 状态变更锁
    setup_lock: Mutex<()>,       // setup 执行锁 (互斥)
    terminal_lock: RwLock<()>,   // 终端操作锁
}
```

### 并发规则

| 操作 A | 操作 B | 允许并发 |
|--------|--------|----------|
| 创建终端 | 创建终端 | ✅ 是 |
| 执行 setup | 执行 setup | ❌ 否 |
| 销毁 workspace | 任何操作 | ❌ 否 |
| 读取状态 | 任何操作 | ✅ 是 |
| Git 操作 | Git 操作 | ❌ 否 (同一 worktree) |

---

## 事件通知

### Workspace 生命周期事件

```json
// 状态变更
{
  "method": "event.workspace.stateChanged",
  "params": {
    "workspace_id": "...",
    "old_state": "creating",
    "new_state": "initializing"
  }
}

// Setup 进度
{
  "method": "event.setup.progress",
  "params": {
    "workspace_id": "...",
    "step": "npm install",
    "status": "running",
    "progress": 0.5,
    "output": "Installing dependencies..."
  }
}

// Setup 完成
{
  "method": "event.setup.completed",
  "params": {
    "workspace_id": "...",
    "success": true,
    "duration_ms": 12345
  }
}

// Workspace 销毁
{
  "method": "event.workspace.destroyed",
  "params": {
    "workspace_id": "..."
  }
}
```
