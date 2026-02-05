# WebSocket Base64 改二进制传输

## TL;DR

> **Quick Summary**: 将 TidyFlow 的 WebSocket 通信从 JSON + Base64 编码改为 MessagePack 二进制传输，消除 Base64 的 33% 开销，提升终端和文件传输性能。
> 
> **Deliverables**:
> - Rust Core 使用 MessagePack 发送/接收二进制消息
> - JavaScript 客户端处理二进制 WebSocket 帧
> - 协议版本升级到 v2
> - 更新协议设计文档
> 
> **Estimated Effort**: Medium（3-5 天）
> **Parallel Execution**: YES - 3 waves
> **Critical Path**: Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6

---

## Context

### Original Request
WebSocket base64 改二进制传输

### Interview Summary
**Key Discussions**:
- 改造范围：终端 I/O + 文件操作 + 控制消息，全部改成二进制
- 向后兼容：不需要向后兼容，直接切换
- 压缩：暂不需要
- 测试策略：手动测试

**Research Findings**:
- 当前实现：所有消息通过 JSON text frame 传输，二进制数据使用 base64 编码
- Rust 端：`ws.rs` 使用 `Message::Text(json)` 发送，`BASE64.encode/decode` 处理数据
- JS 端：`state.js` 的 `encodeBase64/decodeBase64`，通过 `WebSocket.send(JSON.stringify())` 发送
- 协议版本：当前为 v1（`PROTOCOL_VERSION: u32 = 1`）
- 影响的消息类型：`Input`、`Output`（终端）、`FileRead`、`FileWrite`（文件）、所有控制消息

### Metis Review
**Identified Gaps** (addressed):
- 序列化格式选择：选用 MessagePack（轻量、不需要 schema 文件、与 JSON 语义兼容）
- 帧格式设计：采用简单的二进制帧结构
- 调试支持：开发模式下可 dump 消息内容
- 回滚策略：使用 feature branch 开发

---

## Work Objectives

### Core Objective
将 WebSocket 通信从 JSON + Base64 改为 MessagePack 二进制传输，消除 Base64 编解码开销。

### Concrete Deliverables
- `core/src/server/ws.rs`: 使用 `Message::Binary` 发送/接收 MessagePack 数据
- `core/src/server/protocol.rs`: 移除 `data_b64`/`content_b64` 字段，改为 `data`/`content`（二进制）
- `core/Cargo.toml`: 添加 `rmp-serde` 依赖
- `app/TidyFlow/Web/main/state.js`: 处理二进制 WebSocket 消息
- `app/TidyFlow/Web/main/messages.js`: 解析 MessagePack 消息
- `app/TidyFlow/Web/main/tabs.js`: 发送二进制终端输入
- `app/TidyFlow/Web/vendor/msgpack.min.js`: 添加 MessagePack 库
- `docs/design/12-ws-control-protocol.md`: 更新协议文档

### Definition of Done
- [x] 终端输入输出正常工作（无乱码）
- [x] 文件读写正常工作（内容一致）
- [x] 多终端并行正常
- [x] 中文输入显示正常
- [x] TUI 应用（vim、tmux）正常运行

### Must Have
- MessagePack 序列化/反序列化
- 二进制 WebSocket 帧传输
- 协议版本升级到 v2
- 移除所有 base64 编解码逻辑

### Must NOT Have (Guardrails)
- 不做消息压缩
- 不做批量消息合并
- 不做文件流式传输
- 不修改 `TerminalManager` 的会话管理逻辑
- 不修改 `find_incomplete_escape_sequence` 函数的核心逻辑
- 不破坏 ANSI 转义序列和 UTF-8 多字节字符处理
- 不添加向后兼容层

---

## Verification Strategy (MANDATORY)

> **UNIVERSAL RULE: ZERO HUMAN INTERVENTION**
>
> ALL tasks in this plan MUST be verifiable WITHOUT any human action.
> The executing agent uses tools (Playwright, Bash, tmux) to verify.

