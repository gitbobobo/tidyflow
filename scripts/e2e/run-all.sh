#!/usr/bin/env bash
# 串行执行 iphone/ipad/mac 三端 e2e，避免并行 xcodebuild。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

generate_run_id() {
    date -u +%Y%m%d-%H%M%S
}

run_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)
            run_id="${2:-}"
            shift 2
            ;;
        -h|--help)
            echo "用法: ./scripts/e2e/run-all.sh [--run-id <run_id>]"
            exit 0
            ;;
        *)
            echo "[e2e] 未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$run_id" ]]; then
    run_id="$(generate_run_id)"
    echo "[e2e] 自动生成 run_id=$run_id"
fi

status=0
for device in iphone ipad mac; do
    echo "[e2e] ===== 开始执行 $device ====="
    if ! "$PROJECT_ROOT/scripts/e2e/$device.sh" --run-id "$run_id"; then
        echo "[e2e] $device 执行失败"
        status=1
    fi
done

if [[ $status -eq 0 ]]; then
    echo "[e2e] 三端执行完成: run_id=$run_id"
else
    echo "[e2e] 存在失败设备: run_id=$run_id"
fi

exit $status
