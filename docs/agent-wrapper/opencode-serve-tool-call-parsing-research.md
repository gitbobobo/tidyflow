# OpenCode Serve 工具调用解析逻辑调研

更新时间：2026-03-13

目标：调研 GitHub 上已经接入 `opencode serve` 事件流的开源实现，提炼“工具调用如何解析、如何合并、如何分类”的可复用规则，为 TidyFlow Core 的归一化工具分类逻辑提供直接参考。

## 调研范围

本次只看确实消费 `opencode serve` 事件流、且代码里能看到 `message.part.updated` / 工具 part 处理逻辑的实现：

| 仓库 | 角色 | 关注点 |
| --- | --- | --- |
| [bjesus/opencode-web](https://github.com/bjesus/opencode-web/tree/7205e20c2c89412382eac32e4159b59133fb9d99) | 极简 Web 客户端 | 最小保真透传、part upsert、工具结果最基础渲染 |
| [chris-tse/opencode-web](https://github.com/chris-tse/opencode-web/tree/0ab3c855189064e756aec2be27617e5caf9d56ff) | Web 客户端 | UI 层工具状态文案、基于 `args` 和 `cwd` 的标题推导 |
| [different-ai/openwork](https://github.com/different-ai/openwork/tree/8011579c8a5fad5791e93a1c4af922e61e2f58da) | 多端客户端与桥接器 | 会话层批处理/去抖、文本 delta 追加、工具分类与摘要、`callID` 去重 |

## 一、共性结论

### 1. 开源客户端普遍把“工具调用”当作 `message.part.updated` 里的 `part.type == "tool"`

几个样本都没有单独定义一套 `tool_call` 传输层，而是统一在 `message.part.updated` 里取：

- `part.type`
- `part.id`
- `part.callID`
- `part.tool`
- `part.state.status`
- `part.state.input`
- `part.state.output`
- `part.state.title`

直接含义：

- OpenCode Serve 下的“工具调用对象”本质上是消息 part，不是独立协议层实体。
- 如果 TidyFlow 要做归一化工具分类，第一步主键应该先落在 part 维度，而不是只看工具名。

### 2. `delta` 主要服务文本 part；工具 part 通常按“完整快照替换”处理

本次看到的真实实现里：

- `different-ai/openwork` 只对 `part.type == "text"` 且 `delta` 存在时做追加；其他情况一律整体替换 part。
- `bjesus/opencode-web` 和 `chris-tse/opencode-web` 都直接把 `message.part.updated` 当成完整 part 快照处理。

直接含义：

- 归一化层不要把工具输出默认当 append-only 流。
- 工具 part 更适合作为“可覆盖快照”；文本 part 才适合 delta 追加。

### 3. 工具分类的上游信号强弱排序基本一致

从几个实现可以抽出一个很稳定的优先级：

1. `part.type == "tool"`
2. `part.tool`
3. `part.state.input`
4. `part.state.title`
5. `part.state.output`

直接含义：

- 分类优先级应当是“结构化字段优先、展示文案次之、输出文本最后兜底”。
- 如果只靠输出文本或标题分类，容易把同一种工具在不同阶段误判成不同类别。

## 二、各实现的具体解析逻辑

## 1. `bjesus/opencode-web`：最小保真透传客户端

### 1.1 事件层只做分发，不做工具专属改写

这个项目的 `subscribeToEvents()` 只是按事件名 switch，把 `message.part.updated` 原样交给 `onPartUpdate`。

- 代码：
  - [`src/api/sse.ts#L12-L45`](https://github.com/bjesus/opencode-web/blob/7205e20c2c89412382eac32e4159b59133fb9d99/src/api/sse.ts#L12-L45)

直接结论：

- 它不在 transport 层处理工具调用。
- 这类实现适合作为“最小保真客户端”参考，不适合作为强归一化规则来源。

### 1.2 part 合并键是 `(messageId, part.id)`，更新策略是整体替换

`updatePart()` 会先按 `messageId` 找消息，再按 `part.id` 找 part；找到就整条替换，找不到就插入。

- 代码：
  - [`src/stores/session.ts#L61-L80`](https://github.com/bjesus/opencode-web/blob/7205e20c2c89412382eac32e4159b59133fb9d99/src/stores/session.ts#L61-L80)

直接结论：

- 这个项目把 `part.id` 视为消息内稳定主键。
- 它完全不尝试 merge `state.output`、`state.input` 或 `delta`。

### 1.3 工具展示只认三件事：`tool`、`state.status`、终态输出

UI 层渲染逻辑非常直接：

- 运行中：spinner
- 完成：展示 `state.output`
- 失败：展示 `state.error`
- 标题：直接展示 `part.tool`

- 代码：
  - [`src/components/MessageItem.tsx#L86-L136`](https://github.com/bjesus/opencode-web/blob/7205e20c2c89412382eac32e4159b59133fb9d99/src/components/MessageItem.tsx#L86-L136)

直接结论：

- 它没有做“read/edit/search/terminal”二级分类。
- 对归一化层的启发是：原始 `tool` 名和 `state` 应始终完整保留，否则这种最小客户端都很难复现。

## 2. `chris-tse/opencode-web`：UI 层启发式分类与标题推导

### 2.1 底层 store 仍然是按 `part.id` 整体替换

它的 `handlePartUpdated()` 与上一个项目基本一致：按 `messageID` 找消息，再按 `part.id` 找 part，找到后整条替换。

- 代码：
  - [`src/stores/messageStoreV2.ts#L80-L123`](https://github.com/chris-tse/opencode-web/blob/0ab3c855189064e756aec2be27617e5caf9d56ff/src/stores/messageStoreV2.ts#L80-L123)

直接结论：

- 这个项目的“聪明”主要发生在 UI 文案层，不在会话态聚合层。
- 它同样默认工具 part 是快照，不是 delta。

### 2.2 工具状态文案优先依赖 `toolName + state.status`

`useEventStream()` 在收到 `part.type == "tool"` 时，不直接展示原始对象，而是调用 `getContextualToolStatus()` 生成状态文案。

- 代码：
  - [`src/hooks/useEventStream.ts#L48-L103`](https://github.com/chris-tse/opencode-web/blob/0ab3c855189064e756aec2be27617e5caf9d56ff/src/hooks/useEventStream.ts#L48-L103)

直接结论：

- 工具分类和展示在这个实现里是“事件消费后的派生视图”，不是底层状态的一部分。
- 这说明 TidyFlow Core 更适合输出保真字段，再派生归一化分类，而不是反过来只保留分类结果。

### 2.3 它对工具名做了轻量规范化，但并不试图发明新类别

`getToolDisplayName()` 做了三类处理：

- `mcp_` / `localmcp_` 前缀去除
- `webfetch -> Fetch`
- `todowrite` / `todoread -> Plan`

- 代码：
  - [`src/utils/toolStatusHelpers.ts#L26-L49`](https://github.com/chris-tse/opencode-web/blob/0ab3c855189064e756aec2be27617e5caf9d56ff/src/utils/toolStatusHelpers.ts#L26-L49)

直接结论：

- 这个项目偏向“保留原工具名，再做小幅 display normalization”。
- 对 TidyFlow 来说，这是比激进折叠更稳的方向。

### 2.4 运行中标题主要由 `state.args` 推导，而不是靠输出倒推

`getToolTitle()` 的规则比较直接：

- `read/edit/write`：从 `args.filePath` 提取相对路径
- `bash`：取 `args.description`
- `webfetch`：取 URL host
- `todowrite`：按 todo 完成度生成人类可读阶段

- 代码：
  - [`src/utils/toolStatusHelpers.ts#L133-L223`](https://github.com/chris-tse/opencode-web/blob/0ab3c855189064e756aec2be27617e5caf9d56ff/src/utils/toolStatusHelpers.ts#L133-L223)

直接结论：

- `state.args` 是构建工具标题和分类提示的强信号。
- 这比从 `state.output` 里猜“这是读文件还是搜索”稳得多。

### 2.5 它把“仍未完成”的任何工具都视为活跃工具

`getOverallToolStatus()` / `hasActiveToolExecution()` 的逻辑是：

- 只要 `part.type == "tool"` 且 `state.status != completed`，就认为工具仍在执行
- 完成数则单独统计

- 代码：
  - [`src/utils/toolStatusHelpers.ts#L69-L131`](https://github.com/chris-tse/opencode-web/blob/0ab3c855189064e756aec2be27617e5caf9d56ff/src/utils/toolStatusHelpers.ts#L69-L131)

直接结论：

- 即使没有细粒度状态机，这种“未完成即活跃”的规则也足够稳定。
- TidyFlow 的归一化状态层也可以先保持这个保守语义。

## 3. `different-ai/openwork`：会话层批处理、去抖与工具摘要

### 3.1 part upsert 仍然是整体替换，但文本 part 支持 delta 追加

`upsertPartInfo()` 本身只是整体替换；真正的特殊逻辑在 `message.part.updated` 分支：

- 如果 `delta` 存在、`part.type == "text"`、且旧文本不存在同一后缀，就把 delta 追加到旧文本
- 其他情况仍然把整个 part 作为新快照覆盖

- 代码：
  - [`packages/app/src/app/context/session.ts#L111-L117`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/app/src/app/context/session.ts#L111-L117)
  - [`packages/app/src/app/context/session.ts#L1164-L1216`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/app/src/app/context/session.ts#L1164-L1216)

直接结论：

- 这是本次样本里最值得直接借鉴的合并策略。
- 结论很明确：
  - `text` part：可以按 delta 做 append，并带重复尾缀保护
  - `tool` part：按完整快照 replace 更稳

### 3.2 update 可以先于 message 到达，因此它会补占位 message

在处理 `message.part.updated` 时，如果 `draft.messages[part.sessionID]` 里还没有对应 `messageID`，OpenWork 会先通过 `createPlaceholderMessage(part)` 补一条占位消息。

- 代码：
  - [`packages/app/src/app/context/session.ts#L1172-L1178`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/app/src/app/context/session.ts#L1172-L1178)

直接结论：

- 乱序不是异常边角，而是实际客户端显式处理的现实。
- TidyFlow 在多项目、多工作区、多会话并发下也应默认允许“part 先到、message 后到”。

### 3.3 为了性能，它会对 `message.part.updated` 做按 part 粒度 coalescing

OpenWork 在 SSE 消费层维护一个队列和 `coalesced` map：

- `session.status` / `session.idle`：按 `sessionID` 合并
- `message.part.updated`：按 `messageID:part.id` 合并
- flush 时只处理最新事件

- 代码：
  - [`packages/app/src/app/context/session.ts#L1271-L1309`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/app/src/app/context/session.ts#L1271-L1309)

直接结论：

- 对高频工具流和文本流，先 coalesce 再入状态层可以显著减轻 UI 压力。
- 这对 TidyFlow 当前“聊天界面性能优化”的目标尤其直接。

### 3.4 它的工具分类优先看 `toolName`，不是看输出内容

`classifyTool()` 的顺序是：

- `skill`
- `read/cat/fetch -> read`
- `apply_patch -> write`
- `edit/replace/update -> edit`
- `write/create/patch -> write`
- `grep/search/find -> search`
- `bash/shell/exec/command/run -> terminal`
- `glob/list/ls -> glob`
- `task/agent/todo -> task`

- 代码：
  - [`packages/app/src/app/utils/index.ts#L609-L621`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/app/src/app/utils/index.ts#L609-L621)

直接结论：

- 这是一个很实用的“工具名 first”规则。
- 即使未来要做更精细的分类，也建议把这类映射作为第一层粗分类，而不是直接废弃。

### 3.5 标题和 detail 来自 `state.input` / `state.title` / `state.output` 的分层回退

OpenWork 构建工具摘要的优先级非常清晰：

- 先看 `toolName`
- 再从 `state.input` 里提取 `filePath`、`pattern`、`command`、`subagent_type`、`url`
- 再退回 `state.title`
- 最后才用 `state.output` 生成完成态短摘要

- 代码：
  - [`packages/app/src/app/utils/index.ts#L682-L865`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/app/src/app/utils/index.ts#L682-L865)
  - [`packages/app/src/app/utils/index.ts#L914-L933`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/app/src/app/utils/index.ts#L914-L933)

直接结论：

- `state.output` 适合作为完成态 detail 的最后兜底，不适合作为主分类依据。
- 这是对“归一化分类逻辑”非常关键的边界。

### 3.6 同仓库的桥接器用 `callID + status` 做去重，而不是重复转发每次工具 update

OpenWork 的 router bridge 在转发工具状态到 Telegram/Slack 时：

- 只处理 `part.type == "tool"`
- 用 `callID` 识别同一次工具调用
- 用 `seenToolStates[callID]` 过滤同状态重复事件
- 文案优先用 `state.title`，否则退回 `formatInputSummary(state.input)`

- 代码：
  - [`packages/opencode-router/src/bridge.ts#L134-L145`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/opencode-router/src/bridge.ts#L134-L145)
  - [`packages/opencode-router/src/bridge.ts#L1591-L1614`](https://github.com/different-ai/openwork/blob/8011579c8a5fad5791e93a1c4af922e61e2f58da/packages/opencode-router/src/bridge.ts#L1591-L1614)

直接结论：

- `part.id` 更适合消息内渲染主键。
- `callID` 更适合跨更新识别“同一次工具调用”的生命周期。

## 三、对 TidyFlow Core 最直接可用的规则

## 1. 主键分层

建议至少拆成两层主键：

- part 主键：`(workspace_scope, sessionID, messageID, partID)`
- tool call 主键：`(workspace_scope, sessionID, callID)`，仅当 `callID` 存在时启用

其中 `workspace_scope` 至少应包含：

- 项目
- 工作区
- 目录或 serve 路由键

原因：

- `part.id` 适合驱动消息 UI 和局部覆盖。
- `callID` 适合识别同一工具调用的连续状态。
- 多项目/多工作区场景下，单独使用 `sessionID` 或 `callID` 都不够稳。

## 2. 合并策略

建议采用下面的归一化合并规则：

- `text` part：若带 `delta`，做 append，并加重复尾缀保护。
- `tool` part：按完整快照 replace，不做输出字符串拼接。
- update 先到时：补 placeholder message，不要丢事件。
- `session.status` / `session.idle`：允许被后来的同 key 事件覆盖。

这基本就是 `different-ai/openwork` 的做法，只是需要把主键扩展到 TidyFlow 的多工作区语义。

## 3. 分类优先级

建议把工具归一化分类的优先级固定为：

1. `part.type`
2. `part.tool`
3. `state.input`
4. `state.title`
5. `state.output`

建议的第一层粗分类映射：

- `read/cat/fetch` -> `read`
- `edit/replace/update` -> `edit`
- `write/create/patch/apply_patch` -> `write`
- `grep/search/find` -> `search`
- `bash/shell/exec/command/run` -> `terminal`
- `glob/list/ls` -> `list`
- `task/agent/todo` -> `task`
- `skill` -> `skill`
- 其他 -> `tool`

重点：

- `output` 只做 detail 和完成态摘要，不做主分类依据。
- `title` 可以参与展示，但不应覆盖 `tool` 的程序语义。

## 4. 标题与 detail 的推荐来源

可以直接沿用 OpenWork 这类分层策略：

- 标题优先从 `state.input` 中取结构化关键参数：
  - `filePath/path/file`
  - `pattern/query`
  - `command/cmd`
  - `url`
  - `subagent_type`
- 若没有，再退回 `state.title`
- detail 再从以下字段取：
  - `offset/limit`
  - `path/files`
  - `command`
  - `pattern`
  - `subtitle/detail/summary`
  - 完成态 `output` 首个有效摘要行

这能避免把大段输出提前塞进归一化主视图。

## 5. 性能与去抖

如果 Core 要直接给 Apple 端稳定、高频的流式工具状态，建议在 Core 或共享层就做 coalescing：

- `message.part.updated` 按 `(workspace_scope, sessionID, messageID, partID)` 合并
- `session.status` / `session.idle` 按 `(workspace_scope, sessionID)` 合并
- flush 周期可比普通状态刷新稍长一些，让文本和工具高频流先收敛

这条规则直接来自 `different-ai/openwork`，也是最贴近当前项目性能目标的一条。

## 四、最终结论

从 GitHub 上真实接入 `opencode serve` 的开源实现看，比较稳定的共识不是“把工具调用做成一套复杂状态机”，而是：

- 把工具调用当作 `tool part` 快照
- 用 `part.id` 做消息内 upsert
- 用 `callID` 做同一次工具调用识别
- 文本 delta 追加、工具快照替换
- 分类先看 `tool`，标题先看 `input`
- 输出只做完成态摘要

对 TidyFlow Core 来说，最直接可落地的方案不是增加更多字符串猜测，而是先把这些保真字段稳定保留下来，再在共享归一化层上做：

- 主键分层
- 工具名粗分类
- 结构化输入驱动的标题/detail 生成
- 高并发流式事件的 coalescing

这会比单纯从 `state.output` 或 `title` 猜工具类别更稳，也更适合多项目、多工作区、多会话并行场景。
