# Draft: Rust 端大文件拆分

## 用户需求
- 拆分 Rust 端的大文件
- 提高代码可维护性和模块化

## 待确认信息
- 拆分标准（行数阈值）
- 拆分策略（功能模块 vs 类型 vs 混合）
- 测试策略
- 是否有特定文件需要优先处理

## 初步分析
项目结构：
- `/core/src/` - Rust 核心代码
- 主要模块：main.rs, pty/, server/, workspace/, util/

## 用户选择
- 拆分标准：500 行以上
- 拆分策略：混合策略（根据内容灵活选择）
- 测试策略：每个文件拆分后立即测试
- **拆分范围**：仅拆分最大的两个文件（ws.rs 和 git_tools.rs）
- **拆分顺序**：从大到小（ws.rs → git_tools.rs）
- **提交策略**：细粒度提交（每个子模块拆分完成且测试通过后提交）

## 文件分析结果
### 需要拆分的文件（选中 2 个）

1. **ws.rs (3222行)** - 优先级 1
   - WebSocket 连接处理
   - 巨大的 handle_client_message 函数
   - TerminalManager
   - **拆分方案**：
     - `handlers/terminal.rs` - 终端相关消息处理
     - `handlers/file.rs` - 文件操作消息处理
     - `handlers/git.rs` - Git 消息处理
     - `handlers/project.rs` - 项目和工作空间管理
     - `handlers/settings.rs` - 设置相关消息
     - `terminal/manager.rs` - TerminalManager
     - `terminal/session.rs` - 终端会话逻辑

2. **git_tools.rs (2699行)** - 优先级 2
   - 20+ 个类型定义
   - Git 核心操作函数
   - **拆分方案**：
     - `git/status.rs` - 状态查询（status、diff、log、show）
     - `git/operations.rs` - 文件操作（stage、unstage、discard）
     - `git/branches.rs` - 分支管理
     - `git/commit.rs` - 提交操作（commit、rebase、fetch）
     - `git/integration.rs` - 集成工作流（merge_to_default 等）
     - `git/utils.rs` - 辅助函数和类型定义

3. **protocol.rs (763行)** - 暂不处理
   - 保持现状

## 测试基础设施
- 项目使用标准 Rust 测试框架
- 测试命令：`cargo test`
- 编译检查：`cargo check`

## Metis 审查结果 + 用户决策

### 关键决策（用户已确认）
1. **API 兼容性**：内部可调（允许调整内部 API，但 WebSocket 协议不变）
2. **问题处理**：原地修复（不使用 git revert）

### 默认决策（应用合理默认值）
3. **测试基准线**：运行 `cargo test` 获取当前通过标准
4. **共享状态处理**：通过代码分析识别，移动到合适位置
5. **编译优化**：保持现有引用方式，不优化
6. **文档同步**：暂不更新设计文档（可后续单独进行）
7. **辅助函数位置**：放在 `ws/util.rs` 和 `git/utils.rs`
8. **模块导入**：使用绝对路径（`use crate::server::...`）
9. **错误处理**：保持现有错误类型，通过 mod.rs 重新导出

### 护栏要求
- 零功能回归（所有测试通过）
- 每次拆分后立即编译和测试
- 不改变 WebSocket 协议
- 不触碰其他文件（除必要的 mod.rs）
- 不引入性能退化

### 边缘情况处理
- 循环依赖：通过共享 types.rs 解决
- 全局状态：使用 grep 搜索并处理
- Trait 实现：随类型定义一起移动
- 错误类型：通过 mod.rs 重新导出保持兼容

## 准备生成计划
所有信息已收集完毕...
