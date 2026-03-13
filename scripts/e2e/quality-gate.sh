#!/usr/bin/env bash
# 统一质量门禁入口：所有链路（CLI / CI / release）共享的门禁契约。
#
# 门禁阶段划分：
#   protocol_check    - 协议一致性 / schema 同步 / 版本一致性
#   core_regression   - Core 单元测试与回归
#   system_health     - 系统健康快照判定（需 Core 运行时，dry-run 跳过）
#   evidence_integrity - 证据索引完整性校验
#   apple_regression  - Apple 多工作区定向回归（串行）
#   apple_build       - macOS / iOS Simulator 构建验证（串行）
#
# 所有结果显式携带 cycle_id / run_id / project / workspace 维度。
# 输出可机读 JSON 摘要到 stdout（--json 模式）或人类可读文本。
#
# v1.45: 质量门禁结果作为瓶颈分析引擎的输入之一
# Core 通过 build_analysis_summary() 将门禁裁决、健康 incident、观测聚合
# 和预测异常统一成工作区级瓶颈分析摘要（EvolutionAnalysisSummary）。
# 本脚本仍然独立运行门禁检查，但结果会被 Core 消费并标注
# project/workspace/cycle_id 归属维度，避免同名工作区串台。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

# 加载共享引导脚本（统一 TF_EVIDENCE_ROOT 解析）
# shellcheck source=scripts/e2e/fixtures/bootstrap.sh
source "$PROJECT_ROOT/scripts/e2e/fixtures/bootstrap.sh"

generate_run_id() {
    date -u +%Y%m%d-%H%M%S
}

# ============================================================================
# 参数解析
# ============================================================================

cycle_id=""
run_id=""
step="all"
dry_run=0
verify_only=0
project="${TF_PROJECT:-tidyflow}"
workspace="${TF_WORKSPACE:-default}"
json_output=0
skip_apple=0

print_usage() {
    cat <<'EOF'
用法: ./scripts/e2e/quality-gate.sh --cycle <cycle_id> [选项]

必填参数：
  --cycle <cycle_id>       Evolution 循环 ID

可选参数：
  --run-id <run_id>        运行 ID（默认取 cycle_id）
  --step <阶段>            执行阶段：all | protocol_check | core_regression |
                           performance_regression | system_health |
                           evidence_integrity | apple_regression |
                           apple_build（默认: all）
  --dry-run                干运行模式，仅打印将执行的命令
  --verify-only            跳过测试执行，仅运行证据校验
  --project <name>         项目名（默认: tidyflow）
  --workspace <name>       工作区名（默认: default）
  --json                   输出可机读 JSON 摘要
  --skip-apple             跳过 Apple 相关检查
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cycle)        cycle_id="${2:-}";    shift 2 ;;
        --run-id)       run_id="${2:-}";      shift 2 ;;
        --step)         step="${2:-all}";     shift 2 ;;
        --dry-run)      dry_run=1;            shift ;;
        --verify-only)  verify_only=1;        shift ;;
        --project)      project="${2:-}";     shift 2 ;;
        --workspace)    workspace="${2:-}";   shift 2 ;;
        --json)         json_output=1;        shift ;;
        --skip-apple)   skip_apple=1;         shift ;;
        -h|--help)      print_usage;          exit 0 ;;
        *)
            echo "[quality-gate] 未知参数: $1" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$cycle_id" ]]; then
    echo "[quality-gate] 错误: 缺少 --cycle" >&2
    exit 1
fi

[[ -z "$run_id" ]] && run_id="$cycle_id"

# ============================================================================
# 门禁结果收集
# ============================================================================

# 阶段结果数组（bash 3.2 兼容：使用变量前缀）
gate_result_protocol_check="skipped"
gate_result_core_regression="skipped"
gate_result_performance_regression="skipped"
gate_result_system_health="skipped"
gate_result_evidence_integrity="skipped"
gate_result_apple_regression="skipped"
gate_result_apple_build="skipped"
gate_overall="pass"
gate_failure_reasons=""
gate_warnings=""

record_phase_result() {
    local phase="$1"
    local result="$2"
    local detail="${3:-}"
    eval "gate_result_${phase}=${result}"
    if [[ "$result" == "fail" ]]; then
        gate_overall="fail"
        if [[ -n "$detail" ]]; then
            gate_failure_reasons="${gate_failure_reasons:+${gate_failure_reasons}; }${phase}: ${detail}"
        else
            gate_failure_reasons="${gate_failure_reasons:+${gate_failure_reasons}; }${phase}"
        fi
    fi
}

