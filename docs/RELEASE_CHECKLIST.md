# TidyFlow 发布清单

用于每次正式发布前的最小流程，默认使用一键发布脚本。

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

- [ ] 执行：`./scripts/release_local.sh --dry-run`
- [ ] 检查输出中的版本号、签名证书、DMG 路径、Tag、仓库名是否正确

## 5. 一键发布

- [ ] 询问用户是否执行脚本上传产物到 GitHub Release；若用户确认，则执行：`./scripts/release_local.sh --upload-release`
