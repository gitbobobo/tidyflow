# TidyFlow Release Checklist v0.1.0

> Release Captain 检查清单 - 覆盖稳定性、兼容性、性能、可观测、文档与回归测试

## 优先级说明

| 级别 | 含义 | 处理方式 |
|------|------|----------|
| **P0** | 阻断发布 | 必须修复后才能发布 |
| **P1** | 建议修复 | 强烈建议修复，可酌情推迟 |
| **P2** | 可推迟 | 记录为 Known Issue，下版本修复 |

---

## A. 平台与环境 (P0)

### A1. macOS 版本要求
- **目的**: 确认最低支持版本
- **操作步骤**:
  1. 检查 `app/TidyFlow/TidyFlow.xcodeproj/project.pbxproj` 中的 `MACOSX_DEPLOYMENT_TARGET`
  2. 确认当前开发环境: `sw_vers`
- **预期结果**: macOS 14.0+ (Sonoma) 或更高
- **失败定位**: 检查 Xcode 项目设置 → Build Settings → Deployment Target
- **当前状态**: macOS 26.0 (Sequoia) 开发环境，建议最低支持 macOS 14.0

### A2. Xcode / Swift 版本
- **目的**: 确认编译工具链
- **操作步骤**:
  ```bash
  xcodebuild -version
  swift --version
  ```
- **预期结果**: Xcode 15.0+ / Swift 5.9+
- **失败定位**: 更新 Xcode 或检查 Command Line Tools
- **当前状态**: Xcode 26.1.1 / Swift 6.2.1

### A3. Rust Toolchain
- **目的**: 确认 Rust 编译环境
- **操作步骤**:
  ```bash
  rustc --version
  cargo --version
  ```
- **预期结果**: Rust 1.75.0+ (stable)
- **失败定位**: `rustup update stable`
- **当前状态**: Rust 1.92.0 (2025-12-08)

### A4. 端口配置
- **目的**: 确认默认端口可用
- **操作步骤**:
  ```bash
  lsof -i :47999
  echo $TIDYFLOW_PORT
  ```
- **预期结果**: 端口 47999 未被占用，或 TIDYFLOW_PORT 已配置
- **失败定位**: 设置 `export TIDYFLOW_PORT=<其他端口>`

---

## B. 核心功能回归 (P0)

### B1. Workspace Import/Create
- **目的**: 验证项目导入和工作区创建
- **操作步骤**:
  1. 运行 `scripts/workspace-demo.sh`
  2. 检查 workspace-demo 目录下的 worktree
- **预期结果**: 脚本成功完成，worktree 创建正确
- **失败定位**: 检查 git 版本 (`git --version >= 2.20`)，检查 .tidyflow.toml 格式

### B2. 多 Workspace 并行
- **目的**: 验证多工作区同时运行
- **操作步骤**:
  1. 运行 `scripts/multi-workspace-smoke.sh`
- **预期结果**: 多个 workspace 可同时运行，PTY cwd 隔离正确
- **失败定位**: 检查 WebSocket 连接状态，检查 term_list 返回

### B3. 统一 Tabs (Editor/Terminal/Diff)
- **目的**: 验证 Tab 系统正常工作
- **操作步骤**: 参见 `scripts/release/ui-manual-check.md` 第 3 节
- **预期结果**: Tab 切换流畅，状态保持正确
- **失败定位**: 检查 main.js 中的 tab 管理逻辑

### B4. Cmd+P 全量索引
- **目的**: 验证 Quick Open 文件索引
- **操作步骤**:
  1. 运行 `scripts/file-index-smoke.sh`
  2. 在 UI 中按 Cmd+P 测试搜索
- **预期结果**: 文件列表正确返回，搜索响应 < 200ms
- **失败定位**: 检查 FileIndex 消息处理，检查 ignore 规则

