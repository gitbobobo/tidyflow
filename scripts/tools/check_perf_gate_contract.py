#!/usr/bin/env python3
"""
性能门禁契约工具

加载 performance_gate_contract.json，读取各 suite 比较器的报告，
合并生成统一性能门禁汇总报告 build/perf/performance-gate-report.json。

## 统一报告 schema
- $schema_version
- contract_version
- overall: pass | warn | fail
- release_blocking: bool
- reason_codes[]: 所有阻断原因码
- warnings[]: 所有非阻断告警
- suites[]: 每个 suite 的汇总结果
- report_paths: 各报告路径映射
- project / workspace / cycle_id / run_id
- generated_at

## 阻断规则（来自契约 release_blocking_reason_codes）
- suite 报告缺失             → suite_report_missing → release_blocking=true
- suite overall=fail         → 对应原因码 → release_blocking=true
- suite 含阻断原因码         → release_blocking=true
- warn 仅记录告警，不阻断

## 用法
    python3 scripts/tools/check_perf_gate_contract.py \\
        --contract scripts/tools/performance_gate_contract.json \\
        --project tidyflow \\
        --workspace default \\
        --cycle-id <cycle_id> \\
        --run-id <run_id> \\
        --output build/perf/performance-gate-report.json \\
        [--json] [--self-test]

## 自测模式
    python3 scripts/tools/check_perf_gate_contract.py --self-test
    覆盖 pass/warn/fail/missing_evidence/suite_report_missing，并补充真实文件读取集成样例。
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

SCHEMA_VERSION = "1"
TOOL_VERSION = "1.0.0"


def load_contract(contract_path: str) -> dict[str, Any]:
    p = Path(contract_path)
    if not p.exists():
        print(f"[check_perf_gate_contract] 错误: 契约文件不存在: {contract_path}", file=sys.stderr)
        sys.exit(2)
    return json.loads(p.read_text(encoding="utf-8"))


def resolve_project_root(contract_path: str) -> Path:
    """根据契约文件位置解析项目根目录。"""
    contract_dir = Path(contract_path).resolve().parent
    return contract_dir.parent.parent


def _collect_suite_reason_codes(suite_report: dict[str, Any]) -> list[str]:
    """从 suite 报告中收集所有 reason_codes（兼容 hotspot 和 apple 两种格式）。"""
    codes: list[str] = []
    # hotspot_perf_guard 格式: scenario_results[].reason_codes
    for sr in suite_report.get("scenario_results", []):
        codes.extend(sr.get("reason_codes", []))
    # apple_client_perf 格式: scenarios[].reason_codes
    for sc in suite_report.get("scenarios", []):
        codes.extend(sc.get("reason_codes", []))
    return codes


def merge_suite_reports(
    contract: dict[str, Any],
    suite_reports: dict[str, Any | None],
    project: str = "",
    workspace: str = "",
    cycle_id: str = "",
    run_id: str = "",
) -> dict[str, Any]:
    """
    contract: 契约 dict
    suite_reports: {suite_id: report_dict 或 None（文件缺失）}
    返回统一汇总报告 dict（不含 generated_at，由调用方注入）。
    """
    blocking_codes_set: set[str] = set(contract.get("release_blocking_reason_codes", []))

    suite_results: list[dict[str, Any]] = []
    all_reason_codes: list[str] = []
    all_warnings: list[str] = []
    overall = "pass"
    release_blocking = False

    for suite_def in contract.get("suites", []):
        suite_id: str = suite_def["suite_id"]
        report_path: str = suite_def["report_path"]
        suite_report = suite_reports.get(suite_id)

        if suite_report is None:
            # 报告文件缺失
            suite_result: dict[str, Any] = {
                "suite_id": suite_id,
                "overall": "fail",
                "release_blocking": True,
                "reason_codes": ["suite_report_missing"],
                "warnings": [],
                "report_path": report_path,
            }
            all_reason_codes.append("suite_report_missing")
            release_blocking = True
            overall = "fail"
        else:
            suite_overall: str = suite_report.get("overall", "unknown")
            suite_warnings: list[str] = suite_report.get("warnings", [])
            suite_all_codes = _collect_suite_reason_codes(suite_report)

            # 找出属于阻断集合的 reason_codes
            blocking_found = [c for c in suite_all_codes if c in blocking_codes_set]
            # suite overall=fail 也视为阻断（即使 reason_codes 未完全标准化）
            suite_is_blocking = (suite_overall == "fail") or bool(blocking_found)

            if suite_is_blocking:
                release_blocking = True
                overall = "fail"
                suite_blocking_codes = blocking_found if blocking_found else ["fail"]
                all_reason_codes.extend(suite_blocking_codes)
                suite_result = {
                    "suite_id": suite_id,
                    "overall": suite_overall,
                    "release_blocking": True,
                    "reason_codes": list(dict.fromkeys(suite_blocking_codes)),
                    "warnings": suite_warnings,
                    "report_path": report_path,
                }
            elif suite_overall == "warn":
                if overall == "pass":
                    overall = "warn"
                all_warnings.extend(suite_warnings)
                suite_result = {
                    "suite_id": suite_id,
                    "overall": "warn",
                    "release_blocking": False,
                    "reason_codes": [],
                    "warnings": suite_warnings,
                    "report_path": report_path,
                }
            else:
                suite_result = {
                    "suite_id": suite_id,
                    "overall": suite_overall,
                    "release_blocking": False,
                    "reason_codes": [],
                    "warnings": suite_warnings,
                    "report_path": report_path,
                }

        suite_results.append(suite_result)

    report_paths: dict[str, str] = {s["suite_id"]: s["report_path"] for s in suite_results}
    report_paths["unified"] = contract.get("unified_report_path", "build/perf/performance-gate-report.json")

    return {
        "$schema_version": SCHEMA_VERSION,
        "contract_version": contract.get("contract_version", "unknown"),
        "overall": overall,
        "release_blocking": release_blocking,
        "reason_codes": list(dict.fromkeys(all_reason_codes)),
        "warnings": all_warnings,
        "suites": suite_results,
        "report_paths": report_paths,
        "project": project,
        "workspace": workspace,
        "cycle_id": cycle_id,
        "run_id": run_id,
    }


def load_suite_reports_from_contract(contract_path: str, contract: dict[str, Any]) -> dict[str, Any | None]:
    """按契约定义从文件系统读取 suite 报告。"""
    project_root = resolve_project_root(contract_path)
    suite_reports: dict[str, Any | None] = {}
    for suite_def in contract.get("suites", []):
        suite_id = suite_def["suite_id"]
        report_rel = suite_def["report_path"]
        report_abs = project_root / report_rel
        if report_abs.exists():
            try:
                suite_reports[suite_id] = json.loads(report_abs.read_text(encoding="utf-8"))
            except Exception as e:
                print(
                    f"[check_perf_gate_contract] 警告: 读取 suite 报告失败 {report_abs}: {e}",
                    file=sys.stderr,
                )
                suite_reports[suite_id] = None
        else:
            suite_reports[suite_id] = None
    return suite_reports


def run(
    contract_path: str,
    project: str,
    workspace: str,
    cycle_id: str,
    run_id: str,
    output_path: str,
    json_output: bool = False,
) -> int:
    """加载契约，读取各 suite 报告，生成统一报告，返回 exit code。"""
    contract = load_contract(contract_path)
    suite_reports = load_suite_reports_from_contract(contract_path, contract)

    unified = merge_suite_reports(
        contract=contract,
        suite_reports=suite_reports,
        project=project,
        workspace=workspace,
        cycle_id=cycle_id,
        run_id=run_id,
    )
    unified["generated_at"] = datetime.now(tz=timezone.utc).isoformat()

    output_p = Path(output_path)
    output_p.parent.mkdir(parents=True, exist_ok=True)
    output_p.write_text(json.dumps(unified, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    if json_output:
        print(json.dumps(unified, indent=2, ensure_ascii=False))
    else:
        _print_text_summary(unified)

    return 0 if not unified["release_blocking"] else 1


def _print_text_summary(report: dict[str, Any]) -> None:
    print("[check_perf_gate_contract] ===== 统一性能门禁摘要 =====")
    print(f"  contract_version : {report.get('contract_version')}")
    print(f"  overall          : {report.get('overall')}")
    print(f"  release_blocking : {report.get('release_blocking')}")
    print(f"  project          : {report.get('project')}")
    print(f"  workspace        : {report.get('workspace')}")
    print(f"  cycle_id         : {report.get('cycle_id')}")
    print()
    for suite in report.get("suites", []):
        blocking_str = "🔴 BLOCKING" if suite.get("release_blocking") else "✅"
        print(f"  {blocking_str}  [{suite['suite_id']}] overall={suite['overall']}")
        if suite.get("reason_codes"):
            print(f"         reason_codes: {suite['reason_codes']}")
        if suite.get("warnings"):
            print(f"         warnings: {suite['warnings']}")
    print()
    if report.get("reason_codes"):
        print(f"  阻断原因码: {report['reason_codes']}")
    if report.get("warnings"):
        print(f"  告警 ({len(report['warnings'])} 条):")
        for w in report["warnings"]:
            print(f"     - {w}")
    print("[check_perf_gate_contract] =============================")


# ---------------------------------------------------------------------------
# 自测模式（WI-004）
# ---------------------------------------------------------------------------

def _make_test_contract() -> dict[str, Any]:
    """生成内置自测契约（不依赖文件系统）。"""
    return {
        "contract_version": "1.0",
        "suites": [
            {"suite_id": "hotspot_perf_guard", "report_path": "build/perf/hotspot-regression-report.json"},
            {"suite_id": "apple_client_perf", "report_path": "build/perf/apple-client-regression-report.json"},
        ],
        "unified_report_path": "build/perf/performance-gate-report.json",
        "release_blocking_reason_codes": [
            "ratio_exceeded_fail",
            "absolute_budget_exceeded",
            "scenario_missing",
            "missing_evidence",
            "evidence_file_missing",
            "metric_exceeded_fail",
            "suite_report_missing",
            "contract_version_mismatch",
        ],
        "warn_only_reason_codes": ["ratio_exceeded_warn", "metric_exceeded_warn", "no_samples"],
    }


def _run_repo_report_integration_test(expect: Any, failures: list[str]) -> None:
    """读取仓库真实 build/perf 报告，覆盖路径解析与 JSON 加载链路。"""
    repo_root = Path(__file__).resolve().parents[2]
    contract_path = repo_root / "scripts/tools/performance_gate_contract.json"
    hotspot_report = repo_root / "build/perf/hotspot-regression-report.json"
    apple_report = repo_root / "build/perf/apple-client-regression-report.json"
    required_paths = [contract_path, hotspot_report, apple_report]
    missing_paths = [str(path) for path in required_paths if not path.exists()]
    if missing_paths:
        print("自测样例 6: INTEGRATION (repo build/perf) - SKIP")
        print(f"  跳过原因: 缺少真实报告文件 {missing_paths}")
        return

    print("自测样例 6: INTEGRATION (repo build/perf)")
    contract = load_contract(str(contract_path))
    suite_reports = load_suite_reports_from_contract(str(contract_path), contract)
    expect("INTEGRATION: resolved project_root", str(resolve_project_root(str(contract_path))), str(repo_root))
    expect("INTEGRATION: hotspot report loaded", suite_reports["hotspot_perf_guard"] is not None, True)
    expect("INTEGRATION: apple report loaded", suite_reports["apple_client_perf"] is not None, True)
    merged = merge_suite_reports(contract, suite_reports, project="tidyflow", workspace="default")
    expect("INTEGRATION: overall", merged["overall"], "pass")
    expect("INTEGRATION: release_blocking", merged["release_blocking"], False)
    expect("INTEGRATION: reason_codes empty", merged["reason_codes"], [])


def _run_temp_fs_integration_test(expect: Any, failures: list[str]) -> None:
    """构造最小项目目录，覆盖 contract_dir.parent.parent / exists / json.loads。"""
    print("自测样例 7: INTEGRATION (temp filesystem)")
    with TemporaryDirectory(prefix="perf-gate-contract-") as temp_dir:
        temp_root = Path(temp_dir)
        contract_path = temp_root / "scripts/tools/performance_gate_contract.json"
        hotspot_path = temp_root / "build/perf/hotspot-regression-report.json"
        apple_path = temp_root / "build/perf/apple-client-regression-report.json"

        contract_path.parent.mkdir(parents=True, exist_ok=True)
        hotspot_path.parent.mkdir(parents=True, exist_ok=True)

        contract = _make_test_contract()
        contract_path.write_text(json.dumps(contract, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        hotspot_path.write_text(
            json.dumps({"overall": "pass", "warnings": [], "scenario_results": []}, indent=2, ensure_ascii=False)
            + "\n",
            encoding="utf-8",
        )
        apple_path.write_text(
            json.dumps({"overall": "pass", "warnings": [], "scenarios": []}, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

        suite_reports = load_suite_reports_from_contract(str(contract_path), contract)
        expect(
            "TEMP_FS: resolved project_root",
            str(resolve_project_root(str(contract_path))),
            str(temp_root.resolve()),
        )
        expect("TEMP_FS: hotspot report loaded", suite_reports["hotspot_perf_guard"] is not None, True)
        expect("TEMP_FS: apple report loaded", suite_reports["apple_client_perf"] is not None, True)
        merged = merge_suite_reports(contract, suite_reports, project="tidyflow", workspace="default")
        expect("TEMP_FS: overall", merged["overall"], "pass")
        expect("TEMP_FS: release_blocking", merged["release_blocking"], False)
        expect("TEMP_FS: reason_codes empty", merged["reason_codes"], [])


def run_self_test() -> int:
    """
    内置自测，覆盖 pass/warn/fail/missing_evidence/suite_report_missing 五类关键分支。
    exit 0 → 全部通过；exit 1 → 有失败。
    """
    failures: list[str] = []
    contract = _make_test_contract()

    def expect(label: str, actual: Any, expected: Any) -> None:
        if actual != expected:
            failures.append(f"{label}: 期望 {expected!r}，实际 {actual!r}")
        else:
            print(f"  OK  {label}")

    # --- 样例 1: PASS（两个 suite 均 pass）---
    print("自测样例 1: PASS")
    reports: dict[str, Any | None] = {
        "hotspot_perf_guard": {"overall": "pass", "warnings": [], "scenario_results": []},
        "apple_client_perf": {"overall": "pass", "warnings": [], "scenarios": []},
    }
    r = merge_suite_reports(contract, reports, project="tidyflow", workspace="default")
    expect("PASS: overall", r["overall"], "pass")
    expect("PASS: release_blocking", r["release_blocking"], False)
    expect("PASS: reason_codes empty", r["reason_codes"], [])

    # --- 样例 2: WARN（hotspot warn，apple pass）---
    print("自测样例 2: WARN")
    reports = {
        "hotspot_perf_guard": {
            "overall": "warn",
            "warnings": ["file_index.filter: ratio=2.5x"],
            "scenario_results": [{"status": "warn", "reason_codes": ["ratio_exceeded_warn"]}],
        },
        "apple_client_perf": {"overall": "pass", "warnings": [], "scenarios": []},
    }
    r = merge_suite_reports(contract, reports)
    expect("WARN: overall", r["overall"], "warn")
    expect("WARN: release_blocking", r["release_blocking"], False)
    expect("WARN: reason_codes empty", r["reason_codes"], [])
    expect("WARN: has warnings", len(r["warnings"]) > 0, True)

    # --- 样例 3: FAIL（hotspot fail，含 ratio_exceeded_fail）---
    print("自测样例 3: FAIL (ratio_exceeded_fail)")
    reports = {
        "hotspot_perf_guard": {
            "overall": "fail",
            "warnings": [],
            "scenario_results": [{"status": "fail", "reason_codes": ["ratio_exceeded_fail"]}],
        },
        "apple_client_perf": {"overall": "pass", "warnings": [], "scenarios": []},
    }
    r = merge_suite_reports(contract, reports)
    expect("FAIL_RATIO: overall", r["overall"], "fail")
    expect("FAIL_RATIO: release_blocking", r["release_blocking"], True)
    expect("FAIL_RATIO: reason_codes has ratio_exceeded_fail", "ratio_exceeded_fail" in r["reason_codes"], True)

    # --- 样例 4: FAIL（apple evidence_file_missing）---
    print("自测样例 4: FAIL (missing_evidence / evidence_file_missing)")
    reports = {
        "hotspot_perf_guard": {"overall": "pass", "warnings": [], "scenario_results": []},
        "apple_client_perf": {
            "overall": "fail",
            "warnings": [],
            "scenarios": [
                {"scenario_id": "chat_stream", "overall": "fail", "reason_codes": ["evidence_file_missing"]}
            ],
        },
    }
    r = merge_suite_reports(contract, reports)
    expect("MISSING_EVIDENCE: overall", r["overall"], "fail")
    expect("MISSING_EVIDENCE: release_blocking", r["release_blocking"], True)
    expect("MISSING_EVIDENCE: reason_codes has evidence_file_missing", "evidence_file_missing" in r["reason_codes"], True)

    # --- 样例 5: FAIL（suite 报告文件不存在 → None）---
    print("自测样例 5: FAIL (suite_report_missing)")
    reports = {
        "hotspot_perf_guard": None,
        "apple_client_perf": {"overall": "pass", "warnings": [], "scenarios": []},
    }
    r = merge_suite_reports(contract, reports)
    expect("SUITE_MISSING: overall", r["overall"], "fail")
    expect("SUITE_MISSING: release_blocking", r["release_blocking"], True)
    expect("SUITE_MISSING: reason_codes has suite_report_missing", "suite_report_missing" in r["reason_codes"], True)
    expect("SUITE_MISSING: hotspot suite release_blocking True", r["suites"][0]["release_blocking"], True)

    _run_repo_report_integration_test(expect, failures)
    _run_temp_fs_integration_test(expect, failures)

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
        description="性能门禁契约工具：合并 suite 报告生成统一性能门禁汇总",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--contract",
        default="scripts/tools/performance_gate_contract.json",
        help="契约文件路径（默认: scripts/tools/performance_gate_contract.json）",
    )
    parser.add_argument(
        "--project",
        default="tidyflow",
        help="项目名（默认: tidyflow）",
    )
    parser.add_argument(
        "--workspace",
        default="default",
        help="工作区名（默认: default）",
    )
    parser.add_argument(
        "--cycle-id",
        default="",
        help="Evolution 循环 ID（可为空）",
    )
    parser.add_argument(
        "--run-id",
        default="",
        help="运行 ID（可为空）",
    )
    parser.add_argument(
        "--output",
        default="build/perf/performance-gate-report.json",
        help="统一报告输出路径（默认: build/perf/performance-gate-report.json）",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="同时向 stdout 输出统一报告 JSON",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="执行内置自测并退出（包含真实文件集成样例）",
    )
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test())

    sys.exit(run(
        contract_path=args.contract,
        project=args.project,
        workspace=args.workspace,
        cycle_id=args.cycle_id,
        run_id=args.run_id,
        output_path=args.output,
        json_output=args.json_output,
    ))


if __name__ == "__main__":
    main()
