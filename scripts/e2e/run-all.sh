#!/usr/bin/env bash
# 串行执行 iphone/ipad/mac 三端 e2e，避免并行 xcodebuild。
# 三端共享同一 run_id，便于证据校验脚本按 run_id 聚合检查。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

# 加载共享引导脚本
# shellcheck source=scripts/e2e/fixtures/bootstrap.sh
source "$PROJECT_ROOT/scripts/e2e/fixtures/bootstrap.sh"

generate_run_id() {
    date -u +%Y%m%d-%H%M%S
}

run_id=""
skip_verify=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)
            run_id="${2:-}"
            shift 2
            ;;
        --skip-verify)
            skip_verify=1
            shift
            ;;
        -h|--help)
            echo "用法: ./scripts/e2e/run-all.sh [--run-id <run_id>] [--skip-verify]"
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

echo "[e2e] 三端串行执行开始: run_id=$run_id evidence_root=$TF_EVIDENCE_ROOT"

# 记录各设备执行状态（使用变量前缀，兼容 bash 3.2）
device_status_iphone="ok"
device_status_ipad="ok"
device_status_mac="ok"
overall_status=0

for device in iphone ipad mac; do
    echo "[e2e] ===== 开始执行 $device ====="
    if "$PROJECT_ROOT/scripts/e2e/$device.sh" --run-id "$run_id"; then
        eval "device_status_${device}=ok"
        echo "[e2e] $device 执行成功"
    else
        eval "device_status_${device}=FAILED"
        overall_status=1
        echo "[e2e] $device 执行失败（继续执行后续设备）"
    fi
done

echo "[e2e] ===== 三端执行汇总: run_id=$run_id ====="
for device in iphone ipad mac; do
    varname="device_status_${device}"
    echo "[e2e]   $device: ${!varname}"
done

if [[ $overall_status -eq 0 ]]; then
    echo "[e2e] 三端执行全部成功: run_id=$run_id"
else
    echo "[e2e] 存在失败设备（见汇总）: run_id=$run_id"
fi

# 可选：执行证据索引完整性校验
if [[ $skip_verify -eq 0 ]] && command -v python3 &>/dev/null; then
    echo "[e2e] 运行证据索引完整性校验..."
    if python3 "$PROJECT_ROOT/scripts/e2e/verify_evidence_index.py" \
        --evidence-root "$TF_EVIDENCE_ROOT" \
        --run-id "$run_id" \
        --require-devices iphone ipad mac \
        --require-scenarios AC-WORKSPACE-LIFECYCLE AC-AI-SESSION-FLOW AC-TERMINAL-INTERACTION; then
        echo "[e2e] 证据校验通过"
    else
        echo "[e2e] 证据校验失败（不影响 run-all 退出码，请人工核查）"
    fi
fi

exit $overall_status
