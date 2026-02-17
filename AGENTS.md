# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> CLAUDE.md 是 AGENTS.md 的符号链接，始终保持同步。

1. 使用中文交流、编写代码注释、文档
2. 经验总结：获取到经验教训后，如果它属于可复用的项目开发流程，就用简洁的语言记录到 AGENTS.md 中

## Project Overview

TidyFlow is a macOS-native multi-project development tool with VS Code-level terminal experience and Git worktree-based workspace isolation.

**Architecture**: Hybrid native + web
- **Frontend**: SwiftUI + AppKit (macOS app in `/app/`)
- **Backend**: Rust core engine (in `/core/`)
- **Terminal**: xterm.js in WKWebView
- **Communication**: WebSocket(MessagePack) + HTTP(JSON, pairing endpoints) (protocol v2, default port 47999)

## 经验总结
- 用户要发布新版本时，严格按 `docs/RELEASE_CHECKLIST.md` 执行；版本号递增（如 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`core/Cargo.toml`）由代理自动处理并同步。
- 同一业务状态若在多个入口写入（如终端创建时间），应抽取统一路径或至少补齐兜底写入，避免分支遗漏导致 UI 状态不一致。
- 对外返回列表数据时，不要依赖 `HashMap` 迭代顺序；应在服务端显式排序，确保启动与刷新顺序稳定可预期。
- 在 git worktree 场景调用 Codex CLI 执行提交时，若需要写 `.git/worktrees/*` 元数据（如 `index.lock`），应使用 `--dangerously-bypass-approvals-and-sandbox`，避免 `workspace-write` 沙箱拦截。
- 同一 AI 代理在不同业务入口（如 AI 提交/AI 合并）应复用完全一致的 CLI 参数模板；业务差异仅通过 prompt 表达，避免入口分叉导致行为不一致。
- 使用 Cursor Agent 执行自动提交时，建议固定携带 `--sandbox disabled -f`（配合 `-p`），避免沙箱/审批导致 git 命令被拒绝。
- 解析 AI CLI 的结构化 JSON 输出时，应兼容 `stdout` 与 `stderr` 混合场景：优先抽取外层 JSON 包络字段（如 `response`/`result`），再解析业务 JSON，避免日志噪音导致解析失败。
- 拆分 Swift 大文件时，除移动源码外还必须同步更新 `app/TidyFlow.xcodeproj/project.pbxproj` 的 `PBXFileReference`、`PBXBuildFile`、`PBXGroup` 和 `PBXSourcesBuildPhase`，否则新文件不会参与编译。
- 拆分 Rust 超长 handler 时，优先保持对外入口函数签名不变，在目录模块内按能力域拆 `try_handle` 子模块并由 `mod.rs` 串行分发，先做“零行为变化”重构再谈逻辑优化。
- OpenCode 的 `--format json` 输出是事件流，最终结果应从最后一个 `type=text` 事件的 `part.text` 提取，而不是取最后一条事件（通常是 `step_finish`）。
- 流式聊天若过程中插入“工具调用/思考过程”消息，`done` 事件必须定位并收敛到正在流式的那条回复气泡；不要简单更新“最后一条 assistant 消息”，否则会覆盖工具消息并导致加载状态不收敛。
- 同一轮用户消息若触发多条 assistant 回复，流式 loading 必须与“当前增量对应的 message_id”一一绑定并保持互斥；收到新 message/part 增量时要及时清理旧消息的 `isStreaming`。
- 对接 OpenCode SSE 时，`message.part.updated` 只有 `messageID` 不含 role，必须结合 `message.updated` 的 `role` 做过滤；否则会把 user 消息的 part 当成 assistant 文本转发，造成“用户消息在回复中重复显示”。
- OpenCode 新版流式增量可能通过 `message.part.delta` 下发，而非在 `message.part.updated.properties.delta` 里；需要先从 `message.part.updated.part.type` 建立 `partID -> type(text/reasoning/...)` 映射，再把 `message.part.delta` 路由为增量输出。
- OpenCode Desktop 的多路径会话通常通过请求头 `x-opencode-directory` 路由（而不是多开 `opencode serve`）；事件流使用 `/global/event` 单连接按 `directory` 分流；释放目录实例资源优先调用 `POST /instance/dispose`（同样依赖 `x-opencode-directory`）。
- AI 聊天斜杠命令列表应优先通过 OpenCode `GET /command` 动态获取，并保留最小本地兜底（仅 `/new`），避免写死命令与 CLI 实际可用命令不一致。
- 对接 OpenCode 的 `GET /session` 时不要假设服务端会按 `x-opencode-directory` 过滤会话列表；实际返回往往是“全局会话数组”，需要客户端/中间层基于 session 的 `directory` 字段自行过滤，才能做到按工作空间隔离。
- Git 面板展示分支领先/落后时，应复用 `git_status` 返回并基于项目 `default_branch` 做本地分支比较，避免硬编码 `main` 或依赖远端 `fetch` 导致慢/不稳定。
- 多项目共存时，工作空间名（如 `"default"`）不具备全局唯一性；需要关联项目的场景必须显式传递 `projectName`，禁止通过遍历 `projects` 按工作空间名反查项目（会命中第一个匹配项而非实际所属项目）。
- 跨分支入口触发但实际写入默认分支的操作（如 AI 合并到默认分支），其后台阻塞任务归属应绑定默认工作空间，避免错误地落在来源分支队列。
- 引入移动端远程访问时，Core 应默认仅监听 loopback，并通过显式开关切换到 `0.0.0.0`；远程连接统一走“本机生成配对码 -> 移动端换取短期 token”链路，且 `pair/start`/`pair/revoke` 保持仅本机可调用。
- 编辑 `app/TidyFlow.xcodeproj/project.pbxproj` 时，带条件的 build setting 键（如 `[sdk=iphone*]`）必须写成带引号的完整键名（如 `"INFOPLIST_FILE[sdk=iphone*]"`），否则工程会因 plist 解析失败而无法打开。
- 移动端连接入口展示的地址/端口必须来自运行时状态（局域网 IP + Core 当前监听端口），不要假设固定端口（如 47999），避免重启后动态端口变化导致连接失败。
- 移动端展示/配对使用的端口必须取 Core `running` 态端口；不要使用 `starting` 态端口（尚未监听），并确保 `AppState` 转发 `CoreProcessManager` 变更以避免 UI 端口文案滞后。
- 涉及 Core 重启（如切换远程访问开关）时，不要用固定延时后直接 `start()`；应等待 `stop` 确认完成后再启动，否则会被运行态守卫拦截并出现“端口不可用”卡死。
- `CoreProcessManager` 的异步回调（`stop` 完成、`terminationHandler`、延迟置 `running`）必须校验“是否仍是当前 process 实例”；否则旧进程回调会覆盖新状态，导致 UI 误判为“端口不可用”。
- 对“监听地址/网络暴露”这类 socket 绑定配置，若产品要求不中断进行中任务，应采用“仅落盘配置、下次启动生效”策略，不在设置页切换时重启 Core。
- 使用 MessagePack + AnyCodable 解析协议时，动态值模型必须显式支持 `Data`（bin）；否则终端输出/scrollback 等二进制字段会解码失败并表现为黑屏或无输出。
- 使用 AnyCodable 编码请求体时，`[UInt8]` 必须优先转为 `Data`（MessagePack bin）或显式映射为整数；否则会被默认分支转成字符串数组，导致 `input`/`file_write` 等二进制字段在 Core 端解析失败。
- 排查启动卡顿/卡死时先确认日志归属：Debug 构建主要看 `~/.tidyflow/logs/*-dev.log` / `*.dev.log`，应用包运行主要看 `~/.tidyflow/logs/YYYY-MM-DD.log`，避免错看时间段。
- 应用启动链路（首屏前）禁止在主线程同步执行外部命令并 `waitUntilExit`；此类探测应放后台并加超时兜底，否则会出现 Dock 图标持续跳动但窗口不出现。
- 排查开发环境问题时应优先查看 `~/.tidyflow/logs/*-dev.log`（或 `*.dev.log`）；仅排查打包产物/生产行为时再看纯日期日志。
- 启动期若要延迟展示主窗口，隐藏动作应放在 `AppDelegate.applicationDidFinishLaunching`（窗口首帧前）而非 `ContentView.onAppear`，否则会出现窗口闪一下。
- iOS 侧若在 `List` 等容器内使用 SwiftUI `Menu` 触发 UIKit “`_UIReparentingView` 加到 `UIHostingController.view`”告警/层级异常，可优先尝试给 `Menu`（或其 label）加 `.compositingGroup()`；若仍存在再考虑将入口移到 `toolbar` 的 `Menu`（避免在 `List` cell 内弹出）。
- iOS 终端若改为原生输入代理，不能同时关闭 xterm stdin 作为唯一输入路径；至少保留 xterm `onData` 兜底，并确保触摸手势可触发 `term.focus()`，否则会出现“无法输入/键盘不弹出”。
- 远程终端订阅归属必须使用稳定设备标识（如配对 `token_id`），不要绑定瞬时 `conn_id`；移动端进程被系统回收后重连应可继续看到并附着原会话。
- 移动端终端页面切换/返回时，优先做“仅取消当前 WS 输出订阅、不关闭 PTY”的 detach（例如 `term_detach`）；避免后台持续转发输出导致滚动抖动、卡顿与不必要的内存/带宽占用。真正终止会话必须显式走 `term_close`/kill。
- iOS 虚拟键盘输入链路应采用 `onData` 主路径 + `textarea input/composition` 兜底；仅依赖 `onData` 会在部分键盘布局下丢失空格或特殊符号。
- iOS 终端工具栏提供 `Ctrl` 时，不能只在工具栏按键内做组合映射；必须把 `Ctrl` 锁定态接入 `onData` 主输入链路，并在消费后同步回写工具栏状态，确保 `Ctrl+C` 等“Ctrl + 虚拟键盘字符”可用。
- iOS 终端从 `WKWebView + xterm.js` 迁移到 `SwiftTerm` 时，应以 `TerminalViewDelegate.send` 作为统一输入路径，并通过 `TerminalView.inputAccessoryView` 挂接原生工具栏，避免继续依赖 `WKContentView` 的 runtime 替换。
- iOS 多终端切换时，客户端必须按 `term_id` 隔离本地渲染状态；切换前先重置/清空 `TerminalView`（含 scrollback），避免 SwiftUI 复用视图导致不同终端输出“串台”。
- iOS SwiftTerm 的 scrollback 滚动本质是 `UIScrollView.contentOffset`；若 TUI 持续刷新导致用户滚动被“抢回底部”/抖动，可采用“离开底部即暂停输出（必要时 `term_detach`），回到底部且手势结束后再 `term_attach` 回放 scrollback”的策略，并配合禁用 `bounces` 降低回弹抖动。
- iOS 需要“默认避开顶部安全区但仍允许内容滚进安全区”时，可让容器 `ignoresSafeArea(.top)`，同时对内部滚动视图设置 `contentInset.top = safeAreaTop`；`GeometryProxy.safeAreaInsets` 在部分布局下可能为 0，建议用 `UIView.safeAreaInsets.top` 兜底取较大值。
- SwiftTerm(iOS) 的 `TerminalView` 会在内部 `updateScroller()` 中强制重置 `contentOffset`，并直接用 `contentOffset` 做可见行映射；仅设置 `contentInset.top` 往往不会得到“首屏下移”的效果。要实现顶部安全区留白且可滚入，建议对子类在 `scrolled/sizeChanged/safeAreaInsetsDidChange` 后把 `contentOffset.y` 平移为 `logicalOffset - topPadding`（配合 `contentInset.top = topPadding`）。
- iOS SwiftTerm 远程终端场景下，zle 出现 `3R` 乱码的根因是 SwiftTerm 使用 8-bit C1 引导符（`0x9b`）而 shell 不识别，并非网络延迟；正确做法是在 `TerminalViewDelegate.send` 中做 C1→7-bit 规范化（`0x9b`→`ESC[`），而非丢弃 CPR 应答——丢弃会导致依赖 DSR/CPR 的 TUI 应用（helix、lazygit 等）无法获取光标位置而报错。
- 终端 PTY 的 `cols/rows` 来自客户端上报，服务端必须做范围 clamp 并记录告警日志；异常尺寸（过大/为 0）可能触发远端 TUI/CLI 进程按屏幕大小分配缓存，从而 OOM 被系统 kill。
- AI 聊天的 `pendingSendMessage`（等待会话创建后发送）等跨异步边界的临时状态，必须在工作空间切换时清除，并携带发起时的 `projectName/workspaceName` 做一致性校验；否则快照恢复触发 `aiCurrentSessionId` 变更时会把旧消息误发到新工作空间。切换回旧工作空间时应重新拉取当前会话消息，弥补切走期间被 guard 丢弃的流式增量。
- AI 聊天支持多代理工具（如 OpenCode/Codex）时，协议请求与事件必须强制携带 `ai_tool`，并在客户端按 `project/workspace/ai_tool` 维度做事件过滤与快照分桶；否则切换工具后会话、流式增量和模型/Agent 列表会串台。
- 多 AI 工具“后台保活”场景下，WebSocket 事件不能只按当前选中工具过滤；应按 `ai_tool` 路由到对应状态桶，当前工具仅负责前台渲染，并额外维护未读/进行中徽标以支持无损切换查看。
- 会话侧栏若需融合多 AI 工具历史，状态层应继续按 `ai_tool` 分桶存储，展示层再做全局聚合并按 `updatedAt` 降序排序；每条会话必须携带 `ai_tool`，且非当前工具分桶更新也要触发列表刷新。
- 会话列表跨 `ai_tool` 点击会话时，应先把目标 `session_id` 写入目标工具的状态桶，再切换 `ai_tool`，并由切换后的统一重载流程拉取详情；避免先切工具再写状态导致首击空白，以及重复拉取触发 Copilot `Session ... is already loaded`。
- Copilot ACP 适配层不要在“仅为获取模型/模式元数据”的路径里调用 `session/load` 历史会话；这会把会话提前置为 loaded，随后拉历史详情易报 `Session ... is already loaded`。元数据优先走缓存，缺失时用最小兜底。
- 对接 Codex app-server 时，不要在首条消息前对新建线程强制调用 `thread/resume`：新线程 rollout 文件会延迟到首条用户消息后才落盘；发送链路应优先 `turn/start`，仅在 `thread not found` 时再 `thread/resume` 后重试。
- 对接 GitHub Copilot ACP 时，不能复用 Codex 的 `thread/*`/`turn/*` 协议；需按 ACP 使用 `initialize(protocolVersion)` + `session/new|load|list|prompt`，并将 `session/update` 事件映射到统一聊天增量模型。
- 各 AI 适配器返回 `AiAgentInfo.mode` 时必须遵守统一语义（`primary`/`subagent`/`all`），不要复用后端原始 mode id（如 URI）；否则会被 `ai_agent_list` 的通用过滤逻辑误过滤，前端出现“模型有、代理空”。
- 对接 Codex app-server 的“Agent”选择应按会话 `mode` 语义处理：优先走远端动态获取，展示值与发送值保持一致（如远端返回 `default` 就展示/发送 `default`）。
- Codex `getUserAgent` 返回的是客户端 UA 字符串而非会话 mode；mode 列表应使用 `mode/list`（失败时再做最小本地兜底）。
- AI 聊天消息需要支持 Markdown 时，assistant 内容应采用“流式阶段纯文本增量渲染、`done` 后一次性转 Markdown”策略，避免代码块/列表在增量过程中频繁重排造成抖动。
- SwiftUI 聊天 Markdown 若直接用 `AttributedString(markdown: .full)`，可能把列表/段落结构扁平化；应改用 `inlineOnlyPreservingWhitespace` 并按 `inlinePresentationIntent` 显式映射粗体/斜体/代码字体。
- 若聊天 Markdown 需要同时支持块级语法（如 `##`/列表）与行内样式，建议采用“行级解析块结构 + 行内 Markdown 二次渲染”而非单次 `AttributedString(markdown:)`，避免标题符号原样显示或段落被压扁。
- 聊天 Markdown 做视觉微调时，优先在 `AttributedString` 层控制 `lineSpacing`、标题字号梯度和 `backgroundColor`（行内代码/代码块），能在不改消息模型的前提下快速提升层次感与可读性。
- `AITabView` 等在 `switch` 分支中创建的子视图，切换工作空间时可能在同一 SwiftUI 更新周期被移除，导致 `onChange` 不触发而 `appState` 上的全局状态残留。必须在 `onDisappear` 保存快照（用 `previousSnapshotKey` 而非 `currentSnapshotKey`，因为后者已指向新空间），并在 `onAppear` 恢复当前工作空间的快照或清空，不能仅依赖 `onChange`。
- 聊天输入框实现 `@` 文件引用和 `/` 斜杠命令自动补全时，应以“光标所在 token”做触发与替换范围，且在 `hasMarkedText` 组合态暂停补全并兼容全角 `＠`/`／`，避免中文输入法候选期误触发与整段文本被覆盖。
- iOS 聊天自动补全弹层定位不要写死偏移；应由 `UITextView.caretRect` 上报光标位置，并结合容器宽度做左右 clamp，避免弹层漂移到中间或超出屏幕。
- iOS 聊天输入区采用底部吸附布局时，键盘顶部需保留小间距（如 `padding(.bottom, 8)`），并让左右按钮使用统一尺寸与 `HStack(.center)` 对齐，避免视觉偏小和垂直不齐。
- 若产品定义 iOS 聊天“仅按钮发送”，应将 `UITextView.returnKeyType` 设为默认回车并在 `shouldChangeTextIn` 放行 `"\n"`，避免回车触发发送导致换行能力丢失。
- iOS 圆形操作按钮若已有自定义 `Circle` 背景，图标应避免使用 `*.circle.fill` 这类自带圆底的 SF Symbol（如改用 `arrow.up`/`stop.fill`），否则会出现双层背景与内间距观感。
- iOS 聊天输入框若默认态视觉偏高，可同时下调 `UITextView` 的最小高度 clamp（如 `36 -> 32`）与容器内边距（如 `vertical 4 -> 2`、`textContainerInset 6 -> 5`），比只改单一参数更容易保持垂直居中观感。
- iOS 聊天“命令/引用”sheet 的搜索框聚焦建议统一为“单一 `@FocusState` 枚举 + 统一打开入口 + 延迟重试”；弹窗前先让主输入框失焦并收起底部面板，避免多焦点状态竞争。
- WebSocket `handle_client_message` 内不要同步阻塞长生命周期流（如 AI 流式回复）；应改为后台 task 并通过 `cmd_output_tx` 回传事件，否则同连接的 `ai_chat_abort` 等控制消息无法及时处理，会出现“前端已停止但代理仍在执行”。
- 单 Target 多平台工程若通过 `EXCLUDED_SOURCE_FILE_NAMES` 做按 SDK 排除，macOS 专用视图仍建议做文件级 `#if os(macOS)` 包裹，并在改动后执行一次 `xcodebuild -sdk iphonesimulator` 校验，避免排除名单漂移导致 iOS 编译回归。
- 需求包含“远端实时搜索”时，先核对现有协议是否支持 `query`；若仅有全量接口（如 `file_index`），应先做可选 `query` 的向后兼容扩展，再接入 UI 搜索，避免前端看似实时但实际只在本地过滤。
- 对接 OpenCode 工具调用展示时，必须以 `tool state.status`（`pending/running/completed/error`）作为主判别并结构化解析 `input/output/metadata`；不要仅按是否存在 `input/output` 做弱判断，避免状态与展示错位。
- 工具卡片若已有稳定结构化语义（如 todo 列表），应优先渲染“语义化视图（任务+状态）”而非直接展示 `input/output/metadata` 原始 JSON，避免信息噪音淹没关键信息。
- SwiftUI 渲染统一 diff 时，若需要“行级背景准确对齐 + 文本可跨行选择且不选中行号”，应将行号列与内容列拆分，并让内容列禁换行（`fixedSize(horizontal: true, vertical: true)` + 横向滚动）；否则长行软换行会导致背景与行号错位。
- 聊天页含可折叠侧栏时，应由外层容器先定义总宽度约束（主区可压缩、侧栏宽度按可用空间夹取）；内部控件避免滥用 `fixedSize`，防止长文案反向撑宽窗口。
- macOS 侧边栏可折叠页面若使用 `HSplitView`，在“侧栏隐藏”场景应切换为非 split 的单列布局，并给顶部工具栏显式固定高度，避免出现异常留白/工具栏高度被拉伸。
- 聊天长列表优化时，避免在 `onPreferenceChange` 中按滚动帧持续写入 `@State`（如锚点坐标）；应只在“是否接近底部”等阈值变化时更新，并为 Markdown 解析结果加缓存，以降低历史消息首轮滑动卡顿。
- AI 聊天的高频流式状态应下沉到独立状态域（如 `AIChatStore`），并在 WS 增量到 UI 的链路做约 30fps 批量提交；避免把 token 级更新直接写入全局 `AppState` 导致整页重绘。
- AI 图片附件链路应采用“客户端传二进制原图（MessagePack bin）+ 服务端统一探测格式并按需转码（如 HEIC→JPEG）”；不要在客户端先转 base64 或各端各自转码，避免格式误判与行为不一致。
- AI 图片“可上传但不可读”排障时，应同时做两件事：前端基于模型能力（如 `capabilities.input.image`）发送前拦截并提示，后端记录 `image_parts` 的数量/mime/字节数日志，用于快速区分“上传链路正常但模型/代理不支持”与“附件传输失败”。
- 对接 OpenCode 的图片工具链（如 `look_at`）时，优先把图片落临时文件并传 `file://`；`data:` URL 在部分链路会出现 `failed to fetch the data URL` 并导致工具长期停留 `pending`。
- SwiftUI 组件新增可选交互参数时，避免使用 `let + 默认值` 期待自动成员初始化器透传；该模式不会生成对应入参。需要跨调用点可配置时应显式编写带默认值的 `init`，避免 “extra arguments in call” 编译错误。
- SwiftUI 视图计算属性若参与渲染构建（如 `presentation`/`sections`）时，禁止在构建链路中反向读取依赖该构建结果的布尔 getter（如 `shouldShow...`）；否则会形成 getter 环并触发主线程递归栈溢出闪退。
- AI 聊天若要求“以代理回传为准”，发送后不要本地插入 user 气泡；输入框清空应与消息渲染解耦（可在请求入队后立即清空），避免依赖 user echo 事件导致残留输入。
- AI 聊天严格模式下，若 assistant 首包先于 user echo 到达，`ensureMessage` 需将 user 消息前插到当前流式 assistant 之前并重建索引，避免时间线出现“assistant 在前、user 在后”倒序。
- OpenCode 流式里 `part.updated/part.delta` 可能早于或缺失 `message.updated(role)`；role 未知时不能默认 assistant，需结合“awaiting 状态 + assistant 锚点 + part 类型(file)”推断 user，避免实时顺序错乱与清空信号丢失。
- AI 聊天流式批处理若同时收到 `message.updated` 与 `part.*`，应先处理 `message.updated` 建立 `message_id -> role` 映射，再消费 `part`，避免同批次内因处理顺序导致角色误判与消息倒序。
- AI 聊天等待 user echo 时，收敛条件应绑定“本轮新消息范围”（如进入 awaiting 时的消息基线索引）；不要让旧 user 消息的增量更新提前结束 awaiting，否则会清空本轮 assistant 锚点并导致实时顺序错乱。
- AI 聊天若要求“用户消息以代理回传为准”，不要在发送时预插 assistant 占位气泡；否则会在 user echo 尚未回传时形成“assistant 先出现”的实时错觉，导致顺序体验不稳定。

