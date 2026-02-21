# TidyFlow AI 自主进化系统 JSON 结构定义

## 1. 总体约束

- 所有 JSON 文件必须包含 `$schema_version`。
- 时间字段统一使用 RFC3339 UTC 字符串。
- `cycle_id` 在单 workspace 目录下全局唯一。
- 调度推进前必须完成结构校验。

## 2. cycle.json

用途：单次 cycle 的主状态与控制面。

### 2.1 字段定义

- `$schema_version`: string，示例 `1.0`
- `cycle_id`: string
- `project`: string
- `workspace`: string
- `status`: enum
  - `pending | running | interrupted | completed | failed_exhausted | failed_system | cancelled`
- `current_stage`: enum
  - `bootstrap | direction | plan | implement | verify | judge | report`
- `pipeline`: 固定阶段数组
- `verify_iteration`: integer，`0..3`
- `verify_iteration_limit`: integer，固定 `3`
- `global_loop_round`: integer，`>= 1`
- `interrupt`: object
  - `requested`: boolean
  - `requested_by`: string|null
  - `requested_at`: string|null
  - `reason`: string|null
- `direction`: object
  - `selected_type`: enum `feature|performance|bugfix|architecture|ui`
  - `candidate_scores`: array
  - `final_reason`: string
- `llm_defined_acceptance`: object
  - `criteria`: array
  - `minimum_evidence_policy`: object
- `stage_files`: object，固定 7 个阶段文件名
- `chat_map_file`: string
- `evidence_index_file`: string
- `handoff_file`: string
- `created_at`: string
- `updated_at`: string

### 2.2 示例

```json
{
  "$schema_version": "1.0",
  "cycle_id": "2026-02-19T13-20-00Z_p1_w_default_0001",
  "project": "tidyflow",
  "workspace": "default",
  "status": "running",
  "current_stage": "verify",
  "pipeline": ["bootstrap", "direction", "plan", "implement", "verify", "judge", "report"],
  "verify_iteration": 2,
  "verify_iteration_limit": 3,
  "global_loop_round": 12,
  "interrupt": {
    "requested": false,
    "requested_by": null,
    "requested_at": null,
    "reason": null
  },
  "direction": {
    "selected_type": "architecture",
    "candidate_scores": [
      {"type": "feature", "score": 0.64, "reason": "..."},
      {"type": "architecture", "score": 0.83, "reason": "..."}
    ],
    "final_reason": "..."
  },
  "llm_defined_acceptance": {
    "criteria": [{"id": "ac-1", "text": "..."}],
    "minimum_evidence_policy": {"strategy": "llm_decided", "description": "..."}
  },
  "stage_files": {
    "bootstrap": "stage.bootstrap.json",
    "direction": "stage.direction.json",
    "plan": "stage.plan.json",
    "implement": "stage.implement.json",
    "verify": "stage.verify.json",
    "judge": "stage.judge.json",
    "report": "stage.report.json"
  },
  "chat_map_file": "chat.map.json",
  "evidence_index_file": "evidence.index.json",
  "handoff_file": "handoff.md",
  "created_at": "2026-02-19T13:20:00Z",
  "updated_at": "2026-02-19T13:26:10Z"
}
```

## 3. stage.<name>.json

用途：单阶段执行输入、输出、决策、耗时。

### 3.1 字段定义

- `$schema_version`: string
- `cycle_id`: string
- `stage`: enum `bootstrap|direction|plan|implement|verify|judge|report`
- `agent`: string
- `status`: enum `pending|running|blocked|done|failed|cancelled`
- `inputs`: array
- `outputs`: array
- `decision`: object
  - `result`: enum `pass|fail|n/a`
  - `reason`: string
- `next_action`: object
  - `type`: enum `goto_stage|finish_cycle|stop_cycle|none`
  - `target`: string|null
- `timing`: object
  - `started_at`: string|null
  - `completed_at`: string|null
  - `duration_ms`: integer|null
- `error`: object|null

### 3.2 示例

```json
{
  "$schema_version": "1.0",
  "cycle_id": "2026-02-19T13-20-00Z_p1_w_default_0001",
  "stage": "verify",
  "agent": "VerifierAgent",
  "status": "done",
  "inputs": [
    {"type": "file", "path": "stage.plan.json"},
    {"type": "file", "path": "stage.implement.json"}
  ],
  "outputs": [
    {"type": "log", "path": "evidence/verify/test.log"},
    {"type": "screenshot", "path": "evidence/verify/ui-main.png"}
  ],
  "decision": {"result": "fail", "reason": "..."},
  "next_action": {"type": "goto_stage", "target": "implement"},
  "timing": {
    "started_at": "2026-02-19T13:24:01Z",
    "completed_at": "2026-02-19T13:25:40Z",
    "duration_ms": 99000
  },
  "error": null
}
```

## 4. evidence.index.json

用途：证据总索引，供 Judge 与 App 面板统一读取。

### 4.1 字段定义

- `$schema_version`: string
- `cycle_id`: string
- `items`: array
  - `evidence_id`: string
  - `type`: enum `test_log|build_log|screenshot|metrics|diff_summary|custom`
  - `path`: string
  - `generated_by_stage`: stage enum
  - `linked_criteria_ids`: string array
  - `summary`: string
  - `created_at`: string

### 4.2 示例

```json
{
  "$schema_version": "1.0",
  "cycle_id": "2026-02-19T13-20-00Z_p1_w_default_0001",
  "items": [
    {
      "evidence_id": "ev-001",
      "type": "test_log",
      "path": "evidence/verify/test.log",
      "generated_by_stage": "verify",
      "linked_criteria_ids": ["ac-1"],
      "summary": "...",
      "created_at": "2026-02-19T13:25:10Z"
    }
  ]
}
```

## 5. chat.map.json

用途：阶段与 AI 会话映射，支撑 App 聊天回放。

### 5.1 字段定义

- `$schema_version`: string
- `cycle_id`: string
- `project`: string
- `workspace`: string
- `sessions`: array
  - `stage`: stage enum
  - `ai_tool`: string
  - `session_id`: string
- `updated_at`: string

### 5.2 示例

```json
{
  "$schema_version": "1.0",
  "cycle_id": "2026-02-19T13-20-00Z_p1_w_default_0001",
  "project": "tidyflow",
  "workspace": "default",
  "sessions": [
    {"stage": "direction", "ai_tool": "codex", "session_id": "s-dir-001"},
    {"stage": "plan", "ai_tool": "codex", "session_id": "s-plan-001"},
    {"stage": "implement", "ai_tool": "codex", "session_id": "s-impl-003"},
    {"stage": "verify", "ai_tool": "codex", "session_id": "s-ver-002"},
    {"stage": "judge", "ai_tool": "codex", "session_id": "s-judge-002"}
  ],
  "updated_at": "2026-02-19T13:25:41Z"
}
```

## 6. 校验失败处理原则

- `cycle.json` 失败：禁止推进，返回 `evo_cycle_file_invalid`。
- `stage.*.json` 失败：保持原阶段，返回 `evo_stage_file_invalid`。
- `evidence.index.json` 失败：禁止 judge，返回 `evo_evidence_index_invalid`。
- `chat.map.json` 缺失目标 stage：允许调度继续，但 App 打开聊天时报 `evo_chat_session_not_found`。

## 7. 验收与证据映射规范（w-3）

- 验收标准建议统一命名为 `ac-1`、`ac-2`...
- 每条验收标准必须至少映射到 `verification_plan.checks` 中一条或多条 check，且 `minimum_evidence` 至少一项；
- 证据不足应显式标注为 `insufficient_evidence`，不得替代为通过。
