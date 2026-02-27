#!/usr/bin/env bash
# 兼容旧 quality-gate 参数，底层迁移到新 e2e 链路。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

generate_run_id() {
    date -u +%Y%m%d-%H%M%S
}

cycle_id=""
run_id=""
step="all"
dry_run=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cycle)
            cycle_id="${2:-}"
            shift 2
            ;;
        --run-id)
            run_id="${2:-}"
            shift 2
            ;;
        --step)
            step="${2:-all}"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            echo "用法: ./scripts/e2e/quality-gate.sh --cycle <cycle_id> [--run-id <run_id>] [--step all] [--dry-run]"
            exit 0
            ;;
        *)
            echo "[quality-gate] 未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$cycle_id" ]]; then
    echo "[quality-gate] 缺少 --cycle"
    exit 1
fi

if [[ -z "$run_id" ]]; then
    run_id="$cycle_id"
fi

if [[ -z "$run_id" ]]; then
    run_id="$(generate_run_id)"
fi

if [[ "$step" != "all" ]]; then
    echo "[quality-gate] 已迁移到统一 e2e，忽略旧 step=$step，仅执行 all"
fi

cmd=("$PROJECT_ROOT/scripts/e2e/main.sh" "--device" "all" "--run-id" "$run_id")
if [[ $dry_run -eq 1 ]]; then
    printf '[quality-gate] DRY RUN:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    exit 0
fi

exec "${cmd[@]}"
