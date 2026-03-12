# Codex Server 协议工具调用解析逻辑调研

更新日期：2026-03-13

## 目标

这份调研只关注一件事：GitHub 上真实接入 Codex app-server / server 协议的开源实现，究竟如何解析工具调用相关事件、如何做生命周期归并、如何处理状态和容错，以及哪些规则可以直接转成 TidyFlow 核心层的“归一化工具分类逻辑”。

主要用途：

- 为 `core` 里的 Codex 适配层提供直接可抄的解析策略。
- 避免把 Codex 的工具调用只当作单条日志，而忽略它本质上是一个跨 `item/started`、delta、`item/completed` 的状态对象。
- 为多项目、多工作区、多会话场景明确主键、状态、分类层级和降级策略。

## 调研样本

本次优先挑了三类来源：

| 样本 | 类型 | 价值 |
| --- | --- | --- |
| [openai/codex](https://github.com/openai/codex/tree/main) | 上游权威实现 | 提供 app-server 官方协议类型、Python client 通知解析、TypeScript SDK 公开数据模型 |
| [nshkrdotcom/codex_sdk](https://github.com/nshkrdotcom/codex_sdk/tree/master) | 第三方 Elixir SDK | 提供更接近“客户端状态机”的归并逻辑、状态归一化、approval 关联和容错降级 |
| [just-every/code](https://github.com/just-every/code/tree/main) | 上游分叉实现 | README 和协议枚举把 item 生命周期、approval 顺序、动态工具调用暴露得更完整，适合作为行为语义参照 |

调研时查看的源码版本：

- `openai/codex`：`4e99c0f1798856d445624e1c28dcd43c6b6a715f`
- `nshkrdotcom/codex_sdk`：`81df7287aa687fa474da63ec1fa3302fefb3c480`
- `just-every/code`：`0952848225e7616df0df71173090689bba5c09cd`

## 一、先看协议层到底把什么当“工具调用”

Codex app-server 并不是只暴露一个 `tool_call` 结构。真实协议里，工具相关对象分散在多个 `ThreadItem` 变体里：

- `commandExecution`
- `fileChange`
- `mcpToolCall`
- `dynamicToolCall`
- `collabAgentToolCall`
- `webSearch`
- `imageView`

上游 Python 生成类型直接把这些都放进 `ThreadItem` union：

- [`sdk/python/src/codex_app_server/generated/v2_all.py#L3530-L3615`](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/generated/v2_all.py#L3530-L3615)
- [`sdk/python/src/codex_app_server/generated/v2_all.py#L6578-L6672`](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/generated/v2_all.py#L6578-L6672)

直接含义：

- Codex 协议里的第一层分类不是 `read/write/search/bash`，而是“协议原生 item type”。
- `read/write/search/bash` 这种更接近产品展示或工具归类，应该是第二层派生分类，而不是直接拿来替代协议类型。

这点和当前 TidyFlow 的做法有明显差异：当前实现会把 `commandExecution` 进一步推断成 `read/list/grep/bash`，把 `fileChange` 直接折叠成 `write`。

参考当前实现：

- [core/src/ai/codex/tool_mapping.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/codex/tool_mapping.rs#L48)
- [core/src/ai/codex/tool_mapping.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/codex/tool_mapping.rs#L145)

## 二、上游 `openai/codex` 的实际解析逻辑

### 1. Python client 先按 method 做“通知模型分发”，未知方法直接保底为原始对象

上游 Python client 的 `_coerce_notification()` 先查 `NOTIFICATION_MODELS`，找不到或校验失败都降级成 `UnknownNotification`：

- [`sdk/python/src/codex_app_server/client.py#L455-L466`](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/client.py#L455-L466)
- [`sdk/python/src/codex_app_server/generated/notification_registry.py#L68-L85`](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/generated/notification_registry.py#L68-L85)

这套逻辑的价值很直接：

- 解析入口先按 `method` 分派，不靠后续猜字段。
- 对新方法或脏数据不崩溃，保留原始 payload 继续向上游传。
- 协议升级时，客户端能“看不懂但不丢消息”。

对 TidyFlow 的直接启发：

- 归一化层前面应该有一层“协议 method 解析层”。
- 这层的职责是 `method -> typed event | raw event`，不要一开始就试图把所有东西压成统一工具卡片。

### 2. 公开协议把 item 生命周期分成“完整快照 + 增量事件”

上游注册表里明确区分了：

- `item/started`
- `item/completed`
- `item/agentMessage/delta`
- `item/commandExecution/outputDelta`
- `item/commandExecution/terminalInteraction`
- `item/fileChange/outputDelta`
- `item/mcpToolCall/progress`

参考：

- [`sdk/python/src/codex_app_server/generated/notification_registry.py#L68-L81`](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/generated/notification_registry.py#L68-L81)

这说明：

- `item/started` 和 `item/completed` 都是完整 item 快照。
- delta 事件只是补充 UI 实时态，不是最终权威状态。
- 最终展示与持久化必须回落到 `item/completed`。

### 3. approvals 在上游默认也是 item 级别，而不是“工具名级别”

Python client 的默认 approval handler 只针对两个明确 method：

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`

参考：

- [`sdk/python/src/codex_app_server/client.py#L478-L483`](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/client.py#L478-L483)

直接含义：

- approval 不是抽象的“某次工具调用需要确认”，而是带明确 item 语义的协议请求。
- 所以后续如果要把 approval 挂到工具卡片上，关联键优先应该是 `threadId + turnId + itemId`，而不是 `tool_name`。

### 4. 上游 TypeScript SDK 暴露的是“简化后的消费模型”，不能当协议权威源

上游 TypeScript SDK 的 `ThreadItem` 只保留了 `command_execution`、`file_change`、`mcp_tool_call`、`web_search` 等一部分类型，而且字段名已经转成 snake_case：

- [`sdk/typescript/src/items.ts#L5-L127`](https://github.com/openai/codex/blob/main/sdk/typescript/src/items.ts#L5-L127)

这里有两个重要观察：

- 它没有完整暴露 app-server 全量 item 类型，例如 `dynamicToolCall`、`collabAgentToolCall`、`imageView`、review mode。
- 它已经是“面向 SDK 使用者的二次消费模型”，不是协议原型。

结论：

- TidyFlow 不应以 TypeScript SDK 的公开 union 作为协议分类基准。
- 它更适合作为“对外 API 可以多么简化”的参考，而不是内部归一化层的上限。

## 三、`nshkrdotcom/codex_sdk` 的解析与归并策略

第三方 Elixir SDK比上游更接近“客户端真正怎么做状态机”。

### 1. NotificationAdapter 先把 app-server method 映射成内部 typed event

它把每个 method 显式映射到内部事件结构：

- `item/started` / `item/completed`
- `item/agentMessage/delta`
- `item/reasoning/textDelta`
- `item/reasoning/summaryTextDelta`
- `item/commandExecution/outputDelta`
- `item/commandExecution/terminalInteraction`
- `item/fileChange/outputDelta`
- `item/mcpToolCall/progress`

参考：

- [`lib/codex/app_server/notification_adapter.ex#L129-L235`](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/notification_adapter.ex#L129-L235)

这里最值得抄的细节有两个：

- 同时接受 camelCase 和 snake_case 的字段名，比如 `threadId` / `thread_id`、`itemId` / `item_id`。
- delta 事件统一抽成“按 `item_id` 附着到某个 item 上的增量”，而不是另起一套工具对象。

对多平台客户端很有价值，因为这层把服务端协议异味吃掉了。

### 2. ItemAdapter 明确区分“可识别 item”和“原样透传 item”

Elixir 的 `ItemAdapter` 对已知 item type 进行结构化解析；未知 type 直接返回 `{:raw, item}`：

- [`lib/codex/app_server/item_adapter.ex#L6-L119`](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/item_adapter.ex#L6-L119)

它当前识别的类型包括：

- `userMessage`
- `agentMessage`
- `reasoning`
- `commandExecution`
- `fileChange`
- `mcpToolCall`
- `webSearch`
- `imageView`
- `enteredReviewMode`
- `exitedReviewMode`

这比 TidyFlow 当前 `other => 当工具处理` 的策略更保守，也更稳妥：

- 已知类型严格结构化。
- 未知类型保底原样上送。
- 不因为看不懂某个新 item，就把它误分类成普通工具。

### 3. 它保留协议原始 status，不把 `declined` 折叠成 `error`

`ItemAdapter.normalize_status()` 只做有限映射：

- `inProgress -> :in_progress`
- `completed -> :completed`
- `failed -> :failed`
- `declined -> :declined`

参考：

- [`lib/codex/app_server/item_adapter.ex#L146-L160`](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/item_adapter.ex#L146-L160)

这个点对 TidyFlow 很关键，因为当前实现会把：

- `failed`
- `error`
- `declined`
- `cancelled`

都归并成统一的 `"error"`。

参考：

- [core/src/ai/codex/tool_mapping.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/codex/tool_mapping.rs#L26)

问题在于：

- `declined` 是用户/策略拒绝，不是执行失败。
- 对审批流、回放、统计和 UI 文案来说，这两个状态必须分开。

### 4. 文件变更与命令执行都保留协议细节，不急着映射成最终展示分类

`commandExecution` 会保留：

- `command`
- `cwd`
- `processId`
- `commandActions`
- `aggregatedOutput`
- `exitCode`
- `durationMs`

`fileChange` 会保留：

- `changes[].path`
- `changes[].kind`
- `changes[].diff`
- `changes[].kind.type == update` 时的 `movePath`

参考：

- [`lib/codex/app_server/item_adapter.ex#L36-L71`](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/item_adapter.ex#L36-L71)
- [`lib/codex/app_server/item_adapter.ex#L121-L144`](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/item_adapter.ex#L121-L144)

结论：

- “命令执行”与“读文件/搜文件/列目录”这种用户友好分类，应该基于 `commandActions` 二次推导。
- “文件修改”不应该直接压成 `write`，否则会损失 `add/delete/update/move` 等信息。

### 5. approval 关联是按 thread/turn/item 三元组匹配的

Elixir transport 只把下面两个 method 当 approval request：

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`

并且要求它们与当前 thread/turn 匹配。

参考：

- [`lib/codex/transport/app_server.ex#L320-L342`](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/transport/app_server.ex#L320-L342)
- [`lib/codex/app_server/approvals.ex#L12-L95`](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/approvals.ex#L12-L95)

这套策略很适合直接借鉴：

- approval 自己是一类独立事件。
- 它通过 `(thread_id, turn_id, item_id)` 回挂到已有 item。
- 不把 approval 本身塞进工具类别推导逻辑。

### 6. 对缺失 `call_id` 的工具调用，第三方 SDK 明确做了 fallback 去重

虽然这部分主要出现在它的高层 runner，而不是纯 app-server transport，但思路非常值得参考：

- 优先用 `call_id`
- 没有 `call_id` 时退化到 `hash(tool_name, arguments)`

参考：

- [`lib/codex/thread.ex#L1806-L1866`](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/thread.ex#L1806-L1866)
- [`test/codex/thread_test.exs#L996-L1028`](https://github.com/nshkrdotcom/codex_sdk/blob/master/test/codex/thread_test.exs#L996-L1028)

这条规则可以直接迁移成 TidyFlow 的补救策略：

- 协议主键优先：`(session/thread, turn, itemId)`
- 若未来接到只有 `call_id` 的高层工具事件，优先 `(session, call_id)`
- 若连 `call_id` 都没有，再退到 `(tool_name, normalized_arguments_hash)`

### 7. 测试明确验证了“流式更新不是一次性结果”

第三方测试里专门断言：

- `mcpToolCall` 会先收到 `ItemUpdated`，结果里只有部分 `result.content`
- 最后再收到 `ItemCompleted`，状态变成 `:completed`，`structured_content` 也补全

参考：

- [`test/codex/thread_test.exs#L457-L514`](https://github.com/nshkrdotcom/codex_sdk/blob/master/test/codex/thread_test.exs#L457-L514)

这说明：

- 对 MCP 工具尤其不能只看完成态快照，也不能把中间态覆盖成最终态之后丢弃增量上下文。
- UI 层与持久化层都需要“同一 item 的进行中快照”。

## 四、`just-every/code` 暴露出的协议行为语义

这个分叉的价值主要不在客户端实现，而在它把 app-server 行为说明写得很细。

### 1. 它把工具相关 item、生命周期、approval 顺序都说清楚了

README 直接列出所有工具相关 item 及字段：

- `commandExecution`
- `fileChange`
- `mcpToolCall`
- `collabToolCall`
- `webSearch`
- `imageView`

并强调：

- `item/started` 是开始态完整快照
- `item/completed` 是最终权威状态
- `item/commandExecution/outputDelta` 只负责流式输出
- `item/fileChange/outputDelta` 是底层 `apply_patch` 响应

参考：

- [`codex-rs/app-server/README.md#L767-L809`](https://github.com/just-every/code/blob/main/codex-rs/app-server/README.md#L767-L809)

### 2. approval 顺序文档非常适合作为实现验收标准

它明确给出了 command/file 两种 approval 顺序：

1. `item/started`
2. `item/*/requestApproval`
3. 客户端 response
4. `serverRequest/resolved`
5. `item/completed`

参考：

- [`codex-rs/app-server/README.md#L831-L856`](https://github.com/just-every/code/blob/main/codex-rs/app-server/README.md#L831-L856)

这可以直接作为 TidyFlow 归一化层的状态机验收标准。

### 3. 协议枚举明确把动态工具调用单列出来

`just-every/code` 的 app-server protocol 明确声明：

- `item/tool/call` 是客户端执行动态工具调用
- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/agentMessage/delta`
- `item/commandExecution/outputDelta`
- `item/fileChange/outputDelta`

参考：

- [`codex-rs/app-server-protocol/src/protocol/common.rs#L653-L682`](https://github.com/just-every/code/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs#L653-L682)
- [`codex-rs/app-server-protocol/src/protocol/common.rs#L796-L804`](https://github.com/just-every/code/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs#L796-L804)

这说明一件事：

- 如果 TidyFlow 未来只围绕 `commandExecution/fileChange/mcpToolCall` 建模，会漏掉 `dynamicToolCall` 这条协议分支。

## 五、综合结论：最值得直接采用的解析与归一化规则

### 1. 先保留协议原生 item type，再做第二层工具分类

建议拆成两个维度：

- `protocol_item_type`
  - `command_execution`
  - `file_change`
  - `mcp_tool_call`
  - `dynamic_tool_call`
  - `collab_tool_call`
  - `web_search`
  - `image_view`
- `normalized_tool_family`
  - `read`
  - `list`
  - `search`
  - `execute`
  - `edit`
  - `mcp`
  - `dynamic`
  - `collab`
  - `web`
  - `view`
  - `other`

这样做的好处：

- 第一层对协议变化稳定。
- 第二层对 UI/统计/过滤友好。
- 不会因为分类推导失误丢掉原始语义。

### 2. 主键不要只用 `tool_name` 或 `tool_call_id`

对 Codex app-server，建议优先级如下：

1. `(session_or_thread_id, turn_id, item_id)`
2. `(session_or_thread_id, call_id)`
3. `(session_or_thread_id, normalized_tool_name, normalized_arguments_hash)`

原因：

- app-server 的实时流主要围绕 `itemId` 运转。
- approval 也通过 `itemId` 回挂。
- `call_id` 适合高层动态工具或 runner 事件，但不是所有 app-server item 都显式暴露。

### 3. 状态必须保真，至少保留这五类

- `pending`
- `running`
- `completed`
- `failed`
- `declined`

如果需要对外统一，可以再映射出一层展示状态，但底层持久化不要把 `declined` 折叠成 `error`。

### 4. 生命周期必须按“started + deltas + completed”建模

建议统一流程：

1. `item/started` 创建进行中快照
2. delta 事件按 `item_id` 追加或更新缓冲区
3. `item/completed` 覆盖为最终权威快照
4. `serverRequest/resolved` 单独清理 approval 挂件

不要把 delta 直接当最终输出，也不要假设 `turn/completed` 里会提供完整 item 列表。

### 5. `commandExecution` 的二级分类应基于 `commandActions`

可直接借鉴当前 TidyFlow 的思路，但要从“最终 tool_name”降级为“family 推断”：

- `read -> read`
- `listFiles -> list`
- `search -> search`
- 其他 -> `execute`

这样可以保留 `protocol_item_type = command_execution`，同时仍满足 UI 的读/搜/执行分类需求。

### 6. `fileChange` 不应直接压成 `write`

更合理的做法：

- `protocol_item_type = file_change`
- `normalized_tool_family = edit`
- 额外保留：
  - `paths`
  - `changes[].kind`
  - `changes[].diff`
  - `move_path`

否则后续做 diff 展示、批量统计、审批文案时都要重新从原始 JSON 猜。

### 7. `mcpToolCall`、`dynamicToolCall`、`collabToolCall` 需要单列

原因分别不同：

- `mcpToolCall` 有 `server/tool/arguments/result/error`
- `dynamicToolCall` 是客户端执行的动态工具
- `collabToolCall` 本质上是 agent 间协作，不是本地文件/命令工具

把这三者全折到 “other” 会让后续多 agent、多工作区设计变得很难扩展。

### 8. 未知 item type 必须 raw fallback

建议保留：

- 原始 `type`
- 原始 `item`
- 原始 `method`
- 解析失败原因

这点上游和第三方 SDK 都是一致的：未知不崩、原样透传。

## 六、和当前 TidyFlow 实现的对照

当前 `core/src/ai/codex/tool_mapping.rs` 已经做了几件正确的事：

- 有一层 `canonical_method()` 做大小写/分隔符归一化。
- 能从 `commandActions` 推断 `read/list/grep`。
- 能从 `fileChange.changes` 提取 `path` 和 `diff`。
- 对未知工具会保留 `raw`。

参考：

- [core/src/ai/codex/tool_mapping.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/codex/tool_mapping.rs#L4)
- [core/src/ai/codex/tool_mapping.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/codex/tool_mapping.rs#L48)
- [core/src/ai/codex/tool_mapping.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/codex/tool_mapping.rs#L62)
- [core/src/ai/codex/tool_mapping.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/codex/tool_mapping.rs#L293)

但和 GitHub 上这些样本相比，还有四个明显差距：

### 1. 把协议类型和归一化类别混成了一层

当前：

- `commandExecution -> read/list/grep/bash`
- `fileChange -> write`

问题：

- 丢失协议原生 item type。
- 后续无法区分“命令执行型 read”与“原生 fileRead”。

### 2. 把 `declined/cancelled` 直接压成 `error`

当前：

- `failed | error | declined | cancelled | canceled -> error`

问题：

- 审批拒绝和执行失败语义不同。
- 统计、回放、UI 文案都会失真。

### 3. 归一化输出主要围绕单个 item 快照，缺少明确的 item 生命周期层

当前文件主要处理 `item -> AiPart` 映射，但没有把：

- `item/started`
- delta
- `item/completed`

作为一套单独状态机抽象出来。

### 4. 尚未把 `dynamicToolCall`、`collabToolCall` 明确纳入第一层模型

这会限制后续多 agent、多工作区场景。

## 七、建议的直接落地方案

如果下一步要优化核心“归一化工具分类逻辑”，建议先落这三个结构，而不是继续在 `tool_name` 上追加 if/else：

### 方案 A：引入协议原生维度

新增字段：

- `vendor = codex`
- `protocol_item_type`
- `protocol_status`
- `item_id`
- `thread_id`
- `turn_id`

### 方案 B：把归一化分类改成派生字段

新增字段：

- `normalized_tool_family`
- `normalized_tool_action`
- `normalized_title`

其中：

- `family` 表示大类，如 `execute/edit/mcp/collab`
- `action` 表示细分动作，如 `read/list/search/apply_patch`

### 方案 C：单独建立 item 聚合器

它的职责只做：

- 创建 started 快照
- 吸收 delta
- 合并 approval
- 以 completed 收口

做完这层后，再把最终聚合结果喂给现有 `AiPart` 映射会更干净。

## 八、可直接作为实现验收标准的检查项

后续改造完成后，至少应满足下面这些行为：

1. 同一个 `itemId` 的 `started`、delta、`completed` 会被聚成同一条工具记录。
2. `commandExecution` 和 `fileChange` 的 approval 会挂到正确 item 上，而不是丢成独立消息。
3. `declined` 不会再显示成普通错误。
4. `commandExecution` 既保留原始协议类型，也能派生出 `read/list/search/execute`。
5. `fileChange` 能区分 `add/delete/update/move`。
6. `mcpToolCall`、`dynamicToolCall`、`collabToolCall` 不会再落入模糊的 `other`。
7. 未知 item type 会保留 raw payload，而不是导致整条消息丢失。

## 参考链接

### openai/codex

- [sdk/python/src/codex_app_server/client.py#L455-L483](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/client.py#L455-L483)
- [sdk/python/src/codex_app_server/generated/notification_registry.py#L68-L85](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/generated/notification_registry.py#L68-L85)
- [sdk/python/src/codex_app_server/generated/v2_all.py#L3530-L3615](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/generated/v2_all.py#L3530-L3615)
- [sdk/python/src/codex_app_server/generated/v2_all.py#L6578-L6672](https://github.com/openai/codex/blob/main/sdk/python/src/codex_app_server/generated/v2_all.py#L6578-L6672)
- [sdk/typescript/src/items.ts#L5-L127](https://github.com/openai/codex/blob/main/sdk/typescript/src/items.ts#L5-L127)

### nshkrdotcom/codex_sdk

- [lib/codex/app_server/notification_adapter.ex#L129-L235](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/notification_adapter.ex#L129-L235)
- [lib/codex/app_server/item_adapter.ex#L6-L160](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/item_adapter.ex#L6-L160)
- [lib/codex/app_server/approvals.ex#L12-L95](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/app_server/approvals.ex#L12-L95)
- [lib/codex/transport/app_server.ex#L320-L342](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/transport/app_server.ex#L320-L342)
- [lib/codex/thread.ex#L1806-L1866](https://github.com/nshkrdotcom/codex_sdk/blob/master/lib/codex/thread.ex#L1806-L1866)
- [test/codex/thread_test.exs#L457-L514](https://github.com/nshkrdotcom/codex_sdk/blob/master/test/codex/thread_test.exs#L457-L514)
- [test/codex/thread_test.exs#L996-L1028](https://github.com/nshkrdotcom/codex_sdk/blob/master/test/codex/thread_test.exs#L996-L1028)

### just-every/code

- [codex-rs/app-server/README.md#L767-L856](https://github.com/just-every/code/blob/main/codex-rs/app-server/README.md#L767-L856)
- [codex-rs/app-server-protocol/src/protocol/common.rs#L653-L682](https://github.com/just-every/code/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs#L653-L682)
- [codex-rs/app-server-protocol/src/protocol/common.rs#L796-L804](https://github.com/just-every/code/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs#L796-L804)
