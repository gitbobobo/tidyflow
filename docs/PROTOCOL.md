# TidyFlow Protocol v7

本文档描述 TidyFlow 客户端（macOS / iOS）与 Rust Core 之间的通信约定。

## 传输层

- 实时写入与推送通道：`WebSocket`（`/ws`）
- 读取通道：`HTTP`（`/api/v1/*`）
- 配对控制通道：`HTTP`（`/pair/*`）
- 默认监听地址：`127.0.0.1:47999`（安全默认）
- 可通过 `TIDYFLOW_BIND_ADDR` 切换监听地址（例如 `0.0.0.0` 以支持局域网客户端）
- WebSocket 编码：`MessagePack`（二进制）
- 配对 HTTP 编码：`JSON`
- 协议版本常量：`core/src/server/protocol/mod.rs` 中 `PROTOCOL_VERSION = 7`
- 协议 schema 权威源：`schema/protocol/v7/`

## 消息模型（v7 包络，结构沿用 v6）

- 客户端请求：
- `ClientEnvelopeV6 { request_id, domain, action, payload, client_ts }`
- 服务端响应/事件：
  - `ServerEnvelopeV6 { request_id?, seq, domain, action, kind, payload, server_ts }`
  - `kind`：`result` / `event` / `error`
- 业务消息体仍由 `ClientMessage` / `ServerMessage` 定义并映射到 `action + payload`
- 定义位置：`core/src/server/protocol/mod.rs`

## Core 启动 Bootstrap（stdout）

- Core 监听成功后会输出一行：`TIDYFLOW_BOOTSTRAP {json}`
- `json` 字段：
  - `port`
  - `bind_addr`
  - `fixed_port`
  - `remote_access_enabled`
  - `protocol_version`
  - `core_version`

## 远程配对（pairing_v1）

- 能力标识：`pairing_v1`
- 端点：
  - `POST /pair/start`：生成 6 位配对码（仅 loopback 请求允许）
  - `POST /pair/exchange`：移动端使用配对码换取短期 `ws_token`
  - `POST /pair/revoke`：吊销已签发 token（仅 loopback 请求允许）
- 鉴权规则：
  - 当监听地址为非 loopback（例如 `0.0.0.0`）或设置了 `TIDYFLOW_WS_TOKEN` 时，`/ws` 需携带 `token` 查询参数；
  - `/api/v1/*` 在相同条件下也必须鉴权，支持 `Authorization: Bearer <token>`，并兼容 `?token=<token>`；
  - 例外：`GET /api/v1/system/snapshot` 为公开只读端点，始终免鉴权；
  - `token` 可为启动 token，或 `/pair/exchange` 返回的配对 token；
  - `/pair/start` 与 `/pair/revoke` 仍仅允许 loopback 请求；
  - 配对 token 过期后不可继续用于连接；
  - 未携带 token 的远程连接将返回 `401 Unauthorized`。

## 读取 API（`/api/v1`）

