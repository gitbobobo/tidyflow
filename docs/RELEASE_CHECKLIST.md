# TidyFlow 发布清单

用于每次正式发布前的最小流程，默认使用统一入口脚本 `./scripts/tidyflow`。

## 1. 版本准备

- [ ] 更新版本号（`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`core/Cargo.toml`）
- [ ] 根据提交历史补充 `CHANGELOG.md` 当前版本条目（见下方「补充 CHANGELOG」）
- [ ] 将 `[Unreleased]` 下已写入的条目移到新版本区块，并填上版本号与日期

## 2. 补充 CHANGELOG（根据提交历史）

在更新「当前版本条目」时，应基于自上一 tag 的提交历史整理变更说明，避免遗漏或凭空编写。

- [ ] 查看自上一版本 tag 以来的提交：
  ```bash
  git log $(git describe --tags --abbrev=0)..HEAD --oneline
  ```
  或指定 tag，例如：`git log v1.1.0..HEAD --oneline`
- [ ] 按类别归纳到 `CHANGELOG.md` 新版本区块下：
  - **Added**：新功能、新配置、新文档
  - **Changed**：行为变更、重构、配置/文案调整
  - **Fixed**：Bug 修复、崩溃/异常处理
  - **Removed**（如有）：移除的功能或废弃项
- [ ] 每条用一句话描述用户可见变更，可合并同主题的多次提交为一条；忽略纯 chore/docs 的琐碎提交时可合并为「文档与构建/脚本小调整」等。

## 3. 提交修改

- [ ] 将版本号与 CHANGELOG 的修改提交到当前分支，例如：
  ```bash
  git add CHANGELOG.md app/TidyFlow.xcodeproj/project.pbxproj core/Cargo.toml core/Cargo.lock
  git commit -m "chore: bump version and update changelog for vX.Y.Z"
  ```

## 4. 发布预演（无副作用）

- [ ] 执行：`./scripts/tidyflow release --dry-run`
- [ ] 检查输出中的版本号、签名证书、DMG 路径、Tag、仓库名是否正确
  - [ ] 确认包含以下关键项：版本号、Tag、DMG 路径、SHA 路径、签名证书、Notary Profile
  - [ ] 记录安全模式核对结论（默认本地监听 `127.0.0.1`，远程需显式 `remote_access_enabled`）
  - [ ] 识别兼容性风险：若本轮有 loopback/鉴权变更，补充回滚与恢复步骤

## 5. 架构护栏检查（必做）

- [ ] 执行：`./scripts/tidyflow check`
- [ ] 确认输出通过：
  - 协议一致性检查（Core 协议版本与文档、App 文档一致）
  - 协议 schema 同步检查（`schema/protocol` 与 Core/App domain 路由一致）
  - 版本一致性检查（`MARKETING_VERSION` 与 `core/Cargo.toml` 同步）

## 6. Evolution 证据回归检查

> 本节用于确保 Evolution 系统的测试与证据链正常工作。

- [ ] 执行统一入口：`./scripts/evo-run.sh --cycle <latest_cycle_id> --dry-run`（模拟执行）
- [ ] 检查日志关键字：确保 `[evo][build]`、`[evo][run]`、`[evo][ws]`、`[evo][evidence]` 标记存在
- [ ] 验证证据完整度：`evidence.index.json` 包含 build_log、test_log、screenshot、diff_summary
- [ ] 失败可追溯：若存在失败，确认可通过 `failure_context` 定位日志关键字与截图
- [ ] 兼容性说明：本次变更仅影响测试与证据链，不改变运行时对外行为

**回滚策略**：若证据机制导致不稳定，退回原手工验证流程，关闭统一入口调用。

## 7. 一键发布

- [ ] 询问用户是否执行脚本上传产物到 GitHub Release；若用户确认，则执行：`./scripts/tidyflow release --upload-release`
