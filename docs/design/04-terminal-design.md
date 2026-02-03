# TidyFlow - 终端设计 (Terminal Design)

> 版本: 1.0 (Frozen)
> 最后更新: 2026-01-31

## 设计目标

**核心原则**: 终端体验必须对齐 VS Code，使用相同的技术栈 (xterm.js + PTY)。

### 必须支持的场景

| 场景 | 要求 |
|------|------|
| vim/neovim | 完整功能，包括插件、语法高亮、分屏 |
| tmux | 完整功能，包括分屏、session、鼠标支持 |
| htop/top | 实时刷新、鼠标交互 |
| less/more | 分页浏览、搜索 |
| git log/diff | 颜色、分页 |
| SSH | 远程终端完整功能 |
| 复杂 prompt | oh-my-zsh, starship, powerlevel10k |

---

## 技术架构

### 数据流

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           User Input Flow                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Keyboard/Mouse                                                         │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────┐    keydown/paste     ┌─────────────────────────────┐  │
│  │  WKWebView  │ ──────────────────▶  │        xterm.js             │  │
│  └─────────────┘                      │  ┌───────────────────────┐  │  │
│                                       │  │   Terminal.onData()   │  │  │
│                                       │  └───────────┬───────────┘  │  │
│                                       └──────────────┼──────────────┘  │
│                                                      │                  │
│                                                      │ WebSocket        │
│                                                      ▼                  │
│                                       ┌─────────────────────────────┐  │
│                                       │       Rust Core             │  │
│                                       │  ┌───────────────────────┐  │  │
│                                       │  │  Terminal Service     │  │  │
│                                       │  │  - decode input       │  │  │
│                                       │  │  - write to PTY       │  │  │
│                                       │  └───────────┬───────────┘  │  │
│                                       └──────────────┼──────────────┘  │
│                                                      │                  │
│                                                      │ write()          │
│                                                      ▼                  │
│                                       ┌─────────────────────────────┐  │
│                                       │     PTY Master (Rust)       │  │
│                                       │     - portable-pty          │  │
│                                       └──────────────┬──────────────┘  │
│                                                      │                  │
│                                                      │ kernel           │
│                                                      ▼                  │
│                                       ┌─────────────────────────────┐  │
│                                       │     PTY Slave (Shell)       │  │
│                                       │     - /bin/zsh              │  │
│                                       └─────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                          Output Flow                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────┐                                       │
│  │     PTY Slave (Shell)       │                                       │
│  │     - program output        │                                       │
│  └──────────────┬──────────────┘                                       │
│                 │                                                       │
│                 │ kernel                                                │
│                 ▼                                                       │
│  ┌─────────────────────────────┐                                       │
│  │     PTY Master (Rust)       │                                       │
│  │     - read() loop           │                                       │
│  └──────────────┬──────────────┘                                       │
│                 │                                                       │
│                 │ bytes                                                 │
│                 ▼                                                       │
│  ┌─────────────────────────────┐                                       │
│  │       Rust Core             │                                       │
│  │  ┌───────────────────────┐  │                                       │
│  │  │  Terminal Service     │  │                                       │
│  │  │  - buffer output      │  │                                       │
│  │  │  - batch send         │  │                                       │
│  │  └───────────┬───────────┘  │                                       │
│  └──────────────┼──────────────┘                                       │
│                 │                                                       │
│                 │ WebSocket (base64 encoded)                            │
│                 ▼                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                        xterm.js                                  │   │
│  │  ┌───────────────────────┐  ┌───────────────────────────────┐   │   │
│  │  │   Terminal.write()    │  │      WebGL Renderer           │   │   │
│  │  │   - parse ANSI        │  │      - GPU accelerated        │   │   │
│  │  │   - update buffer     │  │      - 60fps render           │   │   │
│  │  └───────────────────────┘  └───────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                 │                                                       │
│                 │ render                                                │
│                 ▼                                                       │
│  ┌─────────────────────────────┐                                       │
│  │        WKWebView            │                                       │
│  │        - display            │                                       │
│  └─────────────────────────────┘                                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Terminal Session 生命周期