- AI：
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/sessions`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/sessions/:session_id/messages`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/sessions/:session_id/status`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/providers`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/agents`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/slash-commands`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/session-config-options`
- Evolution：
  - `GET /api/v1/evolution/snapshot`
  - `GET /api/v1/evolution/projects/:project/workspaces/:workspace/agent-profile`
  - `GET /api/v1/evolution/projects/:project/workspaces/:workspace/cycle-history`
  - Evolution 快照与循环历史不再返回 `handoff` 字段；计划文档请直接读取循环目录下的 `plan.md`
  - Evolution 运行时 `stage` 支持动态实例名，例如 `implement.general.1`、`implement.visual.2`、`verify.1`、`reimplement.1`
  - 当前循环的真实 AI 会话 ID 通过 `evo_cycle_updated.executions` 实时下发；前端应直接消费 execution 记录而不是再按 stage 发起读取查询
- Evidence：
  - `GET /api/v1/evidence/projects/:project/workspaces/:workspace/snapshot`
  - `GET /api/v1/evidence/projects/:project/workspaces/:workspace/rebuild-prompt`
  - `GET /api/v1/evidence/projects/:project/workspaces/:workspace/items/:item_id/chunk`
- System：
  - `GET /api/v1/system/snapshot`

## 系统快照（`/api/v1/system/snapshot`）

- 接口：
  - `GET /api/v1/system/snapshot`
- 鉴权：
  - 不需要 `Authorization` 或 `token` 查询参数（全场景免鉴权）。
- 响应字段：
  - `type`: 固定为 `system_snapshot`
  - `core_version`: Core 语义版本（来自 `env!("CARGO_PKG_VERSION")`）
  - `protocol_version`: 协议版本常量（`PROTOCOL_VERSION`）
  - `workspace_items`: 全量工作空间（含 `default`），按 `(project, workspace)` 升序
- `workspace_items` 字段：
  - `project`
  - `workspace`
  - `path`
  - `branch`
  - `workspace_status`（见下方工作区生命周期状态说明）
  - `evolution_status`（无运行态记录时为 `not_started`）
  - `evolution_cycle_id`（无循环时为 `null`）
  - `title`（有循环且已生成标题时有值，否则为 `null`）
  - `failure_reason`（失败原因汇总，无失败时为 `null`；优先级：`terminal_error_message` > `rate_limit_error_message` > `terminal_reason_code`）

## 项目与工作区生命周期

### 工作区列表（`list_workspaces`）

- 请求：`{ type: "list_workspaces", project: "<name>" }`
- 响应：`{ type: "workspaces", project: "<name>", items: [...] }`
- 每个 `items` 条目的字段：`name`、`root`、`branch`、`status`、`sidebar_status`
- Core 在每个项目的工作区列表最前方注入一个虚拟 `default` 工作区（`status: "ready"`），
  指向项目根目录，不存储在 Core 状态中，无需客户端本地生成。
- 多项目场景下每个项目独立发送 `list_workspaces`，响应中的 `project` 字段是归属标识。

### 工作区生命周期状态（`workspace_status`）

| 状态值 | 含义 | 可操作性 |
|--------|------|----------|
| `ready` | 完全就绪 | 可使用 |
| `creating` | git worktree 已创建，等待 setup | 不可使用 |
| `initializing` | setup 脚本执行中 | 不可使用 |
| `setup_failed` | setup 失败，需手动修复 | 有限操作 |
| `destroying` | 标记删除中 | 不可使用 |

`default` 虚拟工作区的 `workspace_status` 始终为 `ready`，不随项目状态变化。

### 多项目/多工作区消费约束

- 客户端**必须**通过 `(project, workspace)` 二元组唯一标识一个工作区，
  不允许仅用 `workspace` 名称作为缓存键（同名工作区在不同项目下是相互独立的）。
- `list_workspaces` 响应的 `project` 字段是权威归属；
  收到工作区列表时，只更新与 `project` 对应的缓存桶，不得污染其他项目的工作区状态。
- 文件树订阅（`watch_subscribe`/`watch_unsubscribe`）和文件变更事件（`file_changed`）
  均携带 `project`/`workspace`，客户端必须用这两个字段路由到正确的缓存桶。

## WS 读取动作移除

- 以下 WS action 不再提供读取能力，服务端返回：`Error { code: "read_via_http_required" }`
  - AI：`ai_session_list` `ai_session_messages` `ai_session_status` `ai_provider_list` `ai_agent_list` `ai_slash_commands` `ai_session_config_options`
  - Evolution：`evo_get_snapshot` `evo_get_agent_profile` `evo_list_cycle_history`
  - Evidence：`evidence_get_snapshot` `evidence_get_rebuild_prompt` `evidence_read_item`
- 保留：
  - AI 订阅控制：`ai_session_subscribe` `ai_session_unsubscribe`
  - AI/Evolution 实时推送事件
  - 所有写操作 action

## 客户端设置字段（v7）

- `SaveClientSettings` 与 `ClientSettingsResult` 不再包含 `app_language`。
- `app_language` 改为客户端本地偏好：
  - macOS 使用 `UserDefaults`
  - iOS 使用本地存储（不经 Core 同步）
- 保留并继续同步：
  - `custom_commands`
  - `workspace_shortcuts`
  - `merge_ai_agent`
  - `fixed_port`
  - `remote_access_enabled`

## 兼容策略

- 本版本不向后兼容 v6。
- 客户端必须发送 v7 包络；服务端统一返回 v7 包络。
- AI 聊天流式事件已硬切旧协议：
  - 已移除：`ai_chat_message_updated`、`ai_chat_part_updated`、`ai_chat_part_delta`
  - 仅保留：`ai_session_messages_update`（`messages` / `ops` / `cache_revision`）作为流式主链路
  - `ai_chat_done`、`ai_chat_error` 保留为终态控制事件，不承担 token 增量职责

## 主要能力范围

- 终端生命周期管理（创建、输入、缩放、关闭、聚焦）
- 项目/工作区管理（导入、创建、切换、删除）
- 文件能力（列表、读取、写入、索引、重命名、删除、复制、移动）
- Git 能力（状态、diff、stage/unstage、commit、branch、rebase、merge、log、show）
- 客户端设置同步与文件系统监听

## 共享 AI 会话语义层（客户端实现约束）

以下约束描述客户端如何统一处理 AI 会话标识与消息流，macOS 与 iOS 必须共享相同规则，不允许各自维护独立推导逻辑。

### 会话键格式（`sessionKey`）

每个 AI 会话由四元组唯一标识：

```
{project}::{workspace}::{ai_tool}::{session_id}
```

- 双冒号 `::` 作为分隔符。
- `ai_tool` 使用工具的 `rawValue`（如 `codex`、`claude`）。
- 会话键由 `AISessionSemantics.sessionKey(project:workspace:aiTool:sessionId:)` 统一生成，不允许各调用点自行拼接字符串。
- 该四元组默认兼容多项目、多工作区并行场景，不依赖单工作区单例状态。

### 列表可见性规则

- `origin=evolution_system` 的会话不出现在默认会话列表中（由自动化循环创建）。
- `origin=user`（或字段缺失时的默认值）的会话在默认列表中可见。
- 规则由 `AISessionSemantics.isSessionVisibleInDefaultList(origin:)` 统一判断，macOS/iOS 不各自判断。

### 消息流归一化链路

`ai_session_messages`（历史加载）与 `ai_session_messages_update`（流式快照分支）共用同一归一化入口：

```
AISessionSemantics.normalizeMessageStream(sessionId:messages:primarySelectionHint:)
```

归一化入口负责：

1. **Pending question 重建**：从 `messages` 中扫描 `tool_view.question` 字段，重建尚未回答的 `AIQuestionRequestInfo` 列表（`pendingQuestionRequests`）。
2. **Selection hint 合并**：协议层传入的 `selectionHint` 与消息内嵌 hint 按优先级合并为 `effectiveSelectionHint`，交给上层决定是否应用。
3. **多工作区边界**：归一化本身不感知当前激活的 project/workspace，调用方负责在调用前做四元组过滤，保证多工作区并行时不串数据。

`ai_session_messages_update` 的增量 ops 分支（`ev.ops != nil`）不经过此归一化入口；selection hint 更新仍走 `applyAISessionSelectionHint`。

### 双端消息处理路由

macOS 与 iOS 均通过 `AIMessageHandler` 协议的单一适配器接收所有 AI WS 事件：

- macOS：`AppStateAIMessageHandlerAdapter`（`AppState+CoreWS+MessageHandlers.swift`）
- iOS：`MobileAppStateAIMessageHandlerAdapter`（`MobileAppState.swift`）

适配器通过弱引用持有各自的 `AppState`/`MobileAppState`，由 `WSClient.aiMessageHandler` 统一分发，不再使用独立的 `wsClient.onAI*` 闭包。

## AI 会话列表分页（HTTP `.../sessions`）

- 客户端请求：
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/sessions`
  - `limit`：页大小（可选）
    - 缺省：`50`
    - `<= 0`：按 `50` 处理
    - `> 200`：按 `200` 处理
  - `cursor`：下一页游标（可选）
    - 服务端使用不透明游标
    - 游标无效时：服务端回退到第一页，不报错
  - `ai_tool`：工具筛选（可选）
    - 为空：返回当前工作区全部工具会话
    - 非空：仅返回指定工具会话
