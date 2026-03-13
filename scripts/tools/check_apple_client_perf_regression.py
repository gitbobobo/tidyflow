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
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "1"
TOOL_VERSION = "1.0.0"


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
    required_keys: list[str] = scenario.get("required_evidence_keys", [])
    metrics: list[dict] = scenario.get("metrics", [])

    issues: list[str] = []
    reason_codes: list[str] = []
    overall = "pass"
    metric_results: list[dict] = []
    missing_keys: list[str] = []

    if not evidence_file_exists:
        overall = "fail"
        reason_codes.append("evidence_file_missing")
        issues.append(f"场景 {scenario_id} 证据日志文件不存在")
        return {
            "scenario_id": scenario_id,
            "overall": overall,
            "reason_codes": reason_codes,
            "metrics": [],
            "missing_evidence_keys": [],
            "issues": issues,
        }

    # 必需证据键检查
    for key in required_keys:
        if not check_evidence_key_present(log_text, key):
            missing_keys.append(key)

    if missing_keys:
        overall = "fail"
        reason_codes.append("missing_evidence")
        issues.append(f"缺少必需证据键: {', '.join(missing_keys)}")

    # 数值指标检查
    for metric in metrics:
        metric_id: str = metric["metric_id"]
        log_pattern: str = metric["log_pattern"]
        value_key: str = metric["value_key"]
        warn_limit: float = float(metric.get("warn_limit", float("inf")))
        fail_limit: float = float(metric.get("fail_limit", float("inf")))

        samples = extract_metric_samples(log_text, log_pattern, value_key)
        if not samples:
            # 无样本 → 记 warn（日志可能因场景简化未采集到样本）
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
            "status": metric_status,
            "reason": metric_reason,
            "p95_ms": round(p95, 3) if p95 is not None else None,
            "sample_count": len(samples),
            "warn_limit": warn_limit,
            "fail_limit": fail_limit,
        })

    return {
        "scenario_id": scenario_id,
        "overall": overall,
        "reason_codes": list(dict.fromkeys(reason_codes)),
        "metrics": metric_results,
        "missing_evidence_keys": missing_keys,
        "issues": issues,
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
        "tool_version": TOOL_VERSION,
        "suite_id": baseline.get("suite_id", "apple_client_perf"),
        "overall": overall,
        "scenarios": scenario_results,
        "warnings": warnings,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "baseline_path": str(baseline_file.resolve()),
        "evidence_dir": str(evidence_dir_path.resolve()),
    }

    report_path_obj = Path(report_path)
    report_path_obj.parent.mkdir(parents=True, exist_ok=True)
    report_path_obj.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

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
