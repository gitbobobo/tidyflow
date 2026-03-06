#!/bin/bash
# TidyFlow App - Run Script
# Builds and launches the macOS app
# Note: Core server is managed by the app itself (CoreProcessManager)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 构建并运行应用
APP_DIR="$PROJECT_ROOT/app"
BUILD_DIR="$PROJECT_ROOT/build"
BUILD_LOG="$BUILD_DIR/build.log"
CORE_DIR="$PROJECT_ROOT/core"
APP_PATH="$BUILD_DIR/Build/Products/Debug/TidyFlow-Debug.app"
CORE_PROFILE="${TIDYFLOW_CORE_PROFILE:-debug}"

case "$CORE_PROFILE" in
    debug)
        CARGO_ARGS=()
        CORE_BINARY="$CORE_DIR/target/debug/tidyflow-core"
        ;;
    release)
        CARGO_ARGS=(--release)
        CORE_BINARY="$CORE_DIR/target/release/tidyflow-core"
        ;;
    *)
        echo "[run-app] ERROR: 不支持的 Core profile: $CORE_PROFILE"
        echo "[run-app] 可选值: debug / release"
        exit 1
        ;;
esac

mkdir -p "$BUILD_DIR"

# 1. 先编译 Rust Core（开发模式默认使用 debug，加快本地联调）
echo "[run-app] Building tidyflow-core ($CORE_PROFILE)..."
export PATH="$HOME/.cargo/bin:$PATH"
(cd "$CORE_DIR" && cargo build "${CARGO_ARGS[@]}")
echo "[run-app] Core build done."

# 2. 构建 Swift App（复用 Xcode 增量产物，Core 由脚本自行注入）
echo "[run-app] Building TidyFlow.app..."
set +e
xcodebuild -project "$APP_DIR/TidyFlow.xcodeproj" \
    -scheme TidyFlow \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    SKIP_CORE_BUILD=1 \
    build 2>&1 | tee "$BUILD_LOG" | grep -E "(Build Succeeded|error:|warning:)"
xcode_status=${PIPESTATUS[0]}
set -e

if [ "$xcode_status" -ne 0 ]; then
    echo "[run-app] ERROR: xcodebuild failed (exit=$xcode_status)"
fi

# 3. 兜底：直接复制 Core 二进制到 app bundle（防止 Xcode 增量判断仍跳过）
DEST_DIR="$APP_PATH/Contents/Resources/Core"
if [ "$xcode_status" -eq 0 ] && [ -f "$CORE_BINARY" ] && [ -d "$APP_PATH" ]; then
    mkdir -p "$DEST_DIR"
    cp "$CORE_BINARY" "$DEST_DIR/"
    echo "[run-app] Copied latest tidyflow-core to app bundle."
fi

if [ "$xcode_status" -eq 0 ] && [ -d "$APP_PATH" ]; then
    echo "[run-app] Launching TidyFlow.app..."
    open "$APP_PATH"
else
    echo "[run-app] ERROR: Build failed. 查看完整日志:"
    echo "  cat $BUILD_LOG"
    echo ""
    echo "或在 Xcode 中打开:"
    echo "  open $APP_DIR/TidyFlow.xcodeproj"
    echo ""
    echo "=== 构建错误摘要 ==="
    grep -E "(error:|fatal error)" "$BUILD_LOG" | head -20 || echo "(无明显错误，请查看完整日志)"
fi