- 服务端结果 `type=ai_session_list`：
  - `filter_ai_tool`：本次实际使用的工具筛选（可选）
  - `sessions`：会话数组（按 `updated_at DESC, created_at DESC, ai_tool ASC, session_id ASC`，默认排除 `session_origin=evolution_system`）
  - `sessions[].ai_tool`：会话所属工具
  - `sessions[].session_origin`：会话来源，当前取值 `user | evolution_system`
  - `has_more`：是否还有下一页
  - `next_cursor`：下一页游标（用于继续向后加载）
  - 按 `session_id` 精确读取消息/状态不受列表过滤影响

### 请求示例（全部工具首屏）

```json
{
  "domain": "ai",
  "action": "ai_session_list",
  "payload": {
    "project_name": "demo",
    "workspace_name": "default",
    "limit": 50
  }
}
```

### 请求示例（单工具下一页）

```json
{
  "domain": "ai",
  "action": "ai_session_list",
  "payload": {
    "project_name": "demo",
    "workspace_name": "default",
    "ai_tool": "codex",
    "cursor": "opaque_cursor",
    "limit": 50
  }
}
```

### 响应示例

```json
{
  "action": "ai_session_list",
  "kind": "result",
  "payload": {
    "project_name": "demo",
    "workspace_name": "default",
    "filter_ai_tool": null,
    "sessions": [
      {
        "project_name": "demo",
        "workspace_name": "default",
        "ai_tool": "codex",
        "id": "ses_123",
        "title": "实现分页",
        "updated_at": 1730966400000,
        "session_origin": "user"
      }
    ],
    "has_more": true,
    "next_cursor": "opaque_cursor"
  }
}
```