## Build Commands

### Quick Start (Recommended)
```bash
./scripts/run-app.sh  # Builds core + app, launches TidyFlow
```

### Rust Core
```bash
cd core
cargo build --release
cargo run                          # Start WebSocket server
TIDYFLOW_PORT=8080 cargo run       # Custom port
TIDYFLOW_BIND_ADDR=0.0.0.0 cargo run # Expose WS/Pairing service to LAN
cargo test                         # Run all tests
cargo test test_name               # Run specific test by name
cargo test git::status::           # Run tests in a module
RUST_LOG=debug cargo test          # Run with debug logging
```

### macOS App
```bash
# Via Xcode (recommended for development)
open app/TidyFlow.xcodeproj        # Then Cmd+R to run

# Via command line
xcodebuild -project app/TidyFlow.xcodeproj -scheme TidyFlow -configuration Debug build
```

### Release Build
```bash
./scripts/build_dmg.sh                    # Unsigned DMG
SIGN_IDENTITY="Developer ID..." ./scripts/build_dmg.sh --sign  # Signed
./scripts/notarize.sh --profile tidyflow-notary  # Notarize
./scripts/tools/gen_sha256.sh dist/<dmg-name>.dmg # Generate SHA256 (optional if using build_dmg.sh)
./scripts/release_local.sh --upload-release # Local one-click release and upload assets to GitHub Release
./scripts/release_local.sh --dry-run # Preview all release actions without side effects
```

