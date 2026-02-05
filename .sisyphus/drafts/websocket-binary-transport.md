# Draft: WebSocket Base64 改二进制传输

## 现状分析

### Base64 使用位置

**1. 终端 I/O（高频）**
- Rust 服务端 (`core/src/server/ws.rs`)
  - 发送终端输出: `BASE64.encode(&output)` → `ServerMessage::Output { data_b64 }`
  - 接收终端输入: `BASE64.decode(&data_b64)` ← `ClientMessage::Input { data_b64 }`
- JavaScript 客户端 (`app/TidyFlow/Web/main/tabs.js`, `state.js`)
  - 发送输入: `encodeBase64(bytes)` → `btoa(binary)`
  - 接收输出: `decodeBase64(base64)` → `atob(base64)`

**2. 文件操作（中频）**
- 文件读取: `FileReadResult { content_b64 }`
- 文件写入: `FileWrite { content_b64 }`

### 当前协议结构

```
所有消息 = JSON text frame
├── 控制消息: { type: "...", ... }
├── 终端数据: { type: "input/output", data_b64: "..." }
└── 文件数据: { type: "file_read/write", content_b64: "..." }
```

### Base64 开销

- 编码膨胀: 原始数据 * 4/3 ≈ 33% 额外开销
- CPU 开销: 每次编解码都需要遍历字节
- 高频终端 I/O 最受影响

## 技术决策点（待确认）

### 1. 混合模式 vs 纯二进制

**选项 A: 混合模式（推荐）**
- 控制消息保持 JSON text frame
- 仅数据负载（终端 I/O、文件内容）使用 binary frame
- 优点：向后兼容，渐进式改造
- 缺点：需要消息类型识别逻辑

**选项 B: 纯二进制**
- 所有消息都用二进制帧
- 优点：统一处理
- 缺点：调试困难，需要完整协议改造

### 2. 二进制帧格式

需要定义帧头来区分消息类型：

```
选项 A: 简单前缀
[1 byte: type][N bytes: payload]
type = 0x01 终端输出, 0x02 终端输入, 0x03 文件数据

选项 B: 完整帧头
[4 bytes: magic][2 bytes: type][4 bytes: length][N bytes: payload]
```

### 3. term_id 传递

当前终端数据带 term_id：
```json
{"type":"input","term_id":"xxx","data_b64":"..."}
```

二进制传输需要在帧头包含 term_id 或使用其他机制。

## 影响范围

### Rust Core 改动
- `ws.rs`: 发送/接收二进制 WebSocket 帧
- `protocol.rs`: 可能需要新的消息类型或保持不变

### JavaScript 改动
- `state.js`: WebSocketTransport 处理二进制消息
- `tabs.js`: 发送输入时使用二进制
- `messages.js`: 处理接收的二进制输出

### Swift 改动
- `WSClient.swift`: 当前不直接处理终端数据（通过 WebView 的 JavaScript 处理）
- 可能无需改动

## 用户决策（已确认）

1. **改造范围**: 终端 I/O + 文件操作都改成二进制
2. **向后兼容**: 不需要，直接切换
3. **帧格式**: 按最佳实践设计

## 开放问题（待确认）

1. 是否需要压缩？（终端数据通常已经很小）
