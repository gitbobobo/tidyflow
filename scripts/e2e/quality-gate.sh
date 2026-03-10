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
                           system_health | evidence_integrity | apple_regression |
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
gate_result_system_health="skipped"
gate_result_evidence_integrity="skipped"
gate_result_apple_regression="skipped"
gate_result_apple_build="skipped"
gate_overall="pass"
gate_failure_reasons=""

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

should_run_phase() {
    local phase="$1"
    [[ "$step" == "all" || "$step" == "$phase" ]]
}

# ============================================================================
# 门禁摘要输出
# ============================================================================

emit_gate_summary() {
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
      "system_health": "${gate_result_system_health}",
      "evidence_integrity": "${gate_result_evidence_integrity}",
      "apple_regression": "${gate_result_apple_regression}",
      "apple_build": "${gate_result_apple_build}"
    },
    "failure_reasons": "${gate_failure_reasons}",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
        echo "[quality-gate]   system_health=${gate_result_system_health}"
        echo "[quality-gate]   evidence_integrity=${gate_result_evidence_integrity}"
        echo "[quality-gate]   apple_regression=${gate_result_apple_regression}"
        echo "[quality-gate]   apple_build=${gate_result_apple_build}"
        echo "[quality-gate]   overall=${gate_overall}"
        if [[ -n "$gate_failure_reasons" ]]; then
            echo "[quality-gate]   failure_reasons=${gate_failure_reasons}"
        fi
        echo "[quality-gate] ===================="
    fi
}

echo "[quality-gate] cycle=${cycle_id} run_id=${run_id} project=${project} workspace=${workspace} evidence_root=${TF_EVIDENCE_ROOT}"

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
    echo "[quality-gate] DRY RUN: 以下为将执行的门禁阶段"
    should_run_phase protocol_check && echo "  [1] protocol_check: ./scripts/tidyflow check"
    should_run_phase core_regression && echo "  [2] core_regression: ./scripts/tidyflow test"
    should_run_phase system_health && echo "  [3] system_health: (需要 Core 运行时，dry-run 跳过)"
    should_run_phase evidence_integrity && echo "  [4] evidence_integrity: python3 scripts/e2e/verify_evidence_index.py --run-id ${run_id}"
    if [[ $skip_apple -eq 0 ]]; then
        should_run_phase apple_regression && echo "  [5] apple_regression: ./scripts/tidyflow apple-regression --macos-only"
        should_run_phase apple_build && echo "  [6] apple_build: ./scripts/tidyflow apple-build"
    else
        echo "  [5-6] apple 检查已跳过 (--skip-apple)"
    fi
    record_phase_result "protocol_check" "pass"
    record_phase_result "core_regression" "pass"
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
    echo "[quality-gate] [2/6] Core 回归测试..."
    if "$PROJECT_ROOT/scripts/tidyflow" test; then
        record_phase_result "core_regression" "pass"
    else
        record_phase_result "core_regression" "fail" "Core 单元测试存在失败"
    fi
fi

# 阶段 3：系统健康判定（需要 Core 运行时，非 dry-run 但无运行时时记为 skipped）
if should_run_phase system_health; then
    echo "[quality-gate] [3/6] 系统健康判定..."
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
    echo "[quality-gate] [4/6] 证据完整性校验..."
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
    echo "[quality-gate] [5/6] Apple 多工作区回归（串行）..."
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
    echo "[quality-gate] [6/6] Apple 构建验证（串行: macOS → iOS）..."
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
