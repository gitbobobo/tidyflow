#!/usr/bin/env bash
# 共享 E2E 测试环境初始化脚本
# 统一注入 run_id、设备类型等环境变量，避免各 device 脚本重复拼接。
# 使用方式：在 device 脚本中 source 本文件。
# 本文件不能直接执行，只能被 source。

# 确保 PROJECT_ROOT 已在调用方定义
: "${PROJECT_ROOT:?PROJECT_ROOT 未设置，请先在调用方 source 之前赋值}"

# 导出统一环境变量，供 xcodebuild 透传给测试进程
tf_export_test_env() {
    local device="${1:?device 参数缺失}"
    local run_id="${2:?run_id 参数缺失}"
    export TF_E2E_RUN_ID="${run_id}"
    export TF_DEVICE_TYPE="${device}"
    export UI_TEST_MODE="1"
}
