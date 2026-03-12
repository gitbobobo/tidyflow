# Claude `--print` 协议工具调用解析逻辑调研

更新时间：2026-03-13

## 目标

这份调研只关注一件事：GitHub 上真实接入 Claude Code `--print` / `--output-format stream-json` 事件流的开源实现，究竟如何解析工具调用、如何拼装生命周期、如何处理部分流式事件，以及哪些规则可以直接转成 TidyFlow Core 的“归一化工具分类逻辑”。

主要用途：

- 为 `core/src/ai/claude_adapter.rs` 的后续重构提供直接可抄的解析策略。
- 避免把 Claude 的工具调用只当作一条 `tool_use` 日志，而忽略它实际是跨 `stream_event`、`assistant`、`user`、`result` 的状态对象。
- 为多项目、多工作区、多会话场景明确主键、父子链路、状态层级和降级策略。

## 调研样本

本次优先挑了五类样本：

| 样本 | 类型 | 价值 |
| --- | --- | --- |
| [anthropics/claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python/tree/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8) | 官方 SDK | 提供上游对 `stream-json` 的命令构造、stdout 缓冲、强类型消息解析和前向兼容策略 |
| [severity1/claude-agent-sdk-go](https://github.com/severity1/claude-agent-sdk-go/tree/75ac77e299e4e154def737ffe64f06853a92d7ac) | 第三方强类型 SDK | 明确声明与 Python SDK 对齐，并补了流完整性校验与更清晰的类型边界 |
| [peakflames/claude-print](https://github.com/peakflames/claude-print/tree/fce01a15cddde6f657baec241bb5e0fe00a6c53d) | `--print` 包装器 | 对 `--include-partial-messages` 的工具调用显示策略研究得最细，尤其适合作为 UI/归一化状态机参考 |
| [badlogic/cc-wrap](https://github.com/badlogic/cc-wrap/tree/49e2a236aef03edede7ab4491f1067ecd1bde9b1) | Claude CLI 包装器/TUI | 展示会话消费层如何处理 `assistant` / `user` / `result`，以及 subagent 并行/复用 message id 的事实 |
| [Reodit/claude-code-api-wrapper](https://github.com/Reodit/claude-code-api-wrapper/tree/fe0a06707e4091b6d7a1bf0ecbd7bdeaa173e30b) | API Wrapper | 适合作为“较弱实现”样本，能看出只保留最终结果和工具名列表会损失什么信息 |

额外说明：

- [sepehr500/claude-code-ts](https://github.com/sepehr500/claude-code-ts/tree/d6150335a8c0514ff66099a806f693f4cc3b6849) 也看了，主要作为反例。
- [anthropics/claude-agent-sdk-typescript](https://github.com/anthropics/claude-agent-sdk-typescript) 截至本次调研时公开仓库内容主要是 `README` 和 `CHANGELOG`，没有可审阅的解析源码，因此没有列为主要样本。

## 一、先把协议基线说清楚

### 1. Claude 的“工具调用”不在顶层，而是在消息内容块里

多个实现都把顶层事件识别为：

- `system`
- `assistant`
- `user`
- `result`
- 可选 `stream_event`

但真正的工具调用在嵌套内容块里：

- `assistant.message.content[].type == "tool_use"`
- `user.message.content[].type == "tool_result"`

参考：

- [`message_parser.py#L52-L139`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/message_parser.py#L52-L139)
- [`json.go#L75-L97`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/parser/json.go#L75-L97)
- [`claude-cli.md#L58-L66`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/docs/claude-cli.md#L58-L66)

直接含义：

- 顶层 `type` 不是 `read/write/bash/search`。
- `read/write/bash/search` 这类分类只能是第二层派生，不应该直接替代协议原始事件类型。

### 2. 工具调用的稳定关联键是 `tool_use.id <-> tool_result.tool_use_id`

上游和第三方 SDK 都把：

- `tool_use.id`
- `tool_result.tool_use_id`

作为同一条工具调用的主关联键。

参考：

- [`message_parser.py#L66-L80`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/message_parser.py#L66-L80)
- [`json.go#L380-L417`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/parser/json.go#L380-L417)

这意味着：

- 工具调用主键优先应该是 `(session_id, tool_use_id)`。
- `assistant.message.id` 不能替代 `tool_use_id`，因为同一个 assistant message 里可能有多个 `tool_use`。

### 3. `message.id` 只能做消息快照去重或排序辅助，不能当工具调用主键

`cc-wrap` 的文档明确指出：

- 同一条 assistant message 可能多次出现，而且 `message.id` 相同。
- 工具 token 统计要按 `message.id` 取最后一次快照。
- 多个 `Task` 工具甚至可能共享同一个 `message.id`。

参考：

- [`claude-stream-json.md#L296-L334`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/docs/claude-stream-json.md#L296-L334)
- [`claude-stream-json.md#L843-L933`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/docs/claude-stream-json.md#L843-L933)

直接含义：

- `message.id` 更像“assistant 快照流”的 key。
- `tool_use_id` 才是“工具状态机”的 key。

### 4. `parent_tool_use_id` 是 subagent 链路键，不是普通可选字段

真实 subagent 场景里：

- subagent 的 `assistant` 事件带 `parent_tool_use_id`
- subagent 的 `user/tool_result` 事件也带同一个 `parent_tool_use_id`
- 它们和主 agent 共用同一个 `session_id`

参考：

- [`message_parser.py#L55-L56`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/message_parser.py#L55-L56)
- [`json.go#L172-L180`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/parser/json.go#L172-L180)
- [`claude-stream-json.md#L857-L933`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/docs/claude-stream-json.md#L857-L933)

这点对 TidyFlow 很关键：

- 工具树不是天然平铺的。
- 如果后续要支持子 agent / 嵌套工具 / 并行任务，`parent_tool_use_id` 必须进共享状态层。

### 5. `stream_event` 不是最终权威快照，只是可选增量通道

官方 Python E2E 明确验证了：

- `include_partial_messages=True` 时才会出现 `StreamEvent`
- 默认不开时，不会有 `StreamEvent`
- 即使开了，最后仍会收到完整 `AssistantMessage` 与 `ResultMessage`

参考：

- [`test_include_partial_messages.py#L25-L89`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/e2e-tests/test_include_partial_messages.py#L25-L89)
- [`test_include_partial_messages.py#L129-L157`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/e2e-tests/test_include_partial_messages.py#L129-L157)

直接含义：

- `stream_event` 更适合驱动实时 UI。
- 最终持久化和归一化仍应回落到 `assistant` / `user` / `result` 快照。

## 二、`anthropics/claude-agent-sdk-python`：上游官方解析入口

### 1. 官方 SDK 固定以 `stream-json + verbose` 驱动 Claude CLI

官方 Python 传输层默认构造：

- `--output-format stream-json`
- `--verbose`
- `--input-format stream-json`
- 可选 `--include-partial-messages`

参考：

- [`subprocess_cli.py#L166-L169`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/transport/subprocess_cli.py#L166-L169)
- [`subprocess_cli.py#L267-L268`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/transport/subprocess_cli.py#L267-L268)
- [`subprocess_cli.py#L329-L331`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/transport/subprocess_cli.py#L329-L331)

这说明：

- 归一化层应该把 Claude 看成稳定的 NDJSON 事件流，而不是只看最终 `result`。
- `include_partial_messages` 是协议的增强模式，不是另一套协议。

### 2. stdout 解析不是“逐行 parse 一次”这么简单，而是带缓冲的 speculative parsing

官方 Python 读取 stdout 时没有假设每次收到的都是完整 JSON。它会：

- 维护 `json_buffer`
- 持续追加片段
- 每次尝试 `json.loads`
- 成功才产出消息
- 超过上限则报错

参考：

- [`subprocess_cli.py#L524-L564`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/transport/subprocess_cli.py#L524-L564)

这套策略的价值很直接：

- 不假设 IO chunk 边界等于 JSON 边界。
- 能扛住长行截断或读流分片。
- 适合作为 TidyFlow Claude 解析入口的第一层。

### 3. 官方 `parse_message()` 先按顶层 `type` 分发，再按内容块 `type` 二次分发

上游 `parse_message()` 的入口顺序很稳定：

1. 先识别顶层 `type`
2. `assistant` / `user` 时再解析 `message.content`
3. 对 `content` 中的 `text` / `thinking` / `tool_use` / `tool_result` 建强类型块

参考：

- [`message_parser.py#L29-L250`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/message_parser.py#L29-L250)

直接启发：

- TidyFlow 应该显式保留两层判别：
  - 顶层事件层
  - 内容块层
- 不要一上来就把一切压成单个 `tool` part。

### 4. 它保留了 `parent_tool_use_id` 和 `tool_use_result`

官方 Python 在 `user` 消息里显式保留：

- `parent_tool_use_id`
- `tool_use_result`

这两个字段都没有被折叠掉。

参考：

- [`message_parser.py#L55-L57`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/message_parser.py#L55-L57)
- [`message_parser.py#L82-L93`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/message_parser.py#L82-L93)

这意味着：

- `tool_result` 的正文不是唯一输出来源。
- `tool_use_result` 这类结构化结果元数据，本身就应该参与分类和展示。

### 5. 对未知顶层消息，上游选择“跳过但不崩溃”

`parse_message()` 对未知 `type` 返回 `None`，而不是抛异常中断。

参考：

- [`message_parser.py#L246-L250`](https://github.com/anthropics/claude-agent-sdk-python/blob/2d5c3cb350c9218692706e96ad8d7aba8aeb3cf8/src/claude_agent_sdk/_internal/message_parser.py#L246-L250)

这非常值得照抄：

- 协议升级时，旧客户端至少不应该直接炸掉。
- 归一化层应允许“看不懂但可保底透传”。

## 三、`severity1/claude-agent-sdk-go`：更完整的强类型与完整性校验

### 1. 这个 Go SDK 明确复刻了 Python 的 speculative parser

Go 版 `Parser` 直接在注释里写明：

- “implements the same speculative parsing strategy as the Python SDK”

并且完整实现了：

- buffer 累积
- 成功 parse 后清空 buffer
- 不完整 JSON 继续等
- buffer overflow 保护

参考：

- [`json.go#L18-L24`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/parser/json.go#L18-L24)
- [`json.go#L33-L64`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/parser/json.go#L33-L64)
- [`json.go#L123-L152`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/parser/json.go#L123-L152)

这说明：

- 官方 Python 的输入边界假设并不是偶然实现细节，而是值得跨语言复用的解析策略。

### 2. 它把消息层、内容块层、增量层分得更清楚

Go 版共享消息类型里显式定义了：

- `UserMessage`
- `AssistantMessage`
- `ResultMessage`
- `StreamEvent`
- `ToolUseBlock`
- `ToolResultBlock`

并把：

- `ParentToolUseID`
- `ToolUseResult`
- `StructuredOutput`

都保留下来。

参考：

- [`message.go#L53-L60`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/shared/message.go#L53-L60)
- [`message.go#L106-L186`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/shared/message.go#L106-L186)
- [`message.go#L229-L248`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/shared/message.go#L229-L248)
- [`message.go#L268-L303`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/shared/message.go#L268-L303)

这个边界划分很适合 TidyFlow：

- 协议保真字段在共享模型层保留。
- UI 或统计层再派生更激进的分类。

### 3. 它对 `tool_result` 做了严格键校验

`parseToolResultBlock()` 明确要求：

- `tool_use_id` 必须存在
- `is_error` 单独读取
- `content` 保持原样

参考：

- [`json.go#L400-L417`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/parser/json.go#L400-L417)

这里很有价值：

- “没有 `tool_use_id` 的 `tool_result` 不是正常工具结果”。
- 关联关系缺失时应该当解析异常或原始事件，而不是硬拼成匿名工具卡片。

### 4. 它额外做了“流完整性校验”

`StreamValidator` 会跟踪：

- 发起过哪些 `tool_use`
- 收到了哪些 `tool_result`
- 有没有最终 `result`

并在流结束时给出：

- `missing_tool_result`
- `extra_tool_result`
- `missing_result_message`

参考：

- [`validator.go#L7-L17`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/shared/validator.go#L7-L17)
- [`validator.go#L44-L107`](https://github.com/severity1/claude-agent-sdk-go/blob/75ac77e299e4e154def737ffe64f06853a92d7ac/internal/shared/validator.go#L44-L107)

这可以直接转成 TidyFlow Core 的验收标准：

- 如果流回放结束还存在 pending tool，就说明状态机缺了闭环。
- 多工作区并行时，这类校验尤其重要，因为错关联很难在 UI 上第一时间看出来。

## 四、`peakflames/claude-print`：对部分流式工具调用处理得最实用

### 1. 顶层事件先按 `type` 解析，未知事件保底回退为 `BaseEvent`

`claude-print` 的 `ParseEvent()` 先读顶层 `type`，然后分发到：

- `stream_event`
- `result`
- `assistant`
- `user`
- 其他已知类型
- 未知类型则返回 `BaseEvent`

参考：

- [`parser.go#L53-L125`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/internal/events/parser.go#L53-L125)

这和前面两个 SDK 一致：

- 顶层事件判别必须早于工具分类。
- 未知顶层事件不能直接把整个流打断。

### 2. 它认真处理了两个多态字段：`tool_result.content` 与 `tool_use_result`

`claude-print` 对 `user` 事件做了额外解码：

- `tool_use_result` 可能是字符串，也可能是对象
- `tool_result.content` 可能是字符串，也可能是内容块数组
- Task agent 结果会以数组形式出现

参考：

- [`types.go#L186-L279`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/internal/events/types.go#L186-L279)
- [`types.go#L281-L308`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/internal/events/types.go#L281-L308)

直接启发：

- TidyFlow 不应把 `tool_use_result` 只当“文件路径提取器”。
- 这层结构里其实已经包含：
  - `file.numLines`
  - `status`
  - 拒绝/报错文本
- 足够支撑更细的分类和状态文案。

### 3. 它把 `--include-partial-messages` 的处理边界说得非常清楚

`claude-print` 的设计文档明确指出：

- `content_block_start(tool_use)` 时 `input` 可能是空对象
- 真正完整的 `tool_use` 入参要等后续顶层 `assistant` 事件
- `content_block_delta(text)` 已经把文本流输出了，所以顶层 `assistant` 里的文本不能再显示一次

参考：

- [`streaming-event-processing.md#L21-L29`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/docs/streaming-event-processing.md#L21-L29)
- [`streaming-event-processing.md#L40-L65`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/docs/streaming-event-processing.md#L40-L65)
- [`streaming-event-processing.md#L67-L112`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/docs/streaming-event-processing.md#L67-L112)
- [`streaming-event-processing.md#L140-L160`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/docs/streaming-event-processing.md#L140-L160)

这条规则几乎可以原封不动抄进 TidyFlow：

- `stream_event` 负责实时性。
- 顶层 `assistant` 负责完整工具输入快照。
- 顶层 `user` 负责完整工具输出快照。

### 4. 它用 `PendingTools` 把工具开始和工具结果连成闭环

展示层维护了 `PendingTools`：

- `content_block_start(tool_use)` 先挂起
- `assistant(tool_use)` 以完整参数显示并更新挂起状态
- `user(tool_result)` 通过 `tool_use_id` 找回 pending tool，显示结果后移除

参考：

- [`display.go#L397-L425`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/internal/output/display.go#L397-L425)
- [`display.go#L463-L489`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/internal/output/display.go#L463-L489)
- [`display.go#L553-L630`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/internal/output/display.go#L553-L630)

这说明：

- 归一化层最好明确有一个 pending tool map。
- `tool_use` 与 `tool_result` 不是“看到就完事”的独立日志。

### 5. 它单独识别“权限拒绝”而不是并入普通错误

`claude-print` 会检查工具结果文本是否包含 permission denied 模式，并单独显示为拒绝。

参考：

- [`display.go#L481-L487`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/internal/output/display.go#L481-L487)
- [`display.go#L534-L551`](https://github.com/peakflames/claude-print/blob/fce01a15cddde6f657baec241bb5e0fe00a6c53d/internal/output/display.go#L534-L551)

这个点值得直接借鉴：

- `denied` 和 `failed` 在产品语义上不是一回事。
- 后续如果 TidyFlow 要做统计、回放和审批体验，这两个状态必须拆开。

## 五、`badlogic/cc-wrap`：消费层最关心的几个事实

### 1. 它的协议消费虽然简单，但边界清晰

`cc-wrap` 通过 `readline` 逐行读 stdout：

- `system.init` 时提取 `session_id`
- 持续 yield 事件
- 遇到 `result` 结束本轮查询

参考：

- [`claude.ts#L42-L73`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/src/claude.ts#L42-L73)
- [`claude.ts#L149-L180`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/src/claude.ts#L149-L180)

它的价值不在于解析有多强，而在于它展示了最小消费闭环：

- `assistant` 看工具开始
- `user` 看工具结果
- `result` 看回合结束

### 2. UI 层明确把 `assistant/tool_use` 和 `user/tool_result` 分开消费

TUI 消费逻辑是：

- `assistant` 里渲染文本和 `tool_use`
- `user` 里渲染 `tool_result`
- `result` 里渲染最终状态

参考：

- [`chat-tui.ts#L227-L291`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/src/chat-tui.ts#L227-L291)

这点和前面的 SDK、`claude-print` 完全一致，说明这不是偶然实现：

- Claude `--print` 协议天然就是把工具输入和结果拆在不同顶层消息里。

### 3. 它把 subagent 事件显式当成另一条链处理

TUI 里如果 `userEvent.parent_tool_use_id` 存在，直接判为 subagent 消息并跳过当前主视图渲染。

参考：

- [`chat-tui.ts#L248-L254`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/src/chat-tui.ts#L248-L254)

这虽然是个 UI 决策，但揭示了一个协议事实：

- `parent_tool_use_id` 足以把主 agent 和子 agent 事件分开。

### 4. 它的文档把几个最容易踩坑的事实都写出来了

最值得注意的是这几条：

- assistant message 会多次出现，`message.id` 相同
- usage 统计要按 `message.id` 取最后一条
- 并行 `Task` 工具可能共享同一个 `message.id`
- subagent 结果返回顺序按完成时间，不按调用顺序

参考：

- [`claude-stream-json.md#L296-L334`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/docs/claude-stream-json.md#L296-L334)
- [`claude-stream-json.md#L843-L933`](https://github.com/badlogic/cc-wrap/blob/49e2a236aef03edede7ab4491f1067ecd1bde9b1/docs/claude-stream-json.md#L843-L933)

这可以直接转成 TidyFlow 的设计要求：

- 工具排序不要只看接收顺序。
- 并行 subagent 场景必须接受事件交错。

## 六、两类“较弱实现”带来的反例

### 1. `sepehr500/claude-code-ts`：没有剩余缓冲的分块解析很危险

这个实现的流式读取逻辑是：

- 每次读一个 stdout chunk
- `chunk.split("\n")`
- 逐行 `JSON.parse`
- 没有保存跨 chunk 的残余半行

参考：

- [`client.ts#L194-L234`](https://github.com/sepehr500/claude-code-ts/blob/d6150335a8c0514ff66099a806f693f4cc3b6849/src/client.ts#L194-L234)

同时它只做了两件事：

- `assistant.message.content[0].text` -> 直接当内容
- `result.result` -> 直接当内容

参考：

- [`client.ts#L207-L223`](https://github.com/sepehr500/claude-code-ts/blob/d6150335a8c0514ff66099a806f693f4cc3b6849/src/client.ts#L207-L223)

这类实现的问题很明确：

- 一旦 JSON 跨 chunk，被切开的半行就丢了。
- `tool_use` / `tool_result` 生命周期完全没有建模。

### 2. `Reodit/claude-code-api-wrapper`：有缓冲，但仍只保留最终摘要

这个 wrapper 比上面稳一些：

- 它有 `buffer`，能处理跨 chunk 半行
- 收集完成后，会从 assistant 里提取唯一工具名列表

参考：

- [`claude-stream.ts#L300-L330`](https://github.com/Reodit/claude-code-api-wrapper/blob/fe0a06707e4091b6d7a1bf0ecbd7bdeaa173e30b/lib/claude-stream.ts#L300-L330)
- [`claude-stream.ts#L380-L472`](https://github.com/Reodit/claude-code-api-wrapper/blob/fe0a06707e4091b6d7a1bf0ecbd7bdeaa173e30b/lib/claude-stream.ts#L380-L472)

但它最终只保留：

- `messages`
- `stream_events`
- `tools_used` 去重列表
- `result` 和元数据

直接损失是：

- 看不到每次工具调用的稳定主键
- 看不到工具调用顺序和并行关系
- 看不到单次调用的输入/输出/错误/拒绝状态

这很适合作为反例：

- 如果 TidyFlow Core 只保留“本轮用了哪些工具”，后续就很难做真正的归一化工具卡片。

## 七、最值得直接采用的解析与归一化规则

### 1. 主键应该至少是 `(workspace_scope, session_id, tool_use_id)`

原因：

- `tool_use_id` 才是工具调用关联键。
- `session_id` 只在会话内稳定。
- TidyFlow 默认多项目、多工作区并行，不能只靠 `session_id` 或 `tool_use_id`。

建议额外保留：

- `parent_tool_use_id`：父子链路
- `assistant_message_id`：消息快照去重/usage 汇总

### 2. 归一化前面要先有两层协议解析

建议分成：

1. `transport parser`
   - 负责 chunk 拼接、行缓冲、buffer overflow 保护
2. `wire event parser`
   - 负责 `system/assistant/user/result/stream_event`
3. `content block parser`
   - 负责 `text/thinking/tool_use/tool_result`

这样做的好处是：

- 协议升级时只改前两层。
- 归一化分类逻辑不必知道 stdout 分块细节。

### 3. `stream_event` 与顶层快照要分别对待

建议的权威级别：

- `stream_event/content_block_start(tool_use)`：只建 pending，不认定最终输入
- `stream_event/content_block_delta(text/thinking)`：只驱动实时流式文本
- `assistant/tool_use`：工具输入权威快照
- `user/tool_result`：工具输出权威快照
- `result`：回合/会话完成权威快照

这能避免两个常见错误：

- 把空的 partial `tool_use.input={}` 当最终输入
- 把已在 delta 流里显示过的 text 再从 `assistant` 重放一遍

### 4. 归一化分类必须建立在保真字段之上

建议至少保留这些原始字段：

- `raw_tool_name`
- `tool_use_id`
- `parent_tool_use_id`
- `assistant_message_id`
- `input_snapshot`
- `output_snapshot`
- `tool_use_result`
- `top_level_event_type`
- `stream_event_type`
- `is_error`

分类顺序建议固定为：

1. 原始工具名
2. 输入结构键
3. `tool_use_result` 的结构化元数据
4. 父子链路信息（例如 `Task`）
5. 最后才是字符串猜测

### 5. 状态至少要拆到 `announced/running/completed/failed/denied`

从样本看，Claude 上游虽然没有标准 `declined` 字段，但真实 wrapper 已经证明：

- 权限拒绝可以从 `tool_result` 的错误文本中稳定识别
- 它和普通失败不应混在一起

所以建议：

- `announced`：看到 partial start，但还没有完整输入
- `running`：收到完整 `assistant/tool_use`
- `completed`：收到成功 `tool_result`
- `failed`：收到 `is_error=true` 且非拒绝
- `denied`：识别为权限拒绝

### 6. 要把“流完整性校验”放进共享层，而不是只靠 UI 感觉

建议在会话回放或 turn 结束时校验：

- 是否存在没有 `tool_result` 的 pending tool
- 是否存在没有前置 `tool_use` 的孤儿 `tool_result`
- 是否缺 final `result`

这对多工作区并行场景特别重要，因为错绑工具结果时 UI 往往不是立刻崩，而是默默串会话。

## 八、对当前 TidyFlow Claude 适配层的直接启发

当前实现里已经有两件正确的事：

- 会把工具调用建成稳定 `tool_call_id`
- 会从 `tool_use_result.file.filePath` 回补路径别名

参考：

- [core/src/ai/claude_adapter.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/claude_adapter.rs#L33)
- [core/src/ai/claude_adapter.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/claude_adapter.rs#L312)

但从这次调研看，至少有四个结构性问题需要优先改。

### 1. 原始工具名被过早折叠成少数类别

当前 `normalize_tool_name()` 会把：

- `edit` 和 `write` 折叠成 `write`
- `glob/list/ls` 折叠成 `list`
- `grep/search` 折叠成 `grep`

参考：

- [core/src/ai/claude_adapter.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/claude_adapter.rs#L243)

问题在于：

- `Task`、`Glob`、`Grep`、`Edit`、`Write`、`Read` 的语义差异在 Claude 协议里是真实存在的。
- 过早折叠会让后续的“归一化工具分类”只能建立在损失后的字段上。

### 2. 当前工具状态太扁平，装不下协议真实语义

`ClaudeToolState` 现在只保留：

- `tool_name`
- `status`
- `input`
- `title`
- `output`
- `error`

参考：

- [core/src/ai/claude_adapter.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/claude_adapter.rs#L33)

缺的恰好是最关键的字段：

- `raw_tool_name`
- `parent_tool_use_id`
- `tool_use_result`
- `top_level_event_type`
- `stream_event_type`
- `assistant_message_id`

这会直接限制后面的分类和并行链路表达。

### 3. `collect_content_blocks()` 把顶层快照和增量事件混在了一起

当前实现会把：

- `message.content`
- 顶层 `content`
- 甚至名字里带 `delta` 的对象

一起塞进同一个 block 流里消费。

参考：

- [core/src/ai/claude_adapter.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/claude_adapter.rs#L358)

问题是：

- `stream_event delta` 和顶层 `assistant/user` 快照不是同一层语义。
- 一旦混在一起，后面就很难再区分“这是实时片段”还是“这是权威快照”。

### 4. `tool_result` 当前只落成 `completed/error`，且结构化结果几乎没保留

当前 `tool_result` 的处理逻辑基本是：

- 尝试把 `content/output/text` 拼成字符串
- `is_error` 为真就记成 `error`
- 否则记成 `completed`

参考：

- [core/src/ai/claude_adapter.rs](/Users/godbobo/work/projects/tidyflow/core/src/ai/claude_adapter.rs#L1274)

问题在于：

- `denied` 会被并入普通 `error`
- `tool_use_result.file.numLines`、`status` 等元数据没有进入共享状态
- `Task` 类结果的数组内容也没有单独建模

## 九、建议的重构落点

如果下一步要优化 Core 的“归一化工具分类逻辑”，建议优先落下面三个结构，而不是继续在 `normalize_tool_name()` 上追加 if/else。

### 方案 A：先引入 Claude 协议保真层

建议新增类似结构：

- `ClaudeWireEvent`
- `ClaudeContentBlock`
- `ClaudeToolLifecycleState`

职责分别是：

- `ClaudeWireEvent`：顶层事件判别
- `ClaudeContentBlock`：内容块判别
- `ClaudeToolLifecycleState`：按 `(session_id, tool_use_id)` 聚合状态

### 方案 B：把“协议原始类别”和“归一化展示类别”拆成两个字段

建议至少拆开：

- `protocol_tool_name`
- `normalized_tool_kind`

其中：

- `protocol_tool_name` 保持 `Read` / `Edit` / `Task` / `Glob` / `Grep` 原样
- `normalized_tool_kind` 才映射到 `read` / `write` / `search` / `task` / `bash`

### 方案 C：把 partial streaming 语义变成共享状态机

最小状态机建议：

1. `content_block_start(tool_use)` -> `announced`
2. `assistant(tool_use)` -> `running`
3. `user(tool_result)` -> `completed/failed/denied`
4. `result` -> turn closed

一旦这层存在：

- macOS 和 iOS 就能共享同一套工具卡片语义。
- 多工作区、多会话回放也更容易保持一致。

## 十、结论

Claude `--print` 协议最容易被误判的点，不是“工具名怎么猜”，而是：

1. 工具调用本质上跨多条顶层事件。
2. `stream_event` 和顶层快照不是同一层语义。
3. `tool_use_id`、`parent_tool_use_id`、`tool_use_result` 这些字段比字符串标题更关键。

对 TidyFlow Core 来说，下一步最值得做的不是继续扩写当前的工具名归一化表，而是先把 Claude 的保真状态结构补齐，再让归一化分类成为派生字段。
