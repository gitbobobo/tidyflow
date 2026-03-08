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