## AI 会话历史分页（HTTP `.../messages`）

- 客户端请求：
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/sessions/:session_id/messages`
  - `limit`：页大小（可选）
    - 缺省：`50`
    - `<= 0`：按 `50` 处理
    - `> 200`：按 `200` 处理
  - `before_message_id`：向更旧历史翻页游标（可选）
    - 语义：返回严格早于该消息的历史片段（不含锚点消息本身）
    - 游标无效时：服务端回退到“最新一页”，不报错
- 服务端结果 `type=ai_session_messages`：
  - `before_message_id`：本次实际生效的游标（游标无效回退时为 `null`）
  - `messages`：消息数组（顺序固定为旧 -> 新）
  - `has_more`：是否还有更旧历史可翻页
  - `next_before_message_id`：下一页游标（用于继续向前翻页）
  - `selection_hint`：会话选择提示（可选）
  - `truncated`：是否因载荷限制发生裁剪（可选）

### 请求示例（首屏）

```json
{
  "domain": "ai",
  "action": "ai_session_messages",
  "payload": {
    "project_name": "demo",
    "workspace_name": "default",
    "ai_tool": "codex",
    "session_id": "ses_123",
    "limit": 50
  }
}
```

### 请求示例（加载更早消息）

```json
{
  "domain": "ai",
  "action": "ai_session_messages",
  "payload": {
    "project_name": "demo",
    "workspace_name": "default",
    "ai_tool": "codex",
    "session_id": "ses_123",
    "before_message_id": "msg_071",
    "limit": 50
  }
}
```

### 响应示例

```json
{
  "action": "ai_session_messages",
  "kind": "result",
  "payload": {
    "project_name": "demo",
    "workspace_name": "default",
    "ai_tool": "codex",
    "session_id": "ses_123",
    "before_message_id": "msg_071",
    "messages": [],
    "has_more": true,
    "next_before_message_id": "msg_021",
    "truncated": false
  }
}
```

## AI 会话配置选项（ACP `session-config-options`）

- 客户端请求：
  - 读取：`GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/session-config-options`
  - 写入：`ai_session_set_config_option`（WS action，按 `option_id` 设置单个会话配置项）
- 服务端结果/事件：
  - 读取返回 `type=ai_session_config_options`，`options` 为配置项列表。
  - 流式事件仍使用 `ai_session_config_options`。
- AI 发送请求字段：
  - `ai_chat_send`、`ai_chat_command` 新增可选 `config_overrides`（`option_id -> value`），用于“仅本次发送”覆盖。
  - `ai_chat_send`、`ai_chat_command` 新增可选 `audio_parts`（`[{ filename, mime, data(bytes) }]`）。
- 会话选择提示字段：
  - `selection_hint` 新增 `config_options`，用于恢复 `mode/model/thought_level` 等配置状态。

## ACP Slash Commands（`slash-commands`）

- 客户端读取：
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/slash-commands`
  - 支持可选 `session_id`（会话维度）。
- 服务端结果：
  - `type=ai_slash_commands`：一次性返回当前可用命令；`session_id` 可选。
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

## ACP `tool-calls`（完整对齐）

- 规范基线：
  - 以 ACP 官方 `tool-calls` 页面与 schema 为准（实现时采用同版本字段名与语义）。
- Core 解析策略：
  - `session/update`（流式）与 `session/load`（历史）共用同一组 normalized parser。
  - 支持 `tool_call` 首帧与 `tool_call_update` 增量，但对外协议不再透传原始 JSON。
  - 历史消息回放时，同一 `tool_call_id` 的多次更新（如 `running -> completed`）通过 `upsert_tool_part_in_history_messages` 原地更新，避免在历史消息列表中产生重复工具卡片。
  - 状态兼容归一化：
    - 交互态：`pending/running/awaiting_input/requires_input/in_progress`
    - 完成态：`completed/done/success`
    - 失败态：`error/failed/rejected/cancelled/canceled`
  - `content.type` 统一收敛为结构化 `tool_view.sections[].style`：
    - `text` / `code` / `diff` / `markdown` / `terminal`