record_phase_warning() {
    local phase="$1"
    local detail="${2:-}"
    local msg="${phase}: ${detail}"
    gate_warnings="${gate_warnings:+${gate_warnings}; }${msg}"
}

should_run_phase() {
    local phase="$1"
    [[ "$step" == "all" || "$step" == "$phase" ]]
}

# ============================================================================
# 门禁摘要输出
# ============================================================================

emit_gate_summary() {
    local perf_gate_report="$PROJECT_ROOT/build/perf/performance-gate-report.json"
    local perf_structured_json
    # 构建结构化 performance_regression 节点
    if [[ $dry_run -eq 1 ]]; then
        perf_structured_json='{"overall":"pass","release_blocking":false,"contract_version":"1.0","reason_codes":[],"warnings":[],"report_path":"build/perf/performance-gate-report.json","suite_results":{"hotspot_perf_guard":"pass","apple_client_perf":"pass"}}'
    elif [[ -f "$perf_gate_report" ]]; then
        perf_structured_json="$(python3 - "$perf_gate_report" <<'PYEOF'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
out = {
    "overall": d.get("overall", "unknown"),
    "release_blocking": d.get("release_blocking", True),
    "contract_version": d.get("contract_version", "unknown"),
    "reason_codes": d.get("reason_codes", []),
    "warnings": d.get("warnings", []),
    "report_path": "build/perf/performance-gate-report.json",
    "suite_results": {s["suite_id"]: s.get("overall", "unknown") for s in d.get("suites", [])},
}
print(json.dumps(out))
PYEOF
        2>/dev/null || echo '{"overall":"unknown","release_blocking":true,"contract_version":"unknown","reason_codes":["report_parse_error"],"warnings":[],"report_path":"build/perf/performance-gate-report.json","suite_results":{}}')"
    else
        perf_structured_json='{"overall":"missing","release_blocking":true,"contract_version":"unknown","reason_codes":["report_not_found"],"warnings":[],"report_path":"build/perf/performance-gate-report.json","suite_results":{}}'
    fi

    if [[ $json_output -eq 1 ]]; then
        cat <<ENDJSON
{
  "quality_gate": {
    "cycle_id": "${cycle_id}",
    "run_id": "${run_id}",
    "project": "${project}",
    "workspace": "${workspace}",
    "overall": "${gate_overall}",
    "phases": {
      "protocol_check": "${gate_result_protocol_check}",
      "core_regression": "${gate_result_core_regression}",
      "performance_regression": "${gate_result_performance_regression}",
      "system_health": "${gate_result_system_health}",
      "evidence_integrity": "${gate_result_evidence_integrity}",
      "apple_regression": "${gate_result_apple_regression}",
      "apple_build": "${gate_result_apple_build}"
    },
    "performance_regression": ${perf_structured_json},
    "failure_reasons": "${gate_failure_reasons}",
    "warnings": "${gate_warnings}",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "analysis_engine_version": "v1.45"
  }
}
ENDJSON
    else
        echo "[quality-gate] ===== 门禁摘要 ====="
        echo "[quality-gate]   cycle_id=${cycle_id}"
        echo "[quality-gate]   run_id=${run_id}"
        echo "[quality-gate]   project=${project}"
        echo "[quality-gate]   workspace=${workspace}"
        echo "[quality-gate]   protocol_check=${gate_result_protocol_check}"
        echo "[quality-gate]   core_regression=${gate_result_core_regression}"
        echo "[quality-gate]   performance_regression=${gate_result_performance_regression}"
        echo "[quality-gate]   system_health=${gate_result_system_health}"
        echo "[quality-gate]   evidence_integrity=${gate_result_evidence_integrity}"
        echo "[quality-gate]   apple_regression=${gate_result_apple_regression}"
        echo "[quality-gate]   apple_build=${gate_result_apple_build}"
        echo "[quality-gate]   overall=${gate_overall}"
        if [[ -n "$gate_failure_reasons" ]]; then
            echo "[quality-gate]   failure_reasons=${gate_failure_reasons}"
        fi
        if [[ -n "$gate_warnings" ]]; then
            echo "[quality-gate]   warnings=${gate_warnings}"
        fi
        echo "[quality-gate] ===================="
    fi
}

echo "[quality-gate] cycle=${cycle_id} run_id=${run_id} project=${project} workspace=${workspace} evidence_root=${TF_EVIDENCE_ROOT}" >&2

# ============================================================================
# --verify-only 快速路径：仅校验证据
# ============================================================================

if [[ $verify_only -eq 1 ]]; then
    exec python3 "$PROJECT_ROOT/scripts/e2e/verify_evidence_index.py" \
        --evidence-root "$TF_EVIDENCE_ROOT" \
        --run-id "$run_id" \
        --project "$project" \
        --workspace "$workspace" \
        --require-devices iphone ipad mac \
        --require-scenarios AC-WORKSPACE-LIFECYCLE AC-AI-SESSION-FLOW AC-TERMINAL-INTERACTION
