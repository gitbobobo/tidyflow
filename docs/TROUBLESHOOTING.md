# TidyFlow 故障排除指南

> 常见问题诊断与解决方案

## 目录

1. [WebSocket 连接问题](#1-websocket-连接问题)
2. [权限问题](#2-权限问题)
3. [Git 仓库问题](#3-git-仓库问题)
4. [文件索引问题](#4-文件索引问题)
5. [Diff 显示问题](#5-diff-显示问题)
6. [终端问题](#6-终端问题)
7. [构建问题](#7-构建问题)

---

## 1. WebSocket 连接问题

### 症状: UI 显示 "Connecting..." 或无响应

#### 检查 Core 是否运行
```bash
# 检查进程
pgrep tidyflow-core

# 检查端口
lsof -i :47999
```

#### 解决方案

**A. Core 未运行**
```bash
# 启动 Core
./scripts/run-core.sh
```

**B. 端口被占用**
```bash
# 查看占用进程
lsof -i :47999

# 使用其他端口
export TIDYFLOW_PORT=48000
./scripts/run-core.sh
```

**C. 防火墙阻止**
- 系统偏好设置 → 安全性与隐私 → 防火墙
- 允许 tidyflow-core 接受传入连接

### 症状: 连接后立即断开

#### 检查日志
```bash
# 查看 Core 日志
RUST_LOG=debug ./scripts/run-core.sh
```

#### 可能原因
- 协议版本不匹配
- 消息格式错误

---

## 2. 权限问题

### 症状: 无法读取/写入文件

#### 检查文件权限
```bash
ls -la /path/to/file
```

#### 解决方案

**A. 文件只读**
```bash
chmod u+w /path/to/file
```

**B. 目录无写权限**
```bash
chmod u+wx /path/to/directory
```

**C. 沙盒限制**
- TidyFlow 只能访问用户选择的目录
- 重新导入项目以授权访问

### 症状: 无法执行脚本

```bash
# 添加执行权限
chmod +x scripts/*.sh
```

---

## 3. Git 仓库问题

### 症状: Git 面板显示空白

#### 检查是否为 Git 仓库
```bash
cd /path/to/workspace
git status
```

#### 解决方案

**A. 不是 Git 仓库**
```bash
git init
```

**B. .git 目录损坏**
```bash
# 备份后重新克隆
git clone <repo-url> new-directory
```

### 症状: Git 状态不更新

#### 手动刷新
- 按 Cmd+Shift+P
- 执行 "Refresh Git Status"

#### 检查 git 版本
```bash
git --version
# 需要 >= 2.20
```

### 症状: Worktree 创建失败

#### 检查 git worktree 支持
```bash
git worktree list
```

#### 常见错误

**A. "fatal: not a git repository"**
- 确保在 git 仓库根目录

**B. "fatal: branch already exists"**
- 分支名已存在，使用其他名称

**C. "fatal: path already exists"**
- 目标路径已存在，删除或使用其他路径

---

## 4. 文件索引问题

### 症状: Quick Open (Cmd+P) 无结果

#### 检查索引状态
```bash
# 运行索引测试
./scripts/file-index-smoke.sh
```

#### 解决方案

**A. 索引未完成**
- 等待索引完成
- 按 Cmd+Shift+P → "Refresh File Index"

**B. 文件被忽略**
- 检查 .gitignore 规则
- 确认文件不在排除列表

### 症状: 索引截断警告

#### 原因
- 项目超过 50,000 文件

#### 解决方案
```bash
# 检查文件数量
find . -type f | wc -l

# 优化 .gitignore
echo "node_modules/" >> .gitignore
echo "build/" >> .gitignore
echo ".git/" >> .gitignore
```

---

## 5. Diff 显示问题

### 症状: Diff 显示为空

#### 检查文件状态
```bash
git status
git diff
git diff --cached  # staged
```

#### 解决方案

**A. Working 模式无更改**
- 切换到 Staged 模式查看已暂存更改

**B. Staged 模式无更改**
- 先 `git add` 文件

**C. 文件未修改**
- 确认文件确实有更改

### 症状: Binary diff 显示乱码

#### 原因
- 二进制文件无法显示文本 diff

#### 解决方案
- 这是预期行为
- 二进制文件只显示 "Binary file changed"

### 症状: 大 Diff 卡顿

#### 原因
- Diff 内容过大 (>500KB)

#### 解决方案
- 分批提交更改
- 等待渲染完成

---

## 6. 终端问题

### 症状: 终端无输出

#### 检查 PTY 连接
```bash
# 查看 Core 日志
RUST_LOG=debug ./scripts/run-core.sh
```

#### 解决方案

**A. PTY 创建失败**
- 检查系统 PTY 限制
- 重启应用

**B. Shell 路径错误**
- 检查 $SHELL 环境变量

### 症状: 终端显示乱码

#### 可能原因
- 字符编码问题
- 字体不支持

#### 解决方案
```bash
# 设置 UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

### 症状: 终端 CWD 错误

#### 检查 workspace 绑定
- 确认终端已绑定到正确 workspace
- 检查 term_list 返回的 workspace_id

---

## 7. 构建问题

### 症状: Cargo build 失败

#### 检查 Rust 版本
```bash
rustc --version
# 需要 >= 1.75.0

# 更新 Rust
rustup update stable
```

#### 常见错误

**A. 依赖下载失败**
```bash
# 清理缓存重试
cargo clean
cargo build
```

**B. 编译错误**
- 检查 Rust 版本兼容性
- 查看具体错误信息

### 症状: Xcode build 失败

#### 检查 Xcode 版本
```bash
xcodebuild -version
# 需要 >= 15.0
```

#### 常见错误

**A. Command Line Tools 未安装**
```bash
xcode-select --install
```

**B. 签名问题**
- 打开 Xcode 项目
- 选择开发团队
- 或使用 "Sign to Run Locally"

**C. 依赖缺失**
```bash
# 清理构建
rm -rf app/build
xcodebuild clean
```

---

## 日志收集

### Core 日志
```bash
# 详细日志
RUST_LOG=debug ./scripts/run-core.sh 2>&1 | tee core.log
```

### App 日志
```bash
# 打开 Console.app
# 搜索 "TidyFlow"
```

### 系统日志
```bash
log show --predicate 'process == "TidyFlow"' --last 1h
```

---

## 获取帮助

如果以上方案无法解决问题:

1. 收集日志信息
2. 记录复现步骤
3. 提交 Issue 到 GitHub

请附带:
- macOS 版本 (`sw_vers`)
- Xcode 版本 (`xcodebuild -version`)
- Rust 版本 (`rustc --version`)
- 错误日志
- 复现步骤
