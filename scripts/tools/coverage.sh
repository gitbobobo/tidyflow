#!/usr/bin/env bash
# Core 覆盖率采集与阈值门禁
#
# 用法:
#   ./scripts/tools/coverage.sh [options]
#
# 选项:
#   --threshold <percent>   设置总体覆盖率阈值（默认 70）
#   --key-modules           检查关键模块覆盖率 >= 85%
#   --report                生成 HTML 报告到 coverage/
#   --ci                    CI 模式，失败时退出非零
#
# 输出:
#   覆盖率报告到 stdout
#   HTML 报告到 core/target/llvm-cov/html/（如果使用 --report）

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

THRESHOLD="${COVERAGE_THRESHOLD:-70}"
GENERATE_REPORT=false
CI_MODE=false
CHECK_KEY_MODULES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --report)
            GENERATE_REPORT=true
            shift
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        --key-modules)
            CHECK_KEY_MODULES=true
            shift
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

echo "[coverage] 阈值: ${THRESHOLD}%"
echo "[coverage] 运行覆盖率测试..."

# 运行覆盖率测试（只运行单元测试，因为集成测试需要启动服务器）
COVERAGE_OUTPUT=$(cargo llvm-cov --manifest-path core/Cargo.toml --lib -- --test-threads=4 2>&1 || true)

# 提取总覆盖率
TOTAL_LINE=$(echo "$COVERAGE_OUTPUT" | grep "^TOTAL" | tail -1)
if [ -z "$TOTAL_LINE" ]; then
    echo "[coverage] ERROR: 无法获取覆盖率数据"
    if [ "$CI_MODE" = true ]; then
        exit 1
    fi
    exit 0
fi

# 解析覆盖率百分比（区域覆盖率）
# 格式: TOTAL  lines  missed  percent  ...
REGION_PERCENT=$(echo "$TOTAL_LINE" | awk '{print $4}' | sed 's/%//')

echo "[coverage] 行覆盖率: ${REGION_PERCENT}%"

# 检查关键模块覆盖率
KEY_MODULES_RESULT=true
if [ "$CHECK_KEY_MODULES" = true ]; then
    echo ""
    echo "[coverage] 检查关键模块覆盖率 >= 85%..."

    # 关键模块列表（协议核心模块）
    KEY_MODULES=(
        "server/protocol/action_table.rs"
        "server/protocol/mod.rs"
        "server/ws/dispatch/envelope.rs"
        "server/ws/request_scope.rs"
        "workspace/state_store.rs"
    )

    for module in "${KEY_MODULES[@]}"; do
        # 提取模块覆盖率
        MODULE_LINE=$(echo "$COVERAGE_OUTPUT" | grep "$module" | tail -1)
        if [ -n "$MODULE_LINE" ]; then
            MODULE_PERCENT=$(echo "$MODULE_LINE" | awk '{print $4}' | sed 's/%//')
            if (( $(echo "$MODULE_PERCENT >= 85" | bc -l) )); then
                echo "[coverage]   ✓ $module: ${MODULE_PERCENT}%"
            else
                echo "[coverage]   ✗ $module: ${MODULE_PERCENT}% (低于 85%)"
                KEY_MODULES_RESULT=false
            fi
        else
            echo "[coverage]   ? $module: 未找到"
        fi
    done
fi

# 生成 HTML 报告
if [ "$GENERATE_REPORT" = true ]; then
    echo "[coverage] 生成 HTML 报告..."
    cargo llvm-cov --manifest-path core/Cargo.toml --lib --html -- --test-threads=4 2>/dev/null || true
    echo "[coverage] HTML 报告: core/target/llvm-cov/html/index.html"
fi

# 检查阈值
FAILED=false
if [ "$CI_MODE" = true ]; then
    if (( $(echo "$REGION_PERCENT < $THRESHOLD" | bc -l) )); then
        echo "[coverage] FAIL: 覆盖率 ${REGION_PERCENT}% 低于阈值 ${THRESHOLD}%"
        FAILED=true
    else
        echo "[coverage] PASS: 覆盖率 ${REGION_PERCENT}% >= 阈值 ${THRESHOLD}%"
    fi

    if [ "$CHECK_KEY_MODULES" = true ] && [ "$KEY_MODULES_RESULT" = false ]; then
        echo "[coverage] FAIL: 部分关键模块覆盖率低于 85%"
        FAILED=true
    fi

    if [ "$FAILED" = true ]; then
        exit 1
    fi
fi

# 输出 JSON 格式（供 CI 使用）
cat <<EOF
{
  "coverage": {
    "line": ${REGION_PERCENT},
    "threshold": ${THRESHOLD},
    "passed": $(( $(echo "$REGION_PERCENT >= $THRESHOLD" | bc -l) )),
    "key_modules_checked": ${CHECK_KEY_MODULES},
    "key_modules_passed": ${KEY_MODULES_RESULT}
  }
}
EOF
