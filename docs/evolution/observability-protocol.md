# Evolution 可观测性与日志规范

> 文档版本：1.0 | 更新日期：2026-02-19
> 
> 本文档定义 Evolution 系统的统一日志关键字、状态流转与失败定位机制。

## 1. 日志关键字规范

所有 Evolution 相关日志必须使用 `[evo]` 前缀，便于统一过滤。

### 1.1 构建日志关键字

| 关键字 | 含义 | 示例 |
|--------|------|------|
| `[evo][build] 构建开始` | 构建任务启动 | `[evo][build] 构建开始: tidyflow-core` |
| `[evo][build] 构建结束` | 构建任务完成 | `[evo][build] 构建结束: tidyflow-core 退出码=0` |
| `BUILD SUCCESS` | 整体构建成功 | 标记行 |

### 1.2 运行日志关键字

| 关键字 | 含义 | 示例 |
|--------|------|------|
| `[evo][run] app/core 启动` | 应用/Core 启动 | `[evo][run] app/core 启动测试开始` |
| `[evo][run] Core 二进制就绪` | Core 产物检查通过 | `[evo][run] Core 二进制就绪: /path/to/core` |
| `[evo][run] App 产物就绪` | App 产物检查通过 | `[evo][run] App 产物就绪: /path/to/app` |
| `INTEGRATION SUCCESS` | 集成测试成功 | 标记行 |

### 1.3 WebSocket 连接日志关键字

| 关键字 | 含义 | 示例 |
|--------|------|------|
| `[evo][ws] 连接` | WebSocket 连接事件 | `[evo][ws] 连接建立` |
| `[evo][ws] 重连` | WebSocket 重连事件 | `[evo][ws] 重连尝试 #1` |
| `[evo][ws] 中断` | WebSocket 连接中断 | `[evo][ws] 中断: timeout` |
| `[evo][ws] 恢复` | WebSocket 恢复连接 | `[evo][ws] 恢复成功` |

### 1.4 证据日志关键字

| 关键字 | 含义 | 示例 |
|--------|------|------|
| `[evo][evidence] 写入成功` | 证据文件写入成功 | `[evo][evidence] 写入成功: build-xxx.log` |
| `[evo][evidence] 缺失` | 证据文件缺失 | `[evo][evidence] 缺失: screenshot` |
| `[evo][evidence] 路径` | 证据路径引用 | `[evo][evidence] 路径: ./evidence/...` |

---

## 2. 状态防分叉机制

### 2.1 控制消息与长任务分离

**原则**：控制消息（如 abort、pause）必须不被长生命周期任务阻塞。

```
┌─────────────────────────────────────────────────────────────┐
│                     Main Event Loop                          │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ Control Messages (Priority Queue)                       ││
│  │ - abort, pause, resume, status_check                    ││
│  └─────────────────────────────────────────────────────────┘│
│                           ↓                                  │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ Task Queue (FIFO)                                       ││
│  │ - build_task, integration_task, evidence_collection    ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### 2.2 状态校验点

| 检查点 | 触发条件 | 校验内容 |
|--------|---------|---------|
| 启动后 | Core 进程启动 | 端口监听、PID 有效 |
| 连接后 | WebSocket 建连 | 握手成功、协议版本匹配 |
| 任务完成后 | work_item 执行结束 | 产物存在、日志完整 |
| 退出前 | 进程终止 | 清理完成、无孤儿进程 |

### 2.3 进程实例校验

所有回调必须校验"仍是当前 task"：

```pseudo
on_callback(task_id, data):
    if task_id != current_task_id:
        log "[evo] 忽略过期回调: task_id=$task_id"
        return
    process(data)
```

---

## 3. 失败定位索引

### 3.1 单索引定位原则

失败后可通过 `evidence.index.json` 一步定位所有相关证据：

```json
{
  "evidence": [
    {
      "evidence_id": "ev-001",
      "type": "build_log",
      "path": "evidence/build-20260219.log",
      "linked_criteria_ids": ["ac-1"],
      "status": "valid"
    },
    {
      "evidence_id": "ev-002",
      "type": "test_log",
      "path": "evidence/integration-20260219.log",
      "linked_criteria_ids": ["ac-1", "ac-2"],
      "status": "valid"
    }
  ],
  "failure_context": {
    "failed_check_id": "v-2",
    "timestamp": "2026-02-19T10:30:00Z",
    "log_keywords": ["[evo][ws] 中断", "timeout"],
    "screenshot_path": null
  }
}
```

### 3.2 定位路径

```
失败事件 → evidence.index.json → 失败上下文
                                   ↓
                    ┌──────────────┼──────────────┐
                    ↓              ↓              ↓
               日志关键字      截图路径       差异摘要
```

### 3.3 日志关键字快速定位

```bash
# 定位构建失败
grep "\[evo\]\[build\]" evidence/build-*.log

# 定位 WebSocket 问题
grep "\[evo\]\[ws\]" evidence/integration-*.log

# 定位所有失败
grep -E "(FAILED|ERROR|\[evo\].*失败)" evidence/*.log
```

---

## 4. 可观测指标

### 4.1 定义的指标

| 指标名 | 类型 | 描述 |
|--------|------|------|
| `build_success_rate` | gauge | 构建成功率 (0-1) |
| `test_success_rate` | gauge | 测试成功率 (0-1) |
| `evidence_completeness_ratio` | gauge | 证据完整度 (0-1) |
| `failure_localization_latency_ms` | histogram | 失败定位耗时 |

### 4.2 Trace ID 贯穿

```
run_id 贯穿:
  build → integration → evidence_index → diff_summary

check_id 到 evidence_path:
  v-1 → evidence/build-xxx.log
  v-2 → evidence/integration-xxx.log
  v-3 → evidence/screenshot-xxx.png
```

---

## 5. 与现有代码集成

### 5.1 Rust Core 日志增强建议

在 `core/src/` 中使用统一前缀：

```rust
log::info!("[evo][run] 服务启动: port={}", port);
log::info!("[evo][ws] 连接建立: client={}", client_id);
log::warn!("[evo][ws] 连接中断: reason={}", reason);
```

### 5.2 Swift App 日志增强建议

在 `app/` 中使用统一前缀：

```swift
Logger.evo.info("[evo][run] App 启动完成")
Logger.evo.info("[evo][ws] WebSocket 连接成功")
```

---

## 变更日志

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-02-19 | 1.0 | 初始版本，定义日志关键字与失败定位机制 |