### B5. Cmd+Shift+P 命令板
- **目的**: 验证命令面板功能
- **操作步骤**: 参见 `scripts/release/ui-manual-check.md` 第 5 节
- **预期结果**: 命令列表显示，执行正确
- **失败定位**: 检查 palette.js 中的命令注册

### B6. Git Status + Diff Tab
- **目的**: 验证 Git 集成
- **操作步骤**:
  1. 运行 `scripts/git-tools-smoke.sh`
  2. 在 UI 中检查 Git 面板
- **预期结果**: 状态正确显示，diff 渲染正常
- **失败定位**: 检查 git_status/git_diff 消息处理

### B7. Unified/Split Diff 切换
- **目的**: 验证 diff 视图模式
- **操作步骤**: 参见 `scripts/release/ui-manual-check.md` 第 7 节
- **预期结果**: 两种模式切换正常，内容一致
- **失败定位**: 检查 diff 渲染逻辑

### B8. Working/Staged 切换
- **目的**: 验证 diff 模式切换
- **操作步骤**:
  1. 运行 `scripts/staged-diff-smoke.sh`
- **预期结果**: Working 显示未暂存，Staged 显示已暂存
- **失败定位**: 检查 git diff vs git diff --cached 调用

### B9. Editor 保存
- **目的**: 验证文件编辑保存
- **操作步骤**:
  1. 运行 `scripts/editor-smoke.sh`
- **预期结果**: 文件保存成功，内容正确
- **失败定位**: 检查 file_write 消息处理

### B10. Terminal 可见性
- **目的**: 验证终端显示正常
- **操作步骤**: 参见 `scripts/release/ui-manual-check.md` 第 2 节
- **预期结果**: 终端输出正确，交互流畅
- **失败定位**: 检查 xterm.js 初始化，检查 PTY 连接

---

## C. 稳定性与错误处理 (P0/P1)

### C1. 非 Git Repo 时 Git 面板行为 (P0)
- **目的**: 确保非 git 目录不崩溃
- **操作步骤**:
  1. 创建非 git 目录作为 workspace
  2. 打开 Git 面板
- **预期结果**: 显示 "Not a git repository" 或类似提示
- **失败定位**: 检查 git_status 错误处理

### C2. 索引截断提示 (P1)
- **目的**: 大型项目索引限制提示
- **操作步骤**:
  1. 在 >50,000 文件的目录测试 Cmd+P
- **预期结果**: 显示截断警告，返回前 50,000 条
- **失败定位**: 检查 FileIndexResult 中的 truncated 字段

### C3. Diff 截断提示 (P1)
- **目的**: 大文件 diff 限制提示
- **操作步骤**:
  1. 创建 >1MB 的文件修改
  2. 查看 diff
- **预期结果**: 显示 "Diff too large" 或截断提示
- **失败定位**: 检查 diff 大小限制逻辑

### C4. Binary File Diff 提示 (P1)
- **目的**: 二进制文件 diff 处理
- **操作步骤**:
  1. 修改二进制文件 (如 .png)
  2. 查看 diff
- **预期结果**: 显示 "Binary file changed" 提示
- **失败定位**: 检查 git diff 输出解析

### C5. Workspace 切换状态保持 (P0)
- **目的**: 切换 workspace 时 tabs 保留
- **操作步骤**: 参见 `scripts/release/ui-manual-check.md` 第 8 节
- **预期结果**: 切换后 tabs 状态保持
- **失败定位**: 检查 workspace 切换时的状态管理

---

## D. 性能与资源 (P1)

### D1. File Index 耗时
- **目的**: 确认索引性能可接受
- **操作步骤**: 参见 `scripts/release/perf-notes.md` 第 1 节
- **预期结果**: 10,000 文件 < 500ms
- **失败定位**: 检查 ignore 规则是否生效

### D2. 大 Diff 渲染
- **目的**: 确认大 diff 不卡顿
- **操作步骤**: 参见 `scripts/release/perf-notes.md` 第 2 节
- **预期结果**: 500KB diff 渲染 < 1s
- **失败定位**: 检查 diff 分块渲染逻辑

