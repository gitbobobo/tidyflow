#!/usr/bin/env bash
# 统一 e2e 入口：按设备执行真实 UI 测试并由测试代码产出证据。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

generate_run_id() {
    date -u +%Y%m%d-%H%M%S
}

print_usage() {
    cat <<'EOF'
用法:
  ./scripts/e2e/main.sh [--device iphone|ipad|mac|all] [--run-id <run_id>]
EOF
}

device="all"
run_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            device="${2:-}"
            shift 2
            ;;
        --run-id)
            run_id="${2:-}"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "[e2e] 未知参数: $1"
            print_usage
            exit 1
            ;;
    esac
done

if [[ -z "$run_id" ]]; then
    run_id="$(generate_run_id)"
    echo "[e2e] 自动生成 run_id=$run_id"
fi

case "$device" in
    iphone)
        exec "$PROJECT_ROOT/scripts/e2e/iphone.sh" --run-id "$run_id"
        ;;
    ipad)
        exec "$PROJECT_ROOT/scripts/e2e/ipad.sh" --run-id "$run_id"
        ;;
    mac)
        exec "$PROJECT_ROOT/scripts/e2e/mac.sh" --run-id "$run_id"
        ;;
    all)
        exec "$PROJECT_ROOT/scripts/e2e/run-all.sh" --run-id "$run_id"
        ;;
    *)
        echo "[e2e] 不支持的设备类型: $device"
        print_usage
        exit 1
        ;;
esac
