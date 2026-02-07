# 变更日志

本项目变更记录遵循「可读、可追溯」原则。

## [Unreleased]

- 待补充

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
