# TidyFlow 性能基线与测量方法

> 发布前性能验证指南，无需自动化但需可复现

## 1. File Index 性能

### 测量目标
- 文件索引 API 响应时间
- 大型项目索引耗时

### 测量方法

#### 方法 A: 使用 time 命令
```bash
# 准备测试目录 (10,000+ 文件)
cd /path/to/large-project

# 测量索引时间 (需要 core 运行中)
time curl -s -X POST http://127.0.0.1:47999/api/file-index \
  -H "Content-Type: application/json" \
  -d '{"workspace_id": "test", "path": "."}'
```

#### 方法 B: 使用 WebSocket 消息
```bash
# 使用 websocat 发送 FileIndex 请求
echo '{"type":"FileIndex","workspace_id":"test"}' | \
  websocat ws://127.0.0.1:47999/ws
```

### 性能基线

| 文件数量 | 预期耗时 | 可接受上限 |
|----------|----------|------------|
| 1,000 | < 50ms | 100ms |
| 10,000 | < 200ms | 500ms |
| 50,000 | < 1s | 2s |

### 优化建议
- 确保 .gitignore 规则生效
- 检查 node_modules、.git 等目录是否被排除
- 考虑增量索引（未实现）

---

## 2. Diff 渲染性能

### 测量目标
- 大文件 diff 渲染时间
- UI 响应流畅度

### 测量方法

#### 准备测试数据
```bash
# 创建大文件修改
cd workspace-demo
dd if=/dev/urandom bs=1024 count=500 | base64 > large-file.txt
git add large-file.txt
# 修改文件
echo "modification" >> large-file.txt
```

#### 测量渲染时间
1. 打开 Safari/Chrome DevTools (Option+Cmd+I)
2. 切换到 Performance 标签
3. 点击 Git 面板中的大文件
4. 观察渲染耗时

### 性能基线

| Diff 大小 | 预期渲染 | 可接受上限 |
|-----------|----------|------------|
| 10KB | < 100ms | 200ms |
| 100KB | < 300ms | 500ms |
| 500KB | < 800ms | 1.5s |
| 1MB | 截断提示 | - |

### 观察指标
- 首次渲染时间 (FCP)
- 滚动流畅度 (60fps)
- 内存占用增长

---

## 3. 内存与 CPU 监控

### 测量目标
- 长时间运行稳定性
- 资源泄漏检测

### 测量方法

#### 使用 Activity Monitor
1. 打开 Activity Monitor (活动监视器)
2. 搜索 "TidyFlow" 和 "tidyflow-core"
3. 记录初始内存占用

#### 使用 top 命令
```bash
# 监控 core 进程
top -pid $(pgrep tidyflow-core)

# 或使用 ps
watch -n 5 'ps aux | grep tidyflow'
```

#### 长时间测试
```bash
# 运行 1 小时后检查
# 1. 记录初始内存
# 2. 执行常规操作 (打开文件、切换 workspace、查看 diff)
# 3. 每 15 分钟记录内存
# 4. 对比增长趋势
```

### 性能基线

| 组件 | 初始内存 | 1小时后 | 可接受增长 |
|------|----------|---------|------------|
| tidyflow-core | ~30MB | ~50MB | < 100% |
| TidyFlow.app | ~100MB | ~150MB | < 100% |

### 泄漏检测
- 内存持续增长 > 100% 需调查
- CPU 空闲时 > 5% 需调查

---

## 4. WebSocket 连接性能

### 测量目标
- 连接建立时间
- 消息延迟

### 测量方法

```bash
# 测量连接时间
time websocat -1 ws://127.0.0.1:47999/ws

# 测量消息往返
echo '{"type":"Ping"}' | \
  time websocat ws://127.0.0.1:47999/ws
```

### 性能基线

| 指标 | 预期值 | 可接受上限 |
|------|--------|------------|
| 连接建立 | < 50ms | 100ms |
| 消息往返 | < 10ms | 50ms |

---

## 5. 启动时间

### 测量目标
- 应用冷启动时间
- Core 启动时间

### 测量方法

```bash
# Core 启动时间
time ./scripts/run-core.sh &
# 等待 "Listening on" 输出

# App 启动时间 (需要 Core 已运行)
time open app/build/Release/TidyFlow.app
```

### 性能基线

| 组件 | 预期启动 | 可接受上限 |
|------|----------|------------|
| tidyflow-core | < 1s | 2s |
| TidyFlow.app | < 2s | 5s |

---

## 性能测试记录模板

```
日期: ____________
测试环境:
  - macOS 版本: ____________
  - 内存: ____________
  - CPU: ____________

测试结果:
  1. File Index (10k files): ______ ms
  2. Diff 渲染 (100KB): ______ ms
  3. 初始内存 (core): ______ MB
  4. 初始内存 (app): ______ MB
  5. 1小时后内存 (core): ______ MB
  6. 1小时后内存 (app): ______ MB
  7. Core 启动时间: ______ s
  8. App 启动时间: ______ s

结论: [ ] 通过 / [ ] 需优化
备注: ____________
```
