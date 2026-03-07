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

## ACP `tool-calls` 对齐说明（v7）

为对齐 ACP `tool-calls`，AI part 协议已扩展以下字段（均为可选）：

- `tool_kind`
- `tool_title`
- `tool_raw_input`
- `tool_raw_output`
- `tool_locations`（数组项：`uri/path/line/column/end_line/end_column/label`）

同时保留兼容字段：

- `tool_state`（含 `input/raw/output/status/metadata.locations`）
- `tool_part_metadata`（透传未知字段，避免信息丢失）

实现约束：

1. 新字段与兼容字段必须在同一个转换点双写，禁止多处拼装导致漂移。
2. 历史加载（`session/load`）与流式（`session/update`）必须复用同一解析逻辑。
3. macOS/iOS 端统一读取上述字段，优先使用新字段，旧字段回退。

## 历史消息工具卡片合并语义（v7 补充）

历史消息（`session/load`）可能包含同一 `tool_call_id` 的多次状态更新（如先 `running` 后 `completed`）。
Core `upsert_tool_part_in_history_messages` 在加载历史时原地更新已存在的 `part_id`，而非追加，以避免重复工具卡片。

客户端（Swift）在 `replaceMessagesFromSessionCache` 中对每条消息内的 `part_id` 执行去重：
- 保留最后一次（最完整状态）
- 仅在消息内部去重，跨消息的同名 `part_id` 相互独立

## `tool_state.input` 格式兼容（v7 补充）

部分 ACP 适配器（如 Kimi）将 `tool_state.input` 以 JSON 字符串形式传输，而非字典对象。
客户端 `AIToolInvocationState.from` 解析顺序：
1. 若 `input` 已是 `[String: Any]`，直接使用。
2. 若 `input` 为 `String`，尝试 `JSONSerialization` 解析为字典。
3. 均失败时回退为空字典 `{}`，不中断渲染流程。

此行为在 `AIChatProtocolModelsTests.testAIToolInvocationStateFromParsesJSONStringInput` 中有回归覆盖。