## Testing

```bash
cargo test --manifest-path core/Cargo.toml    # Core 自动化测试
./scripts/run-app.sh                            # 本地启动 App 做手工验证
./scripts/build_dmg.sh --sign                   # 发布构建（需签名证书）
./scripts/notarize.sh --profile tidyflow-notary # 发布公证
```

发布手工检查清单见 `docs/RELEASE_CHECKLIST.md`。

## Architecture

```
┌─────────────────────────────────────┐
│   macOS App (SwiftUI + AppKit)     │
│   ┌─────────────────────────────┐   │
│   │  WKWebView (xterm.js)       │   │
│   └──────────┬──────────────────┘   │
└──────────────┼──────────────────────┘
               │ WebSocket (MessagePack)
               ▼
┌─────────────────────────────────────┐
│   Rust Core Engine                  │
│   ├─ PTY Manager (portable-pty)    │
│   ├─ Workspace Engine (git worktree)│
│   ├─ WebSocket Server (axum)       │
│   └─ State Persistence (JSON)      │
└─────────────────────────────────────┘
```

### Rust Core (`/core/src/`)
- `main.rs` - CLI entry point (clap)
- `pty/` - PTY session management
- `server/` - WebSocket server and协议处理
  - `ws.rs` - WebSocket handler，tokio select! 循环处理消息/PTY输出/文件监控事件
  - `protocol/mod.rs` - Protocol v2 (MessagePack) 消息定义
  - `handlers/` - 模块化消息处理器（terminal, file, git, project, settings），每个返回 `Result<bool, String>`
  - `git/` - Git 操作模块（status, operations, branches, commit, integration, utils）
  - `file_api.rs` - 文件操作，`file_index.rs` - Quick Open 索引，`watcher.rs` - 文件监控
