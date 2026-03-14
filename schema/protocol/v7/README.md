# Protocol Schema (v7)

本目录是协议域与版本信息的权威源（source of truth）。

当前包含：

- `domains.yaml`：协议版本与 domain 规则定义。
- `action_rules.csv`：action 到 domain 的匹配规则（exact/prefix/contains）。

配套校验脚本：

- `scripts/tools/check_protocol_schema_sync.sh`
- `scripts/tools/check_protocol_action_sync.sh`
- `scripts/tools/gen_protocol_action_table.sh --check`
- `scripts/tools/gen_protocol_domain_table.sh --check`
- `scripts/tools/gen_protocol_action_swift_rules.sh --check`

校验目标：

1. `domains.yaml` 的 `protocol_version` 与 `core/src/server/protocol/mod.rs` 一致。
2. `domains.yaml` 中的 domain 集合与 `core/src/server/ws/dispatch.rs` 的路由集合一致。
3. `app/TidyFlow/Networking/WSClient+Send.swift` 的 `domainForAction` 返回域覆盖 schema 定义（允许额外 `misc` 兜底域）。
4. `action_rules.csv` 与 Core/App/Web 的 action 规则表保持完全一致。
5. `core/src/server/protocol/action_table.rs` 与 `core/src/server/protocol/domain_table.rs` 必须由生成器产物保持同步，不允许手改漂移。
6. `app/TidyFlow/Networking/WSClient+Send.swift` 的规则块必须由生成器产物保持同步，不允许手改漂移。
7. `app/TidyFlow/Web/main/protocol-rules.js` 的规则块必须由生成器产物保持同步，不允许手改漂移。

## HTTP/WS 传输边界契约（v7）

### 统一运行状态面板字段契约（v1.43+）

任务快照（`TaskSnapshotEntry`）和演化快照（`EvolutionWorkspaceItem` / `EvolutionCycleHistoryItem`）
新增以下字段，用于统一运行状态面板的状态聚合、耗时追踪、失败诊断和一键重试：

| 字段 | 类型 | 适用 | 说明 |
|------|------|------|------|
| `duration_ms` | `u64?` | Task/Evo | 运行耗时（毫秒），Core 权威计算 |
| `error_code` | `string?` | Task/Evo | 失败诊断码 |
| `error_detail` | `string?` | Task | 失败诊断详情 |
| `retryable` | `bool` | Task/Evo | 是否可安全重试 |
| `started_at` | `string?` | Evo | 循环开始时间（RFC3339） |

**约束规则：**
1. 所有新增字段由 Core 权威输出，客户端只消费，不在本地推导。
2. `retryable` 仅对可安全重试的场景开放（Task: `project_command` 失败可重试；Evo: `failed_exhausted` 可重试）。
3. 重试描述符必须保留 `project`/`workspace`/`command_id` 或 `cycle_id` 归属边界，不能退回单项目假设。
4. 新增字段均为可选/默认值，旧客户端忽略即可（向后兼容）。

本节定义哪些能力必须通过 HTTP 读取、哪些通过 WebSocket 流式推送，以及消息必须携带的多工作区边界字段。
所有实现（Core、macOS、iOS）**必须**遵循此契约；任何不在此声明的私有字段不得作为业务逻辑依据。

### HTTP 只读端点（`read_via_http_required`）

以下 domain 的读取能力**只能**通过 HTTP GET 端点获取，若通过 WS action 发起则 Core 返回：
`Error { code: "read_via_http_required" }`

| Domain     | 已移除的 WS 读取 action                                                                                              | HTTP 替代端点                                                                                     |
|------------|---------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| ai         | `ai_session_list` `ai_session_messages` `ai_session_status` `ai_provider_list` `ai_agent_list` `ai_slash_commands` `ai_session_config_options` | `GET /api/v1/projects/:project/workspaces/:workspace/ai/...`                                     |
| evolution  | `evo_get_snapshot` `evo_get_agent_profile` `evo_list_cycle_history`                                                 | `GET /api/v1/evolution/...`                                                                      |
| system     | —（无 WS 读取）                                                                                                     | `GET /api/v1/system/snapshot`（免鉴权）                                                          |

### WS 专用写入与流式事件

以下能力**只能**通过 WS 完成（不提供 HTTP 等价入口）：

