#!/usr/bin/env python3
"""
热点性能回归比较器

读取 core/benches/baselines/hotspot_regression.json（基线契约）
与守卫二进制输出的 hotspot-measurements.json（实测结果），
按 scenario_id 精确比较，输出机器可读的比较报告。

## 输出 schema
- suite_id
- overall: pass | warn | fail
- scenario_results[]: scenario_id, status, baseline_ns, measured_ns,
                      ratio, absolute_budget_ns, reason_codes[]
- generated_at
- warnings[]

## 裁决规则
- measured_ns > baseline_ns * fail_ratio_limit  → fail（reason: ratio_exceeded_fail）
- measured_ns > absolute_budget_ns              → fail（reason: absolute_budget_exceeded）
- measured_ns > baseline_ns * warn_ratio_limit  → warn（reason: ratio_exceeded_warn）
- otherwise                                     → pass

warn 不阻断门禁（exit 0），fail 阻断（exit 1）。

## 用法
    python3 scripts/tools/check_hotspot_perf_regression.py \\
        --baseline core/benches/baselines/hotspot_regression.json \\
        --measurements build/perf/hotspot-measurements.json \\
        --report build/perf/hotspot-regression-report.json \\
        [--json] [--self-test]

## 自测模式（WI-004）
    python3 scripts/tools/check_hotspot_perf_regression.py --self-test
    验证内置的 pass/warn/fail/missing/budget 样例是否按预期裁决，exit 0 表示全部通过。
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "1"
TOOL_VERSION = "1.0.0"


def load_json(path: str) -> Any:
    p = Path(path)
    if not p.exists():
        print(f"[check_hotspot_perf_regression] 错误: 文件不存在: {path}", file=sys.stderr)
        sys.exit(2)
    with p.open(encoding="utf-8") as f:
        return json.load(f)


def decide_scenario(
    scenario_id: str,
    measured_ns: int,
    baseline_ns: int,
    warn_ratio: float,
    fail_ratio: float,
    absolute_budget_ns: int,
) -> tuple[str, list[str]]:
    """返回 (status, reason_codes)。status: pass | warn | fail"""
    reason_codes: list[str] = []
    status = "pass"

    ratio = measured_ns / baseline_ns if baseline_ns > 0 else float("inf")

    if ratio > fail_ratio:
        status = "fail"
        reason_codes.append("ratio_exceeded_fail")

    if measured_ns > absolute_budget_ns:
        status = "fail"
        reason_codes.append("absolute_budget_exceeded")

    if status != "fail" and ratio > warn_ratio:
        status = "warn"
        reason_codes.append("ratio_exceeded_warn")

    return status, reason_codes


def run(
    baseline_path: str,
    measurements_path: str,
    report_path: str,
    json_output: bool,
) -> int:
    baseline = load_json(baseline_path)
    measurements = load_json(measurements_path)

    # 基线 schema 校验
    if baseline.get("schema_version") != SCHEMA_VERSION:
        print(
            f"[check_hotspot_perf_regression] 错误: 基线 schema_version 不兼容: "
            f"期望 '{SCHEMA_VERSION}'，实际 '{baseline.get('schema_version')}'",
            file=sys.stderr,
        )
        sys.exit(2)

    suite_id = baseline.get("suite_id", "hotspot_perf_guard")

    # 构建基线查找表
    baseline_by_id: dict[str, dict] = {}
    for s in baseline.get("scenarios", []):
        sid = s["scenario_id"]
        if sid in baseline_by_id:
            print(
                f"[check_hotspot_perf_regression] 错误: 基线文件存在重复 scenario_id: {sid}",
                file=sys.stderr,
            )
            sys.exit(2)
        baseline_by_id[sid] = s

    # 构建实测查找表
    measured_by_id: dict[str, dict] = {}
    for s in measurements.get("scenarios", []):
        measured_by_id[s["scenario_id"]] = s

    scenario_results: list[dict] = []
    overall = "pass"
    warnings: list[str] = []

    for sid, bline in baseline_by_id.items():
        if sid not in measured_by_id:
            # 缺失场景：记为 fail
            scenario_results.append(
                {
                    "scenario_id": sid,
                    "status": "fail",
                    "baseline_ns": bline["baseline_ns"],
                    "measured_ns": None,
                    "ratio": None,
                    "absolute_budget_ns": bline["absolute_budget_ns"],
                    "reason_codes": ["scenario_missing"],
                }
            )
            overall = "fail"
            continue

        m = measured_by_id[sid]
        measured_ns: int = m["measured_ns"]
        baseline_ns: int = bline["baseline_ns"]
        warn_ratio: float = float(bline["warn_ratio_limit"])
        fail_ratio: float = float(bline["fail_ratio_limit"])
        absolute_budget_ns: int = bline["absolute_budget_ns"]

        ratio = measured_ns / baseline_ns if baseline_ns > 0 else float("inf")
        status, reason_codes = decide_scenario(
            sid, measured_ns, baseline_ns, warn_ratio, fail_ratio, absolute_budget_ns
        )

        scenario_results.append(
            {
                "scenario_id": sid,
                "status": status,
                "baseline_ns": baseline_ns,
                "measured_ns": measured_ns,
                "ratio": round(ratio, 4),
                "absolute_budget_ns": absolute_budget_ns,
                "reason_codes": reason_codes,
            }
        )

        if status == "fail":
            overall = "fail"
        elif status == "warn" and overall == "pass":
            overall = "warn"

        if status in ("warn", "fail"):
            warn_msg = (
                f"{sid}: {status.upper()} "
                f"measured={measured_ns}ns baseline={baseline_ns}ns "
                f"ratio={ratio:.2f} budget={absolute_budget_ns}ns "
                f"[{', '.join(reason_codes)}]"
            )
            warnings.append(warn_msg)

    report: dict = {
        "suite_id": suite_id,
        "overall": overall,
        "scenario_results": scenario_results,
        "generated_at": datetime.now(tz=timezone.utc).isoformat(),
        "warnings": warnings,
    }

    # 写出报告
    report_file = Path(report_path)
    report_file.parent.mkdir(parents=True, exist_ok=True)
    with report_file.open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    if json_output:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        _print_text_summary(report)

    return 0 if overall != "fail" else 1


def _print_text_summary(report: dict) -> None:
    print(f"[check_hotspot_perf_regression] ===== 性能回归摘要 =====")
    print(f"  suite_id : {report['suite_id']}")
    print(f"  overall  : {report['overall']}")
    print(f"  generated: {report['generated_at']}")
    print()
    for r in report["scenario_results"]:
        status_str = r["status"].upper()
        sid = r["scenario_id"]
        if r["measured_ns"] is not None:
            ratio_str = f"{r['ratio']:.2f}x" if r["ratio"] is not None else "N/A"
            print(
                f"  {status_str:4s}  {sid}  "
                f"measured={r['measured_ns']}ns  baseline={r['baseline_ns']}ns  "
                f"ratio={ratio_str}"
            )
        else:
            print(f"  {status_str:4s}  {sid}  [MISSING]")
        if r["reason_codes"]:
            print(f"        reason_codes: {r['reason_codes']}")
    print()
    if report["warnings"]:
        print(f"  ⚠️  告警 ({len(report['warnings'])} 条):")
        for w in report["warnings"]:
            print(f"     - {w}")
    print(f"[check_hotspot_perf_regression] =====================")


def run_self_test() -> int:
    """
    验证 decide_scenario 对内置的 pass/warn/fail/missing/budget 样例能正确裁决。
    exit 0 → 全部通过；exit 1 → 有失败。
    """
    failures: list[str] = []

    def expect(label: str, actual: str, expected: str) -> None:
        if actual != expected:
            failures.append(f"{label}: 期望 {expected}，实际 {actual}")
        else:
            print(f"  OK  {label}: {actual}")

    baseline_ns = 1_000_000
    warn_ratio = 2.0
    fail_ratio = 10.0
    absolute_budget_ns = 5_000_000

    # --- 样例 1: PASS ---
    print("自测样例 1: PASS")
    status, codes = decide_scenario("test_pass", 800_000, baseline_ns, warn_ratio, fail_ratio, absolute_budget_ns)
    expect("PASS: status", status, "pass")
    expect("PASS: no reason_codes", str(codes), "[]")

    # --- 样例 2: WARN (ratio 超过 warn_ratio 但未超 fail_ratio) ---
    print("自测样例 2: WARN (ratio_exceeded_warn)")
    status, codes = decide_scenario("test_warn", 2_500_000, baseline_ns, warn_ratio, fail_ratio, absolute_budget_ns)
    expect("WARN: status", status, "warn")
    expect("WARN: reason ratio_exceeded_warn", str("ratio_exceeded_warn" in codes), "True")

    # --- 样例 3: FAIL (ratio 超过 fail_ratio) ---
    print("自测样例 3: FAIL (ratio_exceeded_fail)")
    status, codes = decide_scenario("test_fail_ratio", 12_000_000, baseline_ns, warn_ratio, fail_ratio, absolute_budget_ns)
    expect("FAIL_RATIO: status", status, "fail")
    expect("FAIL_RATIO: reason ratio_exceeded_fail", str("ratio_exceeded_fail" in codes), "True")

    # --- 样例 4: FAIL (超过 absolute_budget_ns) ---
    print("自测样例 4: FAIL (absolute_budget_exceeded)")
    status, codes = decide_scenario("test_fail_budget", 6_000_000, baseline_ns, warn_ratio, fail_ratio, absolute_budget_ns)
    expect("FAIL_BUDGET: status", status, "fail")
    expect("FAIL_BUDGET: reason absolute_budget_exceeded", str("absolute_budget_exceeded" in codes), "True")

    # --- 样例 5: FAIL (scenario_missing) 通过 run() 层覆盖 ---
    print("自测样例 5: FAIL (scenario_missing) — 验证 run() 缺失场景路径")
    import tempfile, os
    # 基线含一个场景，实测不包含它
    baseline = {
        "schema_version": SCHEMA_VERSION,
        "suite_id": "hotspot_perf_guard",
        "scenarios": [{
            "scenario_id": "missing_scenario",
            "baseline_ns": 1_000_000,
            "warn_ratio_limit": 2.0,
            "fail_ratio_limit": 10.0,
            "absolute_budget_ns": 5_000_000,
        }],
    }
    measurements = {"scenarios": []}
    with tempfile.TemporaryDirectory() as tmp:
        bl_path = os.path.join(tmp, "baseline.json")
        meas_path = os.path.join(tmp, "measurements.json")
        rep_path = os.path.join(tmp, "report.json")
        with open(bl_path, "w") as f:
            import json as _json
            _json.dump(baseline, f)
        with open(meas_path, "w") as f:
            _json.dump(measurements, f)
        ec = run(bl_path, meas_path, rep_path, json_output=False)
        expect("MISSING: exit_code non-zero", str(ec != 0), "True")
        with open(rep_path) as f:
            report = _json.load(f)
        expect("MISSING: overall fail", report["overall"], "fail")
        sr = report["scenario_results"][0]
        expect("MISSING: reason scenario_missing", str("scenario_missing" in sr["reason_codes"]), "True")

    if failures:
        print("\n自测失败:")
        for f in failures:
            print(f"  FAIL: {f}")
        return 1
    print("\n所有自测样例通过")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="热点性能回归比较器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--baseline",
        default="core/benches/baselines/hotspot_regression.json",
        help="基线文件路径（默认: core/benches/baselines/hotspot_regression.json）",
    )
    parser.add_argument(
        "--measurements",
        default="build/perf/hotspot-measurements.json",
        help="守卫输出的实测文件路径（默认: build/perf/hotspot-measurements.json）",
    )
    parser.add_argument(
        "--report",
        default="build/perf/hotspot-regression-report.json",
        help="比较报告输出路径（默认: build/perf/hotspot-regression-report.json）",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="以 JSON 格式打印报告到 stdout",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="执行内置 pass/warn/fail/missing/budget 样例驱动验证并退出",
    )
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test())

    exit_code = run(
        baseline_path=args.baseline,
        measurements_path=args.measurements,
        report_path=args.report,
        json_output=args.json_output,
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
