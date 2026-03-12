# GitHub Copilot ACP 工具调用解析逻辑调研

更新日期：2026-03-13

## 目标

这份调研只关注一件事：`session/update` 里的 `tool_call` / `tool_call_update` 在真实 GitHub Copilot ACP 接入项目里是如何被解析、拼装、容错和分类的。

主要用途：

- 为核心层的“归一化工具分类逻辑”提供可以直接落地的参考。
- 避免把 ACP 工具调用只当作一次性事件，而忽略它其实是一个跨多条消息逐步补全的状态对象。
- 为多项目、多工作区、多会话场景明确主键、合并策略和容错边界。

## 调研样本

| 样本 | 类型 | 价值 |
| --- | --- | --- |
| [agentclientprotocol/agent-client-protocol](https://github.com/agentclientprotocol/agent-client-protocol) | 协议权威源 | 定义 `tool_call` / `tool_call_update` 的字段、状态、内容类型和规范语义 |
| [github/copilot-sdk](https://github.com/github/copilot-sdk) | GitHub 官方 SDK | 提供官方事件建模和 `toolCallId` 贯穿全链路的方式 |
| [MattKotsenas/uplink](https://github.com/MattKotsenas/uplink) | 真实 Copilot ACP Web 客户端 | 展示面向 UI 的会话态聚合、增量内容合并、思考态合成 |
| [bsmi021/mcp-copilot-acp](https://github.com/bsmi021/mcp-copilot-acp) | Copilot ACP 桥接器 | 展示偏保守的 schema 校验、容错聚合器、Copilot 实际行为偏差处理 |
| [MSBart2/cli-acp](https://github.com/MSBart2/cli-acp) | Demo/反例 | 展示不做生命周期归并时会丢失哪些信息 |

## 一、协议基线

### 1. `tool_call` 是“创建完整快照”，不是简单日志

ACP 协议文档把 `tool_call` 定义为一个带稳定 ID 的对象，包含：

- `toolCallId`
- `title`
- `kind`
- `status`
- `content`
- `locations`
- `rawInput`
- `rawOutput`

参考：

- [tool-calls.mdx#L12-L75](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/tool-calls.mdx#L12-L75)
- [tool_call.rs#L24-L56](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/src/tool_call.rs#L24-L56)

直接含义：

- 工具调用的主键不是“时间点”，而是 `toolCallId`。
- `toolCallId` 只保证在 session 内唯一，所以核心主键必须至少是 `(sessionId, toolCallId)`，不能只用 `toolCallId`。

协议文档明确写了 “within the session”：

- [tool-calls.mdx#L33-L35](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/tool-calls.mdx#L33-L35)

### 2. `tool_call_update` 是“补丁”

协议把 `tool_call_update` 定义为仅包含变更字段的更新，除了 `toolCallId` 外其他字段都可选。

参考：

- [tool-calls.mdx#L76-L106](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/tool-calls.mdx#L76-L106)
- [tool_call.rs#L156-L233](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/src/tool_call.rs#L156-L233)

但要注意一个非常关键的点：

- 协议 Rust 类型实现的默认语义是“集合字段覆盖，不是追加”。

具体体现在：

- `ToolCall::update()` 里 `content` / `locations` 是整体替换。
- `ToolCallUpdateFields` 的注释也明确写了 “overwritten, not extended”。

参考：

- [tool_call.rs#L129-L153](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/src/tool_call.rs#L129-L153)
- [tool_call.rs#L202-L233](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/src/tool_call.rs#L202-L233)

这和后面多个真实 Copilot ACP 接入项目的“增量追加”实现存在明显张力，是后续归一化设计里最值得单独处理的点。

### 3. 协议级 `kind`、`status`、`content` 已经能支撑第一层分类

协议里 `ToolKind` 至少包含：

- `read`
- `edit`
- `delete`
- `move`
- `search`
- `execute`
- `think`
- `fetch`
- `switch_mode`
- `other`

`ToolCallStatus` 包含：

- `pending`
- `in_progress`
- `completed`
- `failed`

`ToolCallContent` 支持三类内容：

- 普通内容块 `content`
- 结构化差异 `diff`
- 终端引用 `terminal`

参考：

- [tool_call.rs#L380-L438](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/src/tool_call.rs#L380-L438)
- [tool_call.rs#L446-L520](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/src/tool_call.rs#L446-L520)

这意味着：

- 如果上游真的给了 `kind`，优先直接使用它。
- 如果没有 `kind`，`diff` / `terminal` / `rawInput` 依然足够支撑二次推导。

## 二、各开源实现的具体解析逻辑

### 1. `github/copilot-sdk`：官方实现强调“稳定 ID 贯穿全链路”

官方 Node SDK 在类型层把工具调用和权限请求都显式挂到 `toolCallId` 上：

- `ToolInvocation` 含 `sessionId`、`toolCallId`、`toolName`、`arguments`
- `PermissionRequest` 含 `kind` 和可选 `toolCallId`

参考：

- [types.ts#L132-L143](https://github.com/github/copilot-sdk/blob/main/nodejs/src/types.ts#L132-L143)
- [types.ts#L188-L197](https://github.com/github/copilot-sdk/blob/main/nodejs/src/types.ts#L188-L197)
- [types.ts#L233-L250](https://github.com/github/copilot-sdk/blob/main/nodejs/src/types.ts#L233-L250)

更有价值的是，官方 SDK 的内部 session event 模型把工具调用拆成更细的生命周期：

- `tool.execution_start`
- `tool.execution_partial_result`
- `tool.execution_progress`
- `tool.execution_complete`

这些事件都以 `toolCallId` 为关联键，`tool.execution_start` 还带有：

- `toolName`
- `arguments`
- `mcpServerName`
- `mcpToolName`
- `parentToolCallId`

参考：

- [session-events.ts#L1658-L1727](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/session-events.ts#L1658-L1727)
- [session-events.ts#L1742-L1785](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/session-events.ts#L1742-L1785)
- [session-events.ts#L1804-L1835](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/session-events.ts#L1804-L1835)

可直接借鉴的点：

- 核心层不要把工具调用只建模成 `pending/in_progress/completed` 四态。
- 归一化后最好保留更细粒度阶段，例如：
  - `announced`
  - `running`
  - `streaming_output`
  - `completed`
  - `failed`
- 需要预留 `parentToolCallId`，为未来子 agent / 嵌套工具链路留扩展位。

### 2. `MattKotsenas/uplink`：最像“客户端真正要做的事”

`uplink` 的做法对 TidyFlow 最有直接参考价值。

它先定义了一个比较完整的 ACP 前端类型层：

- `ToolCallSessionUpdate` 表示完整 `tool_call`
- `ToolCallUpdateSessionUpdate` 表示增量 `tool_call_update`
- `ToolCallContent` 保留了 `content` / `diff` / `terminal`

参考：

- [acp-types.ts#L210-L220](https://github.com/MattKotsenas/uplink/blob/main/src/shared/acp-types.ts#L210-L220)
- [acp-types.ts#L222-L309](https://github.com/MattKotsenas/uplink/blob/main/src/shared/acp-types.ts#L222-L309)
- [acp-types.ts#L328-L339](https://github.com/MattKotsenas/uplink/blob/main/src/shared/acp-types.ts#L328-L339)

它的会话聚合逻辑是：

- `tool_call` 时创建 `TrackedToolCall`
- 用 `toolCallId` 存进 `Map`
- `tool_call_update` 时按 ID 合并
- 标量字段采用 last-write-wins
- `content` 和 `locations` 采用追加合并，而不是覆盖

核心代码：

- [conversation.ts#L110-L180](https://github.com/MattKotsenas/uplink/blob/main/src/client/conversation.ts#L110-L180)

它的测试进一步把行为边界说得很清楚：

- `tool_call_update` 可以只更新状态
- `tool_call_update` 的 `content` 是追加，不是替换
- 空 `content: []` 不应该抹掉旧输出
- 未知 `toolCallId` 的更新不应导致崩溃

参考：

- [conversation.test.ts#L80-L189](https://github.com/MattKotsenas/uplink/blob/main/test/unit/conversation.test.ts#L80-L189)
- [conversation.test.ts#L355-L364](https://github.com/MattKotsenas/uplink/blob/main/test/unit/conversation.test.ts#L355-L364)

还有两个非常实用的增强点：

- `agent_thought_chunk` 被合成为一个 `kind = think` 的伪工具调用。
- `rawInput.command` 被保留下来，用于把 execute 类工具展示成真实命令。

参考：

- [conversation.ts#L277-L312](https://github.com/MattKotsenas/uplink/blob/main/src/client/conversation.ts#L277-L312)
- [tool-call.tsx#L20-L31](https://github.com/MattKotsenas/uplink/blob/main/src/client/ui/tool-call.tsx#L20-L31)
- [tool-call.tsx#L92-L123](https://github.com/MattKotsenas/uplink/blob/main/src/client/ui/tool-call.tsx#L92-L123)

这个项目还暴露了一个多会话场景下非常重要的事实：

- `session/load` 成功后，Copilot CLI 会把历史对话重新作为 `session/update` 回放。

参考：

- [acp-types.ts#L139-L142](https://github.com/MattKotsenas/uplink/blob/main/src/shared/acp-types.ts#L139-L142)
- [server/index.ts#L423-L431](https://github.com/MattKotsenas/uplink/blob/main/src/server/index.ts#L423-L431)

直接含义：

- 归一化层必须考虑“历史回放”和“实时流”都可能进入同一条工具调用状态。
- 如果未来要做会话恢复，合并逻辑必须幂等。

### 3. `bsmi021/mcp-copilot-acp`：保守 schema + 容错聚合器

这个仓库的特点是“对输入更保守，对运行时更宽容”。

它用 Zod 直接把 `session/update` 建成基于 `sessionUpdate` 的 discriminated union：

- `tool_call` 只要求 `toolCallId`
- `title` / `kind` / `status` 都是可选
- `tool_call_update` 的 `status` 和 `content` 也都是可选
- `status` 被放宽成 `string`，没有硬绑协议枚举

参考：

- [acp.ts#L222-L257](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/types/acp.ts#L222-L257)

它的聚合器策略是：

- 每次 prompt 创建一个 `ResponseAggregator`
- `tool_call` 时按 `toolCallId` 建记录
- `tool_call_update` 时更新状态并把文本内容追加到 `content[]`
- 如果先收到 `tool_call_update`，会先建一个占位记录再回填
- 所有 malformed notification 都直接忽略，不中断整轮 prompt

参考：

- [response-aggregator.ts#L24-L122](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/response-aggregator.ts#L24-L122)
- [response-aggregator.ts#L153-L225](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/response-aggregator.ts#L153-L225)
- [response-aggregator.test.ts#L82-L117](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/response-aggregator.test.ts#L82-L117)
- [response-aggregator.test.ts#L234-L275](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/response-aggregator.test.ts#L234-L275)

另一个很有参考价值的点是它对异常输入的态度：

- `session/update` 校验失败时直接忽略。
- 权限请求即使不完全匹配 schema，只要检测到 `toolCall`，仍然优先按自动批准路径返回。

参考：

- [acp-client.ts#L268-L276](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/acp-client.ts#L268-L276)
- [acp-client.ts#L320-L347](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/acp-client.ts#L320-L347)

这个项目的作者还记录了几条和 Copilot 实际行为相关的实现笔记，其中和工具解析最相关的是：

- `tool_call_update` 里可能带 `rawOutput`
- 这个 `rawOutput` 可能不符合它当前 `ContentBlock` schema
- 所以 parse failure 被视为“可以忽略的非致命问题”

参考：

- [CLAUDE.md#L98-L108](https://github.com/bsmi021/mcp-copilot-acp/blob/main/CLAUDE.md#L98-L108)

对 TidyFlow 的启示非常直接：

- 归一化层不能把 schema 严格校验和业务可用性绑死。
- 应该允许“字段不完整但仍可追踪”的中间态对象存在。
- `status` 最好先保留原值，再做映射，不要一开始就强转成固定枚举。

### 4. `MSBart2/cli-acp`：一个足够明显的反例

这个 demo 会把 `tool_call` 和 `tool_call_update` 都直接转成 UI 事件：

- 服务端只转发 `toolCallId`、`title`、`status`
- 客户端收到后把每个 update 直接 push 到输出数组
- 没有按 `toolCallId` 做生命周期归并
- 没有合并 `content`
- 没有保留 `kind` / `rawInput` / `locations`

参考：

- [server/index.js#L380-L420](https://github.com/MSBart2/cli-acp/blob/main/webapp/server/index.js#L380-L420)
- [App.jsx#L97-L106](https://github.com/MSBart2/cli-acp/blob/main/webapp/client/src/App.jsx#L97-L106)

这个实现的问题很典型：

- 同一次工具调用会被拆成多条离散 UI 记录。
- 后续无法做稳定分类，因为 `tool_call_update` 已经丢失了初始 `kind` 和 `title`。
- 无法可靠地判断“这个 completed 是哪个工具的完成态”。

它非常适合作为“不要这么做”的边界样本。

## 三、跨样本归纳出的共同模式

### 1. 真正可用的主键都是 `(sessionId, toolCallId)`

原因：

- 协议只保证 `toolCallId` 在 session 内唯一。
- 权限请求、工具执行、工具结果都围绕这个 ID 关联。
- 多项目、多工作区、多会话场景下，全局只按 `toolCallId` 建索引一定会串。

### 2. 真实客户端几乎都会把 `tool_call_update.content` 当“增量”

协议语义是“字段补丁，集合覆盖”。

但真实接入项目里更常见的是：

- `tool_call` 提供初始快照
- 多个 `tool_call_update` 逐步流出文本、终端输出或补充 locations
- 客户端把它们追加进最终展示状态

`uplink` 和 `mcp-copilot-acp` 都这样做。

这说明：

- 只按协议的“覆盖语义”实现，会更像 schema 工具，而不像真实 Copilot 客户端。
- 面向产品展示和分析的归一化层，应该把“增量追加”作为默认消费策略。

### 3. 真实实现都会容忍乱序和缺字段

已观察到的容错方式：

- 未知 `toolCallId` 的 update：忽略或创建占位
- 缺少 `title` / `kind` / `status`：先保留空值，后续回填
- schema 不完全匹配：不中断整轮 prompt

这说明：

- 工具调用归一化必须是“流处理器”，不是“严格反序列化后一次性消费”。

### 4. `kind` 不足以覆盖最终分类，`rawInput` / `content` / 权限类型都要参与

观察到的补充信号：

- `rawInput.command` 可用于识别 `execute`
- `diff` content 可直接识别 `edit`
- `terminal` content 可直接识别 `execute`
- `session/request_permission.kind` 可辅助补全 read/write/shell/url
- `agent_thought_chunk` 在客户端层经常会被合成为 `think`

### 5. 时间线顺序和工具状态对象应分离

`uplink` 的数据模型很说明问题：

- 一份 `Map<toolCallId, TrackedToolCall>` 表示状态
- 一份 `timeline[]` 表示渲染顺序

参考：

- [conversation.ts#L50-L69](https://github.com/MattKotsenas/uplink/blob/main/src/client/conversation.ts#L50-L69)
- [conversation.ts#L131-L145](https://github.com/MattKotsenas/uplink/blob/main/src/client/conversation.ts#L131-L145)

这对 TidyFlow 很重要：

- 分类、统计、聚合应该基于状态对象。
- UI 排序、流式展示应该基于时间线。
- 不要把“数组中的一条 UI 记录”直接等同于“一个工具调用实体”。

## 四、适合 TidyFlow 的直接落地建议

### 1. 核心层先定义一个“协议无关但 ACP 友好”的工具调用状态

建议最少保留：

```ts
type NormalizedToolCall = {
  sessionId: string
  toolCallId: string
  parentToolCallId?: string
  firstSeenSeq: number
  lastSeenSeq: number

  title?: string
  explicitKind?: string
  normalizedKind: "read" | "edit" | "delete" | "move" | "search" | "execute" | "think" | "fetch" | "switch_mode" | "other"

  rawStatus?: string
  normalizedPhase: "announced" | "running" | "streaming_output" | "completed" | "failed"

  contentBlocks: unknown[]
  locations: unknown[]
  rawInput?: unknown
  rawOutput?: unknown

  synthetic: boolean
  missingCreateEvent: boolean
  replayed: boolean
}
```

关键点：

- `explicitKind` 和 `normalizedKind` 分开。
- `rawStatus` 和 `normalizedPhase` 分开。
- `synthetic` 用于区分协议原生工具调用和 UI/客户端合成的 `think`。

### 2. 合并策略建议采用“标量覆盖、集合追加、原始事件保留”

建议规则：

- `tool_call`
  - 若不存在：创建
  - 若已存在：作为补全信息继续合并，不报错
- `tool_call_update`
  - 若不存在：创建占位，并标记 `missingCreateEvent = true`
  - 标量字段：last-write-wins
  - `content`：默认追加
  - `locations`：默认追加
  - `rawInput` / `rawOutput`：保留最新值，同时建议保留原始事件以备诊断

原因：

- 这最接近真实 Copilot ACP 客户端的消费方式。
- 即便以后上游真的改成“完整覆盖”，也可以靠保留原始事件或 provider 标记做细化调整。

### 3. 分类优先级建议固定下来，避免多处重复推导

建议优先级：

1. `explicitKind`
2. `tool_call_update.kind`
3. `content` 结构
4. `permission.kind`
5. `rawInput`
6. `title`
7. `toolName` 或 provider 特定字段
8. fallback `other`

建议映射：

| 信号 | 建议归类 |
| --- | --- |
| `kind = read` | `read` |
| `kind = edit` | `edit` |
| `kind = delete` | `delete` |
| `kind = move` | `move` |
| `kind = search` | `search` |
| `kind = execute` | `execute` |
| `kind = think` | `think` |
| `kind = fetch` | `fetch` |
| `kind = switch_mode` | `switch_mode` |
| `content` 含 `diff` | `edit` |
| `content` 含 `terminal` | `execute` |
| `rawInput.command` 存在 | `execute` |
| 权限 `kind = shell` | `execute` |
| 权限 `kind = write` | `edit` |
| 权限 `kind = read` | `read` |
| 权限 `kind = url` | `fetch` |
| 由 `agent_thought_chunk` 合成 | `think` |

### 4. 状态归一化不要假设枚举绝对稳定

真实项目里已经有人把 `status` 放宽成普通字符串来容错。

所以建议：

- 原始状态保留原值
- 内部阶段单独映射
- 未识别状态不要丢弃，落到：
  - `rawStatus = "..."`
  - `normalizedPhase = "running"` 或 `"announced"` 的保守值

### 5. 为会话恢复和历史回放设计幂等性

因为 `session/load` 可能回放整段历史，建议：

- 把每个原始 ACP update 都赋一个本地 `arrivalSeq`
- 如果同一 session 被恢复回放，允许重复 merge
- 不要因为“重复收到同一 `tool_callId`”就直接视为错误

如果后续需要更强去重，可加：

- `(sessionId, toolCallId, status, title, contentFingerprint, locationsFingerprint)` 级别的 event 指纹

## 五、对当前核心归一化逻辑最值得立刻吸收的结论

如果只提炼成几条最直接可落地的结论，就是下面这些：

- 工具调用必须建模成“状态对象 + 增量补丁”，不能只当流式日志。
- 主键必须是 `(sessionId, toolCallId)`，否则多会话一定串。
- `tool_call_update` 的 `content` / `locations` 在真实 Copilot 接入里应按“增量追加”消费。
- 严格 schema 校验不能阻断工具调用归一化；缺字段、乱序、异常 `rawOutput` 都要容忍。
- 分类不能只看 `kind`，必须同时参考 `rawInput`、`content`、权限请求和合成思考态。
- 时间线和实体状态必须解耦，否则生命周期会碎成多条 UI 记录。

## 参考链接

- ACP 协议工具调用文档：
  - [tool-calls.mdx](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/tool-calls.mdx)
  - [tool_call.rs](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/src/tool_call.rs)
- GitHub 官方 SDK：
  - [types.ts](https://github.com/github/copilot-sdk/blob/main/nodejs/src/types.ts)
  - [session-events.ts](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/session-events.ts)
- `uplink`：
  - [acp-types.ts](https://github.com/MattKotsenas/uplink/blob/main/src/shared/acp-types.ts)
  - [conversation.ts](https://github.com/MattKotsenas/uplink/blob/main/src/client/conversation.ts)
  - [tool-call.tsx](https://github.com/MattKotsenas/uplink/blob/main/src/client/ui/tool-call.tsx)
  - [conversation.test.ts](https://github.com/MattKotsenas/uplink/blob/main/test/unit/conversation.test.ts)
- `mcp-copilot-acp`：
  - [acp.ts](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/types/acp.ts)
  - [acp-client.ts](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/acp-client.ts)
  - [response-aggregator.ts](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/response-aggregator.ts)
  - [response-aggregator.test.ts](https://github.com/bsmi021/mcp-copilot-acp/blob/main/src/response-aggregator.test.ts)
  - [CLAUDE.md](https://github.com/bsmi021/mcp-copilot-acp/blob/main/CLAUDE.md)
- `cli-acp`：
  - [server/index.js](https://github.com/MSBart2/cli-acp/blob/main/webapp/server/index.js)
  - [App.jsx](https://github.com/MSBart2/cli-acp/blob/main/webapp/client/src/App.jsx)
