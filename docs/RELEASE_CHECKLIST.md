# TidyFlow 发布清单

用于每次正式发布前的最小流程，默认使用一键发布脚本。

## 1. 版本准备

- [ ] 更新版本号（`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`core/Cargo.toml`）
- [ ] 更新 `CHANGELOG.md` 当前版本条目

## 2. 发布预演（无副作用）

- [ ] 执行：`./scripts/release_local.sh --dry-run`
- [ ] 检查输出中的版本号、签名证书、DMG 路径、Tag、仓库名是否正确

## 3. 一键发布

- [ ] 仅本地签名+公证：`./scripts/release_local.sh`
- [ ] 或自动上传 GitHub Release：`./scripts/release_local.sh --upload-release`
- [ ] 如需自定义：可加 `--repo owner/name`、`--notes-file <file>`、`--latest`

## 4. 发布后确认

- [ ] 产物存在：`dist/TidyFlow-<version>-<build>.dmg` 与 `.sha256`
- [ ] 本地验签：`xcrun stapler validate dist/<dmg-name>.dmg`
- [ ] 若上传 Release，确认 GitHub 页面资产与说明正确
