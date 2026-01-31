#!/bin/bash
# TidyFlow Core - Run Script
# Starts the PTY WebSocket server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default port, can be overridden via TIDYFLOW_PORT
export TIDYFLOW_PORT="${TIDYFLOW_PORT:-47999}"

# Set log level if not set
export RUST_LOG="${RUST_LOG:-info}"

echo "Building TidyFlow Core..."
cargo build --manifest-path "$PROJECT_ROOT/core/Cargo.toml"

echo ""
echo "Starting TidyFlow Core..."
echo "  WebSocket: ws://127.0.0.1:${TIDYFLOW_PORT}/ws"
echo "  Log level: ${RUST_LOG}"
echo ""

exec "$PROJECT_ROOT/core/target/debug/tidyflow-core"
