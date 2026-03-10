#!/usr/bin/env bash
# 共享 E2E 测试环境初始化脚本
# 统一注入 run_id、设备类型、证据目录等环境变量，避免各 device 脚本重复拼接。
# 使用方式：在 device 脚本中 source 本文件。
# 本文件不能直接执行，只能被 source。

# 确保 PROJECT_ROOT 已在调用方定义
: "${PROJECT_ROOT:?PROJECT_ROOT 未设置，请先在调用方 source 之前赋值}"

# 证据根目录：优先使用已有环境变量，否则使用默认路径
: "${TF_EVIDENCE_ROOT:=$PROJECT_ROOT/.tidyflow/evidence}"
export TF_EVIDENCE_ROOT

# 确保证据目录存在
mkdir -p "$TF_EVIDENCE_ROOT"

# 写入运行上下文文件，供测试代码读取 run_id / device_type / evidence_root
# 注意：串行三端执行时，每个设备依次写入；后写的不会影响前一个设备已完成的证据目录。
tf_write_run_context() {
    local device="${1:?device 参数缺失}"
    local run_id="${2:?run_id 参数缺失}"
    local context_file="$TF_EVIDENCE_ROOT/.run-context.json"
    cat > "$context_file" <<EOF
{
  "device_type": "${device}",
  "run_id": "${run_id}",
  "evidence_root": "${TF_EVIDENCE_ROOT}"
}
EOF
    echo "[bootstrap] 运行上下文已写入: device=${device} run_id=${run_id} root=${TF_EVIDENCE_ROOT}"
}

# 为指定设备和 run_id 创建证据目录
tf_prepare_device_dir() {
    local device="${1:?device 参数缺失}"
    local run_id="${2:?run_id 参数缺失}"
    mkdir -p "$TF_EVIDENCE_ROOT/$device/e2e/$run_id"
}

# 导出统一环境变量，供 xcodebuild 透传给测试进程
tf_export_test_env() {
    local device="${1:?device 参数缺失}"
    local run_id="${2:?run_id 参数缺失}"
    export TF_EVIDENCE_ROOT
    export TF_E2E_RUN_ID="${run_id}"
    export TF_DEVICE_TYPE="${device}"
    export UI_TEST_MODE="1"
}