### Test Decision
- **Infrastructure exists**: YES（已有 `cargo test`）
- **Automated tests**: 手动测试为主，关键编解码逻辑添加单元测试
- **Framework**: cargo test (Rust)

### Agent-Executed QA Scenarios (MANDATORY — ALL tasks)

**Verification Tool by Deliverable Type:**

| Type | Tool | How Agent Verifies |
|------|------|-------------------|
| Rust 编译 | Bash | `cargo build --release` 无错误 |
| Rust 测试 | Bash | `cargo test` 全部通过 |
| 终端功能 | Playwright | 打开应用，输入命令，验证输出 |
| 文件操作 | Playwright | 打开文件，编辑保存，验证内容 |

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately):
├── Task 1: 添加 MessagePack 依赖和基础类型
└── Task 2: 添加 JavaScript MessagePack 库

Wave 2 (After Wave 1):
├── Task 3: Rust 服务端二进制传输改造
└── Task 4: JavaScript 客户端二进制接收改造

Wave 3 (After Wave 2):
├── Task 5: JavaScript 客户端二进制发送改造
└── Task 6: 更新协议文档和版本号

Wave 4 (After Wave 3):
└── Task 7: 端到端验证和清理
```

### Dependency Matrix

| Task | Depends On | Blocks | Can Parallelize With |
|------|------------|--------|---------------------|
| 1 | None | 3 | 2 |
| 2 | None | 4, 5 | 1 |
| 3 | 1 | 4, 7 | 2 |
| 4 | 2, 3 | 7 | None (depends on 3) |
| 5 | 2, 4 | 7 | None (depends on 4) |
| 6 | 3 | 7 | 4, 5 |
| 7 | 3, 4, 5, 6 | None | None (final) |

### Agent Dispatch Summary

| Wave | Tasks | Recommended Agents |
|------|-------|-------------------|
| 1 | 1, 2 | quick (依赖添加) |
| 2 | 3, 4 | unspecified-high (核心改造) |
| 3 | 5, 6 | unspecified-low |
| 4 | 7 | quick (验证) |

---

## TODOs

- [x] 1. 添加 MessagePack 依赖和协议类型定义

  **What to do**:
  - 在 `core/Cargo.toml` 添加依赖：
    - `rmp-serde` - MessagePack 序列化库
    - `serde_bytes` - 用于 `#[serde(with = "serde_bytes")]` 高效二进制序列化
  - 在 `core/src/server/protocol.rs` 中：
    - 将 `data_b64: String` 改为 `data: Vec<u8>`（使用 `#[serde(with = "serde_bytes")]`）
    - 将 `content_b64: String` 改为 `content: Vec<u8>`
    - 更新 `PROTOCOL_VERSION` 为 2
  - 确保所有消息类型都能正确序列化为 MessagePack

  **Must NOT do**:
  - 不修改消息的业务语义
  - 不添加新的消息类型

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 简单的依赖添加和字段类型修改
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `git-master`: 不需要复杂的 git 操作

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 2)
  - **Blocks**: Task 3
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - `core/src/server/protocol.rs:1-30` - 当前协议版本和消息定义模式
  - `core/Cargo.toml` - 依赖管理

  **API/Type References**:
  - `core/src/server/protocol.rs:ClientMessage::Input` - 终端输入消息，包含 `data_b64`
  - `core/src/server/protocol.rs:ServerMessage::Output` - 终端输出消息，包含 `data_b64`
  - `core/src/server/protocol.rs:ClientMessage::FileWrite` - 文件写入，包含 `content_b64`
  - `core/src/server/protocol.rs:ServerMessage::FileReadResult` - 文件读取结果，包含 `content_b64`

  **External References**:
  - rmp-serde 文档: https://docs.rs/rmp-serde - MessagePack 序列化
  - serde_bytes 文档: https://docs.rs/serde_bytes - 二进制数据序列化（需作为依赖添加）

  **WHY Each Reference Matters**:
  - `protocol.rs` 包含所有需要修改的消息类型定义
  - rmp-serde 是 Rust 的 MessagePack 序列化库
  - serde_bytes 用于高效序列化 `Vec<u8>`（必须在 Cargo.toml 中添加此依赖才能使用 `#[serde(with = "serde_bytes")]`）

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Rust 项目编译成功
    Tool: Bash
    Preconditions: 在 core/ 目录
    Steps:
      1. cd core && cargo build --release
      2. Assert: 编译无错误
    Expected Result: Build succeeds
    Evidence: Build output captured

  Scenario: 协议版本更新
    Tool: Bash (grep)
    Preconditions: protocol.rs 已修改
    Steps:
      1. grep "PROTOCOL_VERSION" core/src/server/protocol.rs
      2. Assert: 输出包含 "2"
    Expected Result: Version is 2
    Evidence: grep output
  ```

  **Commit**: YES
  - Message: `refactor(protocol): switch to MessagePack binary encoding`
  - Files: `core/Cargo.toml`, `core/src/server/protocol.rs`
  - Pre-commit: `cd core && cargo build`

---

- [x] 2. 添加 JavaScript MessagePack 库

  **What to do**:
  - 下载 msgpack-lite 或 @msgpack/msgpack 的浏览器版本
  - 添加到 `app/TidyFlow/Web/vendor/msgpack.min.js`
  - 在 `app/TidyFlow/Web/index.html` 中引入

  **Must NOT do**:
  - 不使用 npm/webpack，直接使用 CDN 版本的 UMD 构建

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 简单的文件下载和引入
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 1)
  - **Blocks**: Task 4, Task 5
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - `app/TidyFlow/Web/index.html` - 查看现有库的引入方式
  - `app/TidyFlow/Web/vendor/xterm.js` - 现有 vendor 库的组织方式

  **External References**:
  - @msgpack/msgpack: https://github.com/msgpack/msgpack-javascript
  - CDN: https://unpkg.com/@msgpack/msgpack/dist.es5+umd/msgpack.min.js

  **WHY Each Reference Matters**:
  - 需要遵循现有的 vendor 库组织方式
  - msgpack-javascript 是官方维护的 JavaScript MessagePack 库

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: MessagePack 库文件存在
    Tool: Bash
    Preconditions: None
    Steps:
      1. ls -la app/TidyFlow/Web/vendor/msgpack.min.js
      2. Assert: 文件存在且大小 > 0
    Expected Result: File exists
    Evidence: ls output

  Scenario: index.html 引入了 MessagePack
    Tool: Bash (grep)
    Preconditions: index.html 已修改
    Steps:
      1. grep "msgpack" app/TidyFlow/Web/index.html
      2. Assert: 输出包含 script 标签
    Expected Result: Script tag found
    Evidence: grep output
  ```

  **Commit**: YES
  - Message: `feat(web): add MessagePack JavaScript library`
  - Files: `app/TidyFlow/Web/vendor/msgpack.min.js`, `app/TidyFlow/Web/index.html`
  - Pre-commit: None

