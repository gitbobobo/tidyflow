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
- [ ] 检查 `evidence.index.json` 包含：`evidence/failure_context/completeness/runs`
- [ ] 检查 `completeness.required_types` 覆盖 `build_log/test_log/screenshot/diff_summary/metrics`
- [ ] 若失败，确认日志包含失败锚点与上一稳定 `run_id` 回退建议
- [ ] 执行 AC->check->evidence 对照核验：
  - ac-1 => `v-2,v-3,v-4` => `test_log,screenshot`
  - ac-2 => `v-1,v-2,v-4` => `test_log,diff_summary`
  - ac-3 => `v-3,v-5` => `screenshot,build_log`
- [ ] 核对 `v-3` 证据必须同时覆盖 macOS+iOS 且状态为 `empty/loading/ready`
- [ ] 核对旧状态兼容窗口：`initial/processing/complete/error` 仅保留读取兼容 1 个发布周期，不允许新写入
- [ ] 若任一 AC 缺失 minimum_evidence，判定为阻断项，不允许发布

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

## 3.6. 热点性能回归检查（v1.46 新增）

- [ ] 执行：`./scripts/tidyflow perf-regression`
  - **或**通过 `./scripts/tidyflow quality-gate --cycle <cycle_id> --step all` 间接执行（推荐）
- [ ] 确认报告文件存在：`build/perf/hotspot-regression-report.json`
- [ ] 确认报告 `overall` 字段 **不为 `fail`**（`pass` 或 `warn` 均可继续发布）
- [ ] 若 `overall=warn`，检查 `warnings` 字段列出的场景，评估是否需要更新基线或优化热路径
- [ ] **不允许** 在 verify 路径中自动更新基线文件；基线更新只允许显式本地命令触发：
  ```bash
  # 仅在明确接受新的性能测量值时手动更新基线
  # 编辑 core/benches/baselines/hotspot_regression.json 并提交 code review
  ```

## 3.6.1. Apple 客户端性能基线（iPhone Simulator，本轮新增）

> 本节仅要求 iPhone 16 Simulator（iOS 18.6），不要求 macOS UI 自动化。

- [ ] 确认 Apple 客户端性能报告存在：`build/perf/apple-client-regression-report.json`
  - 由 `./scripts/tidyflow perf-regression` 自动生成（已包含聊天流式与 Evolution 面板两个场景）
- [ ] 确认报告 `overall` 字段 **不为 `fail`**
- [ ] 确认以下两个场景均有证据日志：
  - 聊天流式：`build/perf/apple-chat-stream-fixture-oslog.log`（含 `hotspot_key=ios_ai_chat`、`aiMessageTailFlush`、`memory_snapshot`）
  - Evolution 面板：`build/perf/apple-evolution-panel-fixture-oslog.log`（含 `evolution_timeline_recompute_ms=`、`evolution_monitor tier_change`、`memory_snapshot`）
- [ ] 若 `overall=warn`，检查各场景 `metrics[].p95_ms` 是否超过 warn_limit，评估是否需要优化
- [ ] 若 `overall=fail`，报告会区分 Core 热点失败与 Apple 客户端失败的原因，根据对应原因处理
- [ ] **不允许** 在 verify 路径中自动更新 `scripts/tools/apple_client_perf_baselines.json`；基线更新只允许显式本地修改后提交

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
