# D5-1: DMG Packaging (Unsigned)

## 目标
产出内部可用的 DMG，不签名、不公证。

## 目录结构

```
dist/
├── TidyFlow-1.0-1.dmg          # 最终产物
└── (临时文件已清理)

TidyFlow.app/
└── Contents/
    ├── MacOS/
    │   └── TidyFlow             # 主程序
    ├── Resources/
    │   └── Core/
    │       └── tidyflow-core    # 嵌入的 Core 二进制
    └── Info.plist
```

## 构建命令

```bash
# 完整构建（包含 Core）
./scripts/release/build_dmg.sh

# 跳过 Core 构建（需已有 core binary）
./scripts/release/build_dmg.sh --skip-core
```

## 版本号策略

从 Xcode 项目读取：
- `MARKETING_VERSION` → 短版本号 (如 1.0)
- `CURRENT_PROJECT_VERSION` → 构建号 (如 1)
- DMG 命名: `TidyFlow-{短版本}-{构建号}.dmg`

修改版本号：
1. 打开 `app/TidyFlow.xcodeproj`
2. 选择 TidyFlow target > General > Identity
3. 修改 Version 和 Build

## Gatekeeper 提示

因为未签名，首次运行会被 macOS Gatekeeper 拦截：

**方法 1: 右键打开**
1. 右键点击 TidyFlow.app
2. 选择"打开"
3. 在弹窗中点击"打开"

**方法 2: 系统设置**
1. 系统设置 > 隐私与安全性
2. 找到"TidyFlow 已被阻止"
3. 点击"仍要打开"

## 已知限制

1. **未签名**: 无法直接双击打开，需右键绕过
2. **未公证**: 从网络下载后需额外步骤解除隔离
3. **无自动更新**: 未集成 Sparkle

## 下一步 (D5-2)

- Developer ID 签名 (codesign)
- Apple 公证 (notarization)
- Stapling
