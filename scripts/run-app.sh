#!/bin/bash
# TidyFlow App - Run Script
# Builds and launches the macOS app
# Note: Core server is managed by the app itself (CoreProcessManager)

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 构建并运行应用
APP_DIR="$PROJECT_ROOT/app"
BUILD_DIR="$PROJECT_ROOT/build"
BUILD_LOG="$BUILD_DIR/build.log"

mkdir -p "$BUILD_DIR"

echo "[run-app] Building TidyFlow.app..."
if xcodebuild -project "$APP_DIR/TidyFlow.xcodeproj" \
    -scheme TidyFlow \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | tee "$BUILD_LOG" | grep -E "(Build Succeeded|error:|warning:)" || true; then
    :
fi

APP_PATH="$BUILD_DIR/Build/Products/Debug/TidyFlow-Debug.app"

if [ -d "$APP_PATH" ]; then
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
