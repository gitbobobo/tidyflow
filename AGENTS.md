# AGENTS.md

## 交流与产出约束

- 请使用中文与用户交流。
- 请使用中文编写文档和代码注释。
- 这是一个非常早期的项目，没有真实用户，也没有稳定数据负担。为了长期可维护性，可以大胆重构，不必为了兼容临时方案而保守。
- TidyFlow 是多项目并行开发工具。任何功能设计都必须默认兼容多个项目、多个工作区，而不是只对单项目场景成立。
- 保持 macOS 和 iOS 功能语义一致。允许平台 UI 呈现不同，但核心能力、状态模型、协议含义、用户可理解的行为不能漂移。
- 不要并行执行多个 `xcodebuild`。如果需要多个 Apple 平台构建，串行执行。

## 任务完成要求

- 完成任务前，至少执行与改动范围匹配的最小验证，并在回复里明确说明验证结果。
- 涉及协议、schema、代码生成、版本号同步的改动，完成前必须运行 `./scripts/tidyflow check`。
- 涉及 Rust Core 行为、服务端接口、协议处理、状态持久化的改动，优先运行 `./scripts/tidyflow test`。
- 涉及 macOS App 编译或界面集成的改动，至少执行一次 macOS build 验证。
- 涉及 iOS App 编译或界面集成的改动，至少执行一次 iOS Simulator build 验证。
- 如果因为环境、耗时或外部依赖未完成验证，必须明确说明未验证项、原因和风险，不能假装已完成。

## 项目快照

TidyFlow 是一个面向 AI 时代的原生多项目并行开发工具，核心目标是把多个项目、多个分支、多个 AI 会话、终端和文件操作统一到同一个工作空间里，减少上下文切换成本。

这个仓库当前处于快速塑形阶段。只要能显著提升一致性、可维护性、长期架构质量，就可以提出并实施较大的结构调整。

## 当前工作重点

1. 优化对 AI 工具的包装，尤其是 codex，可参考 t3code。
2. 优化聊天界面的性能与稳定性。

## 核心优先级

1. 正确性优先。
2. 稳定性优先。
3. 多项目与多工作区场景优先。
4. 跨端一致性优先。
5. 性能优化建立在可预测行为之上。

如果必须权衡，优先选择长期可维护、行为可预测、故障后容易恢复的方案，而不是局部快速修补。

## 可维护性要求

- 新功能先考虑抽象能否落到共享模型、共享协议、共享状态机，而不是分别在多个视图或多个平台各写一套逻辑。
- 重复逻辑是异味，尤其是 macOS/iOS 两端重复复制同一业务规则时，应优先抽取共享层或统一协议映射。
- 不要通过堆叠局部 if/else 修补架构问题。发现状态边界混乱、模型职责不清、协议定义分散时，应顺手整理。
- 改动应尽量沿着现有分层落位：UI 展示、客户端状态、网络协议、Core 领域逻辑、持久化，各自边界清晰。
- 当现有实现明显阻碍后续演进时，可以直接重构，不必为了“保持旧样子”保留低质量结构。

## 目录与职责

- `core/`：Rust Core，负责 PTY、项目/工作区、文件系统、Git、AI 适配、服务端接口、状态持久化与协议实现。
- `app/TidyFlow/`：macOS 原生客户端，使用 SwiftUI/AppKit，负责桌面工作区体验、终端容器、AI 交互和系统集成。
- `app/TidyFlow-iOS/`：iOS 客户端，负责移动端对应能力与状态呈现，行为语义应与 macOS 对齐。
- `app/TidyFlowTests/`：Swift 单元测试。
- `app/TidyFlowE2ETests/`：Apple 端到端测试与证据采集。
- `schema/protocol/`：协议 schema 与版本化定义。协议相关改动应先检查这里，而不是只改某一端的解析代码。
- `docs/PROTOCOL.md`：当前协议说明文档。用于理解传输层、鉴权、读取 API、WS action 和兼容策略。
- `scripts/`：统一开发、检查、测试、E2E、打包、发布脚本入口。优先使用脚本，不要发明零散手工命令。

## 协议与架构约束

- 当前前后端通信核心是 `WebSocket + MessagePack`，协议版本为 v7；涉及消息结构的修改时，必须同步检查 `core`、Apple 客户端和 `schema/protocol/v7/`。
- `schema/protocol/v7/` 是协议 schema 权威源，`docs/PROTOCOL.md` 是人类可读说明，两者都要保持一致。
- 读取与订阅、一次性结果与流式事件、客户端本地状态与 Core 持久化状态，要明确区分，不要混在一个字段或一个 action 里。

## Apple 客户端约束

- 优先保证 macOS 与 iOS 的数据模型、协议模型、状态迁移逻辑一致，再分别处理平台视图差异。
- 不要把业务规则硬编码在某个 SwiftUI 视图里；可以下沉到 ViewModel、Store、模型转换层或协议层的，不要留在 View 内。
- 涉及终端、文件树、AI 会话、工作区切换的交互修改时，要检查是否同时影响 macOS 和 iOS。
- 本地偏好、平台特有交互、窗口管理可以因平台不同而实现不同，但用户可见能力边界应一致。

## Rust Core 约束

- Core 是系统行为权威源。涉及工作区生命周期、AI 会话状态、文件/Git 操作、远程配对、鉴权、协议兼容时，应优先在 Core 保证一致性。
- 若某个行为已经在 Core 有领域抽象，不要在客户端重复推导一遍。
- 新增服务端能力时，优先保持 domain/action、HTTP 读取接口、WS 流式事件之间的职责清晰。
- 持久化、缓存、恢复逻辑要考虑异常中断、重连、重复请求、部分流式消息丢失后的表现。

## 常用命令

```bash
# 统一入口（推荐）
./scripts/tidyflow dev

# 架构与协议护栏检查
./scripts/tidyflow check

# Core 测试
./scripts/tidyflow test

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

## 推荐工作方式

- 优先使用 `./scripts/tidyflow` 作为统一入口。
- 先读受影响模块，再动手修改；不要在不了解协议链路或状态来源时盲改。
- 先找共享抽象，再写新增逻辑；尤其要避免在 macOS、iOS、Rust Core 三处各自复制规则。
- 若改动跨越协议层，优先先想清楚完整链路：schema、Core、客户端模型、UI 消费方式、验证路径。
- 提交结果时，简要说明做了什么、为什么这样做、运行了哪些验证、还有哪些风险。

## 日志与调试

- Rust Core 会把结构化日志写到 `~/.tidyflow/logs/`。
- 生产环境日志文件名规则：`YYYY-MM-DD.log`。
- 开发环境日志文件名规则：`YYYY-MM-DD-dev.log`。
- 遇到启动、连接、配对、流式事件或状态恢复问题时，优先查看这里，而不是只看客户端表象。

## 参考项目

- [opencode](https://github.com/anomalyco/opencode)：AI 工具参考。
- [codex](https://github.com/openai/codex)：AI 工具参考。
- [t3code](https://github.com/pingdotgg/t3code)： GUI 工具参考（与本项目功能类似）。
