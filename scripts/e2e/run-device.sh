#!/usr/bin/env bash
# 单设备 e2e 执行器：仅负责设置环境变量并触发真实测试执行。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

# 加载共享引导脚本（提供 tf_write_run_context / tf_prepare_device_dir / tf_export_test_env）
# shellcheck source=scripts/e2e/fixtures/bootstrap.sh
source "$PROJECT_ROOT/scripts/e2e/fixtures/bootstrap.sh"

generate_run_id() {
    date -u +%Y%m%d-%H%M%S
}

print_usage() {
    cat <<'EOF'
用法:
  ./scripts/e2e/run-device.sh --device iphone|ipad|mac [--run-id <run_id>]
EOF
}

device=""
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

if [[ -z "$device" ]]; then
    echo "[e2e] 缺少 --device"
    print_usage
    exit 1
fi

if [[ -z "$run_id" ]]; then
    run_id="$(generate_run_id)"
    echo "[e2e] 自动生成 run_id=$run_id"
fi

# 使用 bootstrap 统一写入上下文并准备目录
tf_write_run_context "$device" "$run_id"
tf_prepare_device_dir "$device" "$run_id"
tf_export_test_env "$device" "$run_id"

iphone_destination="${TF_IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 16,OS=18.6}"
ipad_destination="${TF_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad (A16),OS=18.6}"
mac_destination="${TF_MAC_DESTINATION:-platform=macOS}"

case "$device" in
    iphone)
        destination="$iphone_destination"
        skip_core_build="1"
        ;;
    ipad)
        destination="$ipad_destination"
        skip_core_build="1"
        ;;
    mac)
        destination="$mac_destination"
        skip_core_build="0"
        ;;
    *)
        echo "[e2e] 不支持的设备类型: $device"
        exit 1
        ;;
esac

echo "[e2e] device=$device run_id=$run_id"
echo "[e2e] destination=$destination"
echo "[e2e] SKIP_CORE_BUILD=$skip_core_build"
echo "[e2e] evidence_root=$TF_EVIDENCE_ROOT"

TF_EVIDENCE_ROOT="$TF_EVIDENCE_ROOT" \
TF_E2E_RUN_ID="$run_id" \
TF_DEVICE_TYPE="$device" \
UI_TEST_MODE=1 \
xcodebuild -project "$PROJECT_ROOT/app/TidyFlow.xcodeproj" \
    -scheme TidyFlow \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$PROJECT_ROOT/build" \
    "SKIP_CORE_BUILD=$skip_core_build" \
    "TF_EVIDENCE_ROOT=$EVIDENCE_ROOT" \
    "TF_E2E_RUN_ID=$run_id" \
    "TF_DEVICE_TYPE=$device" \
    "UI_TEST_MODE=1" \
    test \
    -only-testing:TidyFlowE2ETests
