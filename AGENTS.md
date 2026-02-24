# AGENTS.md

该文件的作用是描述代理（agents）在此项目中工作时可能遇到的常见错误与困惑点。如果你在项目中遇到任何意外情况，请告知与你协作的开发人员，并在 AGENTS.md 文件中注明此情况，以帮助后续代理避免遇到相同问题。

## 基本约束

- 请使用中文与用户交流
- 请使用中文编写文档和代码注释
- 这个项目没有用户，目前还没有真正的数据，想做什么改动就做什么，不用担心。我们发布时再想办法
- 这个项目非常新颖，完全改变模式也没关系，我们正努力把它弄成合适的形状
- 保持 macOS 和iOS 版本功能一致

## 常用命令

```bash
# 统一入口（推荐）
./scripts/tidyflow dev

# Core 构建（Rust）
cargo build --manifest-path core/Cargo.toml --release

# 查看 Xcode 工程信息（先确认 scheme / destination）
xcodebuild -list -project app/TidyFlow.xcodeproj
xcodebuild -showdestinations -project app/TidyFlow.xcodeproj -scheme TidyFlow

# macOS 构建（Debug）
xcodebuild -project app/TidyFlow.xcodeproj \
  -scheme TidyFlow \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  SKIP_CORE_BUILD=1 \
  build

# iOS 模拟器构建（Debug，示例设备名可替换）
xcodebuild -project app/TidyFlow.xcodeproj \
  -scheme TidyFlow \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -derivedDataPath build-ios-sim \
  SKIP_CORE_BUILD=1 \
  build
```
