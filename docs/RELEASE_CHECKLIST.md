# TidyFlow 1.0.0 发布清单

用于每次正式发布前的最小检查流程，避免“可构建但不可分发”。

## 1. 版本与内容冻结

- [ ] `app/TidyFlow.xcodeproj/project.pbxproj` 中 `MARKETING_VERSION` 与目标版本一致
- [ ] `app/TidyFlow.xcodeproj/project.pbxproj` 中 `CURRENT_PROJECT_VERSION` 已按发布递增
- [ ] `core/Cargo.toml` 中 `version` 与 App 主版本策略一致
- [ ] 更新 `CHANGELOG.md` 当前版本条目（新增/变更/修复）

## 2. 本地验证

- [ ] 运行 `cargo test --manifest-path core/Cargo.toml`
- [ ] 运行 `./scripts/run-app.sh`，验证核心主流程：
  - [ ] 项目/工作区可切换
  - [ ] 终端可输入与缩放
  - [ ] Git 面板状态可刷新
  - [ ] 文件读写与快速打开正常

## 3. 构建与签名

- [ ] 证书可用：`security find-identity -v -p codesigning`
- [ ] 执行签名构建：`SIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_dmg.sh --sign`
- [ ] 产物存在：`dist/TidyFlow-<version>-<build>.dmg`

## 4. 公证与验签

- [ ] 公证：`./scripts/notarize.sh --profile tidyflow-notary --dmg dist/<dmg-name>.dmg`
- [ ] 验证 stapler：`xcrun stapler validate dist/<dmg-name>.dmg`
- [ ] 挂载后验证 Gatekeeper：`spctl --assess --type execute --verbose /Volumes/TidyFlow/TidyFlow.app`

## 5. 发布材料

- [ ] 发布说明包含：版本号、主要变更、已知限制、升级建议
- [ ] 附带 SHA256 校验值（必需）
  - [ ] 执行 `./scripts/tools/gen_sha256.sh dist/<dmg-name>.dmg` 或使用 `./scripts/build_dmg.sh` 自动生成
- [ ] 如需自动上传 GitHub Release，确认：
  - [ ] 已安装并登录 `gh`（`gh auth status`）
  - [ ] 运行 `./scripts/release_local.sh --upload-release`（可加 `--repo owner/name`、`--notes-file <file>`）
- [ ] 正式发布前执行一次预演：`./scripts/release_local.sh --dry-run`
- [ ] README 中发布命令与文档链接可用

## 6. 回归记录

- [ ] 记录本次发布中遇到的问题与处理方式
- [ ] 可复用流程经验同步到 `AGENTS.md` 的“经验总结”部分
