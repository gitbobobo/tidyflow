# Evolution 验收协议与证据基线

> 文档版本：1.1 | 更新日期：2026-02-20
> 
> 本文档定义 Evolution 系统的最小验收标准、检查项与证据类型映射，确保 implement/verify/judge 阶段的证据闭环可判定。

## 1. 验收标准（Acceptance Criteria）

> **与 plan.execution.json 对齐**：以下 AC 定义与 verification_plan.acceptance_mapping 严格一致。

### AC-1：构建通过
**定义**：构建成功，产出有效构建日志。

| 字段 | 值 |
|------|-----|
| ID | ac-1 |
| 描述 | 构建成功，xcodebuild 与 cargo test 通过 |
| 检查项 | v-1（构建） |
| 最小证据 | `build_log` |
| 缺失判定 | build_log 缺失 → **失败** |

### AC-2：集成链路通过
**定义**：run-app 与 core 联调链路正常，产出有效集成日志。

| 字段 | 值 |
|------|-----|
| ID | ac-2 |
| 描述 | 执行 run-app 与 core 联调链路，日志包含关键事件标记 |
| 检查项 | v-2（集成） |
| 最小证据 | `test_log` |
| 缺失判定 | test_log 缺失 → **失败** |

### AC-3：UI 截图证据达标
**定义**：关键界面状态有截图证据。

| 字段 | 值 |
|------|-----|
| ID | ac-3 |
| 描述 | 至少 3 个关键状态有截图，文件名含 cycle_id 与 check_id |
| 检查项 | v-3（截图） |
| 最小证据 | `screenshot` |
| 缺失判定 | 截图数量 < 3 或无法关联 → **未达标** |

### AC-4：差异摘要可判定
**定义**：证据差异摘要能解释新增/缺失证据，并与 check 执行结果一致。

| 字段 | 值 |
|------|-----|
| ID | ac-4 |
| 描述 | diff_summary 能解释新增/缺失证据，且与 check 执行结果一致 |
| 检查项 | v-4（差异摘要）、v-1、v-2 |
| 最小证据 | `diff_summary`, `build_log`, `test_log` |
| 缺失判定 | 任一证据路径无效或字段缺失 → **不可判定** |

---

## 2. 检查项定义（Verification Checks）

> **与 plan.execution.json 对齐**：以下检查项定义与 verification_plan.checks 严格一致。

### V-1：构建检查
```yaml
id: v-1
kind: build
command_or_method: 执行 xcodebuild 与 cargo test 的构建/测试步骤并归档 build_log
expected: 命令退出码为 0，且 evidence.index 存在 build_log 记录
evidence_type: build_log
```

### V-2：集成检查
```yaml
id: v-2
kind: integration
command_or_method: 执行 run-app 与 core 联调链路，采集 test_log 并校验关键日志关键字
expected: 日志包含 build/run/ws/evidence 关键字，且链路可完成一次端到端会话
evidence_type: test_log
```

### V-3：截图检查
```yaml
id: v-3
kind: manual
command_or_method: 按 screenshot-strategy 采集关键状态截图并写入 evidence.index
expected: 至少 3 张截图，文件名含 cycle_id 与 check_id
evidence_type: screenshot
```

### V-4：差异摘要检查
```yaml
id: v-4
kind: manual
command_or_method: 生成证据差异摘要并核对缺失项与失败原因
expected: diff_summary 能解释新增/缺失证据，且与 check 执行结果一致
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

> **来源**：plan.execution.json verification_plan.acceptance_mapping

| 验收标准 | 检查项 | 最小证据 | 缺失规则 |
|---------|--------|---------|---------|
| ac-1 | v-1 | build_log | 缺失 → 失败 |
| ac-2 | v-2 | test_log | 缺失 → 失败 |
| ac-3 | v-3 | screenshot | 不足 → 未达标 |
| ac-4 | v-4, v-1, v-2 | diff_summary, build_log, test_log | 任一路径无效 → 不可判定 |

---

## 5. 判定规则

```
判定优先级：
1. 证据路径无效 → 不可判定
2. 必需证据缺失 → 失败
3. 可选证据缺失 → 未达标（可继续）
4. 全部证据有效 → 通过
```

### 5.1 缺证据即失败原则

为保证 judge 阶段的可判定性，采用**保守判定**策略：
- ac-1/ac-2 缺失必需证据时立即判定为**失败**
- ac-3 截图不足判定为**未达标**（不阻断）
- ac-4 证据索引异常判定为**不可判定**

---

## 6. 与 Evolution 阶段集成

- **implement**：执行 work_items，产出证据文件
- **verify**：依据本协议执行检查，更新 evidence.index.json
- **judge**：基于验收标准和证据索引判定 cycle 结果

### 6.1 阶段流转要求

```
implement → verify → judge
    ↓           ↓         ↓
  产证据     校证据     判定
```

- implement 完成后必须产出至少 build_log 和 test_log
- verify 阶段必须校验所有证据路径有效性
- judge 阶段基于本协议判定 ac-1~ac-4

---

## 变更日志

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-02-20 | 1.1 | 对齐 plan.execution.json.verification_plan，更新 AC 映射 |
| 2026-02-19 | 1.0 | 初始版本，定义 ac-1~ac-4 与证据协议 |
