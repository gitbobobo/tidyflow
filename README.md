## Native Shell 快捷键 (Phase B-2)

### Global
- `Cmd+Shift+P`: 打开命令板 (Command Palette)
- `Cmd+P`: 快速打开文件 (Quick Open)
- `Cmd+1/2/3`: 切换右侧工具面板 (Explorer/Search/Git)
- `Cmd+R`: 重新连接 (Reconnect)

### Workspace
- `Cmd+T`: 新建终端 Tab
- `Cmd+W`: 关闭当前 Tab
- `Ctrl+Tab` / `Ctrl+Shift+Tab`: 切换 Tab
- `Cmd+S`: 保存文件 (Placeholder)

## Native Git Panel (Phase C3-1)

右侧 Git 工具面板已原生化，支持：
- 显示 git status 列表（M/A/D/??/R/C 等状态）
- 文件名过滤搜索
- 点击文件打开 Native Diff Tab
- 自动刷新（60秒缓存）和手动刷新
- 空态显示（非 git 仓库、无变更、断开连接）

## Build DMG

### Unsigned Build (Internal Testing)

```bash
./scripts/release/build_dmg.sh
```

首次运行需右键 > 打开绕过 Gatekeeper。

### Signed Build (Distribution)

```bash
# 查看可用签名身份
security find-identity -v -p codesigning

# 使用 Developer ID Application 签名
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release/build_dmg.sh --sign
```

签名后仍需公证（D5-3）才能完全绕过 Gatekeeper。

产物位置：`dist/TidyFlow-<version>.dmg`

详见 `design/45-codesign-d5-2.md`。

### Notarize (D5-3)

公证让用户无需手动绕过 Gatekeeper。

```bash
# 1. 创建 Keychain profile（一次性）
xcrun notarytool store-credentials tidyflow-notary \
  --apple-id your@email.com \
  --team-id YOURTEAMID \
  --password <app-specific-password>

# 2. 公证已签名的 DMG
./scripts/release/notarize.sh --profile tidyflow-notary

# 3. 验证
xcrun stapler validate dist/TidyFlow-*.dmg
hdiutil attach dist/TidyFlow-*.dmg
spctl --assess --type execute --verbose /Volumes/TidyFlow/TidyFlow.app
```

详见 `design/46-notarization-d5-3a.md`。

### CI Build (GitHub Actions)

手动触发 workflow 构建 DMG：

1. 进入 Actions > "Build Release DMG"
2. 点击 "Run workflow"
3. 可选：勾选 "Sign the app" 进行签名构建
4. 可选：勾选 "Notarize the signed app" 进行公证（需先勾选签名）

签名构建需要配置 GitHub Secrets：
- `MACOS_CERT_P12_BASE64` - Developer ID 证书（p12 base64）
- `MACOS_CERT_PASSWORD` - p12 密码
- `SIGN_IDENTITY` - 签名身份字符串

公证构建需要额外配置：
- `ASC_API_KEY_ID` - App Store Connect API Key ID
- `ASC_API_ISSUER_ID` - App Store Connect Issuer ID
- `ASC_API_KEY_P8_BASE64` - AuthKey_XXXX.p8（base64）

详见 `design/48-ci-codesign-d5-3b-2.md` 和 `design/49-ci-notarize-d5-3b-3.md`。

### Release via Tag (D5-3c)

推送 `v*` 格式的 tag 自动触发发布：

```bash
git tag v1.0.0
git push origin v1.0.0
```

自动执行：
1. 构建签名 DMG
2. 提交 Apple 公证
3. 创建 GitHub Release
4. 上传 notarized DMG 作为 Asset

发布后用户可直接从 GitHub Releases 下载，双击运行无 Gatekeeper 警告。

详见 `design/50-github-release-d5-3c.md`。

## 许可证

本项目使用 `LGPL-3.0-only`。完整许可证文本见 `LICENSE`，并附带 `COPYING`（GNU GPL v3）供引用。