| 能力               | WS action 前缀/名称                                              |
|--------------------|------------------------------------------------------------------|
| AI 订阅控制        | `ai_session_subscribe` `ai_session_unsubscribe`                  |
| AI/Evo 流式推送    | `ai_session_messages_update` `ai_session_status_update` `ai_chat_done` `ai_chat_error` `evo_*` |
| 终端 / 文件 / Git  | 全部写操作 action                                                |
| 系统健康           | `health_report` `health_repair`（写入）/ `health_snapshot` `health_repair_result`（推送） |

### 多工作区边界字段约束

所有 HTTP 响应 **和** WS 事件必须携带以下字段（适用时），作为工作区隔离的权威标识：

| 字段          | 含义                                       | 类型     | 是否必须  |
|---------------|--------------------------------------------|----------|-----------|
| `project`     | 所属项目名称                               | string   | 必须      |
| `workspace`   | 所属工作区名称                             | string   | 必须      |
| `session_id`  | AI 会话 ID（AI 相关消息）                  | string?  | 条件必须  |
| `cycle_id`    | Evolution 循环 ID（Evolution 相关消息）    | string?  | 条件必须  |

**约束规则：**
1. 客户端**必须**通过 `(project, workspace)` 二元组路由消息到对应缓存桶，不允许仅凭 `workspace` 名称决定归属。
2. 来自其他工作区的 HTTP/WS 数据**不允许**覆盖当前激活工作区的 UI 状态。
3. 错误响应中的 `project`/`workspace` 决定哪个上下文的状态受影响，不允许通过 `message` 字符串匹配推断归属。
4. `(project, workspace)` 的多工作区语义默认成立，不允许将 `default` 或当前选中工作区视为隐含单例。

### Snapshot 回退语义

- 客户端在 HTTP 读取失败时，**必须**以 `(project, workspace)` 为键决定是否对当前激活工作区发起回退，不影响其他工作区状态。
- WS 流式增量事件与 HTTP snapshot 共用兼容的 `project/workspace/session_id/cycle_id` 元数据，不允许出现两套键规则。
- 后台工作区的 snapshot fallback **不允许**覆盖当前激活工作区的流式状态。

### 订阅确认语义（`ai_session_subscribe_ack`）

WS 订阅确认必须携带 `project`/`workspace` 字段，客户端按 `(project, workspace, ai_tool, session_id)` 四元组路由到对应会话状态，不允许按 `session_id` 单键匹配。

## 项目/工作区协议语义约束

### default 虚拟工作区

每个项目均有一个 `default` 虚拟工作区，由 Core 在 `list_workspaces` 响应和 `system_snapshot` 结果中动态注入。
- **`workspace_status` 始终为 `ready`**，不随项目状态变化。
- 指向项目根目录（`Project.root_path`）。
- 不存储在 `Project.workspaces` HashMap 中；客户端**不得**在本地生成该工作区。
- 在 `(project, workspace)` 排序下，`default` 始终排在该项目其他命名工作区之前（字典序靠前）。

### 工作区生命周期状态（`workspace_status`）

| 状态值 | 含义 |
|--------|------|
| `ready` | 完全就绪，可以使用 |
| `creating` | git worktree 已创建，等待 setup |
| `initializing` | setup 脚本执行中 |
| `setup_failed` | setup 失败，需手动修复 |
| `destroying` | 标记删除中，不接受新操作 |

`workspace_status` 的状态机转换（见 `core/src/workspace/state.rs`）：

```
Creating → Initializing → Ready
                        ↘ SetupFailed
(任意状态) → Destroying
```

### 工作区恢复状态（`recovery_state`）

`system_snapshot` 的 `workspace_items` 中，每个命名工作区可携带以下可选恢复字段，
按 `(project, workspace)` 复合键隔离，崩溃重启后不会将一个工作区的恢复状态施加到另一个工作区：

| 字段 | 类型 | 含义 |
|------|------|------|
| `recovery_state` | `string?` | 恢复状态：`interrupted` \| `recovering` \| `recovered`；正常运行时省略（`None`）|
| `recovery_cursor` | `string?` | 恢复游标：上次已知执行位置（如 Evolution 阶段名、步骤 ID）；省略时表示无法定位游标 |

