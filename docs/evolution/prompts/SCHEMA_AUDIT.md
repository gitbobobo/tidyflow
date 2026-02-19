# Prompts 与 Schema 对照审计（最终版）

更新时间：2026-02-19  
审计范围：
- `docs/evolution/SCHEMAS.md`
- `docs/evolution/ARCHITECTURE.md`
- `docs/evolution/FAILURE_MODEL.md`
- `docs/evolution/prompts/stage.*.prompt.md`（6 份）

## 结论

- 初始发现问题：7
- 已修复：7
- 未解决：0

当前六阶段提示词已与现有 schema/状态机约束达成一致，可作为基线版本继续迭代。

## 已收敛规则（当前生效）

1. `stage.*.json` 写入必须包含 11 个必填字段：`$schema_version`、`cycle_id`、`stage`、`agent`、`status`、`inputs`、`outputs`、`decision`、`next_action`、`timing`、`error`。
2. `next_action` 统一约束：`type` 只能为 `goto_stage|finish_cycle|stop_cycle|none`；`target` 类型必须为 `string|null`；仅 `goto_stage` 允许阶段名，其它类型必须是 JSON `null`。
3. 写入后必须通过对应 schema 校验，未通过不得标记为成功。
4. `verify` 与 `judge` 的 `verify_iteration`（及 `verify_iteration_limit`）必须从 `cycle.json` 读取并回填，禁止写死常量。
5. 非 `direction` 阶段默认不修改 `cycle.json` 控制字段（`status/current_stage/verify_iteration/pipeline`），由 orchestrator 推进。
6. 六阶段失败写入统一要求：`error` 至少包含 `code`、`message`、`context`。
7. 错误码覆盖已补齐执行类错误（按阶段职责）：`evo_llm_output_unparseable`、`evo_interrupt_in_progress`、`evo_verify_iteration_exhausted`。
8. `report.result.json.final_result.recommended_cycle_status` 已收敛为建议字段，仅供展示/分析，不直接驱动状态机；当前限定值为 `completed|failed_exhausted`，且 `judge_result=pass` 时必须为 `completed`。

## 回归检查清单

每次调整任一阶段提示词后，至少复核：
1. `stage.*.json` 11 字段与 `next_action` 类型约束是否仍完整。
2. 阶段跳转是否仍符合 `direction -> plan -> implement -> verify -> judge -> report` 与回路规则。
3. `verify_iteration` 是否始终从 `cycle.json` 读取。
4. 失败写入是否包含 `error.code/message/context`。
5. `report` 的 `recommended_cycle_status` 语义是否仍为“建议值”且不越权控制状态机。
