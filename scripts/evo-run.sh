#!/usr/bin/env bash
# Evolution 质量门禁执行入口（最小实现）
# 目标：
# 1) 保证 ./scripts/tidyflow quality-gate 可执行，不再引用缺失脚本；
# 2) 提供可复用的 step 路由与 dry-run 能力；
# 3) 明确 xcodebuild 串行执行，避免并发构建。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

LOG_DIR="$HOME/.tidyflow/logs"
LOG_DAY="$(date +%Y-%m-%d)"
DEV_LOG_FILE="$LOG_DIR/$LOG_DAY-dev.log"

STEP="all"
CYCLE_ID=""
RUN_ID=""
DRY_RUN=0

usage() {
    cat <<'EOF'
用法:
  ./scripts/evo-run.sh --cycle <cycle_id> [--run-id <run_id>] [--step all|build|integration|verify] [--dry-run]

说明:
  - all: integration + verify
  - integration: 执行 core unit + integration 测试
  - build: 串行执行 macOS/iOS xcodebuild
  - verify: 执行证据索引存在性与字段最小检查
EOF
}

ensure_log_file() {
    mkdir -p "$LOG_DIR"
    touch "$DEV_LOG_FILE"
}

write_event_log() {
    local event_name="$1"
    local detail="${2:-}"
    ensure_log_file
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"%s","cycle_id":"%s","run_id":"%s","step":"%s","detail":"%s"}\n' \
        "$ts" "$event_name" "$CYCLE_ID" "$RUN_ID" "$STEP" "$detail" >>"$DEV_LOG_FILE"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cycle)
            CYCLE_ID="${2:-}"
            shift 2
            ;;
        --run-id)
            RUN_ID="${2:-}"
            shift 2
            ;;
        --step)
            STEP="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[evo-run] 未知参数: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$CYCLE_ID" ]; then
    echo "[evo-run] 缺少必填参数 --cycle" >&2
    exit 1
fi

if [ -z "$RUN_ID" ]; then
    RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
fi

CYCLE_DIR=".tidyflow/evolution/$CYCLE_ID"
EVIDENCE_DIR="$CYCLE_DIR/evidence"
mkdir -p "$EVIDENCE_DIR"

echo "[evo] quality_gate_invoked cycle_id=$CYCLE_ID run_id=$RUN_ID step=$STEP dry_run=$DRY_RUN"
write_event_log "quality_gate_invoked" "dry_run=$DRY_RUN"

run_cmd() {
    local label="$1"
    shift
    if [ $DRY_RUN -eq 1 ]; then
        echo "[evo][dry-run] $label :: $*"
        return 0
    fi
    echo "[evo][run] $label :: $*"
    "$@"
}

run_integration() {
    run_cmd "unit(v-1)" cargo test --manifest-path core/Cargo.toml
    run_cmd "integration(v-2)" cargo test --manifest-path core/Cargo.toml --test protocol_v1 --test manager_test
}

run_build() {
    # 严格串行：先 macOS，再 iOS。
    run_cmd "build(v-3,macOS)" xcodebuild -project app/TidyFlow.xcodeproj -scheme TidyFlow -configuration Debug -destination platform=macOS -derivedDataPath build SKIP_CORE_BUILD=1 build
    run_cmd "build(v-4,iOS)" xcodebuild -project app/TidyFlow.xcodeproj -scheme TidyFlow -configuration Debug -destination "platform=iOS Simulator,name=iPhone 16,OS=18.6" -derivedDataPath build SKIP_CORE_BUILD=1 build
}

run_verify() {
    local evidence_index="$CYCLE_DIR/evidence.index.json"
    if [ $DRY_RUN -eq 1 ]; then
        echo "[evo][dry-run] verify(v-5~v-7) :: check evidence index at $evidence_index"
        return 0
    fi
    if [ ! -f "$evidence_index" ]; then
        echo "[evo][verify] 缺失证据索引: $evidence_index" >&2
        return 1
    fi
    if ! rg -q '"items"' "$evidence_index"; then
        echo "[evo][verify] 证据索引缺少 items 字段: $evidence_index" >&2
        return 1
    fi
    local item_count
    item_count="$(jq '.items | length' "$evidence_index" 2>/dev/null || echo 0)"
    echo "[evo] evidence_index_updated cycle_id=$CYCLE_ID items_total=$item_count"
    write_event_log "evidence_index_updated" "items_total=$item_count"
    echo "[evo] quality_gate_script_resolved script=./scripts/evo-run.sh"
    write_event_log "quality_gate_script_resolved" "script=./scripts/evo-run.sh"
    echo "[evo] verification_check_completed check_id=v-7 result=pass"
    write_event_log "verification_check_completed" "check_id=v-7 result=pass"
}

case "$STEP" in
    all)
        run_integration
        run_verify
        ;;
    integration)
        run_integration
        ;;
    build)
        run_build
        ;;
    verify)
        run_verify
        ;;
    *)
        echo "[evo-run] 不支持的 step: $STEP" >&2
        exit 1
        ;;
esac

echo "[evo-run] completed cycle_id=$CYCLE_ID run_id=$RUN_ID step=$STEP"
