# TidyFlow 发布清单

用于正式发布前的最小流程，默认使用统一入口 `./scripts/tidyflow`。

## 1. 版本准备

- [ ] 本轮默认不强制修改版本号；仅在发布策略要求时再更新 `MARKETING_VERSION/CURRENT_PROJECT_VERSION/core/Cargo.toml`
- [ ] 若更新版本，补齐 `CHANGELOG.md`
- [ ] 确认本轮变更已记录跨端一致性影响（macOS/iOS）

## 2. 质量门禁（新增，发布前必做）

- [ ] 选择最新 cycle_id
- [ ] 执行：`./scripts/tidyflow quality-gate --cycle <cycle_id> --step all`
- [ ] 检查验证顺序为：`v-1(unit) -> v-2(integration) -> v-3(e2e) -> v-4(manual)`，`v-5(build)` 作为独立门禁

## 3. 架构护栏检查

- [ ] 执行：`./scripts/tidyflow check`
- [ ] 协议一致性、schema 同步、代码生成、版本一致性全部通过

## 3.5. 可观测性与诊断证据（v1.42 新增）

- [ ] 执行 `./scripts/tidyflow test` 确认 Core 观测快照测试通过
- [ ] 确认 `system_snapshot` 输出包含 `perf_metrics` 和 `log_context` 字段
- [ ] 确认结构化日志文件存在于 `~/.tidyflow/logs/`，格式为 `YYYY-MM-DD[-dev].log`
- [ ] 确认 macOS 调试面板（DebugPanelView）能正常展示性能指标与日志上下文
- [ ] 确认 iOS 工作区详情页（WorkspaceDetailView）能显示系统诊断条目
- [ ] 若开启了 `TIDYFLOW_PERF_LOG`，确认 perf 日志路径可访问且不为空
- [ ] 日志、指标与构建证据能共同支撑问题排查，而不是只保留单一日志文件

## 3.6. 热点性能回归检查与统一性能门禁（v1.47 更新）

> 本节由统一性能门禁契约 `scripts/tools/performance_gate_contract.json` 管理。发布阻断语义只由该契约决定，不再由 shell / checklist 各自维护判断规则。

- [ ] 执行：`./scripts/tidyflow quality-gate --cycle <cycle_id> --step all`
  - 性能回归包含在 `step all` 中，无需单独运行 `perf-regression`
  - 若需单独验证：`./scripts/tidyflow perf-regression`
- [ ] 确认统一性能门禁报告存在：`build/perf/performance-gate-report.json`
  - 报告须包含 `contract_version`、`overall`、`release_blocking=false`、`reason_codes`、`suites[]`、`project`、`workspace`
- [ ] 确认报告 `overall` 不为 `fail`，且 `release_blocking=false`
  - `pass` 或 `warn` 均可继续发布（`warn` 表示接近预算但未越过发布红线）
  - `fail` 或 `release_blocking=true` 将被 `release_local.sh` 自动阻断，需修复后重跑
- [ ] 确认子报告存在且结构完整：
  - Core 热点：`build/perf/hotspot-regression-report.json`
- [ ] 若任一子报告的 `overall=warn`，检查对应场景的 `reason_codes`，评估是否需要更新基线或优化热路径
- [ ] 若 `overall=fail`，报告会列出 `reason_codes`（如 `ratio_exceeded_fail`、`evidence_file_missing`、`suite_report_missing` 等），按原因处理
- [ ] **不允许** 在 verify 路径中自动更新基线文件；基线更新只允许显式本地修改后提交：
  - Core 热点：`core/benches/baselines/hotspot_regression.json`

### 3.6.1. 性能门禁绕过（仅当必要）

- 绕过仅通过 `--skip-quality-gate --bypass-reason "说明原因"` 路径，不新增静默开关
- 绕过会写入审计日志 `.tidyflow/release/gate-bypass.audit.log`，记录 cycle/project/workspace/原因

## 3.7. 多工作区性能回归与仪表盘验证（v2.0 新增）

> 本节基于 WI-001 新增的多工作区 fixture 场景与 PerformanceDashboardStore 共享投影层。

