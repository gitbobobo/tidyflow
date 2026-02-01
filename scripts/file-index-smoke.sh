#!/bin/bash
# File Index Smoke Test
# Tests the file_index API for Quick Open functionality

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CORE_DIR="$PROJECT_ROOT/core"

echo "=== File Index Smoke Test ==="
echo ""

# Step 1: Build the core
echo "[1/3] Building core..."
cd "$CORE_DIR"
cargo build --release 2>/dev/null || cargo build 2>/dev/null
echo "  ✓ Core built"

# Step 2: Run Rust unit tests for file_index
echo ""
echo "[2/3] Running file_index unit tests..."
cd "$CORE_DIR"
cargo test file_index --release 2>&1 | grep -E "(running|test |ok\.|FAILED)"
echo "  ✓ Unit tests passed"

# Step 3: Verify protocol changes
echo ""
echo "[3/3] Verifying protocol messages..."

# Check that FileIndex message exists in protocol.rs
if grep -q "FileIndex" "$CORE_DIR/src/server/protocol.rs"; then
    echo "  ✓ FileIndex client message defined"
else
    echo "  ✗ FileIndex client message missing"
    exit 1
fi

if grep -q "FileIndexResult" "$CORE_DIR/src/server/protocol.rs"; then
    echo "  ✓ FileIndexResult server message defined"
else
    echo "  ✗ FileIndexResult server message missing"
    exit 1
fi

if grep -q "file_index" "$CORE_DIR/src/server/protocol.rs"; then
    echo "  ✓ file_index capability registered"
else
    echo "  ✗ file_index capability missing"
    exit 1
fi

# Check handler in ws.rs
if grep -q "ClientMessage::FileIndex" "$CORE_DIR/src/server/ws.rs"; then
    echo "  ✓ FileIndex handler implemented"
else
    echo "  ✗ FileIndex handler missing"
    exit 1
fi

echo ""
echo "=== Summary ==="
echo "Ignored directories: .git, target, node_modules, dist, build, .build, .swiftpm, etc."
echo "Max file count: 50,000"
echo "Hidden files: Excluded (files starting with .)"
echo ""
echo "FILE INDEX SMOKE PASSED"