**约束规则：**
1. 客户端**必须**通过 `(project, workspace)` 路由 `recovery_state` 到对应 UI 状态，不允许仅凭工作区名称判断。
2. `recovery_state` 为 `None` 时（字段不存在或值为 `none`），客户端不应渲染恢复提示。
3. 健康探针 `core.workspace_recovery` 会为 `recovery_state = interrupted | recovering` 的工作区生成 `Warning` 级 incident，归属上下文携带 `(project, workspace)`。

### 多项目/多工作区唯一标识

- 工作区唯一键：`(project, workspace)` 二元组。
- 不允许仅凭 `workspace` 名称作为全局缓存键（不同项目可能有同名工作区）。
- `file_changed` 事件必须通过 `project`/`workspace` 字段路由到正确的缓存桶，
  不允许仅凭工作区名称判断是否刷新当前界面。
- `watch_subscribe` 订阅语义是"当前连接的单一活跃订阅"；切换工作区时必须先 `watch_unsubscribe` 再重新订阅。

## 文件系统统一状态机契约

每个 `(project, workspace)` 维护一个独立的**文件工作区相位**（`FileWorkspacePhase`），
描述该工作区文件子系统的聚合就绪状态。相位由 Core 权威管理，客户端只消费、不推导。

### 相位枚举

| 相位 | 含义 | 文件操作可用性 |
|------|------|----------------|
| `idle` | 未激活，无 watcher、无索引 | 读写均可（按需触发） |
| `indexing` | 文件索引扫描进行中 | 读写均可（缓存兜底） |
| `watching` | watcher 就绪，增量事件正常投递 | 完全可用 |
| `degraded` | watcher 遇非致命错误，缓存可能过时 | 读写可用（数据可能过时） |
| `error` | 致命错误，文件操作不可用 | 读操作缓存兜底，写操作阻塞 |
| `recovering` | 正在从 error/degraded 恢复 | 读写可用（恢复中） |

### 状态迁移

```text
idle ──(watch_subscribe)──► watching
idle ──(index_request)───► indexing
indexing ──(complete)─────► idle（若无 watcher）
indexing ──(complete)─────► watching（若 watcher 已就绪）
watching ──(watcher_error)► degraded
watching ──(unsubscribe)──► idle
degraded ──(recover)──────► recovering
recovering ──(success)────► watching
recovering ──(fail)───────► error
error ──(retry)───────────► recovering
(任意) ──(disconnect)─────► idle
(任意) ──(workspace_switch)► idle
```

### 文件变更事件类型（`FileChangeKind`）

统一的文件变更事件类型，替代原先的字符串字面量：

| 值 | 含义 |
|----|------|
| `created` | 文件或目录被创建 |
| `modified` | 文件内容被修改 |
| `removed` | 文件或目录被删除 |
| `renamed` | 文件或目录被重命名 |

不可识别的 kind 值统一回退为 `modified`。

### 多工作区隔离约束

1. 文件相位按 `(project, workspace)` 隔离，不同工作区的相位互不影响。
2. 断线重连后，所有工作区的文件相位归位为 `idle`，由客户端按需重新订阅。
3. 工作区切换时，旧工作区相位保持不变（可被后台缓存策略淘汰），新工作区按其已有相位继续。
4. `watch_subscribe` 只影响目标 `(project, workspace)` 的相位，不改变其他工作区。

### 权威源与验证

- 协议类型定义：`core/src/server/protocol/file.rs`（`FileWorkspacePhase`、`FileChangeKind`）
- 运行时状态追踪：`core/src/application/file.rs`（`FileWorkspacePhaseTracker`）
- 协议一致性检查：`./scripts/tidyflow check`

## Evolution 读取补充（v7）

Evolution 快照与循环历史结果不再暴露 `handoff` 字段。
客户端若需展示计划文档，应直接读取循环目录中的 `plan.md`。
Evolution 运行时 `stage` 字段允许动态实例名，例如 `implement.general.1`、`implement.visual.2`、`reimplement.1`。
Plan / Verify 相关产物中的工作项归属字段统一使用 `implementation_stage_kind`，不再使用旧的 `implementation_agent`。

## ACP `tool-calls` 对齐说明（v7）

