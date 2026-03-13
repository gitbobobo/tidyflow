# Protocol Schema (v10)

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

## Node / Evolution 协作状态契约（v10）

Evolution 在多项目、多工作区场景下默认启用项目级协作编排；v10 新增节点网络发现、配对与跨节点 direction/sync 编排。

### 阶段语义

1. `current_stage` 允许出现公开阶段 `integration` 与 `sync`。
2. `sync` 只适用于 `default` 工作区，且发生在 `auto_commit` 之后。
3. `integration` 只适用于非 `default` 工作区；`default` 工作区不会进入该阶段。
4. 功能分支工作区本轮只有在 `integration` 成功后，才允许进入下一轮 `direction`。

### 新增字段

`EvolutionWorkspaceItem` 与 `evo_cycle_updated` 载荷新增以下可选字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `coordination_state` | `string?` | 当前协作状态，如等待方向轮次、等待主线完成当前阶段、等待 integration 槽位 |
| `coordination_reason` | `string?` | 面向用户展示的具体等待原因 |
| `coordination_scope` | `string?` | 协作作用域：`local_project` / `network_repo_direction` / `network_repo_sync` |
| `coordination_peer_node_id` | `string?` | 当前等待或被其阻塞的对端节点 ID |
| `coordination_peer_node_name` | `string?` | 当前等待或被其阻塞的对端节点名称 |
| `coordination_peer_project` | `string?` | 当前等待或被其阻塞的对端项目 |
| `coordination_peer_workspace` | `string?` | 当前正在等待或被其阻塞的对端工作区 |
| `coordination_queue_index` | `u32?` | 当前工作区在项目内 FIFO integration 队列中的位置，从 0 开始 |

### 编排约束

1. 同一 `remote_url` 下，所有工作区在整个节点网络中同一时刻只允许一个工作区执行 `direction`。
2. 同一项目同一时刻只允许一个非默认工作区执行本机 `integration`，等待顺序严格按 FIFO 排队。
3. `default` 工作区只等待本机 `integration`，不等待远端节点的 `integration`。
4. 同一 `remote_url` 下，整个节点网络同一时刻只允许一个 `default` 工作区执行 `sync`。
5. macOS 与 iOS 必须直接消费上述字段展示等待状态，不允许在客户端本地重新推导队列与阻塞原因。

## 可观测性字段职责边界（v1.42）

`system_snapshot` HTTP 响应携带的可观测性数据分为三类，职责互不重叠：

| 类别 | 字段 | 隔离维度 | 说明 |
|------|------|----------|------|
| **性能指标** | `perf_metrics` | 全局（不按工作区隔离） | WS 管线延迟、广播计数器、终端回收/裁剪等运行时性能计数器的一次性快照 |
| **缓存指标** | `cache_metrics` | `(project, workspace)` | 文件/Git 缓存的 hit/miss/rebuild/eviction 等指标 |
| **终端资源** | `terminal_resource` | `(project, workspace)` 按 `per_workspace` 隔离 | 终端注册表的全局预算与每工作区占用快照 |
| **日志上下文** | `log_context` | 全局 | 当天日志文件路径、保留策略、perf 日志开关 |
| **健康 incidents** | `health_incidents` | 按 incident.context 归属 | 健康异常条目列表 |
| **修复审计** | `recent_repairs` | 按 audit.context 归属 | 最近修复执行记录 |

**职责边界约束：**

1. `perf_metrics` 是全局计数器的**一次性快照**，不是流式事件。客户端只在请求 `system_snapshot` 时获取，不通过 WS 推送。
2. `cache_metrics` 和 `terminal_resource` 按 `(project, workspace)` 隔离，客户端按该复合键路由到对应缓存桶。
3. `log_context` 用于调试面板关联日志文件与快照，不携带日志内容本身。
4. 流式推送的健康事件（`health_snapshot`）与一次性读取的 `health_incidents` 字段共享模型但传输路径不同。
5. 客户端**不允许**本地派生 `perf_metrics` 中的计数器值，Core 是唯一权威源。

## HTTP/WS 传输边界契约（v9）

