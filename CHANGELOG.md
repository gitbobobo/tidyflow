# 变更日志

本项目变更记录遵循「可读、可追溯」原则。

## [Unreleased]

- 待补充

## [1.2.0] - 2026-02-09

### Added

- 后台任务完成通知：Toast 右下角展示结果，支持任务完成后系统横幅通知（应用在后台时提醒）
- 项目命令配置与执行：在工作空间中作为后台任务运行自定义命令，支持取消与实时输出流式推送
- 后台任务列表支持显示项目命令定义的自定义图标
- 终端快捷命令 Tab 支持在 Tab 栏显示命令配置的图标
- 工具栏外部编辑器按钮、项目命令执行按钮添加文本标签
- 后台任务支持停止与移除，适用于 AI 任务与项目命令
- Copilot CLI 作为 AI 代理选项
- 发布流程支持 git tag 自动创建与推送

### Changed

- 重构 Git 面板布局，均分区域与展开状态外部化控制
- 统一 AI 相关术语为一键提交、智能合并
- 图标选择器简化为仅支持系统图标和品牌图标
- 日志系统统一由 Rust Core 集中写入文件
- 协议定义与 App/核心状态拆分为模块化目录结构（CommandPaletteState、FileCacheState、Store 等）
- Handler 工作空间解析逻辑统一

### Fixed

- 保持 WebView 始终在视图树中，避免切换至项目配置页时终端全部断开
- 后台任务运行时显示与任务 ID 设置同步

### 文档与构建

- 补充发布检查清单，新增根据提交历史补充 CHANGELOG 的操作指南
- 移除已废弃 menu.sh 脚本的语法检查

## [1.1.0] - 2026-02-08

### Added

- WebSocket 自动重连与终端持久化：系统唤醒探活 + 重连附着 scrollback 回放
- 全局终端注册表与 scrollback 缓冲，支持终端跨连接持久化
- WSClient 断连标记与 ping 探活能力
- 后台任务系统，将 AI 提交/合并改为非阻塞执行
- AI 智能提交能力（v1.26），支持多 Agent 后端（Codex / Cursor / OpenCode）
- Git 面板展示当前分支相对默认分支的领先/落后状态
- 工具栏标题旁添加应用 slogan 展示
- README 中英双语版本，提升国际化支持

### Changed

- AI Agent 配置拆分为提交代理与合并代理，支持独立设置
- WebSocket 处理重构，从 TerminalManager 迁移到全局 terminal_registry
- AI 任务结果从二态改为三态，无法解析时标记为 unknown
- 统一 AI CLI 参数模板，移除动态沙箱开关
- Git handler 拆分为按能力域组织的模块化目录结构
- Models / ProtocolModels / WSClient / GitCacheState / Views 等大文件拆分为模块化结构

### Fixed

- AI 合并任务归属绑定默认工作空间，避免错误落在来源分支队列
- 后台任务面板工作空间匹配使用统一全局 key
- 增强工作空间删除流程，添加删除中状态标记与缓存清理
- 增强 AI CLI JSON 输出解析，兼容 stdout/stderr 混合与多种事件形态
- 禁用 APP_INTENTS_METADATA_EXTRACTION 避免构建警告

## [1.0.0] - 2026-02-07

### Added

- 首个稳定版本发布基线（macOS 原生 UI + Rust Core + git worktree 工作区隔离）
- 发布清单文档：`docs/RELEASE_CHECKLIST.md`
- 协议说明文档：`docs/PROTOCOL.md`

### Changed

- 统一版本号到 `1.0.0`（`app` 与 `core` 对齐）
- 修正文档中的协议描述为 WebSocket + MessagePack（Protocol v2）
- 修正发布脚本与命令示例中的路径不一致问题

### Fixed

- 修复 `scripts/notarize.sh` 项目根目录计算错误（此前可能导致找不到 `dist` 目录）