- [ ] 确认 `scripts/tools/performance_gate_contract.json` 的 `contract_version` 为 `"2.0"`
- [ ] 执行 `./scripts/tidyflow perf-regression`，确认生成：
  - `build/perf/hotspot-regression-report.json`
  - `build/perf/performance-gate-report.json`（overall、release_blocking、reason_codes）
- [ ] 若发现新场景 `warn` 或 `fail`：
  - 排查实时趋势：查看 `build/perf/hotspot-regression-report.json` 中对应场景的 `reason_codes`
  - 参考 `PerformanceDashboardProjection.isTrendDegrading` 语义判断是否是趋势性退化
  - **不允许** 为通过门禁而上调 warn_limit/fail_limit，需先分析退化原因
- [ ] 验证聊天界面性能卡与 Evolution 性能卡正确展示：
  - macOS：`AIChatStageView` 包含 `ChatPerformanceBadge`，`EvolutionPipelineView` 包含 `EvolutionPerformanceBadge`
  - iOS：`MobileAIChatView` 包含 `ChatPerformanceBadge`，`WorkspaceDetailView` 包含 `EvolutionPerformanceBadge`
  - 两端的状态名、颜色语义、阈值含义均来自 `PerformanceBudgetStatus.colorSemanticName` 和 `label`，不在视图层重新定义
- [ ] 验证多工作区隔离：切换工作区后，旧工作区的性能数据不出现在新工作区的仪表盘中
  - 对应代码：`PerformanceDashboardStore.clearRealtimeBuffers(project:workspace:)`
- [ ] 核对 iOS Simulator 定向测试通过：
  - `TidyFlowTests/PerformanceDashboardStoreTests`
  - `TidyFlowTests/PerformanceDashboardProjectionTests`
  - `TidyFlowTests/EvolutionPerfFixtureTests`

## 4. 发布预演（无副作用）

- [ ] 执行：`./scripts/tidyflow release --dry-run`
- [ ] 核对：版本号、Tag、DMG 路径、签名证书、Notary profile
- [ ] 记录安全模式结论（默认本地回环，远程访问需显式开启）

## 5. 升级与回退演练

- [ ] 先演练升级：`./scripts/upgrade.sh --skip-core`
- [ ] 记录脚本输出的 `backup_path`
- [ ] 验证回退入口：`./scripts/upgrade.sh --rollback-from <backup_path>`
- [ ] 确认失败恢复步骤可执行（应用退出、恢复旧包、重新启动）

## 6. 一键发布（人工确认后）

- [ ] 执行：`./scripts/tidyflow release --upload-release`
- [ ] 上传后核对 Release 资产与 SHA256 文件

## 3.7. 终端会话恢复验证（WI-002/WI-003）

- [ ] Rust Core 测试：`./scripts/tidyflow test` 通过（含 terminal_recovery SQLite 持久化层）
- [ ] 协议检查：`./scripts/tidyflow check` 通过（schema、协议版本与客户端规则同步）
- [ ] 性能回归：`./scripts/tidyflow perf-regression` 通过（含 3 个高负载多工作区新场景）
- [ ] Apple 定向测试（macOS build + 手工执行）：
  - [ ] `TerminalWorkspaceIsolationTests` — 恢复成功、恢复失败、同名工作区隔离三场景全绿
  - [ ] `WorkspaceSharedStateSemanticsTests` — 恢复语义回归全绿
- [ ] macOS Build：`xcodebuild -scheme TidyFlow -destination 'platform=macOS' SKIP_CORE_BUILD=1 build` 无错误
- [ ] iOS Simulator Build：`xcodebuild -scheme TidyFlow -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' SKIP_CORE_BUILD=1 build` 无错误
- [ ] 验证 `recovery_failed` 状态：健康面板显示 Critical incident，终端不可用提示正确
- [ ] 验证 Core 重启后恢复流程：启动日志中出现 `Loaded terminal recovery entries on startup`
- [ ] 验证同名工作区隔离：不同 project 下同名 workspace 的终端恢复记录互不干扰
