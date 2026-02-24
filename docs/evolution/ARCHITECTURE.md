# TidyFlow AI 自主进化系统架构设计

## 1. 目标与边界

本设计用于在 TidyFlow 内构建“可持续循环”的 AI 自主进化系统，覆盖功能新增、性能优化、Bug 修复、架构优化、界面优化等方向。

关键约束：

- 方向选择：LLM 自主评分优先。
- 多工作空间并行：不同 `project/workspace` 可同时运行。
- 单工作空间串行：同一 `project/workspace` 内严格单线程推进阶段。
- 验证回路上限：单次 cycle 最多 3 次 `implement -> verify -> judge`。
- 全流程循环不限次数：由用户显式中断。
- 验收门槛与最小证据集：由 LLM 自主定义。
- 调度真相源：结构化 JSON 文件；文档用于人类阅读与语义交接。

## 2. 核心概念

- Cycle：一次完整进化循环，包含方向选择到结果报告。
- Stage：cycle 内的阶段，固定为 direction -> plan -> implement -> verify -> judge -> report。
- Workspace Pipeline：单 workspace 的串行执行器。
- Global Orchestrator：全局编排器，管理并发、队列、用户中断和恢复。
- Evidence：验证证据，如日志、截图、指标、diff 摘要。

## 3. 架构分层

### 3.1 Core 层

- `Global Evolution Orchestrator`
  - 维护全局运行视图。
  - 负责多 workspace 并行调度和公平轮转。
  - 处理中断、恢复、重入幂等。
- `Workspace Pipeline Runner`
  - 读取与写入 cycle/stage JSON。
  - 串行推进阶段。
  - 执行验证回路计数和上限控制。
- `Agent Runtime`
  - 复用现有 AI Chat/Session 能力。
  - 每阶段使用独立会话，防止消息串线。
- `Evidence Store`
  - 管理 `evidence.index.json` 与证据文件路径。

### 3.2 App 层

- `Evolution Console`
  - 展示全局并发状态和 workspace 队列。
  - 展示每个 stage 的聊天流与证据。
  - 提供 `停止 workspace`、`停止全部`、`恢复` 操作。
- `Stage Chat Viewer`
  - 根据 `chat.map.json` 映射打开对应 AI 会话。

## 4. 调度模型

### 4.1 并发规则

- 并发键：`workspace_key = project + ":" + workspace`。
- 同键互斥：同一键同时只允许一个 `running` cycle。
- 异键并行：多个键可并发执行，受全局并发上限控制。

### 4.2 串行规则

- 同一 workspace 内，阶段严格顺序执行。
- 任何阶段未完成前，不允许进入下游阶段。

### 4.3 回路规则

- `judge = pass`：进入 `report`。若开启自动续轮，`report` 结束后先执行一键提交，成功后再创建下一轮 cycle；失败则当前 cycle 进入 `failed_system`。
- `judge = fail` 且 `verify_iteration < 3`：回到 `implement`。
- `judge = fail` 且 `verify_iteration == 3`：标记 `failed_exhausted`，开始下一全流程循环或等待策略决策。

## 5. 状态机

### 5.1 Cycle 状态

- `pending`
- `running`
- `interrupted`
- `completed`
- `failed_exhausted`
- `failed_system`
- `cancelled`

### 5.2 合法转移

- `pending -> running`
- `running -> interrupted`
- `interrupted -> running`
- `running -> completed`
- `running -> failed_exhausted`
- `* -> failed_system`
- `pending|running|interrupted -> cancelled`

## 6. 存储布局

目录约定：

`.tidyflow/evolution/<project>/<workspace>/<cycle_id>/`

核心文件：

- `cycle.json`
- `stage.direction.json`
- `stage.plan.json`
- `stage.implement.json`
- `stage.verify.json`
- `stage.judge.json`
- `stage.report.json`
- `evidence.index.json`
- `chat.map.json`
- `handoff.md`

## 7. 一致性与幂等

- 同一 workspace 的调度动作必须幂等。
- 同一事件必须可去重（`event_id`、`event_seq`）。
- 调度推进前必须通过 schema 校验。
- 调度决策只读取 JSON，不依赖自然语言正文。

## 8. 中断与恢复

- 中断类型：`workspace`、`global`。
- 中断策略：写入中断请求后，在阶段安全点退出。
- 恢复策略：从 `cycle.json.current_stage` 与阶段文件恢复，不重跑已完成阶段。
- 异常恢复：启动后扫描非终态 cycle，进入 `recovering` 分支后再回到 `running`。

## 9. 与现有能力的衔接

- 协议层：基于现有 MessagePack v6 包络增量扩展 `evo_*` 消息。
- 任务广播：复用现有 task broadcast 通道扩展演化事件。
- AI 会话：复用现有 AI Chat，增加 stage 到 session 的映射管理。
