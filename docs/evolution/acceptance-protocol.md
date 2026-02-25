# Evolution 验收协议与证据基线

> 文档版本：1.3 | 更新日期：2026-02-25

本文档对齐 `plan.execution.json`（cycle: `2026-02-25T04-28-04-101Z`），用于让 verify/judge 直接消费 AC->check->evidence 映射。

## 1. 验收标准（AC）映射契约

| AC | 定义 | check_id 映射 | minimum_evidence |
|----|------|---------------|------------------|
| ac-1 | 跨端关键流程具备可判定闭环（截图证据与双端构建同时满足） | `v-3`, `v-5` | `screenshot`, `build_log` |
| ac-2 | 失败可定位（integration 结果可追溯到日志与差异摘要） | `v-2`, `v-4` | `test_log`, `diff_summary` |
| ac-3 | 证据完整性可核验（测试日志+跨端三态截图） | `v-1`, `v-2`, `v-3` | `test_log`, `screenshot` |

判定约束：
- 每条 AC 至少 1 个 `check_id` 且至少 1 个 `minimum_evidence`。
- 缺失任一 `minimum_evidence` 时，该 AC 不能判定为 `pass`。
- 证据必须可通过 `run_id/trace_id/check_id` 关联。

## 2. 检查项（V）

| ID | kind | 命令/方法 | 期望 |
|----|------|-----------|------|
| v-1 | unit | `./scripts/tidyflow test` | 核心单测通过并输出可解析 `test_log` |
| v-2 | integration | `./scripts/evo-run.sh --step integration` | integration 通过并输出结构化日志 |
| v-3 | e2e | `./scripts/evo-screenshot.sh --platform both --states empty,loading,ready` | macOS/iOS 三态截图齐全并可回溯 |
| v-4 | manual | 抽查 `evidence.index.json` 与日志锚点关联 | 可用 `run_id/trace_id` 串联日志与证据 |
| v-5 | build | `xcodebuild`（macOS + iOS） | 双端构建通过，无平台特异性回归 |

## 3. 可观测性与失败锚点

关键流程日志关键词：
- `CROSS_PLATFORM_FLOW_START`
- `CROSS_PLATFORM_FLOW_SUCCESS`
- `CROSS_PLATFORM_FLOW_FAIL`
- `EVIDENCE_INDEX_WRITE_OK`
- `EVIDENCE_INDEX_WRITE_FAIL`

关键指标（至少可从日志或 metrics 文件提取）：
- `cross_platform_flow_pass_rate`
- `evidence_missing_rate`
- `e2e_screenshot_completion_rate`

失败输出要求：
- 必须包含 `failed_check_id` 与失败日志路径。
- 必须输出回退建议（上一稳定 `run_id`）。

## 4. 证据输出要求

实现/验证阶段最小输出集：
- `runs/<run_id>/evidence/*.log`
- `runs/<run_id>/evidence/*-metrics-<run_id>.json`
- `runs/<run_id>/evidence/*-diff-<run_id>.md`
- `artifacts/screenshots/macOS/*.png`
- `artifacts/screenshots/iOS/*.png`
- `evidence.index.json`

verify/judge 必须基于以上产物自动或半自动判定，不依赖聊天文本解释。
