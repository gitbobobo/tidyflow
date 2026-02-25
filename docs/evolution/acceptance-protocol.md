# Evolution 验收协议与证据基线

> 文档版本：1.5 | 更新日期：2026-02-25

本文档对齐当前 cycle `2026-02-25T06-00-02-292Z` 的 `plan.execution.json`，用于让 verify/judge 仅基于映射与证据完成判定。

## 0. 方向权威源

- 当前 cycle 执行方向以 `cycle.json.direction.selected_type=architecture` 为唯一权威。
- 所有实施与验证均以本 cycle 目录结构化产物为准，不依赖聊天文本。

## 1. 验收标准（AC）映射契约

| AC | check_id 映射 | minimum_evidence |
|----|---------------|------------------|
| ac-1 | `v-1`, `v-2` | `test_log` |
| ac-2 | `v-3`, `v-4` | `build_log` |
| ac-3 | `v-5` | `screenshot` |
| ac-4 | `v-6` | `diff_summary` |
| ac-5 | `v-7` | `metrics` |

判定约束：
- 每条 AC 至少 1 个 `check_id` 且至少 1 个 `minimum_evidence`。
- 缺失任一 `minimum_evidence` 时，该 AC 必须判定为 `fail` 或 `undetermined`。
- 未自动化证据必须在索引中显式写入 `missing_reason`，禁止静默缺失。

## 2. 检查项（V）执行口径

| ID | kind | 命令/方法 | 期望 |
|----|------|-----------|------|
| v-1 | unit | `cargo test --manifest-path core/Cargo.toml` | core 单元测试全部通过 |
| v-2 | integration | `cargo test --manifest-path core/Cargo.toml --test protocol_v1 --test manager_test` | 协议与管理器集成测试通过 |
| v-3 | build | `xcodebuild ... -destination 'platform=macOS' ... build` | macOS Debug 构建成功 |
| v-4 | build | `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' ... build` | iOS Debug 构建成功（必须串行，晚于 v-3） |
| v-5 | manual | 按 `docs/evolution/screenshot-strategy.md` 采集双端三态截图并入索引 | macOS+iOS 的 `empty/loading/ready` 各 3 张 |
| v-6 | e2e | `./scripts/tidyflow quality-gate --cycle <cycle_id> --step all` | 入口可执行，且不再出现缺失脚本错误 |
| v-7 | manual | 检查 `~/.tidyflow/logs/` 关键字计数（plan/verify/evidence） | 日志存在关键字并可统计 |

默认验证顺序：`unit -> integration -> e2e -> manual`。  
`build` 为独立门禁，必须串行执行，禁止并行 `xcodebuild`。

## 3. 证据与索引要求

最小证据类型集合：`test_log|build_log|metrics|screenshot|diff_summary`。

证据索引要求：
- 写入采用原子替换（tmp + rename）。
- 同一 `run_id + check_id + path` 重复写入需保持幂等。
- 缺失证据必须显式记录 `missing_reason` 与 `status=missing`。
