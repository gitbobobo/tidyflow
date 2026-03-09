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

## 历史读取裁剪语义（v7 补充）

当 `ai_session_messages` 的历史页过大时，Core 只允许裁剪 `tool_view.sections[].content`，并在响应顶层返回 `truncated=true`。
该裁剪不会删除最近消息本身，也不会删除 `display_title/status/question/linked_session/locations` 等工具卡片骨架字段。

## 流式更新语义（v7 补充）

`ai_session_messages_update` 中：

1. 文本/推理 part 仍可使用 `PartDelta`。
2. tool part 的对外更新统一发送 `PartUpdated`，其中包含当前完整 `tool_view` 快照。
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
