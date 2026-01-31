#!/bin/bash
# Multi-Terminal Smoke Test Wrapper
# Usage: ./scripts/term-multi-smoke.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== TidyFlow Multi-Terminal Smoke Test ==="
echo ""

# Check if websockets is installed
if ! python3 -c "import websockets" 2>/dev/null; then
    echo "Installing websockets..."
    pip3 install websockets --quiet
fi

# Check if core is running
if ! curl -s http://127.0.0.1:47999 >/dev/null 2>&1; then
    echo "WARNING: Core server not running on port 47999"
    echo "Start it with: ./scripts/run-core.sh"
    echo ""
    echo "Attempting to start core in background..."
    cd "$PROJECT_DIR/core"
    cargo run --release &
    CORE_PID=$!
    sleep 3

    if ! curl -s http://127.0.0.1:47999 >/dev/null 2>&1; then
        echo "ERROR: Failed to start core server"
        kill $CORE_PID 2>/dev/null || true
        exit 1
    fi
    echo "Core started (PID: $CORE_PID)"
    STARTED_CORE=1
fi

# Run the test
cd "$PROJECT_DIR"
python3 scripts/term-multi-smoke.py
RESULT=$?

# Cleanup
if [ -n "$STARTED_CORE" ]; then
    echo ""
    echo "Stopping core server..."
    kill $CORE_PID 2>/dev/null || true
fi

exit $RESULT
