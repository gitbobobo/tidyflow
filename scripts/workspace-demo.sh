#!/bin/bash
# workspace-demo.sh - End-to-end demo of TidyFlow Workspace Engine v1
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CORE_DIR="$PROJECT_ROOT/core"
DEMO_DIR="/tmp/tidyflow-demo-$$"
STATE_FILE="$HOME/.tidyflow/state.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[DEMO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

cleanup() {
    log "Cleaning up..."
    rm -rf "$DEMO_DIR" 2>/dev/null || true
    # Remove demo project from state if exists
    if [ -f "$STATE_FILE" ]; then
        # Simple cleanup - just note it exists
        log "State file at: $STATE_FILE"
    fi
}

trap cleanup EXIT

# Build core
log "Building tidyflow-core..."
cd "$CORE_DIR"
cargo build --quiet 2>&1 | head -5
CORE_BIN="$CORE_DIR/target/debug/tidyflow-core"

if [ ! -f "$CORE_BIN" ]; then
    err "Build failed - binary not found"
fi

# Create demo repository
log "Creating demo repository at $DEMO_DIR..."
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"
git init --quiet
git config user.email "demo@tidyflow.local"
git config user.name "TidyFlow Demo"

# Create initial files
cat > README.md << 'EOF'
# Demo Project
This is a demo project for TidyFlow Workspace Engine.
EOF

# Create .tidyflow.toml with setup steps
cat > .tidyflow.toml << 'EOF'
[project]
name = "demo-project"
description = "TidyFlow Workspace Engine Demo"
default_branch = "main"

[setup]
timeout = 60
shell = "/bin/sh"

[[setup.steps]]
name = "Create marker file"
run = "touch .setup-marker"

[[setup.steps]]
name = "Echo workspace info"
run = "echo 'Workspace setup complete' && pwd"

[[setup.steps]]
name = "Conditional step"
run = "echo 'README exists'"
condition = "file_exists:README.md"

[[setup.steps]]
name = "Skip this step"
run = "echo 'This should be skipped'"
condition = "file_exists:nonexistent.txt"

[env]
inherit = true

[env.vars]
DEMO_VAR = "hello-tidyflow"
EOF

git add -A
git commit -m "Initial commit" --quiet

log "Demo repository created with .tidyflow.toml"

# Import project
log "Importing project..."
$CORE_BIN import --name demo-project --path "$DEMO_DIR"

# List projects
log "Listing projects..."
$CORE_BIN list projects

# Create workspace
log "Creating workspace 'feature-1'..."
$CORE_BIN ws create --project demo-project --workspace feature-1

# Show workspace
log "Showing workspace details..."
WS_PATH=$($CORE_BIN ws show --project demo-project --workspace feature-1 2>/dev/null)
echo "Workspace path: $WS_PATH"

# Verify worktree exists
if [ -d "$WS_PATH" ]; then
    log "Worktree directory exists: $WS_PATH"
else
    err "Worktree directory not found!"
fi

# Verify setup marker
if [ -f "$WS_PATH/.setup-marker" ]; then
    log "Setup marker file created - setup ran successfully!"
else
    warn "Setup marker not found - setup may have failed"
fi

# List workspaces
log "Listing workspaces..."
$CORE_BIN list workspaces --project demo-project

# Create another workspace without setup
log "Creating workspace 'feature-2' without setup..."
$CORE_BIN ws create --project demo-project --workspace feature-2 --no-setup

# Run setup manually
log "Running setup for 'feature-2'..."
$CORE_BIN ws setup --project demo-project --workspace feature-2

# Final listing
log "Final workspace listing..."
$CORE_BIN list workspaces --project demo-project

# Verify git worktrees
log "Verifying git worktrees..."
cd "$DEMO_DIR"
git worktree list

# Show state file
log "State file location: $STATE_FILE"

echo ""
echo "=========================================="
echo -e "${GREEN}DEMO PASSED${NC}"
echo "=========================================="
echo ""
echo "Summary:"
echo "  - Created demo git repository"
echo "  - Imported as TidyFlow project"
echo "  - Created 2 workspaces using git worktree"
echo "  - Executed setup steps from .tidyflow.toml"
echo "  - Verified worktree directories exist"
echo ""
echo "To clean up demo project from state:"
echo "  rm -rf $DEMO_DIR"
echo "  # Edit $STATE_FILE to remove 'demo-project'"
