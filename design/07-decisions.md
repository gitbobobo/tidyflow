# TidyFlow - 关键决策记录 (Decisions)

> 版本: 1.0 (Frozen)
> 最后更新: 2026-01-31

## 决策列表

### D1: Workspace 隔离机制

| 项目 | 内容 |
|------|------|
| **Decision** | 使用 Git Worktree 实现 workspace 隔离 |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>Git 原生功能，无需额外依赖</li><li>真正的文件系统隔离</li><li>支持同时在多个 branch 工作</li><li>与现有 git 工作流兼容</li></ul> |
| **Alternatives Considered** | <ul><li>**多仓库克隆**: 浪费磁盘空间，git 对象不共享</li><li>**Stash + 切换**: 不是真正隔离，容易出错</li><li>**虚拟文件系统**: 实现复杂，兼容性问题</li></ul> |
| **Consequences** | <ul><li>✅ 每个 workspace 有独立的工作目录</li><li>✅ 可以同时编译/运行多个 branch</li><li>⚠️ 某些 git 操作在 worktree 中受限 (如 checkout 到已有 worktree 的 branch)</li><li>⚠️ 需要管理 worktree 生命周期</li></ul> |

---

### D2: 终端技术栈

| 项目 | 内容 |
|------|------|
| **Decision** | 使用 xterm.js + WebView + Rust PTY |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>xterm.js 是业界标准，VS Code 验证</li><li>完整的 ANSI/VT 支持</li><li>活跃的社区和丰富的 addon</li><li>WebGL 加速渲染</li></ul> |
| **Alternatives Considered** | <ul><li>**原生 NSTextView**: 需要自己实现 ANSI 解析，工作量巨大</li><li>**SwiftTerm**: 功能不如 xterm.js 完善</li><li>**Electron**: 太重，不符合原生体验目标</li><li>**libvterm + 自定义渲染**: 实现复杂，维护成本高</li></ul> |
| **Consequences** | <ul><li>✅ 终端功能完整，vim/tmux 等正常工作</li><li>✅ 可以复用 VS Code 的终端经验</li><li>⚠️ 需要 WebView 容器</li><li>⚠️ 需要处理 WebView ↔ Native 通信</li></ul> |

---

### D3: 编辑器策略

| 项目 | 内容 |
|------|------|
| **Decision** | M0-M2 优先支持外部编辑器，内嵌编辑器为可选 |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>避免重复造轮子</li><li>用户已有偏好的编辑器</li><li>专注核心价值（多 workspace 管理）</li><li>降低开发复杂度</li></ul> |
| **Alternatives Considered** | <ul><li>**内嵌 Monaco Editor**: 功能强大但增加复杂度</li><li>**内嵌 CodeMirror**: 较轻量但仍需大量工作</li><li>**完全不支持编辑**: 用户体验不完整</li></ul> |
| **Consequences** | <ul><li>✅ 开发资源集中在核心功能</li><li>✅ 用户可以使用熟悉的编辑器</li><li>⚠️ 需要实现外部编辑器集成</li><li>⚠️ 文件跳转体验可能不如内嵌编辑器流畅</li></ul> |

---

### D4: 通信协议

| 项目 | 内容 |
|------|------|
| **Decision** | 使用 JSON-RPC 2.0 over WebSocket |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>标准协议，工具支持好</li><li>人类可读，便于调试</li><li>支持双向通信和事件推送</li><li>语言无关，前后端解耦</li></ul> |
| **Alternatives Considered** | <ul><li>**gRPC**: 需要 protobuf，WebView 支持复杂</li><li>**MessagePack**: 二进制格式，调试困难</li><li>**自定义协议**: 维护成本高</li><li>**REST over HTTP**: 不支持服务端推送</li></ul> |
| **Consequences** | <ul><li>✅ 调试方便，可以用浏览器开发工具查看</li><li>✅ 易于扩展新的 API</li><li>⚠️ JSON 序列化有一定开销（对终端 I/O 影响小）</li><li>⚠️ 需要处理 WebSocket 重连</li></ul> |

---

### D5: 持久化位置

