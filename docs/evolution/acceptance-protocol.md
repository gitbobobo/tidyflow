# Evolution 验收协议与证据基线

> 文档版本：1.2 | 更新日期：2026-02-24

本文档与 `plan.execution.json` 对齐，定义 AC、检查项与证据映射，保证 verify/judge 可判定。

## 1. 验收标准（AC）

| ID | 定义 | 最小证据 |
|----|------|----------|
| ac-1 | 构建链路通过（core+macOS+iOS） | `build_log` |
| ac-2 | 单测与集成链路通过 | `test_log` |
| ac-3 | UI 三态截图达标 | `screenshot` |
| ac-4 | 证据完整性与一致性可判定 | `metrics`, `diff_summary` |
| ac-5 | 失败锚点可回溯且可给出回退建议 | `test_log`, `diff_summary` |

## 2. 检查项（V）

| ID | kind | 命令/方法 | 期望证据 |
|----|------|-----------|----------|
| v-1 | unit | `./scripts/tidyflow test` | `test_log` |
| v-2 | build | `cargo build --manifest-path core/Cargo.toml --release` | `build_log` |
| v-3 | build | `xcodebuild ... -destination 'platform=macOS' ...` | `build_log` |
| v-4 | build | `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' ...` | `build_log` |
| v-5 | integration | `./scripts/evo-run.sh --cycle <cycle_id> --step all` | `test_log` |
| v-6 | e2e/manual | `./scripts/evo-screenshot.sh ... --state initial|processing|complete|error` | `screenshot` |
| v-7 | manual | 核对 `evidence.index.json` 一致性 | `metrics` |
| v-8 | manual | 审阅 `diff-<run_id>.md` 与执行结果一致性 | `diff_summary` |

## 3. 固定执行顺序

`v-1 -> v-2 -> v-3 -> v-4 -> v-5`

- 任一失败时，后续高风险步骤必须停止。
- 失败输出必须包含：`failed_check_id`、日志锚点、上一稳定 `run_id` 回退建议。

## 4. 判定规则

- `build_log` 缺失：`ac-1 = fail`
- `test_log` 缺失：`ac-2 = fail`
- 截图不足三态：`ac-3 = not_met`
- 索引校验失败（路径/类型/ID/时间序）：`ac-4 = fail`
- 无失败锚点或无回退建议：`ac-5 = fail`

## 5. 输出要求

实现阶段至少产出：

- `runs/<run_id>/evidence/*.log`
- `runs/<run_id>/evidence/metrics-<run_id>.json`
- `runs/<run_id>/evidence/diff-<run_id>.md`
- `evidence.index.json`

verify/judge 必须基于这些产物做自动或半自动判定，不依赖聊天文本。
