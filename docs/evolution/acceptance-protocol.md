# Evolution 验收协议与证据基线

> 文档版本：1.0 | 更新日期：2026-02-19
> 
> 本文档定义 Evolution 系统的最小验收标准、检查项与证据类型映射，确保 implement/verify/judge 阶段的证据闭环可判定。

## 1. 验收标准（Acceptance Criteria）

### AC-1：执行成功
**定义**：构建与集成测试通过，产出有效日志。

| 字段 | 值 |
|------|-----|
| ID | ac-1 |
| 描述 | 构建成功，核心链路可运行 |
| 检查项 | v-1（构建）、v-2（集成） |
| 最小证据 | `build_log`, `test_log` |
| 缺失判定 | 任一证据缺失 → **失败** |

### AC-2：失败可定位
**定义**：失败时可快速定位根因。

| 字段 | 值 |
|------|-----|
| ID | ac-2 |
| 描述 | 失败时可追溯日志关键字、截图与差异摘要 |
| 检查项 | v-2（集成日志）、v-4（差异摘要） |
| 最小证据 | `test_log`, `diff_summary` |
| 缺失判定 | 任一证据缺失 → **不可判定** |

### AC-3：UI 证据可用
**定义**：关键界面状态有截图证据。

| 字段 | 值 |
|------|-----|
| ID | ac-3 |
| 描述 | 至少 3 个关键状态有截图 |
| 检查项 | v-3（截图） |
| 最小证据 | `screenshot` |
| 缺失判定 | 截图数量 < 3 或无法关联 → **未达标** |

### AC-4：证据索引可判定
**定义**：所有证据可通过索引快速访问与校验。

| 字段 | 值 |
|------|-----|
| ID | ac-4 |
| 描述 | evidence.index.json 包含完整证据路径与元数据 |
| 检查项 | v-1, v-2, v-3, v-4 |
| 最小证据 | `build_log`, `test_log`, `screenshot`, `diff_summary` |
| 缺失判定 | 任一证据路径无效或字段缺失 → **不可判定** |

---

## 2. 检查项定义（Verification Checks）

### V-1：构建检查
```yaml
id: v-1
kind: build
command: xcodebuild / cargo build
expected: 退出码 0，build_log 路径有效
evidence_type: build_log
```

### V-2：集成检查
```yaml
id: v-2
kind: integration
command: run-app.sh + 核心通信验证
expected: 日志包含 [evo][run] 启动/连接/消息收发/退出码
evidence_type: test_log
```

### V-3：截图检查
```yaml
id: v-3
kind: manual
method: 采集关键 UI 状态截图
expected: ≥3 张截图，命名含 cycle_id/check_id
evidence_type: screenshot
```

### V-4：差异摘要检查
```yaml
id: v-4
kind: manual
method: 对比执行前后 evidence.index.json
expected: diff_summary 说明新增/缺失证据及原因
evidence_type: diff_summary
```

---

## 3. 证据类型规范

### 3.1 build_log
- **路径约定**：`<cycle_dir>/evidence/build-<run_id>.log`
- **内容要求**：包含完整构建输出、警告、错误、退出码
- **判定标准**：最后一行含 `BUILD SUCCESS` 或退出码为 0

### 3.2 test_log
- **路径约定**：`<cycle_dir>/evidence/integration-<run_id>.log`
- **内容要求**：包含启动、连接、消息收发、退出等关键字
- **判定标准**：包含完整 `[evo][run]` 标记链

### 3.3 screenshot
- **路径约定**：`<cycle_dir>/evidence/screenshot-<check_id>-<state>.png`
- **命名规则**：
  - `screenshot-v3-initial.png` — 初始状态
  - `screenshot-v3-processing.png` — 处理中
  - `screenshot-v3-complete.png` — 完成/失败
- **判定标准**：文件存在且大小 > 0

### 3.4 diff_summary
- **路径约定**：`<cycle_dir>/evidence/diff-<run_id>.md`
- **内容要求**：
  ```markdown
  ## 证据差异摘要
  
  ### 新增证据
  - path: ... | type: ... | linked_criteria: [...]
  
  ### 缺失证据
  - path: ... | reason: ...
  
  ### 变更统计
  - 新增: N | 删除: M | 变更: K
  ```

---

## 4. 验收-检查-证据映射表

| 验收标准 | 检查项 | 最小证据 | 缺失规则 |
|---------|--------|---------|---------|
| ac-1 | v-1, v-2 | build_log, test_log | 任一缺失 → 失败 |
| ac-2 | v-2, v-4 | test_log, diff_summary | 任一缺失 → 不可判定 |
| ac-3 | v-3 | screenshot | 不足 → 未达标 |
| ac-4 | v-1, v-2, v-3, v-4 | 全部四种 | 任一路径无效 → 不可判定 |

---

## 5. 判定规则

```
判定优先级：
1. 证据路径无效 → 不可判定
2. 必需证据缺失 → 失败
3. 可选证据缺失 → 未达标（可继续）
4. 全部证据有效 → 通过
```

---

## 6. 与 Evolution 阶段集成

- **implement**：执行 work_items，产出证据文件
- **verify**：依据本协议执行检查，更新 evidence.index.json
- **judge**：基于验收标准和证据索引判定 cycle 结果

---

## 变更日志

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-02-19 | 1.0 | 初始版本，定义 ac-1~ac-4 与证据协议 |