### 状态机

```
┌─────────────┐
│   Starting  │  创建 PTY，启动 shell
└──────┬──────┘
       │ PTY ready + shell started
       ▼
┌─────────────┐
│   Running   │  正常运行，I/O 转发
└──────┬──────┘
       │ shell exit / SIGTERM / error
       ▼
┌─────────────┐
│   Exited    │  进程已退出，保留 scrollback
└─────────────┘
       │ user close / workspace destroy
       ▼
    [Destroyed]  释放所有资源
```

### 创建流程

```rust
async fn create_terminal(workspace_id: Uuid, config: TerminalConfig) -> Result<TerminalSession> {
    // 1. 获取 workspace 信息
    let workspace = get_workspace(workspace_id)?;

    // 2. 准备环境变量
    let mut env = std::env::vars().collect::<HashMap<_, _>>();
    env.insert("TERM".into(), "xterm-256color".into());
    env.insert("COLORTERM".into(), "truecolor".into());
    env.insert("TIDYFLOW_WORKSPACE_ID".into(), workspace_id.to_string());
    env.extend(workspace.env_overrides.clone());

    // 3. 创建 PTY
    let pty_system = native_pty_system();
    let pair = pty_system.openpty(PtySize {
        rows: config.rows,
        cols: config.cols,
        pixel_width: 0,
        pixel_height: 0,
    })?;

    // 4. 启动 shell
    let shell = config.shell.unwrap_or_else(|| get_default_shell());
    let cmd = CommandBuilder::new(&shell);
    cmd.cwd(&workspace.worktree_path);
    cmd.env_clear();
    for (k, v) in &env {
        cmd.env(k, v);
    }

    let child = pair.slave.spawn_command(cmd)?;

    // 5. 创建 session
    let session = TerminalSession {
        id: Uuid::new_v4(),
        workspace_id,
        pty_master: pair.master,
        child,
        state: TerminalState::Running,
        // ...
    };

    // 6. 启动 I/O 转发任务
    spawn_io_forwarder(session.id, session.pty_master.clone());

    Ok(session)
}
```

### 并发模型

**每个 Workspace 可以有多个 Terminal Session**:

```
Workspace A
├── Terminal 1 (zsh)
├── Terminal 2 (running npm start)
└── Terminal 3 (vim)

Workspace B
├── Terminal 1 (zsh)
└── Terminal 2 (running tests)
```

**并发限制**:
| 限制 | 值 | 理由 |
|------|-----|------|
| 每 workspace 最大终端数 | 10 | 防止资源耗尽 |
| 全局最大终端数 | 50 | 系统稳定性 |
| 单终端 scrollback | 10000 行 | 内存控制 |

---

## PTY 管理

### 职责边界

| 组件 | 职责 |
|------|------|
| **Rust Core** | PTY 创建、销毁、resize、I/O 转发 |
| **xterm.js** | 渲染、用户输入捕获、ANSI 解析 |
| **WebView** | 容器、事件传递 |

### PTY 创建

```rust
// 使用 portable-pty crate
use portable_pty::{native_pty_system, PtySize, CommandBuilder};

fn create_pty(rows: u16, cols: u16) -> Result<PtyPair> {
    let pty_system = native_pty_system();
    pty_system.openpty(PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    })
}
```

### Resize 处理

```rust
fn resize_terminal(session_id: Uuid, rows: u16, cols: u16) -> Result<()> {
    let session = get_session(session_id)?;

    // 1. 更新 PTY 大小
    session.pty_master.resize(PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    })?;

    // 2. 更新 session 记录
    session.rows = rows;
    session.cols = cols;

    // 3. 发送 SIGWINCH (由 portable-pty 自动处理)

    Ok(())
}
```

**Resize 触发时机**:
- WebView 容器大小变化
- 用户拖动分隔条
- 窗口最大化/还原

### 销毁流程