- 对外协议约束：
  - `PartInfo` 保留 `tool_name/tool_call_id/tool_kind` 作为工具身份字段。
  - `PartInfo.tool_view` 是前端渲染工具卡片的唯一数据源。
  - 不再传递 `tool_title/tool_raw_input/tool_raw_output/tool_locations/tool_state/tool_part_metadata`。
  - `PartInfo.source` 仅作为来源信息透传，不承担工具卡片渲染职责。
- 历史与实时统一：
  - `ai_session_messages` 返回完整 `tool_view`。
  - `ai_session_messages_update` 中，tool part 的对外更新统一以 `PartUpdated` 发送当前完整 `tool_view` 快照；文本/推理 part 仍可使用 `PartDelta`。
- 大 payload 策略：
  - `ai_session_messages.truncated=true` 表示本次历史响应为展示目的裁剪过 `tool_view.sections[].content`。
  - 历史读取只裁剪 section 内容，保留 `display_title/status/question/linked_session/locations` 与消息骨架，避免最近页退化为空白。
- 客户端 part_id 去重：
  - `replaceMessagesFromSessionCache` 在每条消息内按 `part_id` 去重（保留最后一次，即最完整状态），防止 Core 历史回放中多次工具状态更新产生重复工具卡片。
  - 去重仅在消息内部发生，跨消息的同名 `part_id` 相互独立。

### `tool_view` 字段映射（Core -> App）

| `tool_view` 字段 | 协议含义 | App 模型/渲染 |
| --- | --- | --- |
| `status` | 统一状态：`pending/running/completed/error/unknown` | `AIToolView.status` |
| `display_title` | 卡片标题 | `AIToolView.displayTitle` |
| `status_text` | 状态文案 | `AIToolView.statusText` |
| `summary` | 头部摘要 | `AIToolView.summary` |
| `header_command_summary` | 终端命令摘要 | `AIToolView.headerCommandSummary` |
| `duration_ms` | 持续时长 | `AIToolView.durationMs` |
| `sections[]` | 主体展示区块 | `AIToolView.sections` -> `ToolCardView` |
| `locations[]` | 文件定位信息 | `AIToolView.locations` -> `ToolCardView` |
| `question` | 交互问题结构 | `AIToolView.question` / `AIQuestionRequestInfo` |
| `linked_session` | 关联子会话 | `AIToolView.linkedSession` |

### 权限请求与 Question

- 入站：
  - `session/request_permission` 在 Core 内部解析后直接映射到 `tool_view.question`。
- 回答：
  - `selected`：`respond_to_permission_request`
  - `cancelled`：`reject_permission_request`
- 回填关联：
  - `request_id` 与 `tool_call_id/tool_message_id` 通过结构化 `tool_view.question` 透传，供 UI 精确匹配。
- 缺失 `optionId`：
  - 沿用回退顺序：按答案 label 匹配 -> `allow-once` -> 第一项，并记录告警日志。

### Follow-along（`terminal/create` / `terminal/release`）

- Core RPC：
  - `terminal/create(sessionId, toolCallId)`
  - `terminal/release(terminalId)`
- 生命周期：
  - `kind=terminal` 且运行中时尝试 `create`
  - 工具终态、会话结束、流 teardown 时统一 `release`
- 降级：
  - 能力缺失或方法不支持时非致命，自动回退到普通文本输出链路。
- 可观测性计数：
  - 未识别 `content.type` 次数
  - `tool_call_update` 缺失 `toolCallId` 次数
  - follow-along create/release 失败次数

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

## 错误契约

### 通用错误响应

当 Core 无法处理请求时，发送 `kind = "error"` 包络或 `action = "error"` 事件。Payload 结构（v7）：

```json
{
  "code": "project_not_found",
  "message": "Project 'foo' not found",
  "project": "foo",
  "workspace": "default",
  "session_id": null,
  "cycle_id": null
}
```

- `code`（必填）：稳定错误码字符串，与 `AppError::code()` 一一对应。
- `message`（必填）：人类可读错误描述，**不得**用于状态迁移决策。
- `project`、`workspace`、`session_id`、`cycle_id`（均可选）：多项目/多工作区场景下的错误归属定位。

**共享错误码一览**：

