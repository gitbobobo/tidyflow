# TidyFlow 演化系统协议增量设计（MessagePack v2）

## 1. 设计目标

在不破坏现有协议语义的前提下，新增 `evo_*` 消息族用于：

- 启停与恢复演化任务。
- 订阅多工作空间并行状态。
- 获取单 workspace 的阶段推进细节。
- 在 App 中按阶段回放 AI 聊天过程。

## 2. 客户端消息（ClientMessage）增量

### 2.1 `evo_start_workspace`

启动指定 workspace 的演化循环。

字段：

- `project`: string
- `workspace`: string
- `ai_tool`: string
- `config`: object
  - `parallel_group`: string|null
  - `priority`: integer|null
  - `max_verify_iterations`: integer，固定传 `3`

### 2.2 `evo_stop_workspace`

请求停止指定 workspace。

字段：

- `project`: string
- `workspace`: string
- `reason`: string|null

### 2.3 `evo_stop_all`

请求停止所有运行中的 workspace。

字段：

- `reason`: string|null

### 2.4 `evo_resume_workspace`

恢复 `interrupted` 的 workspace cycle。

字段：

- `project`: string
- `workspace`: string

### 2.5 `evo_get_snapshot`

拉取全局或局部快照。

字段：

- `project`: string|null
- `workspace`: string|null

### 2.6 `evo_subscribe_workspace`

订阅单 workspace 的演化事件流。

字段：

- `project`: string
- `workspace`: string

### 2.7 `evo_unsubscribe_workspace`

取消订阅单 workspace。

字段：

- `project`: string
- `workspace`: string

### 2.8 `evo_open_stage_chat`

根据 `cycle_id + stage` 查询对应 `session_id`，供 App 打开聊天记录。

字段：

- `project`: string
- `workspace`: string
- `cycle_id`: string
- `stage`: string

## 3. 服务端消息（ServerMessage）增量

### 3.1 生命周期类

- `evo_workspace_started`
  - `project`, `workspace`, `cycle_id`, `status`
- `evo_workspace_stopped`
  - `project`, `workspace`, `cycle_id`, `status`, `reason`
- `evo_workspace_resumed`
  - `project`, `workspace`, `cycle_id`, `status`

### 3.2 过程类

- `evo_stage_changed`
  - `project`, `workspace`, `cycle_id`
  - `from_stage`, `to_stage`
  - `verify_iteration`
- `evo_cycle_updated`
  - `project`, `workspace`, `cycle_id`
  - `status`, `current_stage`
  - `llm_defined_acceptance`
- `evo_evidence_updated`
  - `project`, `workspace`, `cycle_id`
  - `evidence_item`
- `evo_judge_result`
  - `project`, `workspace`, `cycle_id`
  - `result` (`pass|fail`)
  - `reason`
  - `next_action`

### 3.3 查询响应类

- `evo_snapshot`
  - `global_status`
  - `workspace_items[]`
- `evo_stage_chat_opened`
  - `project`, `workspace`, `cycle_id`, `stage`
  - `ai_tool`, `session_id`

### 3.4 错误类

- `evo_error`
  - `code`
  - `message`
  - `context`

## 4. 通用事件字段约束

所有 `evo_*` 服务端推送消息必须包含：

- `event_id`: string（UUID）
- `event_seq`: integer（同 workspace 单调递增）
- `project`: string
- `workspace`: string
- `cycle_id`: string
- `ts`: string（RFC3339 UTC）
- `source`: enum `orchestrator|agent|system|user`

## 5. 幂等语义

### 5.1 `evo_start_workspace`

- 若 workspace 已有 `running` cycle，返回 `evo_error.code = evo_workspace_locked`。
- 不重复创建 cycle。

### 5.2 `evo_stop_workspace`

- 重复 stop 视为幂等成功。
- 服务端可附加 `already_interrupted = true`。

### 5.3 `evo_resume_workspace`

- 仅 `interrupted` 状态允许恢复。
- 重复 resume 视为幂等成功。

### 5.4 `evo_open_stage_chat`

- 若映射已存在，返回已有 `session_id`。
- 不重复创建 AI 会话。

## 6. 与现有协议兼容策略

- 仅新增 `evo_*` 消息，不变更既有消息含义。
- 复用现有 `RequestEnvelope/ResponseEnvelope` 关联 `id`。
- 复用现有任务广播机制推送演化事件。
- App 不支持 `evo_*` 时，不影响既有终端、文件、Git、AI Chat 功能。

## 7. 建议的交互时序

1. App 发送 `evo_start_workspace`。
2. Core 回 `evo_workspace_started`。
3. App 发送 `evo_subscribe_workspace`。
4. Core 连续推送 `evo_stage_changed`、`evo_cycle_updated`、`evo_evidence_updated`。
5. App 需要回放阶段聊天时发送 `evo_open_stage_chat`。
6. Core 回 `evo_stage_chat_opened`，App 复用现有 AI 会话接口拉取历史与流式事件。

