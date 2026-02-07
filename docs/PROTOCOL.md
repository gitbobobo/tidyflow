# TidyFlow Protocol v2

本文档描述 TidyFlow App 与 Rust Core 之间的通信约定。

## 传输层

- 通道：`WebSocket`
- 默认地址：`ws://127.0.0.1:47999`
- 编码：`MessagePack`（二进制）
- 协议版本常量：`core/src/server/protocol.rs` 中 `PROTOCOL_VERSION = 2`

## 消息模型

- 客户端消息：`ClientMessage`
- 服务端消息：`ServerMessage`
- 定义位置：`core/src/server/protocol.rs`

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
  - `core/src/server/protocol.rs`
  - `app/TidyFlow/Networking/ProtocolModels.swift`
  - 对应 handler 与 UI 调用方
