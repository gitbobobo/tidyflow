# TidyFlow Protocol v6

本文档描述 TidyFlow 客户端（macOS / iOS）与 Rust Core 之间的通信约定。

## 传输层

- 实时通道：`WebSocket`（`/ws`）
- 配对控制通道：`HTTP`（`/pair/*`）
- 默认监听地址：`127.0.0.1:47999`（安全默认）
- 可通过 `TIDYFLOW_BIND_ADDR` 切换监听地址（例如 `0.0.0.0` 以支持局域网客户端）
- WebSocket 编码：`MessagePack`（二进制）
- 配对 HTTP 编码：`JSON`
- 协议版本常量：`core/src/server/protocol/mod.rs` 中 `PROTOCOL_VERSION = 6`
- 协议 schema 权威源：`schema/protocol/v6/`

## 消息模型（v6 包络）

- 客户端请求：
- `ClientEnvelopeV6 { request_id, domain, action, payload, client_ts }`
- 服务端响应/事件：
  - `ServerEnvelopeV6 { request_id?, seq, domain, action, kind, payload, server_ts }`
  - `kind`：`result` / `event` / `error`
- 业务消息体仍由 `ClientMessage` / `ServerMessage` 定义并映射到 `action + payload`
- 定义位置：`core/src/server/protocol/mod.rs`

## 远程配对（pairing_v1）

- 能力标识：`pairing_v1`
- 端点：
  - `POST /pair/start`：生成 6 位配对码（仅 loopback 请求允许）
  - `POST /pair/exchange`：移动端使用配对码换取短期 `ws_token`
  - `POST /pair/revoke`：吊销已签发 token（仅 loopback 请求允许）
- 鉴权规则：
  - 当监听地址为非 loopback（例如 `0.0.0.0`）或设置了 `TIDYFLOW_WS_TOKEN` 时，`/ws` 需携带 `token` 查询参数；
  - `token` 可为启动 token，或 `/pair/exchange` 返回的配对 token；
  - `/pair/start` 与 `/pair/revoke` 仍仅允许 loopback 请求；
  - 配对 token 过期后不可继续用于连接；
  - 未携带 token 的远程连接将返回 `401 Unauthorized`。

## 客户端设置扩展字段

- `ClientSettingsResult` 新增 `remote_access_enabled`（`bool`），用于在 macOS 端展示局域网连接状态；
- `SaveClientSettings` 请求新增 `remote_access_enabled`（`bool`），用于持久化用户在设置页的远程访问开关。

## 兼容策略

- 本版本不向后兼容 v5。
- 客户端必须发送 v6 包络；服务端统一返回 v6 包络。

## 主要能力范围

- 终端生命周期管理（创建、输入、缩放、关闭、聚焦）
- 项目/工作区管理（导入、创建、切换、删除）
- 文件能力（列表、读取、写入、索引、重命名、删除、复制、移动）
- Git 能力（状态、diff、stage/unstage、commit、branch、rebase、merge、log、show）
- 客户端设置同步与文件系统监听

## 调试建议

- 先确认双方都使用 `MessagePack`，避免把 JSON 文本发到 v3 通道。
- 协议字段变更后，同步更新：
  - `core/src/server/protocol/mod.rs`
  - `app/TidyFlow/Networking/ProtocolModels.swift`
  - 对应 handler 与 UI 调用方