| 错误码 | 分类 | 含义 |
|--------|------|------|
| `project_not_found` | 基础 | 项目不存在 |
| `workspace_not_found` | 基础 | 工作区不存在 |
| `git_error` | 领域 | Git 操作失败 |
| `file_error` | 领域 | 文件操作失败 |
| `ai_session_error` | 领域 | AI 会话操作失败 |
| `evolution_error` | 领域 | Evolution 阶段执行失败 |
| `artifact_contract_violation` | 领域 | Evolution 产物格式违反契约 |
| `internal_error` | 通用 | 内部错误 |
| `error` | 通用 | 兜底错误 |

### 客户端消费约束

1. 状态迁移（可恢复/不可恢复）**必须**依赖 `code` 字段，不允许 `message` 字符串匹配。
2. 多工作区：通过 `project` + `workspace` 字段过滤，来自其它工作区的错误不覆盖当前 UI 状态。
3. macOS 与 iOS 对同一错误码必须表现出一致的核心行为语义。

### Evolution 错误事件

`evo_error` 事件额外包含 `source`、`ts`、`cycle_id`，客户端解析时应通过 `CoreError.fromEvoError()` 提取。

### 结构化日志（v1.30.1）

`log_entry` 消息新增 `error_code`、`project`、`workspace`、`session_id`、`cycle_id` 字段，供 Core 文件日志与客户端日志跨端关联同一问题归因。

## 调试建议

- 先确认双方都使用 `MessagePack`，避免把 JSON 文本发到 v3 通道。
- 协议字段变更后，同步更新：
  - `core/src/server/protocol/mod.rs`
  - `app/TidyFlow/Networking/ProtocolModels.swift`
  - 对应 handler 与 UI 调用方
  - `schema/protocol/v7/README.md`（错误契约部分）

## 工作区缓存可观测性（v1.40+）

### HTTP `GET /system_snapshot` 新增 `cache_metrics` 字段

`system_snapshot` 响应新增 `cache_metrics` 数组，包含每个工作区的缓存可观测性快照。
该字段由 Core 权威输出，客户端不得自行推导缓存预算判定或淘汰原因。

**字段结构**（每个元素对应一个 `(project, workspace)` 唯一键）：

| 字段 | 类型 | 含义 |
|------|------|------|
| `project` | string | 项目名 |
| `workspace` | string | 工作区名（含 `default` 虚拟工作区） |
| `file_cache.hit_count` | u64 | 文件索引缓存命中次数 |
| `file_cache.miss_count` | u64 | 文件索引缓存未命中次数 |
| `file_cache.rebuild_count` | u64 | 文件索引全量重建次数 |
| `file_cache.incremental_update_count` | u64 | 文件索引增量更新次数 |
| `file_cache.eviction_count` | u64 | 文件索引缓存淘汰次数 |
| `file_cache.item_count` | u64 | 当前缓存文件条目数 |
| `file_cache.last_eviction_reason` | string? | 最近淘汰原因 |
| `git_cache.hit_count` | u64 | Git 状态缓存命中次数 |
| `git_cache.miss_count` | u64 | Git 状态缓存未命中次数 |
| `git_cache.rebuild_count` | u64 | Git 状态重建次数 |
| `git_cache.eviction_count` | u64 | Git 状态缓存淘汰次数 |
| `git_cache.item_count` | u64 | Git 状态条目数 |
| `git_cache.last_eviction_reason` | string? | 最近淘汰原因 |
| `budget_exceeded` | bool | 重建次数是否超过预算阈值 |
| `last_eviction_reason` | string? | 最近淘汰原因（文件或 Git 中的最新值） |

**客户端消费约束**：
1. `budget_exceeded` 和 `last_eviction_reason` 必须以 Core 输出为准，不得客户端自行计算。
2. 多项目同名工作区的 `cache_metrics` 条目各自独立，不得以 workspace 名称作为唯一聚合键。
3. macOS 与 iOS 对相同字段的处理语义必须一致（允许 UI 呈现不同）。

---

## v1.40: Git 冲突向导（Conflict Wizard）

### 概述

在 merge/rebase 冲突场景下，原有协议只返回 `conflicts: [String]`（文件路径列表），语义弱、客户端各自推导状态。v1.40 引入冲突向导协议，提供语义化冲突快照与五类解决动作，供双端统一消费。

### 新增字段（已有响应扩展）

以下响应新增 `conflict_files` 字段（向后兼容，旧版客户端忽略此字段）：

- `git_rebase_result`
- `git_op_status_result`
- `git_merge_to_default_result`
- `git_integration_status_result`
- `git_rebase_onto_default_result`

```jsonc
// ConflictFileEntry 结构
{
  "path": "src/main.rs",
  "conflict_type": "content",  // content | add_add | delete_modify | modify_delete
  "staged": false               // true 表示已标记为已解决
}
```

