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

mkdir -p "$BUILD_DIR"
rm -rf "$APP_PATH"

# 1. 先编译 Rust Core（确保二进制始终最新）
echo "[run-app] Building tidyflow-core (release)..."
export PATH="$HOME/.cargo/bin:$PATH"
(cd "$CORE_DIR" && cargo build --release)
echo "[run-app] Core build done."

# 2. 触发 Xcode 重新执行 Build Core 脚本（强制复制最新二进制到 app bundle）
#    Xcode 用 inputPaths/outputPaths 做增量判断，编辑 src 子文件不一定更新目录 mtime，
#    导致 Xcode 跳过复制步骤。这里 touch src 目录确保 input 比 output 新。
touch "$CORE_DIR/src"

# 3. 构建 Swift App（Xcode 会检测到 src 更新，重新执行 copy 脚本）
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

# 4. 兜底：直接复制 Core 二进制到 app bundle（防止 Xcode 增量判断仍跳过）
CORE_BINARY="$CORE_DIR/target/release/tidyflow-core"
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