为对齐 ACP `tool-calls`，AI part 协议在 v7 收敛为“前端渲染导向”的结构化 `tool_view`。

`PartInfo` 对外只保留以下工具身份字段：

- `tool_name`
- `tool_call_id`
- `tool_kind`

`PartInfo.tool_view` 作为唯一工具卡片渲染载荷，字段如下：

- `status`
- `display_title`
- `status_text`
- `summary`
- `header_command_summary`
- `duration_ms`
- `sections[]`
- `locations[]`
- `question`
- `linked_session`

其中：

- `sections[]` 项包含 `id/title/content/style/language/copyable/collapsed_by_default`
- `locations[]` 项包含 `uri/path/line/column/end_line/end_column/label`
- `question` 包含 `request_id/tool_message_id/prompt_items/interactive/answers`
- `linked_session` 包含 `session_id/agent_name/description`

实现约束：

1. `tool_view` 必须由 Core 在单一转换点生成，禁止客户端基于原始 JSON 二次推导。
2. 历史加载（`session/load`）与流式（`session/update`）必须复用同一解析逻辑。
3. macOS/iOS 端统一只读取 `tool_view`，不依赖 `tool_state/raw_input/raw_output/metadata` 回退。

## 历史消息工具卡片合并语义（v7 补充）

历史消息（`session/load`）可能包含同一 `tool_call_id` 的多次状态更新（如先 `running` 后 `completed`）。
Core `upsert_tool_part_in_history_messages` 在加载历史时原地更新已存在的 `part_id`，而非追加，以避免重复工具卡片。

客户端（Swift）在 `replaceMessagesFromSessionCache` 中对每条消息内的 `part_id` 执行去重：
- 保留最后一次（最完整状态）
- 仅在消息内部去重，跨消息的同名 `part_id` 相互独立

## 历史读取裁剪语义（v7 补充）

当 `ai_session_messages` 的历史页过大时，Core 只允许裁剪 `tool_view.sections[].content`，并在响应顶层返回 `truncated=true`。
该裁剪不会删除最近消息本身，也不会删除 `display_title/status/question/linked_session/locations` 等工具卡片骨架字段。

## 流式更新语义（v7 补充）

`ai_session_messages_update` 中：

1. 文本/推理 part 仍可使用 `PartDelta`。
2. tool part 的 `output/progress` 可使用 `PartDelta` 追加；`PartUpdated` 用于首帧骨架、结构性字段变化和终态收敛。
3. 客户端不得再根据原始 provider JSON 或 metadata 拼装工具卡片。

## AI 会话列表读取（v7 补充）

AI 会话列表 HTTP 读取接口统一为：

- `GET /api/v1/projects/:project/workspaces/:workspace/ai/sessions`

查询参数约束：

- `limit`：默认 `50`，最大 `200`
- `cursor`：不透明分页游标
- `ai_tool`：可选工具筛选；为空表示返回当前工作区全部工具会话

返回约束：

- `ai_session_list` 顶层返回 `filter_ai_tool`、`has_more`、`next_cursor`
- `sessions[]` 必须显式包含 `ai_tool`
- `sessions[]` 必须显式包含 `session_origin`
- 排序固定为 `updated_at DESC, created_at DESC, ai_tool ASC, session_id ASC`
- 默认列表排除 `session_origin = evolution_system` 的系统会话
- 按 `session_id` 精确读取消息/状态不受列表过滤影响

## 错误契约（v7）

### 通用错误响应（`kind = "error"` 或 `action = "error"`）

所有 Core 错误响应的 payload 保证以下字段：

```json
{
  "code": "project_not_found",
  "message": "Project 'foo' not found",
  "project": "foo",         // 可选：错误归属项目
  "workspace": "default",   // 可选：错误归属工作区
  "session_id": null,       // 可选：AI 会话 ID
  "cycle_id": null          // 可选：Evolution Cycle ID
}
```

**共享错误码**（`code` 字段）与 `AppError::code()` 保持一一对应：

| 错误码 | 含义 | 可恢复 |
|--------|------|--------|
| `project_not_found` | 指定项目不存在 | ✓ |
| `workspace_not_found` | 指定工作区不存在 | ✓ |
| `git_error` | Git 操作失败 | - |
| `file_error` | 文件操作失败 | - |
| `internal_error` | 内部错误 | - |
| `ai_session_error` | AI 会话操作失败 | - |
| `evolution_error` | Evolution 阶段执行失败 | - |
| `artifact_contract_violation` | Evolution 产物格式违反契约 | - |
| `error` | 通用兜底错误 | - |

