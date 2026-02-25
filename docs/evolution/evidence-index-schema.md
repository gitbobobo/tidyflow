# Evolution 证据索引契约

> 文档版本：1.2 | 更新日期：2026-02-25

本文档定义 `evidence.index.json` 的标准结构、幂等规则与写入要求，供 implement/verify/judge 共用。

## 1. 文件位置

```text
.tidyflow/evolution/<cycle_id>/evidence.index.json
```

## 2. 顶层结构（当前实现）

```json
{
  "$schema_version": "1.0",
  "cycle_id": "2026-02-25T06-00-02-292Z",
  "updated_at": "2026-02-25T06:30:00Z",
  "items": [
    {
      "evidence_id": "ev-001",
      "type": "test_log",
      "path": "evidence/test-v1.log",
      "generated_by_stage": "implement",
      "linked_criteria_ids": ["ac-1"],
      "summary": "core unit 测试日志",
      "created_at": "2026-02-25T06:29:00Z",
      "check_id": "v-1",
      "run_id": "20260225-062900",
      "status": "present",
      "missing_reason": null,
      "source": {
        "kind": "command",
        "value": "cargo test --manifest-path core/Cargo.toml"
      }
    }
  ]
}
```

## 3. 字段要求

最小必填字段：
- `$schema_version`
- `cycle_id`
- `items[]`
  - `evidence_id`
  - `type`（`test_log|build_log|screenshot|metrics|diff_summary|custom`）
  - `path`
  - `generated_by_stage`
  - `linked_criteria_ids`
  - `summary`
  - `created_at`

推荐扩展字段（用于可追溯与缺失显式化）：
- `check_id`
- `run_id`
- `status`（`present|missing`）
- `missing_reason`（`status=missing` 时必填）
- `source.kind/source.value`（记录来源命令或方法）

## 4. 幂等与原子写入

- 幂等合并键建议：`run_id + check_id + path`。
- 同一合并键重复写入时保留 `evidence_id/created_at`，仅更新摘要与状态。
- 写入流程必须为：`临时文件 -> rename`，禁止直接覆盖。

## 5. 一致性检查

- `evidence_id` 全局唯一。
- `created_at` 为 RFC3339 UTC。
- `path` 相对 cycle 根目录。
- 五类证据位（`test_log|build_log|screenshot|diff_summary|metrics`）缺失时必须显式写入 `status=missing + missing_reason`。