---

- [x] 3. Rust 服务端二进制传输改造

  **What to do**:
  - 修改 `core/src/server/ws.rs`：
    - `send_message` 函数：使用 `rmp_serde::to_vec()` 序列化，发送 `Message::Binary`
    - `handle_socket` 函数：处理 `Message::Binary` 接收，使用 `rmp_serde::from_slice()` 反序列化
    - 移除 `BASE64.encode()` 和 `BASE64.decode()` 调用
    - 终端输出：直接发送 `Vec<u8>` 而不是 base64 编码
    - 文件读取：直接发送 `Vec<u8>` 而不是 base64 编码
    - 文件写入：直接接收 `Vec<u8>` 而不是 base64 解码
  - 移除 `use base64::...` 导入（如果不再需要）

  **Must NOT do**:
  - 不修改 `TerminalManager` 的会话管理逻辑
  - 不修改 `find_incomplete_escape_sequence` 函数
  - 不修改 PTY 读写逻辑

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 核心传输层改造，需要理解现有代码结构
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Sequential (Wave 2)
  - **Blocks**: Task 4, Task 7
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - `core/src/server/ws.rs:558-564` - 当前 `send_message` 函数实现
  - `core/src/server/ws.rs:476-514` - 当前 WebSocket 消息接收处理
  - `core/src/server/ws.rs:518-528` - 终端输出发送（BASE64.encode）
  - `core/src/server/ws.rs:597-626` - 终端输入处理（BASE64.decode）

  **API/Type References**:
  - `core/src/server/ws.rs:500-501` - `Message::Binary` 处理（当前只是警告）
  - rmp_serde API: `to_vec()`, `from_slice()`

  **External References**:
  - axum WebSocket: https://docs.rs/axum/latest/axum/extract/ws/enum.Message.html
  - rmp-serde: https://docs.rs/rmp-serde

  **WHY Each Reference Matters**:
  - `ws.rs:558-564` 是发送消息的唯一出口，需要改为二进制
  - `ws.rs:476-514` 是消息接收的主循环，需要处理二进制帧
  - 理解当前的 base64 使用位置才能正确移除

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Rust 项目编译成功
    Tool: Bash
    Preconditions: 代码修改完成
    Steps:
      1. cd core && cargo build --release
      2. Assert: 编译无错误
    Expected Result: Build succeeds
    Evidence: Build output

  Scenario: 无 base64 编码调用
    Tool: Bash (grep)
    Preconditions: ws.rs 已修改
    Steps:
      1. grep -n "BASE64.encode" core/src/server/ws.rs
      2. Assert: 无匹配结果
    Expected Result: No matches
    Evidence: grep output (empty)

  Scenario: 无 base64 解码调用
    Tool: Bash (grep)
    Preconditions: ws.rs 已修改
    Steps:
      1. grep -n "BASE64.decode" core/src/server/ws.rs
      2. Assert: 无匹配结果
    Expected Result: No matches
    Evidence: grep output (empty)

  Scenario: 使用 Message::Binary 发送
    Tool: Bash (grep)
    Preconditions: ws.rs 已修改
    Steps:
      1. grep -n "Message::Binary" core/src/server/ws.rs
      2. Assert: 有匹配结果
    Expected Result: Matches found
    Evidence: grep output
  ```

  **Commit**: YES
  - Message: `refactor(server): implement binary WebSocket transport with MessagePack`
  - Files: `core/src/server/ws.rs`
  - Pre-commit: `cd core && cargo build`

---

- [x] 4. JavaScript 客户端二进制接收改造

  **What to do**:
  - 修改 `app/TidyFlow/Web/main/state.js`：
    - `WebSocketTransport` 类：设置 `ws.binaryType = 'arraybuffer'`
    - `onmessage` 处理：检测 `e.data` 类型，如果是 `ArrayBuffer` 则用 MessagePack 解码
    - 移除 `decodeBase64` 函数的使用（但保留函数定义以备将来）
  - 修改 `app/TidyFlow/Web/main/messages.js`：
    - `handleMessage` 函数：接收解码后的 JavaScript 对象而非 JSON 字符串
    - 终端输出处理：`msg.data` 是 `Uint8Array`，直接写入 xterm
  - 修改 `app/TidyFlow/Web/main/tabs.js`：
    - 文件内容处理：`msg.content` 是 `Uint8Array`，用 TextDecoder 转字符串

  **Must NOT do**:
  - 不修改终端渲染逻辑（xterm.js 配置）
  - 不修改文件编辑器逻辑（CodeMirror 配置）

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 核心传输层改造，多个文件联动
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Sequential (Wave 2, after Task 3)
  - **Blocks**: Task 5, Task 7
  - **Blocked By**: Task 2, Task 3

  **References**:

  **Pattern References**:
  - `app/TidyFlow/Web/main/state.js:25-53` - WebSocketTransport 类实现
  - `app/TidyFlow/Web/main/state.js:63-70` - decodeBase64 函数
  - `app/TidyFlow/Web/main/messages.js:9-11` - handleMessage 入口

  **API/Type References**:
  - `app/TidyFlow/Web/main/messages.js:32-58` - 终端输出处理（使用 decodeBase64）
  - `app/TidyFlow/Web/main/messages.js:221-267` - 文件读取结果处理

  **External References**:
  - WebSocket binaryType: https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/binaryType
  - MessagePack.decode: https://github.com/msgpack/msgpack-javascript#usage

  **WHY Each Reference Matters**:
  - `state.js` 的 WebSocketTransport 是接收消息的入口
  - `messages.js` 的 handleMessage 负责分发消息到各处理器
  - 需要理解 decodeBase64 的所有使用位置

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: WebSocket 设置 binaryType
    Tool: Bash (grep)
    Preconditions: state.js 已修改
    Steps:
      1. grep "binaryType" app/TidyFlow/Web/main/state.js
      2. Assert: 输出包含 "arraybuffer"
    Expected Result: binaryType = arraybuffer
    Evidence: grep output

  Scenario: 使用 MessagePack 解码
    Tool: Bash (grep)
    Preconditions: state.js 或 messages.js 已修改
    Steps:
      1. grep -r "MessagePack\|msgpack\|decode" app/TidyFlow/Web/main/
      2. Assert: 有 MessagePack 解码调用
    Expected Result: MessagePack decode found
    Evidence: grep output

  Scenario: 无 decodeBase64 调用处理终端输出
    Tool: Bash (grep)
    Preconditions: messages.js 已修改
    Steps:
      1. grep "decodeBase64" app/TidyFlow/Web/main/messages.js
      2. Assert: 无匹配结果（或仅保留定义）
    Expected Result: No calls to decodeBase64
    Evidence: grep output
  ```

  **Commit**: YES
  - Message: `refactor(web): implement binary WebSocket message receiving`
  - Files: `app/TidyFlow/Web/main/state.js`, `app/TidyFlow/Web/main/messages.js`
  - Pre-commit: None (需要 Task 5 完成后才能完整测试)