**多工作区/多项目消费约束**：
- 客户端通过 `project` + `workspace` 字段决定是否更新当前上下文的状态
- 来自其它工作区的错误不允许覆盖当前工作区的 UI 状态
- 错误码是决定状态迁移（可恢复/不可恢复）的唯一依据，不允许客户端通过 `message` 字段的字符串匹配决定行为

### Evolution 错误事件（`action = "evo_error"`）

`evo_error` 事件的 payload 继承通用错误字段，并额外包含：

```json
{
  "code": "artifact_contract_violation",
  "message": "...",
  "project": "myproject",
  "workspace": "feature-x",
  "cycle_id": "2026-03-08T06-39-28-187Z",
  "source": "implement.general.1",
  "ts": "2026-03-08T06:45:00.000+00:00"
}
```

### 结构化日志字段（`ClientMessage::LogEntry`，v1.30.1）

客户端日志上报（`log_entry`）现支持携带结构化错误信息：

```json
{
  "type": "log_entry",
  "level": "ERROR",
  "source": "swift",
  "category": "ws",
  "msg": "WebSocket receive failed",
  "detail": "...",
  "error_code": "ws_receive_error",
  "project": "myproject",
  "workspace": "default",
  "session_id": null,
  "cycle_id": null
}
```

Core 文件日志（`~/.tidyflow/logs/YYYY-MM-DD.log`）对客户端日志与 Core 日志均写入相同的上下文字段，便于跨端关联同一问题。

## 工作区缓存可观测性字段（v1.40+）

### HTTP `GET /system_snapshot` 响应新增字段

`system_snapshot` 响应新增 `cache_metrics` 数组，携带每个工作区的缓存可观测性快照。
字段由 Core 权威计算，所有字段按 `(project, workspace)` 唯一键隔离。客户端只消费，不自行推导缓存预算。

```json
{
  "type": "system_snapshot",
  "core_version": "1.3.0",
  "protocol_version": 7,
  "workspace_items": [...],
  "cache_metrics": [
    {
      "project": "myproject",
      "workspace": "default",
      "file_cache": {
        "hit_count": 42,
        "miss_count": 3,
        "rebuild_count": 3,
        "incremental_update_count": 10,
        "eviction_count": 1,
        "item_count": 850,
        "last_eviction_reason": "ttl_expired"
      },
      "git_cache": {
        "hit_count": 100,
        "miss_count": 5,
        "rebuild_count": 5,
        "eviction_count": 2,
        "item_count": 12,
        "last_eviction_reason": "invalidated"
      },
      "budget_exceeded": false,
      "last_eviction_reason": "ttl_expired"
    }
  ]
}
```

### 字段语义约束

- `cache_metrics` 数组元素的排序与 `workspace_items` 一致，按 `(project, workspace)` 字典序。
- `budget_exceeded`：文件缓存与 Git 缓存总重建次数超过阈值时为 `true`，客户端可据此显示预警。
- `last_eviction_reason`：可能的值包括 `ttl_expired`（TTL 到期）、`invalidated`（主动失效），由 Core 写入。
- 不允许客户端本地推导 `budget_exceeded` 或淘汰原因；如需更多上下文，以 `cache_metrics` 字段为准。
- 多项目场景下，同名工作区在不同项目的 `cache_metrics` 条目相互独立，不会合并。

## v1.41：健康诊断域（health）

新增 `health` 域，使用 `health_` 前缀路由。核心 action：

| action | 方向 | 说明 |
|--------|------|------|
| `health_report` | 客户端 → Core | 客户端上报自身运行健康状态与本地检测 incident |
| `health_snapshot` | Core → 客户端 | Core 推送系统健康快照（incidents、摘要） |
| `health_repair` | 客户端 → Core | 客户端请求执行修复动作 |
| `health_repair_result` | Core → 客户端 | Core 推送修复执行结果与审计记录 |

详见 `docs/PROTOCOL.md` 的"系统健康诊断与自修复域"章节。