fi

# ============================================================================
# --dry-run 快速路径
# ============================================================================

if [[ $dry_run -eq 1 ]]; then
    echo "[quality-gate] DRY RUN: 以下为将执行的门禁阶段" >&2
    should_run_phase protocol_check && echo "  [1] protocol_check: ./scripts/tidyflow check" >&2
    should_run_phase core_regression && echo "  [2] core_regression: ./scripts/tidyflow test" >&2
    should_run_phase performance_regression && echo "  [2.5] performance_regression: ./scripts/tidyflow perf-regression" >&2
    should_run_phase system_health && echo "  [3] system_health: (需要 Core 运行时，dry-run 跳过)" >&2
    should_run_phase evidence_integrity && echo "  [4] evidence_integrity: python3 scripts/e2e/verify_evidence_index.py --run-id ${run_id}" >&2
    if [[ $skip_apple -eq 0 ]]; then
        should_run_phase apple_regression && echo "  [5] apple_regression: ./scripts/tidyflow apple-regression --macos-only" >&2
        should_run_phase apple_build && echo "  [6] apple_build: ./scripts/tidyflow apple-build" >&2
    else
        echo "  [5-6] apple 检查已跳过 (--skip-apple)" >&2
    fi
    record_phase_result "protocol_check" "pass"
    record_phase_result "core_regression" "pass"
    record_phase_result "performance_regression" "pass"
    record_phase_result "system_health" "pass"
    record_phase_result "evidence_integrity" "pass"
    record_phase_result "apple_regression" "pass"
    record_phase_result "apple_build" "pass"
    emit_gate_summary
    exit 0
fi

# ============================================================================
# 阶段执行
# ============================================================================

# 阶段 1：协议一致性检查
if should_run_phase protocol_check; then
    echo "[quality-gate] [1/6] 协议一致性检查..."
    if "$PROJECT_ROOT/scripts/tidyflow" check; then
        record_phase_result "protocol_check" "pass"
    else
        record_phase_result "protocol_check" "fail" "协议或架构护栏检查失败"
    fi
fi

# 阶段 2：Core 回归测试
if should_run_phase core_regression; then
    echo "[quality-gate] [2/7] Core 回归测试..."
    if "$PROJECT_ROOT/scripts/tidyflow" test; then
        record_phase_result "core_regression" "pass"
    else
        record_phase_result "core_regression" "fail" "Core 单元测试存在失败"
    fi
fi

# 阶段 2.5：性能回归检查（顺序：core_regression 之后、system_health 之前）
#
# 裁决规则（来自统一性能门禁契约 performance_gate_contract.json）：
# - release_blocking=false → 记录 pass（warn 仅写入 gate_warnings，不阻断）
# - release_blocking=true  → 记录 fail（阻断门禁）
# - 统一报告缺失或解析失败 → 记录 fail
# 阶段结果从统一报告 build/perf/performance-gate-report.json 读取，
# 不再分别解析 hotspot/apple 报告自行拼接裁决。
if should_run_phase performance_regression; then
    echo "[quality-gate] [2.5/7] 性能回归检查..."
    mkdir -p "$PROJECT_ROOT/build/perf"
    _perf_gate_report="$PROJECT_ROOT/build/perf/performance-gate-report.json"

    # 传入 cycle_id / project / workspace 以确保统一报告携带正确归属
    if CYCLE_ID="$cycle_id" TF_PROJECT="$project" TF_WORKSPACE="$workspace" \
        "$PROJECT_ROOT/scripts/tidyflow" perf-regression; then
        _perf_run_ok=1
    else
        _perf_run_ok=0
    fi

    # 从统一报告读取结构化裁决（不再分别解析各子报告）
    if [[ -f "$_perf_gate_report" ]]; then
        _perf_overall="$(python3 -c "import json,sys; d=json.load(open('$_perf_gate_report')); print(d.get('overall','unknown'))" 2>/dev/null || echo "unknown")"
        _perf_release_blocking="$(python3 -c "import json,sys; d=json.load(open('$_perf_gate_report')); print(str(d.get('release_blocking',True)).lower())" 2>/dev/null || echo "true")"
        _perf_reason_codes="$(python3 -c "import json,sys; d=json.load(open('$_perf_gate_report')); print('; '.join(d.get('reason_codes',[])))" 2>/dev/null || echo "")"
        _perf_warnings_str="$(python3 -c "import json,sys; d=json.load(open('$_perf_gate_report')); print('; '.join(d.get('warnings',[])))" 2>/dev/null || echo "")"

        if [[ "$_perf_release_blocking" == "true" ]]; then
            _fail_reason="性能门禁 release_blocking=true reason_codes=[${_perf_release_blocking}] 详见 ${_perf_gate_report}"
            [[ -n "$_perf_reason_codes" ]] && _fail_reason="性能门禁 release_blocking=true reason_codes=[${_perf_reason_codes}] 详见 ${_perf_gate_report}"
            record_phase_result "performance_regression" "fail" "$_fail_reason"
            echo "[quality-gate]   性能回归失败，详见 $_perf_gate_report" >&2
        else
            record_phase_result "performance_regression" "pass"
            if [[ "$_perf_overall" == "warn" && -n "$_perf_warnings_str" ]]; then
                record_phase_warning "performance_regression" "$_perf_warnings_str"
                echo "[quality-gate]   性能回归：warn（不阻断，详见 $_perf_gate_report）"
            fi
        fi
    else
        # 统一报告缺失（perf-regression 未生成）
        record_phase_result "performance_regression" "fail" "统一性能门禁报告缺失：$_perf_gate_report 不存在"
        echo "[quality-gate]   统一性能门禁报告缺失，性能回归视为失败" >&2
    fi
