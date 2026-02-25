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
