#!/bin/bash
# TidyFlow App - Run Script
# Starts the core server and opens the macOS app

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT

TIDYFLOW_PORT="${TIDYFLOW_PORT:-47999}"
export TIDYFLOW_PORT

# Check if core is running
check_core() {
    nc -z 127.0.0.1 "$TIDYFLOW_PORT" 2>/dev/null
}

# Start core in background if not running
if ! check_core; then
    echo "[run-app] Starting core server on port $TIDYFLOW_PORT..."
    "$PROJECT_ROOT/scripts/run-core.sh" &
    CORE_PID=$!

    # Wait for core to be ready (max 5 seconds)
    for i in {1..10}; do
        if check_core; then
            echo "[run-app] Core server ready"
            break
        fi
        sleep 0.5
    done

    if ! check_core; then
        echo "[run-app] ERROR: Core server failed to start"
        kill $CORE_PID 2>/dev/null || true
        exit 1
    fi
else
    echo "[run-app] Core server already running on port $TIDYFLOW_PORT"
fi

# Build and run the app
APP_DIR="$PROJECT_ROOT/app"
BUILD_DIR="$PROJECT_ROOT/build"

echo "[run-app] Building TidyFlow.app..."
xcodebuild -project "$APP_DIR/TidyFlow.xcodeproj" \
    -scheme TidyFlow \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | grep -E "(Build Succeeded|error:|warning:)" || true

APP_PATH="$BUILD_DIR/Build/Products/Debug/TidyFlow.app"

if [ -d "$APP_PATH" ]; then
    echo "[run-app] Launching TidyFlow.app..."
    open "$APP_PATH"
else
    echo "[run-app] ERROR: Build failed. Open in Xcode for details:"
    echo "  open $APP_DIR/TidyFlow.xcodeproj"
fi