本节定义哪些能力必须通过 HTTP 读取、哪些通过 WebSocket 流式推送，以及消息必须携带的多工作区边界字段。
所有实现（Core、macOS、iOS）**必须**遵循此契约；任何不在此声明的私有字段不得作为业务逻辑依据。

## 远程认证与 API key 管理（v9）

远程访问采用“Mac 本地管理 API key，移动端直接使用 API key 连接”的统一模型。

### 本地认证管理端点

以下端点只允许 loopback 请求访问，供 macOS 客户端管理 API key 列表：

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/auth/keys` | 返回全部 API key 条目，包含完整 `api_key` 明文 |
| `POST` | `/auth/keys` | 创建 API key；请求体必须携带 `name` |
| `DELETE` | `/auth/keys/:key_id` | 删除 API key，并立即吊销现有远程连接 |

约束：

1. `name` 为必填，按去空白后的值做大小写不敏感唯一校验。
2. `api_key` 由 Core 生成，格式固定为 `tfk_` + 32 字节随机数的 `base64url(no padding)`。
3. 删除 API key 时，Core 必须同时删除持久化记录、主动关闭现有连接，并清理该 key 下的远程终端订阅。

### 远程鉴权元数据

| 传输通道 | 必填字段 | 可选字段 |
|----------|----------|----------|
| WebSocket `/ws` | `token=<api_key>` `client_id=<client_id>` | `device_name=<device_name>` |
| HTTP `/api/v1/*` | `Authorization: Bearer <api_key>` `X-TidyFlow-Client-ID: <client_id>` | `X-TidyFlow-Device-Name: <device_name>` |

约束：

1. `client_id` 是远程客户端实例的稳定身份，Core 用 `subscriber_id = "<key_id>:<client_id>"` 作为远程订阅恢复标识。
2. `GET /api/v1/system/snapshot` 继续保持免鉴权。
3. 本地 bootstrap token 仍可用于本机连接；远程 API key 鉴权成功后主身份固定为 `key_id`。
4. 当 API key 无效或已被删除时，客户端应进入 `authenticationFailed(reason)`，不得自动重连。

### HTTP 只读端点（`read_via_http_required`）

以下 domain 的读取能力**只能**通过 HTTP GET 端点获取，若通过 WS action 发起则 Core 返回：
`Error { code: "read_via_http_required" }`

| Domain     | 已移除的 WS 读取 action                                                                                              | HTTP 替代端点                                                                                     |
|------------|---------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| project    | `list_projects` `list_workspaces` `list_tasks` `list_templates` `export_template`                                   | `GET /api/v1/projects` `GET /api/v1/projects/:project/workspaces` `GET /api/v1/tasks` `GET /api/v1/templates` `GET /api/v1/templates/:template_id/export` |
| settings   | `get_client_settings`                                                                                               | `GET /api/v1/client-settings`                                                                    |
| terminal   | `term_list`                                                                                                         | `GET /api/v1/terminals`                                                                          |
| file       | `file_list` `file_index` `file_read`                                                                                | `GET /api/v1/projects/:project/workspaces/:workspace/files...`                                   |
| git        | `git_status` `git_diff` `git_branches` `git_log` `git_show` `git_op_status` `git_integration_status` `git_check_branch_up_to_date` `git_conflict_detail` | `GET /api/v1/projects/:project/workspaces/:workspace/git...` |
| ai         | `ai_session_list` `ai_session_messages` `ai_session_status` `ai_provider_list` `ai_agent_list` `ai_slash_commands` `ai_session_config_options` | `GET /api/v1/projects/:project/workspaces/:workspace/ai/...`                                     |
| evolution  | `evo_get_snapshot` `evo_get_agent_profile` `evo_list_cycle_history`                                                 | `GET /api/v1/evolution/...`                                                                      |
| evidence   | `evidence_get_snapshot` `evidence_get_rebuild_prompt` `evidence_read_item`                                          | `GET /api/v1/evidence/projects/:project/workspaces/:workspace/...`                               |
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

## 历史读取语义（v9 补充）

`ai_session_messages` 通过 HTTP `GET .../messages` 读取，默认依赖分页控制返回规模，不因旧的 WebSocket 单帧限制裁剪消息内容。
`truncated` 字段仅为兼容保留；当前历史读取通常不返回该字段。

## 流式更新语义（v9 补充）

`ai_session_messages_update` 中：

1. 文本/推理 part 仍可使用 `PartDelta`。
2. tool part 的 `output/progress` 可使用 `PartDelta` 追加；`PartUpdated` 用于首帧骨架、结构性字段变化和终态收敛。
3. 每次更新必须携带 `from_revision` 与 `to_revision`，客户端按 revision 单调应用或触发重同步。
4. 客户端不得再根据原始 provider JSON 或 metadata 拼装工具卡片。

## AI 会话列表读取（v9 补充）

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

## 错误契约（v9）

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

### 日志可观测性

客户端 `log_entry` 上报接口已移除。当前仅保留 Core 自身文件日志与只读诊断摘要：

- Core 文件日志仍写入 `~/.tidyflow/logs/YYYY-MM-DD[-suffix].log`
- `GET /api/v1/system/snapshot` 的 `log_context` 字段继续暴露当天日志文件路径、保留天数与 perf 日志开关

## 工作区缓存可观测性字段（v1.40+）

### HTTP `GET /system_snapshot` 响应新增字段

`system_snapshot` 响应新增 `cache_metrics` 数组，携带每个工作区的缓存可观测性快照。
字段由 Core 权威计算，所有字段按 `(project, workspace)` 唯一键隔离。客户端只消费，不自行推导缓存预算。

```json
{
  "type": "system_snapshot",
  "core_version": "1.3.0",
  "protocol_version": 9,
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

## v1.46: 全链路性能可观测（WI-001/WI-002）

在 `GET /api/v1/system/snapshot` 响应中新增 `performance_observability` 字段，
提供 Core 全局 WS 管线、工作区关键路径、客户端实例性能的统一可观测快照。

### 新增字段（performance_observability）

| 字段 | 类型 | 说明 |
|------|------|------|
| `core_memory` | `CoreRuntimeMemorySnapshot` | Core 进程当前物理内存、虚拟内存、phys_footprint |
| `ws_pipeline_latency` | `LatencyMetricWindow` | WS dispatch 关键延迟（last/avg/p95/max/count） |
| `workspace_metrics` | `WorkspacePerformanceSnapshot[]` | 按 (project, workspace) 隔离的工作区关键路径延迟 |
| `client_metrics` | `ClientPerformanceReport[]` | 各客户端实例最近上报聚合（按 client_instance_id 排序） |
| `diagnoses` | `PerformanceDiagnosis[]` | Core 产出的性能诊断结果（scope: system/workspace/client_instance） |
| `snapshot_at` | `u64` | 快照生成时间（Unix ms） |

### 新增 HealthReport 字段（WI-001）

`health_report` WS action 新增可选字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `client_performance_report` | `ClientPerformanceReport?` | 客户端性能上报，Core 接收后写入全局注册表 |

`ClientPerformanceReport` 包含：
- `client_instance_id`: 进程生命周期稳定 UUID
- `platform`: `macos` 或 `ios`
- `memory`: 当前 phys_footprint 快照
- 各关键路径延迟窗口（workspace_switch/file_tree_request/file_tree_expand/ai_session_list_request/ai_message_tail_flush/evidence_page_append）

### 诊断规则

| reason | scope | warning 阈值 | critical 阈值 |
|--------|-------|------|------|
| ws_pipeline_latency_high | system | last_ms ≥ 100ms | last_ms ≥ 500ms |
| queue_backpressure_high | system | depth ≥ 50 | depth ≥ 200 |
| core_memory_pressure | system | phys ≥ 512MB | phys ≥ 768MB |
| file_tree_latency_high | workspace | p95 ≥ 500ms | p95 ≥ 2000ms |
| client_memory_pressure | client_instance | macOS ≥ 400MB / iOS ≥ 250MB | macOS ≥ 700MB / iOS ≥ 400MB |
| workspace_switch_latency_high | client_instance | — | p95 ≥ 1000ms |
| ai_session_list_latency_high | client_instance | p95 ≥ 500ms | — |
| message_flush_latency_high | client_instance | p95 ≥ 200ms | — |
| cross_layer_latency_mismatch | client_instance | client/core 倍率 ≥ 3 | — |
