# Kimi ACP 工具调用解析逻辑调研

更新时间：2026-03-13

目标：调研 GitHub 上已经接入 Kimi ACP 的开源实现，提炼“工具调用如何解析、如何合并、如何分类”的可复用规则，为 TidyFlow Core 的归一化工具分类逻辑提供直接参考。

## 调研范围

本次只看和 Kimi ACP 实际接线相关、且代码里能看到 `tool_call` / `tool_call_update` 处理逻辑的实现：

| 仓库 | 角色 | 关注点 |
| --- | --- | --- |
| [MoonshotAI/kimi-cli](https://github.com/MoonshotAI/kimi-cli/tree/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4) | Kimi ACP 服务端 | Kimi 实际发什么、何时把 `content` 当输入/输出、终端工具如何编码 |
| [zed-industries/zed](https://github.com/zed-industries/zed/tree/a8d0cdb5598b0775aefa39e8567698a38deeec20) | ACP 客户端 | 工具调用如何 upsert、类型化渲染、如何保留原始语义 |
| [yetone/avante.nvim](https://github.com/yetone/avante.nvim/tree/9a7793461549939f1d52b2b309a1aa44680170c8) | ACP 客户端 | 轻量客户端如何做消息透传、合并和 UI 映射 |

## 一、Kimi CLI：服务端实际产出的工具调用形态

### 1. `tool_call` 的标题不是纯工具名，而是“工具名 + 关键参数摘要”

Kimi 在服务端维护 `_ToolCallState`，把原始 `function.arguments` 持续喂给 `streamingjson.Lexer`，再用 `extract_key_argument()` 从参数里抽取关键字段，动态生成标题。

- 代码：
  - [`session.py#L75-L106`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/session.py#L75-L106)
  - [`tools/__init__.py#L17-L97`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/tools/__init__.py#L17-L97)

直接结论：

- `ReadFile` 标题会变成 `ReadFile: path/to/file`
- `Shell` 标题会变成 `Shell: npm test`
- `Glob` / `Grep` / `SearchWeb` / `FetchURL` 也会把关键参数拼进标题

这说明：

- 对 Kimi 来说，`title` 不是纯展示字段，它本身就承载了弱结构化语义。
- 当 `rawInput` 缺失时，`title` 前缀和冒号前的 token 很适合参与归一化分类。

### 2. `tool_call` 与 `tool_call_update` 都可能带整段参数文本，而不是纯 delta

Kimi 在 `_send_tool_call()` 里发送 `ToolCallStart`，状态直接是 `in_progress`，并且把当前累计参数文本放进 `content=[{type:"content", content:{type:"text", text: args}}]`。

随后 `_send_tool_call_part()` 并不是只发新增片段，而是把“累计后的完整参数文本”再次放进 `content` 里发 `ToolCallProgress`。

- 代码：
  - [`session.py#L257-L319`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/session.py#L257-L319)

直接结论：

- Kimi 的 `content[].content.text` 在运行中阶段，更像“当前完整输入快照”，不是严格 append-only delta。
- 如果客户端把它当纯增量拼接，容易重复。
- 更稳妥的做法是：
  - 运行中优先当作“输入快照”
  - 终态再判断是否切换为“输出快照”

### 3. `tool_result` 完成后，同一个 `content` 字段会切换为输出承载

Kimi 在 `_send_tool_result()` 里把状态切到 `completed` / `failed`，然后通过 `tool_result_to_acp_content()` 把工具结果编码为：

- `type="content"`：普通文本输出
- `type="diff"`：文件改动
- `type="terminal"`：终端句柄

- 代码：
  - [`session.py#L321-L349`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/session.py#L321-L349)
  - [`convert.py#L53-L128`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/convert.py#L53-L128)

直接结论：

- Kimi 没有把“输入”和“输出”拆成两个稳定字段。
- 同一字段 `content` 的语义依赖阶段：
  - 运行中：通常更像输入
  - 完成后：通常更像输出

### 4. 终端工具是单独编码的，不能只靠标题或文本判定

Kimi 的 ACP 终端工具会：

- 先通过 `terminal/create` 创建终端
- 立即发一个 `tool_call_update`，其中 `content=[{type:"terminal", terminal_id: ...}]`
- 同时用 `HideOutputDisplayBlock` 避免再把同样的终端输出作为普通文本回灌

- 代码：
  - [`acp/tools.py#L42-L158`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/tools.py#L42-L158)
  - [`convert.py#L104-L128`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/convert.py#L104-L128)

直接结论：

- `content.type == "terminal"` 是终端工具最强信号之一。
- 终端类调用的归一化不能只看 `title` 中是否出现 shell/bash。
- 如果把 `terminal` 内容降级成普通文本，会丢掉“这是会话型终端”的语义。

### 5. `tool_call_id` 会加上 turn 前缀，不能假设是底层工具原始 id

Kimi 为避免跨 turn 重号，会把 ACP 层 id 生成为 `"{turn_id}/{llm_tool_call_id}"`。

- 代码：
  - [`session.py#L85-L93`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/session.py#L85-L93)

直接结论：

- 归一化逻辑不应假设 `tool_call_id` 可反推原始工具名。
- `tool_call_id` 更适合作为会话内主键，不适合作为分类依据。

## 二、Avante.nvim：轻量客户端的解析与合并策略

### 1. 传输层基本是“逐行 JSON-RPC”

Avante 的 ACP client 通过 stdio 读 stdout，按换行拆包，每行做一次 JSON decode。收到 `session/update` 后，几乎不做协议层重写，只把 `update` 透传给上层 handler。

- 代码：
  - [`acp_client.lua#L408-L438`](https://github.com/yetone/avante.nvim/blob/9a7793461549939f1d52b2b309a1aa44680170c8/lua/avante/libs/acp_client.lua#L408-L438)
  - [`acp_client.lua#L572-L638`](https://github.com/yetone/avante.nvim/blob/9a7793461549939f1d52b2b309a1aa44680170c8/lua/avante/libs/acp_client.lua#L572-L638)

直接结论：

- Avante 的“解析”主要发生在 UI 层，而不是 ACP transport 层。
- 这类实现适合作为“最小保真客户端”参考，不适合作为强归一化规则来源。

### 2. `tool_call` 初次入栈时，名字优先取 `kind`，其次才是 `title`

Avante 把工具调用映射成一条 `tool_use` 消息：

- `id = toolCallId`
- `name = update.kind or update.title`
- `input = update.rawInput or {}`

- 代码：
  - [`llm.lua#L957-L978`](https://github.com/yetone/avante.nvim/blob/9a7793461549939f1d52b2b309a1aa44680170c8/lua/avante/llm.lua#L957-L978)

直接结论：

- Avante 默认把 `kind` 当成面向 UI 的稳定分类字段。
- 如果 `kind` 缺失，才退回 `title`。
- 这和 Kimi 服务端的输出风格是兼容的，因为 Kimi 常常只有 `title` 有强语义。

### 3. `tool_call_update` 以 `toolCallId` 为键深合并，且会避免空数组清空已有内容

Avante 在收到 `tool_call_update` 后：

- 先按 `toolCallId` 找已有消息
- 如果没有就补一条占位 `tool_use`
- 用 `vim.tbl_deep_extend("force", old, update)` 合并
- 如果 `update.content` 是空数组，先改成 `nil`，避免把旧内容硬清掉

- 代码：
  - [`llm.lua#L1136-L1170`](https://github.com/yetone/avante.nvim/blob/9a7793461549939f1d52b2b309a1aa44680170c8/lua/avante/llm.lua#L1136-L1170)

直接结论：

- 对流式 `tool_call_update`，key 一定是 `toolCallId`，不是标题。
- “空内容不覆盖旧内容”是一个很实用的防抖规则，尤其适合 Kimi 这种不同阶段复用 `content` 的实现。

### 4. `locations` 和 `kind=edit` 会被直接用于 UI 导航，而不是再从标题猜

Avante 只有在 `update.kind == "edit"` 且带 `locations` 时才会自动跳转到文件位置。

- 代码：
  - [`llm.lua#L1068-L1133`](https://github.com/yetone/avante.nvim/blob/9a7793461549939f1d52b2b309a1aa44680170c8/lua/avante/llm.lua#L1068-L1133)

直接结论：

- 一旦上游已经给出 `kind` 和 `locations`，客户端不会再通过标题或输出文本二次猜测。
- 这说明“归一化分类”和“位置解析”最好是共享层职责，不应该散落到视图层。

## 三、Zed：强类型客户端的解析与保真策略

### 1. Zed 明确承认 ACP 缺少 programmatic tool name，因此额外用 `meta.tool_name`

Zed 在 `acp_thread` 里定义了 `TOOL_NAME_META_KEY = "tool_name"`，专门从 `meta` 提取工具的程序化名称，因为 ACP 的 `ToolCall` 没有独立的 `name` 字段。

- 代码：
  - [`acp_thread.rs#L37-L52`](https://github.com/zed-industries/zed/blob/a8d0cdb5598b0775aefa39e8567698a38deeec20/crates/acp_thread/src/acp_thread.rs#L37-L52)

直接结论：

- “原始工具名”和“UI 展示标题”是两层语义。
- 如果协议本身没有 name 字段，保留 `meta.tool_name` 一类旁路字段是合理做法。
- 这对 TidyFlow 很关键：不要过早把所有东西折叠成 `read/edit/write` 这种卡片类别。

### 2. Zed 保留 `kind`、`raw_input`、`raw_output`、`content` 四套信息，不提前塌缩

Zed 的 `ToolCall::from_acp()` / `update_fields()` 会同时保存：

- `kind`
- `title`
- `content`
- `raw_input`
- `raw_output`
- `locations`
- `meta.tool_name`

- 代码：
  - [`acp_thread.rs#L237-L390`](https://github.com/zed-industries/zed/blob/a8d0cdb5598b0775aefa39e8567698a38deeec20/crates/acp_thread/src/acp_thread.rs#L237-L390)

直接结论：

- Zed 的策略不是“立刻做强归一化”，而是“先保真，再在 UI/行为层消费”。
- 这比单一 `tool_name` 字段更适合长期扩展。

### 3. `content` 会被强类型分成 `ContentBlock` / `Diff` / `Terminal`

Zed 解析 `ToolCallContent` 时直接分支：

- `Content` -> 文本/资源
- `Diff` -> 文件改动对象
- `Terminal` -> 终端对象

- 代码：
  - [`acp_thread.rs#L705-L836`](https://github.com/zed-industries/zed/blob/a8d0cdb5598b0775aefa39e8567698a38deeec20/crates/acp_thread/src/acp_thread.rs#L705-L836)

直接结论：

- `diff`、`terminal` 不应该在归一化阶段被压扁成普通文本输出。
- 这类类型信息本身就是工具分类的重要依据。

### 4. 工具调用采用 upsert 语义；更新先到也不会直接丢

Zed 处理 `session/update` 时：

- `ToolCall` -> `upsert_tool_call`
- `ToolCallUpdate` -> `update_tool_call`

如果 update 比 start 更早到，Zed 会创建一个失败占位项而不是静默丢弃。

- 代码：
  - [`acp_thread.rs#L1275-L1313`](https://github.com/zed-industries/zed/blob/a8d0cdb5598b0775aefa39e8567698a38deeec20/crates/acp_thread/src/acp_thread.rs#L1275-L1313)
  - [`acp_thread.rs#L1474-L1614`](https://github.com/zed-industries/zed/blob/a8d0cdb5598b0775aefa39e8567698a38deeec20/crates/acp_thread/src/acp_thread.rs#L1474-L1614)

直接结论：

- 流式环境下应该默认允许乱序或半序。
- “更新先到”不是异常边角，而是需要被显式兜底的现实情况。

### 5. 终端不仅看 `content.type=terminal`，还会读 meta 里的附加通道

Zed 在 agent server 层还做了额外处理：

- `ToolCall.meta.terminal_info`：先创建 display-only terminal
- `ToolCallUpdate.meta.terminal_output`：持续灌输出
- `ToolCallUpdate.meta.terminal_exit`：写退出状态

- 代码：
  - [`agent_servers/acp.rs#L1267-L1355`](https://github.com/zed-industries/zed/blob/a8d0cdb5598b0775aefa39e8567698a38deeec20/crates/agent_servers/src/acp.rs#L1267-L1355)

直接结论：

- 真正的终端类工具，通常不止一个字段能说明问题。
- 归一化时如果只盯 `title` / `kind`，会漏掉 `meta` 提供的强信号。

## 四、三类实现的共同模式

把三个仓库放在一起看，能得到几个稳定结论：

1. `toolCallId` 是主键，不是分类字段。
2. `title` 在 Kimi 生态里是带语义的，尤其冒号前的前缀和冒号后的关键参数摘要。
3. `kind` 更适合作为高层类别，但很多 Kimi 场景里并不稳定或并不总是存在。
4. `rawInput` / `rawOutput` 在强类型客户端里非常重要，不能过早丢掉。
5. `content` 不是纯文本槽位，而是类型化载体；至少要区分 `content` / `diff` / `terminal`。
6. 运行中和完成后的 `content` 语义可能不同，Kimi 尤其明显。
7. 终端工具必须特殊处理，否则会把“终端会话”误降级为普通文本输出。
8. 流式更新必须做 upsert 和乱序兜底，不能假设总是 `tool_call` 先到、`tool_call_update` 后到。

## 五、对 TidyFlow Core 的直接建议

结合外部实现和当前代码 `core/src/ai/acp/tool_call.rs`，建议把归一化拆成两层，而不是只保留一个折叠后的 `tool_name`。

### 建议 1：保留“双层分类”

当前 TidyFlow 已经会把很多输入收敛到 `read` / `edit` / `write` / `terminal` / `search`。

- 参考代码：
  - `normalize_tool_name()`：[`core/src/ai/acp/tool_call.rs#L230-L259`](../../core/src/ai/acp/tool_call.rs)
  - `tool_kind_semantic_id()`：[`core/src/ai/acp/tool_call.rs#L267-L285`](../../core/src/ai/acp/tool_call.rs)

建议升级为同时保留：

- `raw_tool_name`
  - 例如 `ReadFile` / `StrReplaceFile` / `Shell`
- `raw_kind`
  - 例如 `read` / `edit` / `execute`
- `semantic_family`
  - 例如 `file_read` / `file_edit` / `terminal` / `web_fetch`
- `ui_card_kind`
  - 例如 `read` / `edit` / `write` / `terminal` / `search`

原因：

- Zed 明确保留 `meta.tool_name` 和 `kind` 两层语义。
- Avante 也只是拿 `kind` 做 UI 名称，不会反过来把它当唯一真值。
- 如果现在就把 `delete` / `move` / `str_replace` 全折叠进 `edit`，后续再做更细的归一化会很被动。

### 建议 2：明确“阶段感知”的输入/输出判定

当前 TidyFlow 已经对 Kimi 的数组 `content` 做了阶段判定：

- 运行中时偏向输入
- 终态时偏向输出

- 参考代码：
  - [`core/src/ai/acp/tool_call.rs#L548-L859`](../../core/src/ai/acp/tool_call.rs)

这条方向是对的，建议继续强化为固定顺序：

1. 先看显式 `rawInput` / `rawOutput`
2. 再看 `content` 是否包含 `diff` / `terminal` 等非文本项
3. 再看状态是否已终态
4. 最后才把 Kimi 文本数组解释成输入或输出

原因：

- 这是 Kimi CLI 实际产出方式决定的。
- 也是避免把运行中参数文本误判成工具输出的最稳路径。

### 建议 3：把 `meta` 纳入归一化优先级

当前 TidyFlow 解析事件时主要关注：

- `toolName` / `tool_name` / `name`
- `kind`
- `title`
- `rawInput` / `rawOutput`

但还没有像 Zed 一样把 `meta.tool_name`、`meta.terminal_info`、`meta.terminal_output`、`meta.terminal_exit` 作为一等输入源。

建议分类优先级改成：

1. `meta.tool_name`
2. 显式 `toolName` / `name`
3. `kind`
4. `rawInput` 结构
5. `title` 前缀

终端补充信号：

1. `content.type == "terminal"`
2. `meta.terminal_info`
3. `meta.terminal_output`
4. `meta.terminal_exit`
5. `kind == execute`
6. `title` / `rawInput.command`

### 建议 4：不要过早把结构化 `content` 压回字符串

当前 TidyFlow 已经会保留 `structured_content`，这是正确方向。

- 参考代码：
  - [`core/src/ai/acp/tool_call.rs#L566-L783`](../../core/src/ai/acp/tool_call.rs)

建议进一步约束：

- 只要 `content` 中出现 `diff` / `terminal` / 非纯文本块，就把它当结构化输出保留。
- 文本提取只作为摘要、副本或搜索索引，不应替代原结构。

### 建议 5：合并策略继续保持单调状态，但增加“空更新不清空”规则

当前 TidyFlow 已经做了：

- 状态单调合并
- 输出去重拼接
- `progress_lines` 追加

- 参考代码：
  - [`core/src/ai/acp/tool_call.rs#L937-L1125`](../../core/src/ai/acp/tool_call.rs)

建议再补两条：

1. 如果新 update 的 `content=[]` 或空对象，默认不覆盖旧内容。
2. 如果先收到 update、后收到 start，不要只靠日志忽略；应该生成占位 tool state，后续再回填。

这两条分别来自：

- Avante 的空内容防清空策略
- Zed 的 update 先到兜底策略

### 建议 6：把“位置解析”从文本猜测切到结构字段优先

当前 TidyFlow 已支持从 `locations`、`raw_input.path`、`view_range` 等提取位置。

- 参考代码：
  - [`core/src/ai/acp/tool_call.rs#L377-L527`](../../core/src/ai/acp/tool_call.rs)

建议维持这个方向，不要回退到依赖 `title` 或输出文本中的路径猜测。

原因：

- Avante 和 Zed 都是“有 `locations` 就直接消费”。
- 位置字段属于共享状态，不应该让各端 UI 自己猜。

## 六、对当前 TidyFlow 实现的判断

当前实现已经覆盖了不少关键点，尤其是：

1. 已经识别 Kimi 的数组 `content` 双语义。
2. 已经把 `kind` 做了语义归一化。
3. 已经保留结构化 `content`，不会无脑压成字符串。
4. 已经支持状态单调合并和输出去重。
5. 已经支持从输入和输出里补抽 `locations`。

真正值得继续优化的点主要有四个：

1. 过早把工具名收敛成 UI 卡片类别，原始工具名保真还不够强。
2. `meta` 还不是归一化首层输入源，尤其终端附加通道还没纳入。
3. 乱序 update 的兜底策略可以更显式。
4. `delete` / `move` / `edit` / `write` 目前过早折叠，后续如果要做更细工具分析会受限。

## 七、推荐的归一化决策顺序

建议在 Core 中固定为以下顺序：

1. 提取原始字段：
   - `tool_call_id`
   - `meta.tool_name`
   - `toolName/name`
   - `kind`
   - `title`
   - `rawInput/rawOutput`
   - `content`
   - `locations`
   - `meta.terminal_*`
2. 识别承载类型：
   - `terminal`
   - `diff`
   - `content/text`
3. 判断阶段：
   - `pending/in_progress`
   - `completed/failed/cancelled`
4. 生成双层结果：
   - `raw_tool_name/raw_kind`
   - `semantic_family/ui_card_kind`
5. 再做合并：
   - 按 `tool_call_id`
   - 状态单调
   - 空内容不清空
   - 输出做前后缀去重
   - 位置字段只增不乱退

## 八、附：本次重点源码入口

- Kimi CLI
  - [`src/kimi_cli/acp/session.py`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/session.py)
  - [`src/kimi_cli/acp/tools.py`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/tools.py)
  - [`src/kimi_cli/acp/convert.py`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/acp/convert.py)
  - [`src/kimi_cli/tools/__init__.py`](https://github.com/MoonshotAI/kimi-cli/blob/2e2eb2a1d868357eb48f96e2fc7f8ef9bec664d4/src/kimi_cli/tools/__init__.py)
- Zed
  - [`crates/acp_thread/src/acp_thread.rs`](https://github.com/zed-industries/zed/blob/a8d0cdb5598b0775aefa39e8567698a38deeec20/crates/acp_thread/src/acp_thread.rs)
  - [`crates/agent_servers/src/acp.rs`](https://github.com/zed-industries/zed/blob/a8d0cdb5598b0775aefa39e8567698a38deeec20/crates/agent_servers/src/acp.rs)
- Avante.nvim
  - [`lua/avante/libs/acp_client.lua`](https://github.com/yetone/avante.nvim/blob/9a7793461549939f1d52b2b309a1aa44680170c8/lua/avante/libs/acp_client.lua)
  - [`lua/avante/llm.lua`](https://github.com/yetone/avante.nvim/blob/9a7793461549939f1d52b2b309a1aa44680170c8/lua/avante/llm.lua)