| 项目 | 内容 |
|------|------|
| **Decision** | 使用 `~/Library/Application Support/TidyFlow/` |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>macOS 标准应用数据位置</li><li>用户可以通过 Time Machine 备份</li><li>与其他应用数据隔离</li><li>不污染用户 home 目录</li></ul> |
| **Alternatives Considered** | <ul><li>**~/.tidyflow/**: 不符合 macOS 惯例</li><li>**项目目录内**: 会被 git 追踪，不合适</li><li>**/tmp/**: 重启后丢失</li></ul> |
| **Consequences** | <ul><li>✅ 符合 macOS 最佳实践</li><li>✅ 数据与应用生命周期一致</li><li>⚠️ 用户可能不知道数据位置</li><li>⚠️ 需要处理权限问题</li></ul> |

**目录结构**:
```
~/Library/Application Support/TidyFlow/
├── tidyflow.db              # SQLite 数据库
├── config.toml              # 全局配置
├── logs/                    # 日志文件
├── cache/                   # 缓存
└── worktrees/               # Worktree 存储
    └── {project_id}/
        └── {workspace_id}/
```

---

### D6: Rust Core 部署方式

| 项目 | 内容 |
|------|------|
| **Decision** | Rust Core 作为独立进程，通过 WebSocket 通信 |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>进程隔离，崩溃不影响 UI</li><li>可以独立开发和测试</li><li>未来可能支持远程 Core</li><li>调试方便</li></ul> |
| **Alternatives Considered** | <ul><li>**FFI 直接调用**: 崩溃会导致整个应用崩溃</li><li>**XPC Service**: macOS 特定，复杂度高</li><li>**嵌入 WebView**: 不可行，Rust 无法在 WebView 中运行</li></ul> |
| **Consequences** | <ul><li>✅ 架构清晰，职责分离</li><li>✅ 可以独立重启 Core</li><li>⚠️ 需要管理进程生命周期</li><li>⚠️ IPC 有一定开销</li></ul> |

---

### D7: Git 操作实现

| 项目 | 内容 |
|------|------|
| **Decision** | 优先使用 git2-rs，复杂操作 fallback 到 git CLI |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>git2-rs 性能好，无需 fork 进程</li><li>某些操作 git2 不支持或有 bug</li><li>CLI fallback 保证功能完整</li><li>用户可能有自定义 git 配置</li></ul> |
| **Alternatives Considered** | <ul><li>**纯 git2-rs**: 某些操作不支持</li><li>**纯 git CLI**: 性能差，解析输出复杂</li><li>**gitoxide**: 还不够成熟</li></ul> |
| **Consequences** | <ul><li>✅ 常用操作性能好</li><li>✅ 功能完整</li><li>⚠️ 需要维护两套实现</li><li>⚠️ CLI 输出解析可能有兼容性问题</li></ul> |

**操作分类**:
| 操作 | 实现方式 |
|------|----------|
| status | git2-rs |
| diff (简单) | git2-rs |
| log | git2-rs |
| branch list | git2-rs |
| worktree add/remove | git CLI |
| fetch/pull/push | git CLI |
| merge/rebase | git CLI |
| stash | git CLI |

---

### D8: 配置文件格式

| 项目 | 内容 |
|------|------|
| **Decision** | 使用 TOML 格式 |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>人类可读可写</li><li>Rust 生态支持好 (serde + toml crate)</li><li>比 JSON 更适合配置文件</li><li>比 YAML 更不容易出错</li></ul> |
| **Alternatives Considered** | <ul><li>**JSON**: 不支持注释，手写不友好</li><li>**YAML**: 缩进敏感，容易出错</li><li>**INI**: 表达能力不足</li></ul> |
| **Consequences** | <ul><li>✅ 用户可以轻松编辑配置</li><li>✅ 支持注释</li><li>⚠️ 某些用户可能不熟悉 TOML</li></ul> |

---

### D9: 日志策略

| 项目 | 内容 |
|------|------|
| **Decision** | 使用 tracing crate，日志写入文件，保留 7 天 |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>tracing 是 Rust 生态标准</li><li>支持结构化日志</li><li>支持 span 追踪</li><li>7 天保留平衡存储和调试需求</li></ul> |
| **Alternatives Considered** | <ul><li>**log crate**: 功能较弱</li><li>**slog**: 社区不如 tracing 活跃</li><li>**stdout only**: 不便于事后调试</li></ul> |
| **Consequences** | <ul><li>✅ 可以追踪复杂问题</li><li>✅ 支持不同级别过滤</li><li>⚠️ 需要管理日志文件大小</li></ul> |

---

### D10: 错误处理策略

| 项目 | 内容 |
|------|------|
| **Decision** | 使用 thiserror + anyhow，API 返回结构化错误 |
| **Status** | ✅ Frozen |
| **Rationale** | <ul><li>thiserror 用于定义错误类型</li><li>anyhow 用于错误传播</li><li>API 返回结构化错误便于前端处理</li></ul> |
| **Alternatives Considered** | <ul><li>**纯 std::error**: 样板代码多</li><li>**eyre**: 功能类似 anyhow，社区较小</li></ul> |
| **Consequences** | <ul><li>✅ 错误信息清晰</li><li>✅ 前端可以根据错误类型显示不同 UI</li><li>⚠️ 需要定义完整的错误类型层次</li></ul> |

**错误响应格式**:
```json
{
  "jsonrpc": "2.0",
  "id": "...",
  "error": {
    "code": -32000,
    "message": "Workspace creation failed",
    "data": {
      "type": "WorkspaceError::GitOperationFailed",
      "details": "Branch 'feature/foo' does not exist",
      "recoverable": true,
      "suggestion": "Run 'git fetch' to update remote branches"
    }
  }
}
```