---

- [x] 5. JavaScript 客户端二进制发送改造

  **What to do**:
  - 修改 `app/TidyFlow/Web/main/state.js`：
    - `WebSocketTransport.send()`: 接受对象，使用 MessagePack 编码后发送二进制
  - 修改 `app/TidyFlow/Web/main/tabs.js`：
    - 终端输入发送：移除 `encodeBase64`，直接发送 `Uint8Array`
    - 文件保存：移除 `encodeBase64`，直接发送 `Uint8Array`
  - 修改 `app/TidyFlow/Web/main/control.js`：
    - 所有 `TF.transport.send(JSON.stringify(...))` 改为 `TF.transport.send({...})`

  **Must NOT do**:
  - 不修改消息的业务逻辑
  - 不修改 IME 输入处理逻辑

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
    - Reason: 发送端改造相对简单，模式统一
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Sequential (Wave 3)
  - **Blocks**: Task 7
  - **Blocked By**: Task 4

  **References**:

  **Pattern References**:
  - `app/TidyFlow/Web/main/tabs.js:389-397` - 终端输入发送（使用 encodeBase64）
  - `app/TidyFlow/Web/main/tabs.js:262-266` - 备用输入发送
  - `app/TidyFlow/Web/main/tabs.js:295-301` - composition 输入发送

  **API/Type References**:
  - `app/TidyFlow/Web/main/control.js:1-150` - 控制消息发送（多处 JSON.stringify）

  **External References**:
  - MessagePack.encode: https://github.com/msgpack/msgpack-javascript#usage

  **WHY Each Reference Matters**:
  - `tabs.js` 的三处终端输入发送都需要修改
  - `control.js` 有大量控制消息发送

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: 无 encodeBase64 调用发送终端输入
    Tool: Bash (grep)
    Preconditions: tabs.js 已修改
    Steps:
      1. grep "encodeBase64" app/TidyFlow/Web/main/tabs.js
      2. Assert: 无匹配结果（或仅保留定义）
    Expected Result: No calls to encodeBase64
    Evidence: grep output

  Scenario: 无 JSON.stringify 发送消息
    Tool: Bash (grep)
    Preconditions: control.js 已修改
    Steps:
      1. grep "JSON.stringify" app/TidyFlow/Web/main/control.js
      2. Assert: 无匹配结果
    Expected Result: No JSON.stringify calls
    Evidence: grep output

  Scenario: 使用 MessagePack 编码发送
    Tool: Bash (grep)
    Preconditions: state.js 已修改
    Steps:
      1. grep -n "MessagePack.encode\|msgpack.encode" app/TidyFlow/Web/main/
      2. Assert: 有编码调用
    Expected Result: MessagePack encode found
    Evidence: grep output
  ```

  **Commit**: YES
  - Message: `refactor(web): implement binary WebSocket message sending`
  - Files: `app/TidyFlow/Web/main/state.js`, `app/TidyFlow/Web/main/tabs.js`, `app/TidyFlow/Web/main/control.js`
  - Pre-commit: None

---

- [x] 6. 更新协议文档和版本号

  **What to do**:
  - 修改 `docs/design/12-ws-control-protocol.md`：
    - 更新 Protocol Version 为 2
    - 说明消息格式从 JSON text frame 改为 MessagePack binary frame
    - 移除所有 `data_b64` 和 `content_b64` 的描述
    - 添加二进制字段 `data` 和 `content` 的说明
    - 更新示例消息格式

  **Must NOT do**:
  - 不修改协议的业务语义描述
  - 不添加新的消息类型

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: 文档更新任务
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Task 5)
  - **Blocks**: Task 7
  - **Blocked By**: Task 3

  **References**:

  **Documentation References**:
  - `docs/design/12-ws-control-protocol.md` - 当前协议文档

  **WHY Each Reference Matters**:
  - 协议文档是唯一需要更新的设计文档

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: 协议版本已更新
    Tool: Bash (grep)
    Preconditions: 文档已修改
    Steps:
      1. grep -i "version" docs/design/12-ws-control-protocol.md | head -5
      2. Assert: 输出包含 "2" 或 "v2"
    Expected Result: Version 2 mentioned
    Evidence: grep output

  Scenario: 无 base64 引用
    Tool: Bash (grep)
    Preconditions: 文档已修改
    Steps:
      1. grep -i "base64\|data_b64\|content_b64" docs/design/12-ws-control-protocol.md
      2. Assert: 无匹配或仅在历史变更说明中
    Expected Result: No base64 references in current spec
    Evidence: grep output

  Scenario: MessagePack 说明存在
    Tool: Bash (grep)
    Preconditions: 文档已修改
    Steps:
      1. grep -i "messagepack\|binary" docs/design/12-ws-control-protocol.md
      2. Assert: 有相关说明
    Expected Result: MessagePack/binary mentioned
    Evidence: grep output
  ```

  **Commit**: YES
  - Message: `docs(protocol): update WebSocket protocol to v2 with binary transport`
  - Files: `docs/design/12-ws-control-protocol.md`
  - Pre-commit: None

