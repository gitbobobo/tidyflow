# D5-3c: GitHub Release on Tag Push

## Overview

自动化发布流程：当推送 `v*` 格式的 tag 时，自动构建 notarized DMG 并发布到 GitHub Releases。

## Tag 规则

| Pattern | Example | Release Type |
|---------|---------|--------------|
| `v*.*.*` | `v1.0.0` | Stable release |
| `v*.*.*-*` | `v1.0.0-beta.1` | Pre-release |

Tag 必须以 `v` 开头，后跟语义化版本号。

## Workflow 行为

### 触发条件

```yaml
on:
  push:
    tags:
      - 'v*'
```

### 执行步骤

1. **验证 Secrets** - 检查签名和公证所需的所有 secrets
2. **构建签名 DMG** - 使用 `build_dmg.sh --sign`
3. **验证签名** - `codesign --verify`
4. **提交公证** - `notarytool submit --wait`
5. **Staple 票据** - `stapler staple`
6. **Gatekeeper 验证** - `spctl --assess`
7. **创建 Release** - 使用 `softprops/action-gh-release`
8. **上传 DMG** - 作为 Release Asset

### 失败策略

| 阶段 | 失败行为 |
|------|----------|
| Secrets 验证 | Job 立即失败，不构建 |
| 签名验证 | Job 失败，不公证 |
| 公证 | Job 失败，不创建 Release |
| Gatekeeper | Job 失败，不创建 Release |
| Release 创建 | Job 失败 |

**核心原则**：只有完全通过公证和 Gatekeeper 验证的 DMG 才会发布。

## Release 元数据

| 字段 | 值 |
|------|-----|
| Release Name | `TidyFlow vX.Y.Z` |
| Tag | 触发的 tag 名 |
| Draft | `false` |
| Pre-release | 自动检测（tag 包含 `-` 则为 pre-release） |
| Release Notes | GitHub 自动生成 + 安装说明 |
| Assets | `TidyFlow-*.dmg` |

## 所需 Secrets

与 `release-dmg.yml` 相同：

**签名**:
- `MACOS_CERT_P12_BASE64`
- `MACOS_CERT_PASSWORD`
- `SIGN_IDENTITY`

**公证**:
- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`
- `ASC_API_KEY_P8_BASE64`

## 使用方式

```bash
# 创建并推送 tag
git tag v1.0.0
git push origin v1.0.0

# 或一步完成
git tag v1.0.0 && git push origin v1.0.0
```

## 与现有 Workflow 的关系

| Workflow | 触发方式 | 用途 |
|----------|----------|------|
| `release-dmg.yml` | 手动 | 测试构建、调试签名/公证 |
| `release-on-tag.yml` | Tag push | 正式发布 |

两者复用相同的脚本（`build_dmg.sh`），保持单一真源。

## 限制

1. 仅支持 macOS（单平台）
2. Release notes 使用 GitHub 自动生成（未集成 CHANGELOG）
3. 不支持 Sparkle 自动更新（D5-4 实现）