```rust
async fn destroy_terminal(session_id: Uuid) -> Result<()> {
    let session = get_session(session_id)?;

    // 1. 停止 I/O 转发
    session.io_task.abort();

    // 2. 终止进程
    if session.state == TerminalState::Running {
        // 发送 SIGTERM
        session.child.kill()?;

        // 等待退出 (最多 5s)
        tokio::select! {
            _ = session.child.wait() => {}
            _ = tokio::time::sleep(Duration::from_secs(5)) => {
                // 强制 SIGKILL
                unsafe { libc::kill(session.child.process_id() as i32, libc::SIGKILL); }
            }
        }
    }

    // 3. 关闭 PTY
    drop(session.pty_master);

    // 4. 清理资源
    remove_session(session_id);

    // 5. 通知前端
    emit_event(TerminalDestroyed { session_id });

    Ok(())
}
```

---

## 数据传输

### 输出批处理

为了优化性能，PTY 输出需要批处理后发送：

```rust
async fn io_forwarder(session_id: Uuid, pty_master: Box<dyn MasterPty>) {
    let mut reader = pty_master.try_clone_reader()?;
    let mut buffer = Vec::with_capacity(65536);
    let mut batch_buffer = Vec::new();

    loop {
        // 读取可用数据
        let n = reader.read(&mut buffer)?;
        if n == 0 {
            break; // EOF
        }

        batch_buffer.extend_from_slice(&buffer[..n]);

        // 批处理策略：等待更多数据或超时
        tokio::select! {
            // 继续读取 (如果有更多数据)
            _ = reader.readable() => continue,
            // 或者超时后发送
            _ = tokio::time::sleep(Duration::from_millis(5)) => {
                send_output(session_id, &batch_buffer);
                batch_buffer.clear();
            }
        }
    }
}
```

### 输入处理

```rust
fn handle_terminal_input(session_id: Uuid, data: &[u8]) -> Result<()> {
    let session = get_session(session_id)?;

    // 直接写入 PTY
    session.pty_master.write_all(data)?;

    Ok(())
}
```

### WebSocket 消息格式

```json
// 输出 (Server → Client)
{
  "method": "event.terminal.output",
  "params": {
    "session_id": "uuid",
    "data": "base64-encoded-bytes"
  }
}

// 输入 (Client → Server)
{
  "method": "terminal.write",
  "params": {
    "session_id": "uuid",
    "data": "base64-encoded-bytes"
  }
}

// Resize (Client → Server)
{
  "method": "terminal.resize",
  "params": {
    "session_id": "uuid",
    "rows": 24,
    "cols": 80
  }
}
```

---

## xterm.js 配置

### 必需 Addons

| Addon | 用途 | 必需 |
|-------|------|------|
| **@xterm/addon-fit** | 自动调整终端大小以适应容器 | ✅ 是 |
| **@xterm/addon-webgl** | GPU 加速渲染 | ✅ 是 |
| **@xterm/addon-search** | 终端内搜索 | ✅ 是 |
| **@xterm/addon-unicode11** | Unicode 11 支持 (emoji 等) | ✅ 是 |
| **@xterm/addon-web-links** | 可点击链接 | ⚠️ 推荐 |
| **@xterm/addon-image** | 图片显示 (iTerm2 协议) | ⚠️ 可选 |
| **@xterm/addon-serialize** | 序列化终端状态 | ⚠️ 可选 |

### 初始化代码

```typescript
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { WebglAddon } from '@xterm/addon-webgl';
import { SearchAddon } from '@xterm/addon-search';
import { Unicode11Addon } from '@xterm/addon-unicode11';
import { WebLinksAddon } from '@xterm/addon-web-links';

function createTerminal(container: HTMLElement): Terminal {
  const terminal = new Terminal({
    // 基础配置
    cursorBlink: true,
    cursorStyle: 'block',
    fontSize: 14,
    fontFamily: 'Menlo, Monaco, "Courier New", monospace',
    lineHeight: 1.2,

    // 颜色
    theme: {
      background: '#1e1e1e',
      foreground: '#d4d4d4',
      cursor: '#ffffff',
      // ... 完整 256 色配置
    },

    // 性能
    scrollback: 10000,
    fastScrollModifier: 'alt',
    fastScrollSensitivity: 5,

    // 功能
    allowProposedApi: true,
    macOptionIsMeta: true,
    macOptionClickForcesSelection: true,
    rightClickSelectsWord: true,

    // 渲染
    rendererType: 'canvas', // WebGL addon 会覆盖
  });

  // 加载 addons
  const fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);

  const webglAddon = new WebglAddon();
  webglAddon.onContextLoss(() => {
    webglAddon.dispose();
    // 回退到 canvas 渲染
  });
  terminal.loadAddon(webglAddon);

  terminal.loadAddon(new SearchAddon());
  terminal.loadAddon(new Unicode11Addon());
  terminal.loadAddon(new WebLinksAddon());

  // 挂载到 DOM
  terminal.open(container);
  fitAddon.fit();

  // 监听容器大小变化
  const resizeObserver = new ResizeObserver(() => {
    fitAddon.fit();
  });
  resizeObserver.observe(container);

  return terminal;
}
```