---

- [x] 7. 端到端验证和清理

  **What to do**:
  - 运行应用进行端到端验证：
    - 启动 Rust Core 和 macOS App
    - 测试终端输入输出
    - 测试文件打开和保存
    - 测试中文输入
    - 测试 TUI 应用（如 vim）
  - 清理不再需要的代码：
    - 如果 `state.js` 的 `encodeBase64/decodeBase64` 不再使用，可以移除
    - 如果 `ws.rs` 的 base64 导入不再需要，可以移除

  **Must NOT do**:
  - 不删除可能被其他地方使用的函数
  - 不修改通过测试的功能代码

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 验证和清理任务
  - **Skills**: [`playwright`]
    - `playwright`: 用于端到端 UI 测试

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Sequential (Wave 4, final)
  - **Blocks**: None
  - **Blocked By**: Task 3, 4, 5, 6

  **References**:

  **Test References**:
  - `scripts/smoke-test.sh` - 现有的 smoke test 脚本

  **WHY Each Reference Matters**:
  - smoke-test.sh 可以作为验证的参考

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Rust Core 启动成功
    Tool: Bash
    Preconditions: 代码编译完成
    Steps:
      1. cd core && timeout 5 cargo run || true
      2. Assert: 输出包含 "Listening on ws://"
    Expected Result: Server starts
    Evidence: stdout captured

  Scenario: 终端输入输出正常
    Tool: Playwright (playwright skill)
    Preconditions: App running
    Steps:
      1. 打开 TidyFlow 应用
      2. 等待终端加载
      3. 输入: echo "hello world"
      4. 按 Enter
      5. 等待输出
      6. Assert: 屏幕包含 "hello world"
      7. Screenshot: .sisyphus/evidence/task-7-terminal-io.png
    Expected Result: Terminal I/O works
    Evidence: .sisyphus/evidence/task-7-terminal-io.png

  Scenario: 中文输入显示正常
    Tool: Playwright (playwright skill)
    Preconditions: App running, terminal ready
    Steps:
      1. 输入: echo "你好世界"
      2. 按 Enter
      3. 等待输出
      4. Assert: 屏幕包含 "你好世界"
      5. Screenshot: .sisyphus/evidence/task-7-chinese-io.png
    Expected Result: Chinese text displays correctly
    Evidence: .sisyphus/evidence/task-7-chinese-io.png

  Scenario: 文件读写正常
    Tool: Playwright (playwright skill)
    Preconditions: App running
    Steps:
      1. 通过 Command Palette 打开文件
      2. 选择一个测试文件
      3. 等待文件内容加载
      4. Assert: 编辑器显示文件内容
      5. 修改内容
      6. 按 Cmd+S 保存
      7. Assert: 无错误提示
      8. Screenshot: .sisyphus/evidence/task-7-file-rw.png
    Expected Result: File read/write works
    Evidence: .sisyphus/evidence/task-7-file-rw.png
  ```

  **Commit**: YES (if cleanup done)
  - Message: `chore: remove unused base64 encoding functions`
  - Files: (cleanup files if any)
  - Pre-commit: `cd core && cargo build`

---

## Commit Strategy

| After Task | Message | Files | Verification |
|------------|---------|-------|--------------|
| 1 | `refactor(protocol): switch to MessagePack binary encoding` | `core/Cargo.toml`, `core/src/server/protocol.rs` | `cargo build` |
| 2 | `feat(web): add MessagePack JavaScript library` | `vendor/msgpack.min.js`, `index.html` | file exists |
| 3 | `refactor(server): implement binary WebSocket transport with MessagePack` | `core/src/server/ws.rs` | `cargo build` |
| 4 | `refactor(web): implement binary WebSocket message receiving` | `state.js`, `messages.js` | N/A |
| 5 | `refactor(web): implement binary WebSocket message sending` | `state.js`, `tabs.js`, `control.js` | N/A |
| 6 | `docs(protocol): update WebSocket protocol to v2 with binary transport` | `12-ws-control-protocol.md` | N/A |
| 7 | `chore: remove unused base64 encoding functions` | (cleanup) | end-to-end test |

---

## Success Criteria

### Verification Commands
```bash
# Rust 编译
cd core && cargo build --release
# Expected: 无错误

# 无 base64 残留（服务端）
grep -r "BASE64\|base64" core/src/server/ws.rs
# Expected: 无匹配（或仅在注释中）

# 协议版本
grep "PROTOCOL_VERSION" core/src/server/protocol.rs
# Expected: 包含 "2"
```

### Final Checklist
- [x] Rust Core 编译无错误
- [x] 终端输入输出正常
- [x] 文件读写正常
- [x] 中文输入显示正常
- [x] TUI 应用正常运行
- [x] 无 base64 编解码调用残留
- [x] 协议文档已更新
