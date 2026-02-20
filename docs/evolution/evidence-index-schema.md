# Evolution 证据索引契约

> 文档版本：1.0 | 更新日期：2026-02-19
> 
> 本文档定义 `evidence.index.json` 的结构规范，供 verify/judge 阶段共用。

## 1. 文件位置

```
.tidyflow/evolution/<cycle_id>/evidence.index.json
```

## 2. Schema 定义

### 2.1 完整结构

```json
{
  "$schema_version": "1.0",
  "cycle_id": "2026-02-19T17-21-11Z_tidyflow_default_1c76f6ce5681484b99f6b0445776b02c",
  "updated_at": "2026-02-19T10:30:00Z",
  "evidence": [
    {
      "evidence_id": "ev-001",
      "type": "build_log",
      "path": "evidence/build-20260219-103000.log",
      "generated_by_stage": "implement",
      "linked_criteria_ids": ["ac-1", "ac-4"],
      "linked_check_ids": ["v-1"],
      "status": "valid",
      "summary": "构建成功，耗时 45s",
      "created_at": "2026-02-19T10:30:00Z",
      "metadata": {}
    }
  ],
  "failure_context": null,
  "completeness": {
    "required_types": ["build_log", "test_log", "screenshot", "diff_summary"],
    "present_types": ["build_log", "test_log", "diff_summary"],
    "missing_types": ["screenshot"],
    "completeness_ratio": 0.75
  }
}
```

### 2.2 字段说明

#### 根级字段

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `$schema_version` | string | 是 | Schema 版本，固定 "1.0" |
| `cycle_id` | string | 是 | 所属 cycle ID |
| `updated_at` | string | 是 | 最后更新时间 (RFC3339 UTC) |
| `evidence` | array | 是 | 证据条目数组 |
| `failure_context` | object/null | 否 | 失败上下文（仅失败时） |
| `completeness` | object | 是 | 证据完整度统计 |

#### evidence 条目字段

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `evidence_id` | string | 是 | 唯一证据 ID（格式：ev-NNN） |
| `type` | string | 是 | 证据类型（见类型枚举） |
| `path` | string | 是 | 证据文件相对路径 |
| `generated_by_stage` | string | 是 | 产出阶段（implement/verify） |
| `linked_criteria_ids` | array | 是 | 关联的验收标准 ID 列表 |
| `linked_check_ids` | array | 否 | 关联的检查项 ID 列表 |
| `status` | string | 是 | 状态（valid/invalid/missing） |
| `summary` | string | 否 | 简要描述 |
| `created_at` | string | 是 | 创建时间 (RFC3339 UTC) |
| `metadata` | object | 否 | 扩展元数据 |

#### failure_context 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `failed_check_id` | string | 失败的检查项 ID |
| `timestamp` | string | 失败时间 |
| `error_message` | string | 错误信息 |
| `log_keywords` | array | 相关日志关键字 |
| `screenshot_path` | string/null | 失败截图路径 |

---

## 3. 证据类型枚举

| 类型 | 说明 | 文件扩展名 |
|------|------|-----------|
| `build_log` | 构建日志 | `.log` |
| `test_log` | 测试/集成日志 | `.log` |
| `screenshot` | UI 截图 | `.png`, `.jpg` |
| `diff_summary` | 差异摘要 | `.md` |
| `metrics` | 指标数据 | `.json` |
| `custom` | 自定义证据 | 任意 |

---

## 4. 状态枚举

| 状态 | 说明 |
|------|------|
| `valid` | 证据有效，可正常使用 |
| `invalid` | 证据存在但校验失败 |
| `missing` | 证据缺失 |

---

## 5. 一致性检查

### 5.1 必需检查项

verify 阶段必须执行以下检查：

| 检查项 | 规则 |
|--------|------|
| 路径有效性 | `path` 指向的文件必须存在 |
| 类型匹配 | 文件扩展名与 `type` 匹配 |
| 链接完整性 | `linked_criteria_ids` 中的 ID 必须存在 |
| 时间有效性 | `created_at` ≤ `updated_at` |
| ID 唯一性 | `evidence_id` 在数组内唯一 |

### 5.2 自动检测

```python
def validate_evidence_index(index_path):
    """校验 evidence.index.json 一致性"""
    errors = []
    
    with open(index_path) as f:
        index = json.load(f)
    
    for ev in index.get("evidence", []):
        # 路径有效性
        full_path = os.path.join(os.path.dirname(index_path), ev["path"])
        if not os.path.exists(full_path):
            errors.append(f"路径无效: {ev['path']}")
        
        # 类型匹配
        ext = os.path.splitext(ev["path"])[1]
        type_ext_map = {
            "build_log": ".log",
            "test_log": ".log", 
            "screenshot": [".png", ".jpg"],
            "diff_summary": ".md"
        }
        if ev["type"] in type_ext_map:
            expected = type_ext_map[ev["type"]]
            if isinstance(expected, list):
                if ext not in expected:
                    errors.append(f"类型不匹配: {ev['type']} vs {ext}")
            elif ext != expected:
                errors.append(f"类型不匹配: {ev['type']} vs {ext}")
    
    return errors
```

---

## 6. 更新规则

### 6.1 追加原则

