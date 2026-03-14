#!/usr/bin/env python3
"""
Apple 客户端性能基线比较器

读取 scripts/tools/apple_client_perf_baselines.json（基线契约）
与 build/perf/ 下的 fixture 证据日志，提取关键指标并输出统一报告。

## 输出 schema
- suite_id: "apple_client_perf"
- overall: pass | warn | fail
- scenarios[]: scenario_id, overall, metrics[], evidence_files[], missing_evidence_keys[]
- generated_at
- warnings[]

## 裁决规则（每场景独立裁决）
- 必需证据键缺失        → fail（reason: missing_evidence）
- 指标值 > fail_limit  → fail（reason: metric_exceeded_fail）
- 指标值 > warn_limit  → warn（reason: metric_exceeded_warn）
- 证据日志文件不存在     → fail（reason: evidence_file_missing）
- 其余                  → pass

warn 不阻断门禁（exit 0），fail 阻断（exit 1）。

## 用法
    python3 scripts/tools/check_apple_client_perf_regression.py \\
        --baseline scripts/tools/apple_client_perf_baselines.json \\
        --evidence-dir build/perf \\
        --report build/perf/apple-client-regression-report.json \\
        [--json] [--self-test]

## 自测模式（WI-004）
    python3 scripts/tools/check_apple_client_perf_regression.py --self-test
    验证内置的 pass/warn/fail 样例是否按预期裁决，exit 0 表示测试全部通过。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "2"
TOOL_VERSION = "2.0.0"


# ---------------------------------------------------------------------------
# 日志解析工具
# ---------------------------------------------------------------------------

def parse_kv_line(line: str) -> dict[str, str]:
    """
    从形如 `key=value key2=value2 ...` 的日志行中解析键值对。
    value 中如含空格，应用引号包裹；此处做简单 key=token 切割。
    """
    result: dict[str, str] = {}
    for token in line.split():
        if "=" in token:
            k, _, v = token.partition("=")
            result[k.strip()] = v.strip()
    return result


def extract_metric_samples(log_text: str, log_pattern: str, value_key: str) -> list[float]:
    """
    从日志文本中找到所有包含 log_pattern 的行，并提取 value_key=<float> 的值。
    """
    samples: list[float] = []
    for line in log_text.splitlines():
        if log_pattern not in line:
            continue
        kv = parse_kv_line(line)
        # 支持 `evolution_timeline_recompute_ms=12.34` 或 `duration_ms=12.34`
        raw = kv.get(value_key)
        if raw is None:
            # 兼容格式：`perf evolution_timeline_recompute_ms=12.34 round=...`
            m = re.search(r"\b" + re.escape(value_key) + r"=([0-9.]+)", line)
            if m:
                raw = m.group(1)
        if raw is not None:
            try:
                samples.append(float(raw))
            except ValueError:
                pass
    return samples


def percentile(samples: list[float], p: float) -> float:
    if not samples:
        return 0.0
    sorted_s = sorted(samples)
    idx = max(0, int(len(sorted_s) * p / 100.0) - 1)
    return sorted_s[min(idx, len(sorted_s) - 1)]


def check_evidence_key_present(log_text: str, evidence_key: str) -> bool:
    """
    检查证据键是否出现在日志文本中。
    支持两种格式：
    - `key=value`：在日志中找到该 key=value 字符串
    - 纯文本子串匹配
    """
    return evidence_key in log_text


def find_evidence_lines(log_text: str, event_key: str) -> list[str]:
    return [line for line in log_text.splitlines() if event_key in line]


def collect_missing_event_fields(log_text: str, event_key: str, fields: list[str]) -> list[str]:
    evidence_lines = find_evidence_lines(log_text, event_key)
    if not evidence_lines:
        return fields

    for line in evidence_lines:
        missing_fields = [field for field in fields if f"{field}=" not in line]
        if not missing_fields:
            return []
    first_line = evidence_lines[0]
    return [field for field in fields if f"{field}=" not in first_line]


# ---------------------------------------------------------------------------
# 场景裁决
# ---------------------------------------------------------------------------

def decide_scenario(
    scenario: dict[str, Any],
    log_text: str,
    evidence_file_exists: bool,
) -> dict[str, Any]:
    """返回单个场景的裁决结果。"""
    scenario_id: str = scenario["scenario_id"]
    surface_id: str = scenario.get("surface_id", "unknown")
    required_keys: list[str] = scenario.get("required_evidence_keys", [])
    required_event_fields: list[dict[str, Any]] = scenario.get("required_event_fields", [])
    metrics: list[dict] = scenario.get("metrics", [])

    issues: list[str] = []
    reason_codes: list[str] = []
    overall = "pass"
    metric_results: list[dict] = []
    missing_keys: list[str] = []
    missing_event_fields: list[dict[str, Any]] = []

    # budget limits：取第一个 metric 的阈值（向后兼容：缺失时置 inf）
    first_metric = metrics[0] if metrics else {}
    budget_warn_limit = float(first_metric.get("warn_limit", float("inf")))
    budget_fail_limit = float(first_metric.get("fail_limit", float("inf")))

    if not evidence_file_exists:
        overall = "fail"
        reason_codes.append("evidence_file_missing")
        issues.append(f"场景 {scenario_id} 证据日志文件不存在")
        return {
            "scenario_id": scenario_id,
            "surface_id": surface_id,
            "overall": overall,
            "reason_codes": reason_codes,
            "metrics": [],
            "missing_evidence_keys": [],
            "missing_event_fields": [],
            "issues": issues,
            "budget_warn_limit": budget_warn_limit,
            "budget_fail_limit": budget_fail_limit,
        }

    # 必需证据键检查
    for key in required_keys:
        if not check_evidence_key_present(log_text, key):
            missing_keys.append(key)

    if missing_keys:
        overall = "fail"
        reason_codes.append("missing_evidence")
        issues.append(f"缺少必需证据键: {', '.join(missing_keys)}")

    for event_requirement in required_event_fields:
        event_key = str(event_requirement.get("event_key", "")).strip()
        fields = [str(field).strip() for field in event_requirement.get("fields", []) if str(field).strip()]
        if not event_key or not fields:
            continue
        missing_fields = collect_missing_event_fields(log_text, event_key, fields)
        if missing_fields:
            missing_event_fields.append({
                "event_key": event_key,
                "fields": missing_fields,
            })

    if missing_event_fields:
        overall = "fail"
        reason_codes.append("missing_event_fields")
        for item in missing_event_fields:
            issues.append(
                f"证据事件 {item['event_key']} 缺少归属字段: {', '.join(item['fields'])}"
            )

    # 数值指标检查
    for metric in metrics:
        metric_id: str = metric["metric_id"]
        log_pattern: str = metric["log_pattern"]
        value_key: str = metric["value_key"]
        warn_limit: float = float(metric.get("warn_limit", float("inf")))
        fail_limit: float = float(metric.get("fail_limit", float("inf")))

        samples = extract_metric_samples(log_text, log_pattern, value_key)
        if not samples:
            metric_status = "warn"
            metric_reason = "no_samples"
            p95 = None
        else:
            p95 = percentile(samples, 95)
            if p95 > fail_limit:
                metric_status = "fail"
                metric_reason = "metric_exceeded_fail"
                overall = "fail"
                reason_codes.append("metric_exceeded_fail")
                issues.append(f"{metric_id} P95={p95:.2f}ms 超过 fail_limit={fail_limit:.2f}ms")
            elif p95 > warn_limit:
                metric_status = "warn"
                metric_reason = "metric_exceeded_warn"
                if overall == "pass":
                    overall = "warn"
                reason_codes.append("metric_exceeded_warn")
                issues.append(f"{metric_id} P95={p95:.2f}ms 超过 warn_limit={warn_limit:.2f}ms")
            else:
                metric_status = "pass"
                metric_reason = "ok"

        metric_results.append({
            "metric_id": metric_id,
            "surface_id": surface_id,
            "status": metric_status,
            "reason": metric_reason,
            "p95_ms": round(p95, 3) if p95 is not None else None,
            "sample_count": len(samples),
            "warn_limit": warn_limit,
            "fail_limit": fail_limit,
        })

    return {
        "scenario_id": scenario_id,
        "surface_id": surface_id,
        "overall": overall,
        "reason_codes": list(dict.fromkeys(reason_codes)),
        "metrics": metric_results,
        "missing_evidence_keys": missing_keys,
        "missing_event_fields": missing_event_fields,
        "issues": issues,
        "budget_warn_limit": budget_warn_limit,
        "budget_fail_limit": budget_fail_limit,
    }


# ---------------------------------------------------------------------------
# 主比较逻辑
# ---------------------------------------------------------------------------

def run_comparison(
    baseline_path: str,
    evidence_dir: str,
    report_path: str,
    json_output: bool = False,
) -> int:
    """执行比较，写入报告，返回 exit code（0=pass/warn, 1=fail）。"""

    baseline_file = Path(baseline_path)
    if not baseline_file.exists():
        print(f"[check_apple_client_perf] 错误: 基线文件不存在: {baseline_path}", file=sys.stderr)
        return 2

    baseline = json.loads(baseline_file.read_text(encoding="utf-8"))
    evidence_dir_path = Path(evidence_dir)
    scenarios = baseline.get("scenarios", [])
    scenario_results: list[dict] = []
    overall = "pass"
    warnings: list[str] = []

    for scenario in scenarios:
        scenario_id: str = scenario["scenario_id"]
        # 证据日志文件名约定：apple-<scenario_id>-fixture-*.log → 最新的一个
        pattern = f"apple-{scenario_id.replace('_', '-')}-fixture*.log"
        candidate_files = sorted(
            evidence_dir_path.glob(pattern),
            key=lambda p: p.stat().st_mtime if p.exists() else 0,
            reverse=True,
        )
        # 也接受扁平路径 apple-<scenario_id>-fixture-oslog.log
        if not candidate_files:
            oslog_path = evidence_dir_path / f"apple-{scenario_id.replace('_', '-')}-fixture-oslog.log"
            if oslog_path.exists():
                candidate_files = [oslog_path]

        if candidate_files:
            log_text = candidate_files[0].read_text(encoding="utf-8", errors="replace")
            evidence_file_exists = True
            evidence_files = [str(candidate_files[0])]
        else:
            log_text = ""
            evidence_file_exists = False
            evidence_files = []

        result = decide_scenario(scenario, log_text, evidence_file_exists)
        result["evidence_files"] = evidence_files
        scenario_results.append(result)

        if result["overall"] == "fail":
            overall = "fail"
            for issue in result["issues"]:
                print(f"[check_apple_client_perf] FAIL [{scenario_id}] {issue}", file=sys.stderr)
        elif result["overall"] == "warn":
            if overall == "pass":
                overall = "warn"
            for issue in result["issues"]:
                warnings.append(f"[{scenario_id}] {issue}")
                print(f"[check_apple_client_perf] WARN [{scenario_id}] {issue}")

    report = {
        "$schema_version": SCHEMA_VERSION,
        "schema_version": SCHEMA_VERSION,
        "tool_version": TOOL_VERSION,
        "suite_id": baseline.get("suite_id", "apple_client_perf"),
        "overall": overall,
        "scenarios": scenario_results,
        "warnings": warnings,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "baseline_path": str(baseline_file.resolve()),
        "evidence_dir": str(evidence_dir_path.resolve()),
        "context_fields": {
            "project": os.environ.get("TF_PROJECT", ""),
            "workspace": os.environ.get("TF_WORKSPACE", ""),
            "cycle_id": os.environ.get("TF_CYCLE_ID", ""),
            "run_id": os.environ.get("TF_RUN_ID", ""),
        },
        "dashboard_snapshot_path": "build/perf/performance-dashboard-snapshot.json",
    }

    report_path_obj = Path(report_path)
    report_path_obj.parent.mkdir(parents=True, exist_ok=True)
    report_path_obj.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    # 写出精简仪表盘快照（供共享投影层直接读取）
    dashboard_snapshot = {
        "overall": overall,
        "scenarios_summary": [
            {
                "scenario_id": sr["scenario_id"],
                "surface_id": sr.get("surface_id", "unknown"),
                "overall": sr["overall"],
            }
            for sr in scenario_results
        ],
        "generated_at": report["generated_at"],
    }
    dashboard_snapshot_path = report_path_obj.parent / "performance-dashboard-snapshot.json"
    dashboard_snapshot_path.write_text(
        json.dumps(dashboard_snapshot, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    if json_output:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"[check_apple_client_perf] overall={overall}")
        for sr in scenario_results:
            print(f"  [{sr['scenario_id']}] {sr['overall']}")
            for m in sr.get("metrics", []):
                p95_str = f"P95={m['p95_ms']:.2f}ms" if m["p95_ms"] is not None else "P95=n/a"
                print(f"    {m['metric_id']}: {m['status']} ({p95_str}, n={m['sample_count']})")
        print(f"[check_apple_client_perf] 报告: {report_path}")

    return 0 if overall in ("pass", "warn") else 1


# ---------------------------------------------------------------------------
# 自测模式（WI-004）
# ---------------------------------------------------------------------------

def run_self_test() -> int:
    """
    验证 decide_scenario 对内置的 pass/warn/fail 样例能正确裁决。
    exit 0 → 全部通过；exit 1 → 有失败。
    """
    failures: list[str] = []

    def expect(label: str, actual: str, expected: str) -> None:
        if actual != expected:
            failures.append(f"{label}: 期望 {expected}，实际 {actual}")
        else:
            print(f"  OK  {label}: {actual}")

    # 样例场景基准定义（对齐 baselines.json 中的 evolution_panel）
    scenario_def = {
        "scenario_id": "evolution_panel",
        "required_evidence_keys": [
            "evolution_recompute_key=evolution_timeline_recompute_ms",
            "evolution_tier_change_key=evolution_monitor tier_change",
            "memory_snapshot_key=memory_snapshot",
        ],
        "metrics": [
            {
                "metric_id": "evolution_timeline_recompute_p95_ms",
                "log_pattern": "perf evolution_timeline_recompute_ms=",
                "value_key": "evolution_timeline_recompute_ms",
                "warn_limit": 50.0,
                "fail_limit": 200.0,
            }
        ],
    }

    # --- 样例 1: PASS ---
    print("自测样例 1: PASS")
    pass_log = "\n".join([
        "perf evolution_perf_fixture_start scenario=evolution_panel",
        "evolution_recompute_key=evolution_timeline_recompute_ms",
        "evolution_tier_change_key=evolution_monitor tier_change",
        "memory_snapshot_key=memory_snapshot",
    ] + [
        f"perf evolution_timeline_recompute_ms={10 + i * 0.1:.2f} round={i + 1} scenario=evolution_panel"
        for i in range(50)
    ])
    result_pass = decide_scenario(scenario_def, pass_log, evidence_file_exists=True)
    expect("PASS: overall", result_pass["overall"], "pass")
    expect("PASS: missing_evidence_keys empty", str(result_pass["missing_evidence_keys"]), "[]")

    # --- 样例 2: WARN (P95 > warn_limit=50ms 但 < fail_limit=200ms) ---
    print("自测样例 2: WARN")
    warn_log = "\n".join([
        "evolution_recompute_key=evolution_timeline_recompute_ms",
        "evolution_tier_change_key=evolution_monitor tier_change",
        "memory_snapshot_key=memory_snapshot",
    ] + [
        # P95 约 75ms (超过 warn_limit=50 但未超 fail_limit=200)
        f"perf evolution_timeline_recompute_ms={60 + i * 0.3:.2f} round={i + 1} scenario=evolution_panel"
        for i in range(50)
    ])
    result_warn = decide_scenario(scenario_def, warn_log, evidence_file_exists=True)
    expect("WARN: overall", result_warn["overall"], "warn")

    # --- 样例 3: FAIL (证据键缺失) ---
    print("自测样例 3: FAIL (missing evidence keys)")
    fail_missing_log = "\n".join([
        # 缺少 evolution_tier_change_key=evolution_monitor tier_change
        "evolution_recompute_key=evolution_timeline_recompute_ms",
        "memory_snapshot_key=memory_snapshot",
        "perf evolution_timeline_recompute_ms=10.0 round=1 scenario=evolution_panel",
    ])
    result_fail_missing = decide_scenario(scenario_def, fail_missing_log, evidence_file_exists=True)
    expect("FAIL_MISSING: overall", result_fail_missing["overall"], "fail")
    expect("FAIL_MISSING: has missing key", str("evolution_tier_change_key=evolution_monitor tier_change" in result_fail_missing["missing_evidence_keys"]), "True")

    # --- 样例 4: FAIL (P95 > fail_limit=200ms) ---
    print("自测样例 4: FAIL (metric exceeded fail_limit)")
    fail_metric_log = "\n".join([
        "evolution_recompute_key=evolution_timeline_recompute_ms",
        "evolution_tier_change_key=evolution_monitor tier_change",
        "memory_snapshot_key=memory_snapshot",
    ] + [
        f"perf evolution_timeline_recompute_ms={250.0:.2f} round={i + 1} scenario=evolution_panel"
        for i in range(50)
    ])
    result_fail_metric = decide_scenario(scenario_def, fail_metric_log, evidence_file_exists=True)
    expect("FAIL_METRIC: overall", result_fail_metric["overall"], "fail")

    # --- 样例 5: FAIL (证据文件不存在) ---
    print("自测样例 5: FAIL (evidence_file_missing)")
    result_no_file = decide_scenario(scenario_def, "", evidence_file_exists=False)
    expect("NO_FILE: overall", result_no_file["overall"], "fail")
    expect("NO_FILE: reason evidence_file_missing", str("evidence_file_missing" in result_no_file["reason_codes"]), "True")

    # --- 样例 6: chat_stream_workspace_switch PASS ---
    print("自测样例 6: chat_stream_workspace_switch PASS")
    ws_switch_scenario_def = {
        "scenario_id": "chat_stream_workspace_switch",
        "surface_id": "chat_session",
        "required_evidence_keys": [
            "hotspot_key=ios_ai_chat",
            "tail_flush_event=aiMessageTailFlush",
            "memory_snapshot_key=memory_snapshot",
            "workspace_switch_event=workspace_switch",
        ],
        "required_event_fields": [
            {
                "event_key": "workspace_switch_event=workspace_switch",
                "fields": ["project", "workspace", "scenario", "surface", "workspace_context"],
            }
        ],
        "metrics": [
            {
                "metric_id": "aiMessageTailFlush_p95_ms",
                "log_pattern": "perf aiMessageTailFlush",
                "value_key": "duration_ms",
                "warn_limit": 60.0,
                "fail_limit": 250.0,
            },
            {
                "metric_id": "workspace_switch_p95_ms",
                "log_pattern": "perf workspace_switch",
                "value_key": "duration_ms",
                "warn_limit": 300.0,
                "fail_limit": 1000.0,
            },
        ],
    }
    ws_switch_pass_log = "\n".join([
        "hotspot_key=ios_ai_chat",
        "tail_flush_event=aiMessageTailFlush",
        "memory_snapshot_key=memory_snapshot",
        "workspace_switch_event=workspace_switch scenario=chat_stream_workspace_switch project=PerfLab workspace=stream-heavy surface=chat_session workspace_context=AC-CHAT-WS-SWITCH",
    ] + [
        f"perf aiMessageTailFlush duration_ms={40.0:.3f} idx={i}"
        for i in range(100)
    ] + [
        f"perf workspace_switch duration_ms={200.0:.3f} idx={i}"
        for i in range(3)
    ])
    result_ws_pass = decide_scenario(ws_switch_scenario_def, ws_switch_pass_log, evidence_file_exists=True)
    expect("WS_SWITCH_PASS: overall", result_ws_pass["overall"], "pass")
    expect("WS_SWITCH_PASS: surface_id", result_ws_pass["surface_id"], "chat_session")

    # --- 样例 7: evolution_panel_multi_workspace PASS ---
    print("自测样例 7: evolution_panel_multi_workspace PASS")
    multi_ws_scenario_def = {
        "scenario_id": "evolution_panel_multi_workspace",
        "surface_id": "evolution_workspace",
        "required_evidence_keys": [
            "evolution_recompute_key=evolution_timeline_recompute_ms",
            "evolution_tier_change_key=evolution_monitor tier_change",
            "memory_snapshot_key=memory_snapshot",
            "multi_workspace_event=evolution_multi_workspace_sample",
        ],
        "required_event_fields": [
            {
                "event_key": "multi_workspace_event=evolution_multi_workspace_sample",
                "fields": ["project", "workspace", "scenario", "surface", "workspace_context", "cycle_id"],
            }
        ],
        "metrics": [
            {
                "metric_id": "evolution_timeline_recompute_p95_ms",
                "log_pattern": "perf evolution_timeline_recompute_ms=",
                "value_key": "evolution_timeline_recompute_ms",
                "warn_limit": 60.0,
                "fail_limit": 250.0,
            }
        ],
    }
    multi_ws_pass_log = "\n".join([
        "evolution_recompute_key=evolution_timeline_recompute_ms",
        "evolution_tier_change_key=evolution_monitor tier_change",
        "memory_snapshot_key=memory_snapshot",
        "multi_workspace_event=evolution_multi_workspace_sample scenario=evolution_panel_multi_workspace project=perf-fixture-project workspace=perf-fixture-workspace surface=evolution_workspace workspace_context=AC-EVOLUTION-MULTI cycle_id=fixture-evolution-cycle",
    ] + [
        f"perf evolution_timeline_recompute_ms={30.0:.2f} round={i + 1} workspace=ws-{i % 3}"
        for i in range(90)
    ])
    result_multi_pass = decide_scenario(multi_ws_scenario_def, multi_ws_pass_log, evidence_file_exists=True)
    expect("MULTI_WS_PASS: overall", result_multi_pass["overall"], "pass")
    expect("MULTI_WS_PASS: surface_id", result_multi_pass["surface_id"], "evolution_workspace")

    # --- 样例 8: evolution_panel_multi_workspace FAIL (缺 multi_workspace_event 证据键) ---
    print("自测样例 8: evolution_panel_multi_workspace FAIL (missing multi_workspace_event)")
    multi_ws_fail_log = "\n".join([
        "evolution_recompute_key=evolution_timeline_recompute_ms",
        "evolution_tier_change_key=evolution_monitor tier_change",
        "memory_snapshot_key=memory_snapshot",
        # multi_workspace_event=evolution_multi_workspace_sample 缺失
        "perf evolution_timeline_recompute_ms=30.0 round=1 workspace=ws-0",
    ])
    result_multi_fail = decide_scenario(multi_ws_scenario_def, multi_ws_fail_log, evidence_file_exists=True)
    expect("MULTI_WS_FAIL: overall", result_multi_fail["overall"], "fail")
    expect("MULTI_WS_FAIL: has missing_evidence reason", str("missing_evidence" in result_multi_fail["reason_codes"]), "True")

    # --- 样例 9: 旧格式 baselines 不含 surface_id 时，decide_scenario 不崩溃（向后兼容）---
    print("自测样例 9: 旧格式 baselines 不含 surface_id（向后兼容）")
    legacy_scenario_def = {
        "scenario_id": "evolution_panel",
        # 故意不含 surface_id 字段
        "required_evidence_keys": [
            "evolution_recompute_key=evolution_timeline_recompute_ms",
            "evolution_tier_change_key=evolution_monitor tier_change",
            "memory_snapshot_key=memory_snapshot",
        ],
        "metrics": [
            {
                "metric_id": "evolution_timeline_recompute_p95_ms",
                "log_pattern": "perf evolution_timeline_recompute_ms=",
                "value_key": "evolution_timeline_recompute_ms",
                "warn_limit": 50.0,
                "fail_limit": 200.0,
            }
        ],
    }
    legacy_log = "\n".join([
        "evolution_recompute_key=evolution_timeline_recompute_ms",
        "evolution_tier_change_key=evolution_monitor tier_change",
        "memory_snapshot_key=memory_snapshot",
        "perf evolution_timeline_recompute_ms=20.0 round=1",
    ])
    try:
        result_legacy = decide_scenario(legacy_scenario_def, legacy_log, evidence_file_exists=True)
        expect("LEGACY_COMPAT: overall", result_legacy["overall"], "pass")
        expect("LEGACY_COMPAT: surface_id defaults to unknown", result_legacy["surface_id"], "unknown")
        print("  OK  LEGACY_COMPAT: 旧格式不崩溃")
    except Exception as exc:
        failures.append(f"LEGACY_COMPAT: 旧格式 scenario 导致崩溃: {exc}")

    # --- 样例 10: chat_stream_workspace_switch FAIL (证据文件不存在 — WI-002 真实证据要求) ---
    print("自测样例 10: chat_stream_workspace_switch FAIL (evidence_file_missing)")
    result_ws_no_file = decide_scenario(ws_switch_scenario_def, "", evidence_file_exists=False)
    expect("WS_SWITCH_NO_FILE: overall", result_ws_no_file["overall"], "fail")
    expect("WS_SWITCH_NO_FILE: reason evidence_file_missing",
           str("evidence_file_missing" in result_ws_no_file["reason_codes"]), "True")

    # --- 样例 11: evolution_panel_multi_workspace FAIL (证据文件不存在 — WI-002 真实证据要求) ---
    print("自测样例 11: evolution_panel_multi_workspace FAIL (evidence_file_missing)")
    result_multi_no_file = decide_scenario(multi_ws_scenario_def, "", evidence_file_exists=False)
    expect("MULTI_WS_NO_FILE: overall", result_multi_no_file["overall"], "fail")
    expect("MULTI_WS_NO_FILE: reason evidence_file_missing",
           str("evidence_file_missing" in result_multi_no_file["reason_codes"]), "True")

    # --- 样例 12: chat_stream_workspace_switch FAIL (缺 workspace_switch 证据键但文件存在) ---
    print("自测样例 12: chat_stream_workspace_switch FAIL (missing workspace_switch_event)")
    ws_switch_missing_key_log = "\n".join([
        "hotspot_key=ios_ai_chat",
        "tail_flush_event=aiMessageTailFlush",
        "memory_snapshot_key=memory_snapshot",
        # workspace_switch_event=workspace_switch 缺失
        "perf aiMessageTailFlush duration_ms=40.000 idx=0",
    ])
    result_ws_missing_key = decide_scenario(ws_switch_scenario_def, ws_switch_missing_key_log, evidence_file_exists=True)
    expect("WS_SWITCH_MISSING_KEY: overall", result_ws_missing_key["overall"], "fail")
    expect("WS_SWITCH_MISSING_KEY: has missing_evidence reason",
           str("missing_evidence" in result_ws_missing_key["reason_codes"]), "True")

    # --- 样例 13: chat_stream_workspace_switch FAIL (事件缺少归属字段) ---
    print("自测样例 13: chat_stream_workspace_switch FAIL (missing event fields)")
    ws_switch_missing_fields_log = "\n".join([
        "hotspot_key=ios_ai_chat",
        "tail_flush_event=aiMessageTailFlush",
        "memory_snapshot_key=memory_snapshot",
        "workspace_switch_event=workspace_switch scenario=chat_stream_workspace_switch project=PerfLab workspace=stream-heavy",
        "perf aiMessageTailFlush duration_ms=40.000 idx=0",
    ])
    result_ws_missing_fields = decide_scenario(ws_switch_scenario_def, ws_switch_missing_fields_log, evidence_file_exists=True)
    expect("WS_SWITCH_MISSING_FIELDS: overall", result_ws_missing_fields["overall"], "fail")
    expect("WS_SWITCH_MISSING_FIELDS: has missing_event_fields reason",
           str("missing_event_fields" in result_ws_missing_fields["reason_codes"]), "True")

    # --- 样例 14: terminal_output PASS ---
    print("自测样例 14: terminal_output PASS")
    terminal_scenario_def = {
        "scenario_id": "terminal_output",
        "surface_id": "terminal_output",
        "required_evidence_keys": [
            "terminal_flush_event=terminal_output_flush",
            "memory_snapshot_key=memory_snapshot",
        ],
        "required_event_fields": [{
            "event_key": "terminal_flush_event=terminal_output_flush",
            "fields": ["project", "workspace", "scenario", "surface", "workspace_context", "term_id"],
        }],
        "metrics": [{
            "metric_id": "terminalOutputFlush_p95_ms",
            "log_pattern": "perf terminalOutputFlush",
            "value_key": "duration_ms",
            "warn_limit": 50.0,
            "fail_limit": 200.0,
        }],
    }
    terminal_pass_log = "\n".join([
        "terminal_flush_event=terminal_output_flush scenario=terminal_output project=perf-fixture-project workspace=perf-fixture-workspace surface=terminal_output workspace_context=AC-TERMINAL-PERF-FIXTURE term_id=fixture-term-001",
        "memory_snapshot_key=memory_snapshot",
    ] + [
        f"perf terminalOutputFlush duration_ms={1.0 + i * 0.05:.3f} scenario=terminal_output project=perf-fixture-project workspace=perf-fixture-workspace workspace_context=AC-TERMINAL-PERF-FIXTURE term_id=fixture-term-001"
        for i in range(20)
    ])
    result_terminal_pass = decide_scenario(terminal_scenario_def, terminal_pass_log, evidence_file_exists=True)
    expect("TERMINAL_PASS: overall", result_terminal_pass["overall"], "pass")

    # --- 样例 15: terminal_output FAIL（missing term_id） ---
    print("自测样例 15: terminal_output FAIL (missing term_id)")
    terminal_missing_term_log = "\n".join([
        "terminal_flush_event=terminal_output_flush scenario=terminal_output project=perf-fixture-project workspace=perf-fixture-workspace surface=terminal_output workspace_context=AC-TERMINAL-PERF-FIXTURE",
        "memory_snapshot_key=memory_snapshot",
        "perf terminalOutputFlush duration_ms=1.00 scenario=terminal_output project=perf-fixture-project workspace=perf-fixture-workspace workspace_context=AC-TERMINAL-PERF-FIXTURE",
    ])
    result_terminal_missing_term = decide_scenario(terminal_scenario_def, terminal_missing_term_log, evidence_file_exists=True)
    expect("TERMINAL_MISSING_TERM: overall", result_terminal_missing_term["overall"], "fail")
    expect("TERMINAL_MISSING_TERM: has missing_event_fields reason",
           str("missing_event_fields" in result_terminal_missing_term["reason_codes"]), "True")

    # --- 样例 16: git_panel PASS ---
    print("自测样例 16: git_panel PASS")
    git_scenario_def = {
        "scenario_id": "git_panel",
        "surface_id": "git_panel",
        "required_evidence_keys": [
            "git_panel_projection_event=git_panel_projection",
            "memory_snapshot_key=memory_snapshot",
        ],
        "required_event_fields": [
            {
                "event_key": "git_panel_projection_event=git_panel_projection",
                "fields": ["project", "workspace", "scenario", "surface", "workspace_context"],
            },
            {
                "event_key": "perf gitPanelProjection",
                "fields": ["project", "workspace", "scenario", "workspace_context", "staged_count", "unstaged_count", "untracked_count", "item_count"],
            },
        ],
        "metrics": [{
            "metric_id": "gitPanelProjection_p95_ms",
            "log_pattern": "perf gitPanelProjection",
            "value_key": "duration_ms",
            "warn_limit": 50.0,
            "fail_limit": 200.0,
        }],
    }
    git_pass_log = "\n".join([
        "git_panel_projection_event=git_panel_projection scenario=git_panel project=perf-fixture-project workspace=perf-fixture-workspace surface=git_panel workspace_context=AC-GIT-PANEL-PERF-FIXTURE",
        "memory_snapshot_key=memory_snapshot",
    ] + [
        f"perf gitPanelProjection duration_ms={1.5 + i * 0.08:.3f} scenario=git_panel project=perf-fixture-project workspace=perf-fixture-workspace workspace_context=AC-GIT-PANEL-PERF-FIXTURE staged_count=3 unstaged_count=5 untracked_count=0 item_count=8"
        for i in range(20)
    ])
    result_git_pass = decide_scenario(git_scenario_def, git_pass_log, evidence_file_exists=True)
    expect("GIT_PANEL_PASS: overall", result_git_pass["overall"], "pass")

    # --- 样例 17: git_panel FAIL（missing untracked_count） ---
    print("自测样例 17: git_panel FAIL (missing untracked_count)")
    git_missing_field_log = "\n".join([
        "git_panel_projection_event=git_panel_projection scenario=git_panel project=perf-fixture-project workspace=perf-fixture-workspace surface=git_panel workspace_context=AC-GIT-PANEL-PERF-FIXTURE",
        "memory_snapshot_key=memory_snapshot",
        "perf gitPanelProjection duration_ms=1.50 scenario=git_panel project=perf-fixture-project workspace=perf-fixture-workspace workspace_context=AC-GIT-PANEL-PERF-FIXTURE staged_count=3 unstaged_count=5 item_count=8",
    ])
    result_git_missing_field = decide_scenario(git_scenario_def, git_missing_field_log, evidence_file_exists=True)
    expect("GIT_PANEL_MISSING_FIELD: overall", result_git_missing_field["overall"], "fail")
    expect("GIT_PANEL_MISSING_FIELD: has missing_event_fields reason",
           str("missing_event_fields" in result_git_missing_field["reason_codes"]), "True")

    # --- 样例 18: terminal_output_multi_workspace PASS ---
    print("自测样例 18: terminal_output_multi_workspace PASS")
    terminal_mw_scenario_def = {
        "scenario_id": "terminal_output_multi_workspace",
        "surface_id": "terminal_output",
        "required_evidence_keys": [
            "terminal_flush_event=terminal_output_flush",
            "memory_snapshot_key=memory_snapshot",
            "multi_workspace_event=terminal_multi_workspace_sample",
        ],
        "required_event_fields": [
            {
                "event_key": "terminal_flush_event=terminal_output_flush",
                "fields": ["project", "workspace", "scenario", "surface", "workspace_context", "term_id"],
            },
            {
                "event_key": "multi_workspace_event=terminal_multi_workspace_sample",
                "fields": ["project", "workspace", "scenario", "surface", "workspace_context", "term_id"],
            }
        ],
        "metrics": [{
            "metric_id": "terminalOutputFlush_p95_ms",
            "log_pattern": "perf terminalOutputFlush",
            "value_key": "duration_ms",
            "warn_limit": 60.0,
            "fail_limit": 250.0,
        }],
    }
    terminal_mw_pass_log = "\n".join([
        "terminal_flush_event=terminal_output_flush scenario=terminal_output_multi_workspace project=perf-fixture-project workspace=perf-fixture-workspace surface=terminal_output workspace_context=AC-TERMINAL-MULTI-WS term_id=fixture-term-mw-0",
        "memory_snapshot_key=memory_snapshot",
        "multi_workspace_event=terminal_multi_workspace_sample scenario=terminal_output_multi_workspace project=perf-fixture-project workspace=perf-fixture-workspace surface=terminal_output workspace_context=AC-TERMINAL-MULTI-WS term_id=fixture-term-mw-0",
    ] + [
        f"perf terminalOutputFlush duration_ms={1.0 + i * 0.05:.3f} scenario=terminal_output_multi_workspace project=perf-fixture-project workspace=perf-fixture-workspace workspace_context=AC-TERMINAL-MULTI-WS term_id=fixture-term-mw-0"
        for i in range(20)
    ])
    result_terminal_mw = decide_scenario(terminal_mw_scenario_def, terminal_mw_pass_log, evidence_file_exists=True)
    expect("TERMINAL_MW_PASS: overall", result_terminal_mw["overall"], "pass")

    # --- 样例 19: git_panel_multi_workspace PASS ---
    print("自测样例 19: git_panel_multi_workspace PASS")
    git_mw_scenario_def = {
        "scenario_id": "git_panel_multi_workspace",
        "surface_id": "git_panel",
        "required_evidence_keys": [
            "git_panel_projection_event=git_panel_projection",
            "memory_snapshot_key=memory_snapshot",
            "multi_workspace_event=git_panel_multi_workspace_sample",
        ],
        "required_event_fields": [
            {
                "event_key": "git_panel_projection_event=git_panel_projection",
                "fields": ["project", "workspace", "scenario", "surface", "workspace_context"],
            },
            {
                "event_key": "multi_workspace_event=git_panel_multi_workspace_sample",
                "fields": ["project", "workspace", "scenario", "surface", "workspace_context"],
            },
            {
                "event_key": "perf gitPanelProjection",
                "fields": ["project", "workspace", "scenario", "workspace_context", "staged_count", "unstaged_count", "untracked_count", "item_count"],
            }
        ],
        "metrics": [{
            "metric_id": "gitPanelProjection_p95_ms",
            "log_pattern": "perf gitPanelProjection",
            "value_key": "duration_ms",
            "warn_limit": 60.0,
            "fail_limit": 250.0,
        }],
    }
    git_mw_pass_log = "\n".join([
        "git_panel_projection_event=git_panel_projection scenario=git_panel_multi_workspace project=perf-fixture-project workspace=perf-fixture-workspace surface=git_panel workspace_context=AC-GIT-PANEL-MULTI-WS",
        "memory_snapshot_key=memory_snapshot",
        "multi_workspace_event=git_panel_multi_workspace_sample scenario=git_panel_multi_workspace project=perf-fixture-project workspace=perf-fixture-workspace surface=git_panel workspace_context=AC-GIT-PANEL-MULTI-WS",
    ] + [
        f"perf gitPanelProjection duration_ms={1.5 + i * 0.08:.3f} scenario=git_panel_multi_workspace project=perf-fixture-project workspace=perf-fixture-workspace workspace_context=AC-GIT-PANEL-MULTI-WS staged_count=3 unstaged_count=5 untracked_count=0 item_count=8"
        for i in range(20)
    ])
    result_git_mw = decide_scenario(git_mw_scenario_def, git_mw_pass_log, evidence_file_exists=True)
    expect("GIT_MW_PASS: overall", result_git_mw["overall"], "pass")

    if failures:
        print("\n自测失败:")
        for f in failures:
            print(f"  FAIL: {f}")
        return 1
    print("\n所有自测样例通过")
    return 0


# ---------------------------------------------------------------------------
# CLI 入口
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Apple 客户端性能基线比较器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--baseline",
        default="scripts/tools/apple_client_perf_baselines.json",
        help="基线 JSON 路径（默认: scripts/tools/apple_client_perf_baselines.json）",
    )
    parser.add_argument(
        "--evidence-dir",
        default="build/perf",
        help="证据日志目录（默认: build/perf）",
    )
    parser.add_argument(
        "--report",
        default="build/perf/apple-client-regression-report.json",
        help="输出报告路径（默认: build/perf/apple-client-regression-report.json）",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="同时向 stdout 输出可机读 JSON 报告",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="执行内置 pass/warn/fail 样例驱动验证并退出",
    )
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test())

    sys.exit(run_comparison(
        baseline_path=args.baseline,
        evidence_dir=args.evidence_dir,
        report_path=args.report,
        json_output=args.json_output,
    ))


if __name__ == "__main__":
    main()
