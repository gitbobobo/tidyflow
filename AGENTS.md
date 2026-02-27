# AGENTS.md

TidyFlow 是一款多项目并行开发工具，软件中所有功能都兼容不同项目。

## 基本约束

- 请使用中文与用户交流
- 请使用中文编写文档和代码注释
- 这个项目没有用户，目前还没有真正的数据，想做什么改动就做什么，不用担心。我们发布时再想办法
- 这个项目非常新颖，完全改变模式也没关系，我们正努力把它弄成合适的形状
- 保持 macOS 和iOS 版本功能一致
- 不要并行执行多个 `xcodebuild`

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

# iOS 模拟器构建（Debug）
xcodebuild -project app/TidyFlow.xcodeproj \
  -scheme TidyFlow \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -derivedDataPath build \
  SKIP_CORE_BUILD=1 \
  build
```

## 日志位置（Rust Core）

- Rust Core 会把结构化日志写到：`~/.tidyflow/logs/`
- 生产环境文件名规则：`YYYY-MM-DD.log`
- 开发环境文件名规则：`YYYY-MM-DD-dev.log`

## 参考项目

- [opencode](https://github.com/anomalyco/opencode): AI 工具
- [oh-my-opencode](https://github.com/code-yeongyu/oh-my-opencode): OpenCode 的插件
- [codex](https://github.com/openai/codex): AI 工具
