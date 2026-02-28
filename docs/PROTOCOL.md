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

## AI 会话配置选项（ACP `session-config-options`）

- 客户端请求 action：
  - `ai_session_config_options`：拉取当前工具/会话可用的配置项列表。
  - `ai_session_set_config_option`：按 `option_id` 设置单个会话配置项。
- 服务端结果/事件 action：
  - `ai_session_config_options`：结果与事件复用同一个 action，`payload.options` 为配置项列表。
- AI 发送请求字段：
  - `ai_chat_send`、`ai_chat_command` 新增可选 `config_overrides`（`option_id -> value`），用于“仅本次发送”覆盖。
  - `ai_chat_send`、`ai_chat_command` 新增可选 `audio_parts`（`[{ filename, mime, data(bytes) }]`）。
- 会话选择提示字段：
  - `selection_hint` 新增 `config_options`，用于恢复 `mode/model/thought_level` 等配置状态。

## ACP Slash Commands（`slash-commands`）

- 客户端请求 action：
  - `ai_slash_commands`：拉取斜杠命令列表，支持可选 `session_id`（会话维度）。
- 服务端结果 action：
  - `ai_slash_commands`：一次性返回当前可用命令；`payload.session_id` 可选。
- 服务端增量事件 action：
  - `ai_slash_commands_update`：实时推送命令列表更新；包含 `session_id` 与完整 `commands` 数组。
- 命令字段：
  - `name`、`description`、`action`、`input_hint`（可选，来自 ACP `input.hint`）。
- ACP `session/update` 兼容解析：
  - 更新 token 同时支持 `available_commands_update` / `availableCommandsUpdate` 等常见变体。
  - 命令列表同时支持 `availableCommands`、`available_commands`、`content.availableCommands`（含 `commands` 兼容键）。
  - 命令名按大小写不敏感去重，后出现覆盖先出现。
  - 非法命令项仅告警并跳过，不中断会话流。
- 缓存与回退：
  - Core 按 `directory + session_id` 优先缓存命令；
  - 会话命令缺失时回退到目录级命令。
- 兼容策略：
  - 保留 `ai_slash_commands` 一次性拉取接口；
  - 不支持增量推送的后端仍可正常使用（前端继续使用拉取结果）；
  - `/new` 作为本地命令保留，始终可用。

## 双栈兼容策略（锁定）

- 优先级固定为：
  - `configOptions + session/set_config_option`
  - `session/set_mode + prompt.mode`（旧协议回退）
  - `prompt.model`（更旧回退）
- 兼容保留字段：
  - `agent/mode`、`model` 继续保留，不做破坏性移除。
- `session/update` token 兼容：
  - 同时接受 `config_option_update` 与 `config_options_update`。
- 非 ACP 工具：
  - 可忽略 `config_overrides`，保持原行为不变。
  - `audio_parts` 统一降级为文本摘要，不中断请求。

## ACP `content` 协议双栈（完整）

- 能力协商来源：
  - 新协议：`agentCapabilities.promptCapabilities.{image,audio,embeddedContext}`（布尔）。
  - 旧协议：`promptCapabilities.contentTypes`。
- 归一化后基线能力恒包含：
  - `text`
  - `resource_link`
- 编码模式：
  - `New`：检测到新协议布尔能力。
  - `Legacy`：仅检测到旧 `contentTypes`。
  - `Unknown`：两者都缺失（按 Legacy 编码）。
- 出站内容块支持：
  - `text`、`image`、`audio`、`resource`、`resource_link`
  - `image/audio`：
    - `New`：`{ type, mimeType, data(base64) }`
    - `Legacy/Unknown`：`{ type, mimeType, url(data:...) }`
  - `resource_link`：
    - `New`：顶层 `uri/name(/mimeType)`
    - `Legacy/Unknown`：嵌套 `resource.uri/resource.name`
- `file_refs` 嵌入策略：
  - 优先 `resource`（要求能力含 `embeddedContext` -> 归一化为 `resource`）。
  - 文本文件（UTF-8）`<= 256KB`：`resource.text`
  - 二进制文件 `<= 1MB`：`resource.blob(base64)`
  - 读取失败或超限：降级 `resource_link`，若不支持再降级文本提示块。
  - MIME 来源：扩展名推断，保底 `application/octet-stream`。
- 附件顺序（固定）：
  - 用户文本 -> `resource/resource_link` -> `image` -> `audio`
- 入站解析（流式 + 历史统一）：
  - `image(data/url)`、`audio(data/url)`、`resource(text/blob)`、`resource_link(新旧两种结构)`。
  - `resource.text` 映射为 `text` part。
  - `blob/image/audio/resource_link` 映射为 `file` part。
  - `annotations` 与原始 `content` 放入 part `source` 透传。

## UI 首版约束

- 首版界面只展示三类 category：
  - `mode`
  - `model`
  - `thought_level`
- 其他 category 不直接展示，但会在 Core/App 里保存并透传。

## 调试建议

- 先确认双方都使用 `MessagePack`，避免把 JSON 文本发到 v3 通道。
- 协议字段变更后，同步更新：
  - `core/src/server/protocol/mod.rs`
  - `app/TidyFlow/Networking/ProtocolModels.swift`
  - 对应 handler 与 UI 调用方