## AI 会话上下文快照（Context Snapshot）

每个 `(project, workspace, ai_tool, session_id)` 会话在 `ai_chat_done` 时保存上下文快照。

快照包含以下字段：
- `message_count`：快照时刻的会话消息总数
- `context_summary`：来自最后一条 assistant 消息的语义摘要（最多 500 字节，可为 null）
- `selection_hint`：最后使用的模型/Agent 选择提示（可为 null）
- `context_remaining_percent`：最后已知的上下文使用率（剩余百分比 0-100，可为 null）

HTTP 读取接口：
- `GET .../ai/:ai_tool/sessions/:session_id/context-snapshot`：读取单个会话快照
- `GET .../ai/context-snapshots`：读取跨工作区快照列表（支持 `?ai_tool=` 筛选）

跨工作区引用：使用 `@@project-name` 语法后，注入对应项目已持久化的上下文快照（`context_summary` 与 `selection_hint`），不依赖当前运行状态。

## AI 聊天舞台生命周期契约

### 概述

AI 聊天舞台（Chat Stage）是客户端 AI 聊天上下文的统一生命周期抽象。
macOS 与 iOS 双端通过共享状态机（`AIChatStageLifecycle`）驱动所有状态迁移。

### 舞台阶段

- `idle`：无活跃聊天上下文
- `entering`：正在加载会话列表、恢复快照
- `active`：聊天上下文就绪，可收发消息
- `resuming`：断线重连或流式中断后恢复消息流
- `closing`：保存快照、取消订阅（自动迁移到 idle）

### 多工作区隔离约束

1. 舞台状态按 `(project, workspace, ai_tool)` 三元组隔离。
2. 工作区切换时 `WorkspaceViewStateMachine` 自动重置聊天舞台投影缓存。
3. 流式事件仅在 active/resuming 阶段且上下文三元组匹配时被接受。
4. 客户端**不得**用 `session_id` 单键判断事件归属，必须同时校验 `(project, workspace, ai_tool)`。
5. 平台层在工作区切换后必须调用 `lifecycle.apply(.forceReset)` 或 `.close` 确保状态机归位。

### 与订阅确认的关系

- `ai_session_subscribe_ack` 到达后，客户端应将舞台从 entering 迁移到 active。
- 如果处于 resuming 阶段，ack 应触发 `resumeCompleted`，将舞台迁移到 active。
- 如果 ack 到达时舞台已被 `close` 或 `forceReset`（idle），ack 应被丢弃，不得拉回 active。
- 携带与当前工作区不匹配的 `(project, workspace)` 的 ack 必须被拒绝（多工作区隔离）。

### WS 断线重连约束（v1.46）

本节是 `docs/PROTOCOL.md` 中「WS 断线重连契约」的 schema 摘要，两者必须同步。

**`system_snapshot` 连接恢复字段（`workspace_items` 中的命名工作区）：**

| 字段 | 类型 | 持久化键 | 说明 |
|------|------|----------|------|
| `recovery_state` | `string?` | `(project_name, name)` | `interrupted` \| `recovering` \| `recovered`；正常时省略 |
| `recovery_cursor` | `string?` | `(project_name, name)` | 上次已知执行位置；省略时无法定位游标 |

**隔离约束：**
1. 两个字段以 `(project_name, workspace_name)` 复合键持久化，同名工作区在不同项目中严格隔离。
2. 字段缺失（`None`）时客户端视作正常态，不渲染恢复提示，不继承其他工作区的状态。
3. 恢复决策权属于 Core，客户端只消费字段，不在本地推导恢复逻辑。

**终端恢复作用域约束：**
- 重连后 `requestTerminalReattach` 仅恢复当前选中 `(project, workspace)` 的 stale terminals。
- 后台工作区的终端不得被错误恢复；iOS 远程连接可凭 `token_id` 保留已有订阅。


### 生命周期边界验证

以下边界场景为当前阶段的回归验证范围：

| 场景 | 预期行为 |
|------|---------|
| 工作区切换 | close → forceReset 清空旧上下文，enter 建立新上下文 |
| 会话恢复 | resume → resumeCompleted 补拉缺失消息 |
| 流式中断 | streamInterrupted → resumeCompleted 或 close |
| 关闭聊天 | close → idle，快照保存完成 |
| 断开连接 | forceReset → idle，无残留投影 |

