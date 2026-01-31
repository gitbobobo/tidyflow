#!/bin/bash
# Multi-Workspace Parallel Smoke Test
# Verifies that multiple workspaces can run in parallel with isolated PTY cwd

set -e

WS_URL="${WS_URL:-ws://127.0.0.1:47999/ws}"
DEMO_PROJECT="${DEMO_PROJECT:-demo-project}"
WS_A="ws-a"
WS_B="ws-b"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# Check dependencies
command -v websocat >/dev/null 2>&1 || fail "websocat required: brew install websocat"
command -v jq >/dev/null 2>&1 || fail "jq required: brew install jq"

log "Multi-Workspace Parallel Smoke Test"
log "===================================="

# Helper: send message and get response
send_recv() {
    local msg="$1"
    echo "$msg" | websocat -n1 "$WS_URL" 2>/dev/null
}

# Helper: send message, wait for specific response type
send_wait() {
    local msg="$1"
    local wait_type="$2"
    local timeout="${3:-5}"

    (echo "$msg"; sleep "$timeout") | websocat "$WS_URL" 2>/dev/null | while read -r line; do
        local type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        if [ "$type" = "$wait_type" ]; then
            echo "$line"
            break
        fi
    done
}

# Step 1: Connect and verify hello
log "Step 1: Connecting to $WS_URL..."
HELLO=$(send_recv '{"type":"ping"}' | head -1)
if [ -z "$HELLO" ]; then
    fail "Cannot connect to server. Is tidyflow-core running?"
fi
log "Connected successfully"

# Step 2: Check if demo project exists
log "Step 2: Checking for demo project..."
PROJECTS=$(send_wait '{"type":"list_projects"}' "projects")
HAS_PROJECT=$(echo "$PROJECTS" | jq -r ".items[] | select(.name==\"$DEMO_PROJECT\") | .name" 2>/dev/null)

if [ -z "$HAS_PROJECT" ]; then
    warn "Demo project '$DEMO_PROJECT' not found."
    warn "Please create it first with: tidyflow-core import <repo-url> --name $DEMO_PROJECT"
    warn "Then create workspaces: tidyflow-core workspace create $DEMO_PROJECT $WS_A"
    warn "                        tidyflow-core workspace create $DEMO_PROJECT $WS_B"
    fail "Demo project not found"
fi
log "Found project: $DEMO_PROJECT"

# Step 3: Check workspaces
log "Step 3: Checking workspaces..."
WORKSPACES=$(send_wait "{\"type\":\"list_workspaces\",\"project\":\"$DEMO_PROJECT\"}" "workspaces")
WS_A_ROOT=$(echo "$WORKSPACES" | jq -r ".items[] | select(.name==\"$WS_A\") | .root" 2>/dev/null)
WS_B_ROOT=$(echo "$WORKSPACES" | jq -r ".items[] | select(.name==\"$WS_B\") | .root" 2>/dev/null)

if [ -z "$WS_A_ROOT" ] || [ -z "$WS_B_ROOT" ]; then
    warn "Workspaces $WS_A and/or $WS_B not found"
    warn "Create them with:"
    warn "  tidyflow-core workspace create $DEMO_PROJECT $WS_A"
    warn "  tidyflow-core workspace create $DEMO_PROJECT $WS_B"
    fail "Required workspaces not found"
fi
log "Found workspace $WS_A: $WS_A_ROOT"
log "Found workspace $WS_B: $WS_B_ROOT"

# Step 4: Create terminals in both workspaces (parallel)
log "Step 4: Creating terminals in parallel workspaces..."

# Use a persistent connection for multi-message test
FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap "rm -f $FIFO" EXIT

# Start websocat in background
websocat "$WS_URL" < "$FIFO" > /tmp/ws_output.txt 2>/dev/null &
WS_PID=$!
exec 3>"$FIFO"

# Wait for hello
sleep 0.5

# Create terminal in ws-a
echo "{\"type\":\"term_create\",\"project\":\"$DEMO_PROJECT\",\"workspace\":\"$WS_A\"}" >&3
sleep 0.5

# Create terminal in ws-b
echo "{\"type\":\"term_create\",\"project\":\"$DEMO_PROJECT\",\"workspace\":\"$WS_B\"}" >&3
sleep 0.5

# List terminals
echo '{"type":"term_list"}' >&3
sleep 0.5

# Close connection
exec 3>&-
wait $WS_PID 2>/dev/null || true

# Parse results
TERM_LIST=$(grep '"type":"term_list"' /tmp/ws_output.txt | tail -1)
TERM_A=$(echo "$TERM_LIST" | jq -r ".items[] | select(.workspace==\"$WS_A\") | .term_id" 2>/dev/null)
TERM_B=$(echo "$TERM_LIST" | jq -r ".items[] | select(.workspace==\"$WS_B\") | .term_id" 2>/dev/null)
CWD_A=$(echo "$TERM_LIST" | jq -r ".items[] | select(.workspace==\"$WS_A\") | .cwd" 2>/dev/null)
CWD_B=$(echo "$TERM_LIST" | jq -r ".items[] | select(.workspace==\"$WS_B\") | .cwd" 2>/dev/null)

if [ -z "$TERM_A" ] || [ -z "$TERM_B" ]; then
    warn "Could not create terminals in both workspaces"
    cat /tmp/ws_output.txt
    fail "Terminal creation failed"
fi

log "Terminal A (${WS_A}): $TERM_A"
log "  CWD: $CWD_A"
log "Terminal B (${WS_B}): $TERM_B"
log "  CWD: $CWD_B"

# Step 5: Verify CWD isolation
log "Step 5: Verifying CWD isolation..."

if [[ "$CWD_A" != *"$WS_A"* ]]; then
    fail "Terminal A cwd does not contain workspace name: $CWD_A"
fi

if [[ "$CWD_B" != *"$WS_B"* ]]; then
    fail "Terminal B cwd does not contain workspace name: $CWD_B"
fi

if [ "$CWD_A" = "$CWD_B" ]; then
    fail "Both terminals have same cwd - isolation failed!"
fi

log "CWD isolation verified: terminals have different working directories"

# Step 6: Verify term_list includes workspace info
log "Step 6: Verifying term_list includes workspace info..."
PROJ_A=$(echo "$TERM_LIST" | jq -r ".items[] | select(.workspace==\"$WS_A\") | .project" 2>/dev/null)
PROJ_B=$(echo "$TERM_LIST" | jq -r ".items[] | select(.workspace==\"$WS_B\") | .project" 2>/dev/null)

if [ "$PROJ_A" != "$DEMO_PROJECT" ] || [ "$PROJ_B" != "$DEMO_PROJECT" ]; then
    fail "term_list missing project info"
fi
log "term_list includes project/workspace info"

# Cleanup
rm -f /tmp/ws_output.txt

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}MULTI WORKSPACE SMOKE PASSED${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Verified:"
echo "  - Multiple workspaces can be active simultaneously"
echo "  - Each terminal is bound to its workspace"
echo "  - PTY cwd is isolated per workspace"
echo "  - term_list returns workspace binding info"
