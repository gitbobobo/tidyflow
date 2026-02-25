# Evolution 验收协议与证据基线

> 文档版本：1.4 | 更新日期：2026-02-25

本文档对齐当前 cycle `2026-02-25T05-21-59-034Z` 的 `plan.execution.json`，用于让 verify/judge 仅基于映射与证据完成判定。

## 0. 方向权威源

- 当前 cycle 执行方向以 `cycle.json.direction.selected_type=architecture` 为唯一权威。
- `handoff.md` 中出现的 `bugfix` 表述仅作为历史观察，不作为本轮实施方向。

## 1. 验收标准（AC）映射契约

| AC | 定义 | check_id 映射 | minimum_evidence |
|----|------|---------------|------------------|
| ac-1 | 验证链路可追溯（integration + 跨端截图 + 人工核验） | `v-2`, `v-3`, `v-4` | `test_log`, `screenshot` |
| ac-2 | 契约一致且可判定（unit + integration + 人工核验） | `v-1`, `v-2`, `v-4` | `test_log`, `diff_summary` |
| ac-3 | 跨端状态一致（e2e + build） | `v-3`, `v-5` | `screenshot`, `build_log` |

判定约束：
- 每条 AC 至少 1 个 `check_id` 且至少 1 个 `minimum_evidence`。
- 缺失任一 `minimum_evidence` 时，该 AC 必须判定为 `fail` 或 `undetermined`。
- verify/judge 只允许消费 `acceptance_mapping + evidence.index.json` 判定，不依赖聊天文本。

## 2. 检查项（V）执行口径

| ID | kind | 命令/方法 | 期望 |
|----|------|-----------|------|
| v-1 | unit | `./scripts/tidyflow test` | 单测通过并输出 `test_log` |
| v-2 | integration | `./scripts/evo-run.sh --step integration` | 集成通过；失败输出 `failed_check_id/log_path` |
| v-3 | e2e | `./scripts/evo-screenshot.sh --platform both --states empty,loading,ready` | macOS+iOS 三态截图齐全并入索引 |
| v-4 | manual | 人工核验 `evidence.index.json` 的 `run_id/check_id/path` 一致性 | 无孤儿证据，证据链闭环 |
| v-5 | build | `xcodebuild`（macOS + iOS 串行） | 双端构建通过 |

默认验证顺序：`unit -> integration -> e2e -> manual`。
`build` 为独立门禁（串行执行），不与验证链并发写状态。

## 3. 状态词典与兼容窗口

- 新状态词典：`empty/loading/ready`。
- 兼容别名（deprecated）：`initial->empty`、`processing->loading`、`complete->ready`、`error->ready`。
- 兼容窗口：1 个发布周期，仅保留读取兼容；新写入统一使用新词典。

## 4. 证据与索引要求

最小证据类型集合：`test_log|build_log|metrics|screenshot|diff_summary`。

证据索引要求：
- 写入采用原子替换（tmp + rename）。
- 同一 `run_id + check_id + artifact` 重复执行必须幂等（覆盖或去重）。
- 失败链必须可追溯到 `failed_check_id` 与 `log_path`，截图失败需有 `screenshot_path` 或缺失说明。
