# Evolution 证据索引契约

> 文档版本：1.1 | 更新日期：2026-02-24

本文档定义 `evidence.index.json` 的标准结构、幂等规则与写入要求，供 implement/verify/judge 共同使用。

## 1. 文件位置

```text
.tidyflow/evolution/<cycle_id>/evidence.index.json
```

## 2. 顶层结构

```json
{
  "$schema_version": "1.0",
  "cycle_id": "2026-02-24T12-01-45Z_tidyflow_default_xxx",
  "updated_at": "2026-02-24T12:30:00Z",
  "evidence": [
    {
      "evidence_id": "ev-xxxxxxxxxxxx",
      "type": "build_log",
      "path": "runs/20260224-122900/evidence/core-build-20260224-122900.log",
      "generated_by_stage": "implement",
      "linked_criteria_ids": ["ac-1"],
      "summary": "Core release 构建日志",
      "created_at": "2026-02-24T12:29:10Z",
      "run_id": "20260224-122900",
      "check_id": "v-2",
      "artifact_hash": "a1b2c3d4",
      "status": "valid"
    }
  ],
  "failure_context": null,
  "completeness": {
    "required_types": ["build_log", "test_log", "screenshot", "diff_summary", "metrics"],
    "present_types": ["build_log", "test_log", "diff_summary", "metrics"],
    "missing_types": ["screenshot"],
    "completeness_ratio": 0.8
  },
  "runs": [
    {
      "run_id": "20260224-122900",
      "executed_at": "2026-02-24T12:30:00Z",
      "step": "all",
      "outcome": "partial",
      "failed_check_id": "v-6"
    }
  ],
  "evidence_items": []
}
```

## 3. 关键字段说明

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `$schema_version` | string | 是 | 固定 `1.0` |
| `cycle_id` | string | 是 | 当前 cycle ID |
| `updated_at` | string | 是 | RFC3339 UTC |
| `evidence` | array | 是 | 证据主数组（judge 读取） |
| `failure_context` | object/null | 是 | 失败上下文（成功时为 null） |
| `completeness` | object | 是 | 完整度统计 |
| `runs` | array | 是 | run 级执行历史 |
| `evidence_items` | array | 否 | 兼容字段，内容与 `evidence` 镜像 |

## 4. 幂等与原子写入

- 幂等合并键：`run_id + artifact_hash`（若无 hash 则退化为 `run_id + path`）。
- 同一合并键重复写入时：保留已有 `evidence_id` 与 `created_at`，只更新可变字段。
- 写入流程必须为：`临时文件 -> fsync/close -> rename(os.replace)`。
- 若读取到损坏 JSON：
  - 先备份为 `evidence.index.json.corrupted.<UTC>`；
  - 再用空索引重建并写入 `failure_context`。

## 5. 一致性检查

至少覆盖以下规则：

- 路径有效：`path` 对应文件存在。
- 类型匹配：扩展名与 `type` 相符。
- ID 唯一：`evidence_id` 不重复。
- 时间序：`created_at <= updated_at`。
- 完整度：`completeness_ratio = (required - missing) / required`。

## 6. failure_context 约定

失败时写入：

```json
{
  "failed_check_id": "v-4",
  "timestamp": "2026-02-24T12:31:00Z",
  "error_message": "iOS build failed",
  "log_keywords": ["[evo][build]", "[evo][anchor]", "[evo][rollback]"],
  "screenshot_path": null,
  "log_path": "runs/20260224-122900/evidence/ios-build-20260224-122900.log"
}
```

## 7. 与验收标准映射

- `ac-1`：必须能关联到 `build_log`（v-2/v-3/v-4）。
- `ac-2`：必须能关联到 `test_log`（v-1/v-5）。
- `ac-3`：必须能关联到 `screenshot`（v-6 三态）。
- `ac-4`：必须有 `metrics + diff_summary` 且索引一致性通过。
- `ac-5`：必须有 `test_log + diff_summary` 并可追溯失败锚点。