详细迁移规则见 `docs/PROTOCOL.md` 的「AI 聊天舞台生命周期语义」章节。

## 终端会话恢复协议契约（WI-002/WI-003）

### TerminalInfo 生命周期相位

`term_list` HTTP 端点（`GET /api/v1/terminals`）返回的每条 `TerminalInfo` 携带以下恢复相关字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `lifecycle_phase` | `string` | 终端生命周期相位，枚举见下 |
| `recovery_phase` | `string?` | 仅 `recovering`/`recovery_failed` 时非 nil，与 `lifecycle_phase` 同值 |
| `recovery_failed_reason` | `string?` | 仅恢复失败时有值，Core 权威错误摘要 |

**`lifecycle_phase` 枚举值：**

| 值 | 含义 |
|----|------|
| `idle` | 空闲，终端未活跃 |
| `entering` | 创建中，等待 PTY spawn 完成 |
| `active` | 活跃，输出正常流转 |
| `resuming` | WS 断连后重新 attach 中（客户端发起） |
| `recovering` | Core 重启后持久化恢复中（Core 发起） |
| `recovery_failed` | Core 持久化恢复失败，终端不可用 |

**关键区分：**
- `resuming` = 客户端 WS 断线后重附着（临时网络问题）
- `recovering` = Core 进程重启后从持久化元数据恢复（更严重的中断）
- 两者语义正交，客户端不能混用处理逻辑

### 恢复元数据持久化约束

- 恢复元数据按 `(project, workspace, term_id)` 三元组隔离，跨工作区绝不共享
- 只持久化最小字段集：`cwd`、`shell`、`name`、`icon`、`recovery_state`、`failed_reason`
- 不持久化 `scrollback`、订阅计数等运行时数据
- 终端主动关闭（`term_close`/`kill_terminal`）时立即将 `recovery_state` 更新为 `recovered`
- 恢复失败状态 (`recovery_failed`) 是明确终态，不静默回退为 `idle`

### 验证入口

- `./scripts/tidyflow check` — 协议 schema 一致性检查
- `./scripts/tidyflow test` — Rust Core 单元测试（含持久化层）
- `./scripts/tidyflow perf-regression` — 多工作区高负载热点性能回归
- Apple 定向回归：`TerminalWorkspaceIsolationTests`、`WorkspaceSharedStateSemanticsTests`

## 客户端性能上报字段扩展

`health_report` 中的 `client_performance_report` 对象包含以下延迟窗口字段（均为 `LatencyMetricWindow` 类型）：

| 字段（snake_case） | 表面 | 语义 | 引入版本 |
|---------------------|------|------|----------|
| `workspace_switch` | 全局 | 工作区切换端到端延迟 | v1.41 |
| `file_tree_request` | 全局 | 文件树请求延迟 | v1.41 |
| `file_tree_expand` | 全局 | 文件树展开延迟 | v1.41 |
| `ai_session_list_request` | chat_session | AI 会话列表请求延迟 | v1.41 |
| `ai_message_tail_flush` | chat_session | AI 消息尾部刷新延迟 | v1.41 |
| `evidence_page_append` | evolution_workspace | 证据页追加延迟 | v1.41 |
| `terminal_output_flush` | terminal_output | 终端共享输出刷新延迟 | v1.41+ |
| `git_panel_projection` | git_panel | Git 面板投影刷新延迟 | v1.41+ |

**兼容策略：** `terminal_output_flush` 和 `git_panel_projection` 在 Core 侧使用 `#[serde(default)]` 反序列化。旧客户端不发送这两个字段时，Core 以零值填充，不触发诊断。新客户端发送时，Core 按阈值产出 `terminal_output_flush_latency_high` 或 `git_panel_projection_latency_high` 诊断。

**诊断阈值：**
- `terminal_output_flush_latency_high`：warning ≥ 150ms，critical ≥ 500ms
- `git_panel_projection_latency_high`：warning ≥ 200ms，critical ≥ 800ms

**热点落点约束：** 终端热点必须在共享终端输出刷新链路中（非单个 View 计时），Git 热点必须在 `GitWorkspaceProjectionStore.updateProjection()` 中（非 View 层）。
