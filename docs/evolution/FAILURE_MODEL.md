# TidyFlow 演化系统失败模型与恢复策略

## 1. 范围

本文件定义演化系统在调度、阶段执行、LLM 结构化输出、证据校验、用户中断场景下的失败分类、错误码和恢复策略。

## 2. 错误码清单

### 2.1 状态机类

- `evo_invalid_state_transition`
  - 含义：发生非法状态跳转。
  - 必填上下文：`workspace_key`, `cycle_id`, `from_status`, `to_status`.

- `evo_workspace_locked`
  - 含义：workspace 已有运行中的 cycle。
  - 必填上下文：`workspace_key`, `running_cycle_id`.

- `evo_resume_not_allowed`
  - 含义：当前状态不允许恢复。
  - 必填上下文：`cycle_id`, `status`.

### 2.2 数据校验类

- `evo_cycle_file_invalid`
  - 含义：`cycle.json` 不符合 schema。
  - 必填上下文：`cycle_id`, `validation_errors`.

- `evo_stage_file_invalid`
  - 含义：阶段文件不符合 schema。
  - 必填上下文：`cycle_id`, `stage`, `schema_version`, `validation_errors`.

- `evo_evidence_index_invalid`
  - 含义：证据索引不合法或缺失关键字段。
  - 必填上下文：`cycle_id`, `validation_errors`.

- `evo_chat_session_not_found`
  - 含义：阶段聊天会话映射不存在。
  - 必填上下文：`cycle_id`, `stage`.

### 2.3 执行类

- `evo_llm_output_unparseable`
  - 含义：LLM 输出无法解析为结构化内容。
  - 必填上下文：`cycle_id`, `stage`, `raw_excerpt`.

- `evo_verify_iteration_exhausted`
  - 含义：验证回路达到上限（3 次）。
  - 必填上下文：`cycle_id`, `verify_iteration`.

- `evo_interrupt_in_progress`
  - 含义：已收到中断请求，正在安全点退出。
  - 必填上下文：`cycle_id`, `stage`.

- `evo_cycle_not_found`
  - 含义：指定 cycle 不存在。
  - 必填上下文：`workspace_key`, `cycle_id`.

- `evo_internal_error`
  - 含义：未分类内部错误。
  - 必填上下文：`cycle_id`, `trace_id`.

- `evo_auto_commit_failed`
  - 含义：自动续轮前的一键提交失败，续轮被阻断。
  - 必填上下文：`cycle_id`, `message`.

## 3. 状态转移约束

## 3.1 Cycle 状态

`pending | running | interrupted | completed | failed_exhausted | failed_system | cancelled`

### 3.2 合法转移

- `pending -> running`
- `running -> interrupted`
- `interrupted -> running`
- `running -> completed`
- `running -> failed_exhausted`
- `* -> failed_system`
- `pending|running|interrupted -> cancelled`

### 3.3 禁止转移

- `completed -> running`
- `cancelled -> running`
- `failed_exhausted -> running`
- `failed_system -> running`

禁止转移统一返回 `evo_invalid_state_transition`。

## 4. 阶段回路约束

固定阶段序列：

`direction -> plan -> implement -> verify -> judge -> report`

回路规则：

- `judge=pass`：进入 `report`，结束 cycle。
- `judge=fail` 且 `verify_iteration < 3`：回到 `implement` 并加 1。
- `judge=fail` 且 `verify_iteration == 3`：转 `failed_exhausted`。
- `report` 后若启用自动续轮：必须先执行一键提交；提交成功（含无变更）才进入下一轮，失败返回 `evo_auto_commit_failed` 并转 `failed_system`。

## 5. 恢复策略矩阵

### 5.1 用户中断

- 触发：`evo_stop_workspace` 或 `evo_stop_all`。
- 行为：写中断标记，阶段安全点退出，状态变为 `interrupted`。
- 恢复：`evo_resume_workspace`，从 `current_stage` 继续。

### 5.2 解析失败

- 场景：`evo_llm_output_unparseable`。
- 行为：阶段内重试，保留阶段指针不推进。
- 升级：超过阶段重试阈值后进入 `failed_system`。

### 5.3 Schema 失败

- 场景：`evo_cycle_file_invalid` / `evo_stage_file_invalid` / `evo_evidence_index_invalid`。
- 行为：阻断推进，返回错误并保留当前状态。
- 恢复：修复 JSON 后可继续。

### 5.4 系统错误

- 场景：不可恢复 I/O、内部异常。
- 行为：状态置 `failed_system`，记录 `trace_id`。
- 恢复：不允许恢复当前 cycle，需创建新 cycle。

## 6. 幂等与去重

- 命令幂等：
  - `evo_stop_workspace` 重复请求必须成功返回。
  - `evo_resume_workspace` 重复请求必须成功返回。
- 事件去重：
  - 以 `event_id` 和 `event_seq` 去重。
  - App 必须按 `event_seq` 处理乱序。

## 7. 可观测性要求

所有 `evo_error` 事件必须包含：

- `event_id`
- `event_seq`
- `cycle_id`
- `workspace_key`
- `code`
- `message`
- `context`
- `ts`

建议统一落日志关键字：`[EVO]`，便于与现有日志体系检索聚合。