### 新增动作

#### git_conflict_detail（读取单文件四路对比内容）

**请求**：
```jsonc
{
  "type": "git_conflict_detail",
  "project": "myproject",
  "workspace": "default",
  "path": "src/main.rs",
  "context": "workspace"  // workspace | integration
}
```

**响应** (`git_conflict_detail_result`)：
```jsonc
{
  "project": "myproject",
  "workspace": "default",
  "context": "workspace",
  "path": "src/main.rs",
  "base_content": "...",    // 公共祖先（:1:<path>），可为 null
  "ours_content": "...",    // 我方 HEAD（:2:<path>），可为 null
  "theirs_content": "...",  // 对方（:3:<path>），可为 null
  "current_content": "...", // 当前工作树文件（含冲突标记）
  "conflict_markers_count": 2,
  "is_binary": false
}
```

#### git_conflict_accept_ours / git_conflict_accept_theirs / git_conflict_accept_both / git_conflict_mark_resolved（冲突解决动作）

**请求示例**（四个动作结构相同，type 不同）：
```jsonc
{
  "type": "git_conflict_accept_ours",  // 或 accept_theirs / accept_both / mark_resolved
  "project": "myproject",
  "workspace": "default",
  "path": "src/main.rs",
  "context": "workspace"
}
```

**响应** (`git_conflict_action_result`)：
```jsonc
{
  "project": "myproject",
  "workspace": "default",
  "context": "workspace",
  "path": "src/main.rs",
  "action": "accept_ours",
  "ok": true,
  "message": null,
  "snapshot": {
    "context": "workspace",
    "files": [],         // 操作后剩余冲突文件列表
    "all_resolved": true
  }
}
```

### 上下文隔离规则

- `context: "workspace"` 操作在指定 `(project, workspace)` 的工作目录下执行。
- `context: "integration"` 操作在该 project 对应的集成工作树（`~/.tidyflow/worktrees/<project>/__integration`）下执行。
- 两种上下文完全隔离，不会因切换项目或工作区而相互影响。
- `continue`/`abort` 门禁同样受 context 隔离约束（普通 workspace rebase 与 integration rebase 分别由对应 git 状态机控制）。

### 客户端消费约束

1. `conflict_files` 是 `conflicts`（路径列表）的语义增强替代，客户端应优先使用 `conflict_files`。
2. 冲突向导 UI 状态（当前选中文件、可用动作、continue/abort 可用条件）必须以 Core 下发的 snapshot 为权威，不得客户端自行推导。
3. macOS 与 iOS 必须使用同一套共享冲突向导语义模型，禁止各自独立维护 conflicts 推导规则。

## 系统健康诊断与自修复域（v1.41）

### 概述

`health` 域提供系统健康快照、客户端健康上报与关键故障修复动作的标准化协议契约。
Core 是健康状态的权威真源，客户端消费快照，不在本地推导系统级故障状态。

### 健康快照（Core → 客户端推送）

**action**: `health_snapshot`

```jsonc
{
  "snapshot": {
    "snapshot_at": 1709900000000,          // Unix ms
    "overall_status": "degraded",          // "healthy" | "degraded" | "unhealthy"
    "incidents": [
      {
        "incident_id": "abc123",
        "severity": "warning",             // "info" | "warning" | "critical"
        "recoverability": "recoverable",   // "recoverable" | "manual" | "permanent"
        "source": "core_workspace_cache",  // 见下方 source 枚举
        "root_cause": "workspace_cache_stale",
        "summary": "工作区缓存已失效，文件索引可能不完整",
        "first_seen_at": 1709899000000,
        "last_seen_at": 1709900000000,
        "context": {
          "project": "myproject",
          "workspace": "feature/foo",
          "session_id": null,
          "cycle_id": null
        }
      }
    ],
    "recent_repairs": []   // 最近 20 条修复审计记录
  }
}
```

**source 枚举**：
- `core_process`：Core 进程 / 连接层
- `core_workspace_cache`：工作区缓存
- `core_evolution`：Evolution 任务
- `core_log`：Core 结构化日志（error/critical 级别）
- `client_connectivity`：客户端连接状态
- `client_state`：客户端运行时状态

### 客户端健康上报（客户端 → Core）

**action**: `health_report`

```jsonc
{
  "client_session_id": "sess-abc",
  "connectivity": "good",                  // "good" | "degraded" | "lost"
  "incidents": [],                         // 客户端本地检测的 incident 列表（可为空）
  "context": { "project": null, "workspace": null },
  "reported_at": 1709900000000
}
```

