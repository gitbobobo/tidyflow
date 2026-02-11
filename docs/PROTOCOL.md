# TidyFlow Protocol v2

本文档描述 TidyFlow 客户端（macOS / iOS）与 Rust Core 之间的通信约定。

## 传输层

- 实时通道：`WebSocket`（`/ws`）
- 配对控制通道：`HTTP`（`/pair/*`）
- 默认监听地址：`127.0.0.1:47999`
- 可通过 `TIDYFLOW_BIND_ADDR` 切换监听地址（例如 `0.0.0.0` 以支持局域网客户端）
- WebSocket 编码：`MessagePack`（二进制）
- 配对 HTTP 编码：`JSON`
- 协议版本常量：`core/src/server/protocol/mod.rs` 中 `PROTOCOL_VERSION = 2`

## 消息模型

- 客户端消息：`ClientMessage`
- 服务端消息：`ServerMessage`
- 定义位置：`core/src/server/protocol/mod.rs`

## 远程配对（pairing_v1）

- 能力标识：`pairing_v1`
- 端点：
  - `POST /pair/start`：生成 6 位配对码（仅 loopback 请求允许）
  - `POST /pair/exchange`：移动端使用配对码换取短期 `ws_token`
  - `POST /pair/revoke`：吊销已签发 token（仅 loopback 请求允许）
- 鉴权规则：
  - 启用 `TIDYFLOW_WS_TOKEN` 时，`/ws` 需携带 `token` 查询参数
  - `token` 可为启动 token，或 `/pair/exchange` 返回的配对 token
  - 配对 token 过期后不可继续用于连接

## 兼容策略

- 保留基础终端数据面消息（如 `input`、`resize`、`output`）以维持旧行为兼容。
- 新能力按功能版本递增（当前到 `v1.25`），不回退 `v2` 编码格式。

## 主要能力范围

- 终端生命周期管理（创建、输入、缩放、关闭、聚焦）
- 项目/工作区管理（导入、创建、切换、删除）
- 文件能力（列表、读取、写入、索引、重命名、删除、复制、移动）
- Git 能力（状态、diff、stage/unstage、commit、branch、rebase、merge、log、show）
- 客户端设置同步与文件系统监听

## 调试建议

- 先确认双方都使用 `MessagePack`，避免把 JSON 文本发到 v2 通道。
- 协议字段变更后，同步更新：
  - `core/src/server/protocol/mod.rs`
  - `app/TidyFlow/Networking/ProtocolModels.swift`
  - 对应 handler 与 UI 调用方