**禁止覆盖已有条目，只能追加新条目或更新状态。**

```json
// 错误：覆盖
"evidence": [新条目]

// 正确：追加
"evidence": [旧条目1, 旧条目2, 新条目]
```

### 6.2 状态更新

允许更新已有条目的 `status` 字段：

```json
{
  "evidence_id": "ev-001",
  "status": "invalid",  // 从 valid 更新为 invalid
  ...
}
```

### 6.3 失败上下文

仅在检测到失败时写入 `failure_context`：

```json
{
  "failure_context": {
    "failed_check_id": "v-2",
    "timestamp": "2026-02-19T10:35:00Z",
    "error_message": "WebSocket 连接超时",
    "log_keywords": ["[evo][ws]", "timeout"],
    "screenshot_path": "evidence/screenshot-v3-error.png"
  }
}
```

---

## 7. verify/judge 使用指南

### 7.1 verify 阶段

```python
def verify_stage(cycle_dir):
    index_path = f"{cycle_dir}/evidence.index.json"
    index = load_index(index_path)
    
    # 检查必需证据类型
    required = ["build_log", "test_log", "screenshot", "diff_summary"]
    present = [ev["type"] for ev in index["evidence"] if ev["status"] == "valid"]
    
    missing = set(required) - set(present)
    
    # 更新完整度
    index["completeness"]["missing_types"] = list(missing)
    index["completeness"]["completeness_ratio"] = 1 - len(missing) / len(required)
    
    # 一致性检查
    errors = validate_evidence_index(index_path)
    
    return {
        "completeness": index["completeness"],
        "validation_errors": errors,
        "can_proceed": len(errors) == 0 and len(missing) == 0
    }
```

### 7.2 judge 阶段

```python
def judge_stage(cycle_dir, acceptance_criteria):
    index = load_index(f"{cycle_dir}/evidence.index.json")
    
    results = {}
    for ac in acceptance_criteria:
        required_evidence = ac["minimum_evidence"]
        linked = [ev for ev in index["evidence"] 
                  if ac["id"] in ev["linked_criteria_ids"]]
        
        present_types = [ev["type"] for ev in linked if ev["status"] == "valid"]
        missing = set(required_evidence) - set(present_types)
        
        if missing:
            results[ac["id"]] = {
                "status": "failed" if ac["strict"] else "not_met",
                "reason": f"缺失证据: {missing}"
            }
        else:
            results[ac["id"]] = {"status": "passed"}
    
    return results
```

---

## 8. 示例

### 8.1 完整示例

```json
{
  "$schema_version": "1.0",
  "cycle_id": "2026-02-19T17-21-11Z_tidyflow_default_1c76f6ce5681484b99f6b0445776b02c",
  "updated_at": "2026-02-19T10:45:00Z",
  "evidence": [
    {
      "evidence_id": "ev-001",
      "type": "build_log",
      "path": "runs/20260219-103000/evidence/build-20260219-103000.log",
      "generated_by_stage": "implement",
      "linked_criteria_ids": ["ac-1", "ac-4"],
      "linked_check_ids": ["v-1"],
      "status": "valid",
      "summary": "构建成功，BUILD SUCCESS 标记已确认",
      "created_at": "2026-02-19T10:30:00Z",
      "metadata": {
        "duration_seconds": 45,
        "exit_code": 0
      }
    },
    {
      "evidence_id": "ev-002",
      "type": "test_log",
      "path": "runs/20260219-103000/evidence/integration-20260219-103000.log",
      "generated_by_stage": "implement",
      "linked_criteria_ids": ["ac-1", "ac-2", "ac-4"],
      "linked_check_ids": ["v-2"],
      "status": "valid",
      "summary": "集成测试通过，INTEGRATION SUCCESS 标记已确认",
      "created_at": "2026-02-19T10:32:00Z",
      "metadata": {
        "duration_seconds": 12
      }
    },
    {
      "evidence_id": "ev-003",
      "type": "diff_summary",
      "path": "runs/20260219-103000/evidence/diff-20260219-103000.md",
      "generated_by_stage": "implement",
      "linked_criteria_ids": ["ac-2", "ac-4"],
      "linked_check_ids": ["v-4"],
      "status": "valid",
      "summary": "新增证据 3 项，无删除",
      "created_at": "2026-02-19T10:32:30Z",
      "metadata": {}
    },
    {
      "evidence_id": "ev-004",
      "type": "screenshot",
      "path": "evidence/screenshot-v3-initial.png",
      "generated_by_stage": "implement",
      "linked_criteria_ids": ["ac-3", "ac-4"],
      "linked_check_ids": ["v-3"],
      "status": "valid",
      "summary": "初始状态截图",
      "created_at": "2026-02-19T10:33:00Z",
      "metadata": {
        "state": "initial"
      }
    }
  ],
  "failure_context": null,
  "completeness": {
    "required_types": ["build_log", "test_log", "screenshot", "diff_summary"],
    "present_types": ["build_log", "test_log", "screenshot", "diff_summary"],
    "missing_types": [],
    "completeness_ratio": 1.0
  }
}
```

---

## 变更日志

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-02-19 | 1.0 | 初始版本，定义证据索引契约 |