### 修复动作请求（客户端 → Core）

**action**: `health_repair`

```jsonc
{
  "request": {
    "request_id": "req-uuid",
    "action": "invalidate_workspace_cache", // 见下方 action 枚举
    "context": {
      "project": "myproject",
      "workspace": "feature/foo"
    },
    "incident_id": "abc123"               // 可选，关联修复目标 incident
  }
}
```

**action 枚举**：
- `refresh_health_snapshot`：刷新健康快照（无副作用）
- `invalidate_workspace_cache`：失效指定工作区缓存
- `rebuild_workspace_cache`：重建指定工作区缓存
- `restore_subscriptions`：恢复运行时订阅

### 修复执行结果（Core → 客户端推送）

**action**: `health_repair_result`

```jsonc
{
  "audit": {
    "request_id": "req-uuid",
    "action": "invalidate_workspace_cache",
    "context": { "project": "myproject", "workspace": "feature/foo" },
    "incident_id": "abc123",
    "outcome": "success",                  // "success" | "already_healthy" | "failed" | "partial_success"
    "trigger": "client_request",           // "client_request" | "auto_heal" | "system_init"
    "started_at": 1709900000000,
    "duration_ms": 12,
    "result_summary": "缓存已失效，下次访问时自动重建",
    "incident_resolved": true
  }
}
```

### 多项目隔离约束

1. 每个 incident 的 `context` 字段必须填入正确的 project / workspace 归属，系统级事件可留空但不可省略字段。
2. repair action 必须按 `context` 中声明的 project/workspace 边界执行，Core 不允许把一个工作区的修复动作误施加到另一个工作区。
3. 客户端上报的 incident 必须携带上下文，禁止以系统级方式上报工作区级故障。
4. 修复动作的 `project`/`workspace` 字段为必填项（`restore_subscriptions` 和 `refresh_health_snapshot` 除外）。

### 读取 API 扩展

健康快照也可通过 HTTP 读取（含 incidents 和 repair 审计）：

```
GET /api/v1/system/snapshot
```

响应新增字段 `health_incidents` 和 `recent_repairs`，兼容原有字段。

---

## v1.42：AI 智能路由元数据（ai_chat_done / ai_chat_error 扩展）

### 新增字段说明

`ai_chat_done` 和 `ai_chat_error` 事件新增两个可选顶层字段，旧客户端忽略这些字段，不会解析错误。

#### `route_decision`（可选）

路由决策元数据，描述本次请求最终选定的 provider/model 及决策来源。

```jsonc
{
  "provider_id": "anthropic",           // 最终选定的 provider ID
  "model_id": "claude-3-5-sonnet",     // 最终选定的 model ID
  "agent": "code",                      // 选定的 agent（可选）
  "task_type": "code_generation",       // 任务类型：chat | code_generation | code_review | code_completion | documentation | debugging | system | unknown
  "selected_by": "task_type_policy",    // 选择来源：explicit | task_type_policy | selection_hint | default
  "is_fallback": false,                 // 是否为降级路由（首选失败后切换到候选）
  "fallback_reason": null               // 降级原因（is_fallback=true 时有值）
}
```

**`selected_by` 取值语义**：

| 值 | 说明 |
|---|---|
| `explicit` | 用户显式指定 provider/model，优先级最高，策略不得覆盖 |
| `task_type_policy` | 根据任务类型自动选择（路由策略决定） |
| `selection_hint` | 从历史 session selection hint 恢复 |
| `default` | 系统默认兜底 |

#### `budget_status`（可选，仅 ai_chat_done 携带）

工作区预算状态快照，仅在超出阈值或配置了预算限制时有意义。

```jsonc
{
  "budget_exceeded": false,             // 是否已超阈值
  "last_exceeded_reason": null,         // 最近超阈值原因（budget_exceeded=true 时有值）
  "total_tokens": 12500,               // 当前工作区总 token 数（估算，可选）
  "estimated_cost": 0.025              // 当前工作区估算成本（归一化单位，可选）
}
```

### 多工作区隔离约束

1. 路由决策按 `project_name + workspace_name + ai_tool + session_id` 四维键存储，切换工作区不会串台。
2. 预算状态按 `project_name + workspace_name` 二维键存储，不同项目/工作区的预算独立计算。
3. 显式选择（`selected_by=explicit`）不受预算触发的降级影响，保证用户意图优先。
4. 降级记录只影响当前工作区的重试计数，不污染其它工作区状态。