- `workspace/` - Project/workspace management, config, state persistence
- `util/` - 日志等通用工具

### macOS App (`/app/TidyFlow/`)
- `TidyFlowApp.swift` - App entry point
- `ContentView.swift` - Main view composition
- `LocalizationManager.swift` - 运行时语言切换（system/en/zh-Hans），使用 `"key".localized` 模式
- `Views/` - SwiftUI views (sidebar, toolbar, tabs, git panel, command palette, settings)
  - `Models/` - 核心模型与 `AppState` 拆分目录（按领域与扩展分文件维护）
  - `Models.swift` - 兼容占位文件（避免一次性迁移冲击）
  - `KeybindingHandler.swift` - 键盘快捷键处理
- `WebView/` - WKWebView container and Swift-JS bridge
- `Networking/` - WebSocket client (MessagePacker 库), protocol models, AnyCodable
- `Web/` - HTML/JS for xterm.js terminal, CodeMirror diff view
- `Process/` - 进程管理
- `en.lproj/`, `zh-Hans.lproj/` - 本地化字符串文件

## Key Patterns

- **Workspace isolation**: Each workspace is a separate git worktree
- **Protocol versioning**: v2 (MessagePack binary, `rmp-serde`) with feature versions v1.0-v1.25
- **State persistence**: `~/.tidyflow/state.json`（JSON 格式，非 SQLite）
- **Per-project config**: `.tidyflow.toml` for setup scripts
- **WebSocket 消息流**: Client 发送 MessagePack 编码的 `ClientMessage` → Server 通过 `handlers/` 模块化处理 → 返回 `ServerMessage`
- **父进程监控**: Core 监控 Swift app 进程，父进程退出时自动终止
- **本地化**: 运行时语言切换，使用 `"key".localized` 扩展，字符串文件在 `en.lproj/` 和 `zh-Hans.lproj/`

## CLI Commands

```bash
cargo run -- import --name my-project --path /path/to/repo
cargo run -- ws create --project my-project --workspace feature-1
cargo run -- list projects
cargo run -- list workspaces --project my-project
```