### D3. 内存/CPU 观察
- **目的**: 确认无明显资源泄漏
- **操作步骤**: 参见 `scripts/release/perf-notes.md` 第 3 节
- **预期结果**: 长时间运行内存稳定
- **失败定位**: 使用 Instruments 分析

---

## E. 安全与边界 (P0)

### E1. Path Traversal 防护
- **目的**: 防止目录穿越攻击
- **操作步骤**:
  1. 尝试读取 `../../../etc/passwd`
  2. 尝试写入 workspace 外的文件
- **预期结果**: 请求被拒绝，返回错误
- **失败定位**: 检查 file_read/file_write 路径验证

### E2. Workspace Root 限制
- **目的**: 文件操作限制在 workspace 内
- **操作步骤**:
  1. 检查 file API 的路径规范化逻辑
- **预期结果**: 所有路径解析后在 workspace_root 内
- **失败定位**: 检查 canonicalize 和 starts_with 验证

### E3. Git 命令 CWD 固定
- **目的**: git 命令不越界执行
- **操作步骤**:
  1. 检查 git_status/git_diff 的 cwd 设置
- **预期结果**: 所有 git 命令 cwd 为 workspace_root
- **失败定位**: 检查 Command::new("git").current_dir() 调用

---

## F. 文档与开发者体验 (P1)

### F1. README 快速开始
- **目的**: 新用户可从零跑通
- **操作步骤**:
  1. 按 README 步骤执行
  2. 验证应用启动成功
- **预期结果**: 无遗漏步骤，无错误
- **失败定位**: 更新 README 补充缺失步骤

### F2. run-core.sh 可用性
- **目的**: 核心启动脚本可用
- **操作步骤**:
  ```bash
  ./scripts/run-core.sh
  ```
- **预期结果**: Core 成功启动，监听 47999
- **失败定位**: 检查 cargo build 错误

### F3. run-app.sh 可用性
- **目的**: 应用启动脚本可用
- **操作步骤**:
  ```bash
  ./scripts/run-app.sh
  ```
- **预期结果**: App 成功启动
- **失败定位**: 检查 xcodebuild 错误

### F4. Sanity Tests 一键运行
- **目的**: 所有 smoke tests 可一键执行
- **操作步骤**:
  ```bash
  ./scripts/release/sanity.sh
  ```
- **预期结果**: 所有测试通过，输出 "RELEASE SANITY PASSED"
- **失败定位**: 查看具体失败的测试脚本

---

## 发布前最终检查

### 必须完成 (P0)
- [ ] A1-A4: 平台环境确认
- [ ] B1-B10: 核心功能回归全部通过
- [ ] C1, C5: 关键稳定性检查
- [ ] E1-E3: 安全边界验证
- [ ] F4: sanity.sh 全部通过

### 建议完成 (P1)
- [ ] C2-C4: 边界情况提示
- [ ] D1-D3: 性能基线确认
- [ ] F1-F3: 文档和脚本验证

### 可推迟 (P2)
- [ ] WS 断线重连机制 (记录为 Known Issue)
- [ ] 自动更新机制
- [ ] 崩溃日志收集

---

## 快速验证命令

```bash
# 一键运行所有 smoke tests
./scripts/release/sanity.sh

# 单独运行各项测试
./scripts/file-index-smoke.sh      # 文件索引
./scripts/git-tools-smoke.sh       # Git 工具
./scripts/staged-diff-smoke.sh     # Staged diff
./scripts/editor-smoke.sh          # 编辑器
./scripts/multi-workspace-smoke.sh # 多工作区
```

---

## 相关文档

- [UI 手工验收清单](scripts/release/ui-manual-check.md)
- [性能测量方法](scripts/release/perf-notes.md)
- [已知问题](docs/KNOWN_ISSUES.md)
- [故障排除](docs/TROUBLESHOOTING.md)