fi

# 阶段 3：系统健康判定（需要 Core 运行时，非 dry-run 但无运行时时记为 skipped）
if should_run_phase system_health; then
    echo "[quality-gate] [3/7] 系统健康判定..."
    # 系统健康检查通过 Core HTTP API 执行；如果 Core 未运行则标记为跳过
    if curl -sf http://127.0.0.1:45818/api/v1/health >/dev/null 2>&1; then
        health_status="$(curl -sf http://127.0.0.1:45818/api/v1/health | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("overall_status","unknown"))' 2>/dev/null || echo "unknown")"
        if [[ "$health_status" == "healthy" || "$health_status" == "degraded" ]]; then
            record_phase_result "system_health" "pass"
        else
            record_phase_result "system_health" "fail" "系统健康状态: ${health_status}"
        fi
    else
        echo "[quality-gate]   Core 未运行，系统健康检查跳过"
        record_phase_result "system_health" "skipped"
    fi
fi

# 阶段 4：证据完整性校验
if should_run_phase evidence_integrity; then
    echo "[quality-gate] [4/7] 证据完整性校验..."
    if python3 "$PROJECT_ROOT/scripts/e2e/verify_evidence_index.py" \
        --evidence-root "$TF_EVIDENCE_ROOT" \
        --run-id "$run_id" \
        --project "$project" \
        --workspace "$workspace" \
        --require-devices iphone ipad mac \
        --require-scenarios AC-WORKSPACE-LIFECYCLE AC-AI-SESSION-FLOW AC-TERMINAL-INTERACTION 2>&1; then
        record_phase_result "evidence_integrity" "pass"
    else
        record_phase_result "evidence_integrity" "fail" "证据索引校验失败"
    fi
fi

# 阶段 5：Apple 多工作区回归
if should_run_phase apple_regression && [[ $skip_apple -eq 0 ]]; then
    echo "[quality-gate] [5/7] Apple 多工作区回归（串行）..."
    if "$PROJECT_ROOT/scripts/tidyflow" apple-regression --macos-only; then
        record_phase_result "apple_regression" "pass"
    else
        record_phase_result "apple_regression" "fail" "Apple 多工作区回归测试失败"
    fi
elif [[ $skip_apple -eq 1 ]] && should_run_phase apple_regression; then
    record_phase_result "apple_regression" "skipped"
fi

# 阶段 6：Apple 构建验证
if should_run_phase apple_build && [[ $skip_apple -eq 0 ]]; then
    echo "[quality-gate] [6/7] Apple 构建验证（串行: macOS → iOS）..."
    build_failed=0
    if ! "$PROJECT_ROOT/scripts/tidyflow" apple-build macos --skip-core; then
        build_failed=1
    fi
    if ! "$PROJECT_ROOT/scripts/tidyflow" apple-build ios --skip-core; then
        build_failed=1
    fi
    if [[ $build_failed -eq 0 ]]; then
        record_phase_result "apple_build" "pass"
    else
        record_phase_result "apple_build" "fail" "Apple 构建失败"
    fi
elif [[ $skip_apple -eq 1 ]] && should_run_phase apple_build; then
    record_phase_result "apple_build" "skipped"
fi

# ============================================================================
# 输出门禁摘要
# ============================================================================

emit_gate_summary

if [[ "$gate_overall" == "fail" ]]; then
    exit 1
fi
exit 0