### 输入处理

```typescript
// 捕获用户输入并发送到后端
terminal.onData((data: string) => {
  const bytes = new TextEncoder().encode(data);
  const base64 = btoa(String.fromCharCode(...bytes));

  websocket.send(JSON.stringify({
    jsonrpc: '2.0',
    method: 'terminal.write',
    params: {
      session_id: sessionId,
      data: base64
    }
  }));
});

// 处理后端输出
websocket.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.method === 'event.terminal.output') {
    const bytes = Uint8Array.from(atob(msg.params.data), c => c.charCodeAt(0));
    terminal.write(bytes);
  }
};
```

---

## 保障清单

### 功能保障

| 功能 | 验证方法 | 状态 |
|------|----------|------|
| vim 正常工作 | 打开文件、编辑、保存、退出 | 必须通过 |
| neovim 正常工作 | 同上 + 插件加载 | 必须通过 |
| tmux 正常工作 | 创建 session、分屏、切换 | 必须通过 |
| htop 正常工作 | 显示进程、鼠标交互 | 必须通过 |
| 256 色支持 | 运行颜色测试脚本 | 必须通过 |
| TrueColor 支持 | 运行 24-bit 颜色测试 | 必须通过 |
| Unicode/Emoji | 显示 emoji 和 CJK 字符 | 必须通过 |
| 鼠标支持 | vim 鼠标选择、tmux 鼠标 | 必须通过 |
| 复制粘贴 | Cmd+C/V 正常工作 | 必须通过 |
| 搜索 | Cmd+F 搜索终端内容 | 必须通过 |

### 性能保障

| 指标 | 目标值 | 测量方法 |
|------|--------|----------|
| 首字节延迟 | < 50ms | 输入到显示时间 |
| 吞吐量 | > 10MB/s | cat 大文件 |
| 渲染帧率 | 60fps | 快速滚动时 |
| 内存占用 | < 50MB/终端 | 10000 行 scrollback |

### Resize 保障

| 场景 | 要求 |
|------|------|
| 窗口拖动 | 实时更新，无闪烁 |
| 最大化/还原 | 内容不丢失，光标位置正确 |
| vim 中 resize | 编辑内容不乱 |
| tmux 中 resize | 所有 pane 正确调整 |

### 多终端保障

| 场景 | 要求 |
|------|------|
| 同时打开 5 个终端 | 各自独立，互不干扰 |
| 一个终端高负载 | 不影响其他终端响应 |
| 快速切换终端 | 无延迟，状态保持 |

---

## 错误处理

### PTY 错误

| 错误 | 处理 |
|------|------|
| PTY 创建失败 | 返回错误，提示用户 |
| Shell 启动失败 | 尝试 fallback shell (/bin/sh) |
| I/O 错误 | 标记终端为 Exited |

### WebSocket 错误

| 错误 | 处理 |
|------|------|
| 连接断开 | 自动重连 (3 次) |
| 消息解析失败 | 记录日志，忽略消息 |
| 发送失败 | 缓存消息，重连后重发 |

### 渲染错误

| 错误 | 处理 |
|------|------|
| WebGL 上下文丢失 | 回退到 Canvas 渲染 |
| 字体加载失败 | 使用系统默认字体 |
