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
