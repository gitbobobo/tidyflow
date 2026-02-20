# Evolution UI 截图证据策略

> 文档版本：1.0 | 更新日期：2026-02-19
> 
> 本文档定义关键界面状态的截图采集方法、命名规则与缺失处理策略。

## 1. 关键截图点定义

### 1.1 必采截图状态

| 状态 ID | 状态名称 | 触发时机 | 用途 |
|---------|---------|---------|------|
| `initial` | 初始状态 | App 启动后首个稳定界面 | 基线对比 |
| `processing` | 处理中 | 执行任务/命令时 | 状态确认 |
| `complete` | 完成/成功 | 任务成功完成 | 成功证据 |
| `error` | 错误/失败 | 任务失败或异常 | 失败定位 |

### 1.2 界面区域

| 区域 | 描述 | 采集要求 |
|------|------|---------|
| 主窗口 | TidyFlow 主界面 | 必须完整 |
| 终端区域 | xterm.js 终端内容 | 必须可见 |
| 侧边栏 | 项目/工作区列表 | 可选 |
| 弹窗/对话框 | 错误/确认弹窗 | 出现时必须 |

---

## 2. 截图命名规则

### 2.1 标准格式

```
screenshot-<check_id>-<state>-[<timestamp>].png
```

| 部分 | 说明 | 示例 |
|------|------|------|
| `check_id` | 关联的检查项 ID | `v-3` |
| `state` | 状态标识 | `initial`, `processing`, `complete`, `error` |
| `timestamp` | 可选时间戳 | `20260219-103000` |

### 2.2 命名示例

```
screenshot-v3-initial.png
screenshot-v3-processing.png
screenshot-v3-complete.png
screenshot-v3-error.png
screenshot-v3-initial-20260219-103000.png  (带时间戳)
```

### 2.3 与 Cycle/Check 绑定

截图必须存放于 cycle 的 evidence 目录：

```
.tidyflow/evolution/<cycle_id>/evidence/screenshot-v3-initial.png
```

---

## 3. 采集方法

### 3.1 手动采集（macOS）

```bash
# 全屏截图
screencapture -x evidence/screenshot-v3-initial.png

# 指定窗口（需先获取 window-id）
screencapture -l <window-id> evidence/screenshot-v3-initial.png

# 选区截图
screencapture -i evidence/screenshot-v3-initial.png
```

### 3.2 自动采集脚本

创建辅助脚本 `scripts/evo-screenshot.sh`：

```bash
#!/bin/bash
# 用法: ./scripts/evo-screenshot.sh --cycle <cycle_id> --check <check_id> --state <state>

CYCLE_ID="${1:-}"
CHECK_ID="${2:-v-3}"
STATE="${3:-initial}"

CYCLE_DIR=".tidyflow/evolution/$CYCLE_ID"
EVIDENCE_DIR="$CYCLE_DIR/evidence"
mkdir -p "$EVIDENCE_DIR"

FILENAME="screenshot-${CHECK_ID}-${STATE}.png"
screencapture -x "$EVIDENCE_DIR/$FILENAME"

echo "[evo][evidence] 截图保存: $EVIDENCE_DIR/$FILENAME"
```

### 3.3 Playwright 自动化（未来）

对于自动化测试场景，可使用 Playwright：

```typescript
import { test } from '@playwright/test';

test('capture UI states', async ({ page }) => {
  // 初始状态
  await page.goto('http://localhost:3000');
  await page.screenshot({ path: 'evidence/screenshot-v3-initial.png' });
  
  // 处理中状态
  await page.click('#run-button');
  await page.screenshot({ path: 'evidence/screenshot-v3-processing.png' });
  
  // 完成状态
  await page.waitForSelector('.success');
  await page.screenshot({ path: 'evidence/screenshot-v3-complete.png' });
});
```

---

## 4. 截图校验规则

### 4.1 基本校验

| 规则 | 说明 |
|------|------|
| 文件存在 | 路径指向有效文件 |
| 文件大小 > 0 | 非空文件 |
| 格式正确 | PNG/JPEG 格式 |
| 命名合规 | 符合命名规则 |

### 4.2 数量校验

每个 check_id 至少需要 3 个状态截图：

```
最小集: initial + processing + (complete | error)
```

### 4.3 可追溯性

截图必须能在 `evidence.index.json` 中找到对应条目：

```json
{
  "evidence_id": "ev-003",
  "type": "screenshot",
  "path": "evidence/screenshot-v3-initial.png",
  "linked_criteria_ids": ["ac-3"],
  "metadata": {
    "check_id": "v-3",
    "state": "initial",
    "captured_at": "2026-02-19T10:30:00Z"
  }
}
```

---

## 5. 缺失处理策略

### 5.1 缺失判定

- 文件不存在
- 文件大小为 0
- 格式无效
- 命名不符合规则

### 5.2 缺失处理

| 缺失类型 | 处理方式 |
|---------|---------|
| 部分缺失（<3 张） | 标记为 `未达标`，可继续执行 |
| 全部缺失 | 标记为 `失败`，阻断 verify |
| 校验失败 | 记录原因，标记为 `无效` |

### 5.3 verify 阶段处理

```yaml
# verify 检查逻辑
if screenshot_count < 3:
    status = "not_met"
    message = "截图数量不足: {screenshot_count}/3"
    
if all_screenshots_missing:
    status = "failed"
    message = "缺少所有截图证据"
```

---

## 6. 与 Evolution 集成

### 6.1 implement 阶段

- 执行 work_items 时，在关键状态点触发截图
- 截图保存到 cycle evidence 目录
- 更新 evidence.index.json

### 6.2 verify 阶段

- 校验截图数量和质量
- 检查命名规则和可追溯性
- 生成截图校验报告

### 6.3 judge 阶段

- 基于 ac-3 判定 UI 证据是否达标
- 考虑缺失原因（如环境限制）

---

## 变更日志

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-02-19 | 1.0 | 初始版本，定义截图策略 |
