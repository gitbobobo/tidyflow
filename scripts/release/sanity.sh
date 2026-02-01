#!/bin/bash
# TidyFlow Release Sanity Test Suite
# 一键运行所有核心 smoke tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

run_test() {
    local name="$1"
    local script="$2"

    echo -e "\n${YELLOW}▶ Running: $name${NC}"

    if [[ ! -f "$PROJECT_ROOT/$script" ]]; then
        echo -e "${YELLOW}⏭ SKIPPED: $script not found${NC}"
        ((SKIPPED++))
        return 0
    fi

    if ! [[ -x "$PROJECT_ROOT/$script" ]]; then
        chmod +x "$PROJECT_ROOT/$script"
    fi

    if "$PROJECT_ROOT/$script" > /dev/null 2>&1; then
        echo -e "${GREEN}✅ PASSED: $name${NC}"
        ((PASSED++))
    else
        echo -e "${RED}❌ FAILED: $name${NC}"
        ((FAILED++))
        return 1
    fi
}

# Main
print_header "TidyFlow Release Sanity Tests"

echo -e "\n${BLUE}Project Root: $PROJECT_ROOT${NC}"
echo -e "${BLUE}Date: $(date '+%Y-%m-%d %H:%M:%S')${NC}"

# Ensure core is built
print_header "Step 1: Build Core"
echo -e "${YELLOW}▶ Building tidyflow-core...${NC}"
if (cd "$PROJECT_ROOT/core" && cargo build --release 2>/dev/null); then
    echo -e "${GREEN}✅ Core build successful${NC}"
else
    echo -e "${RED}❌ Core build failed${NC}"
    exit 1
fi

# Run smoke tests
print_header "Step 2: Smoke Tests"

# Core smoke tests (must pass)
run_test "File Index API" "scripts/file-index-smoke.sh" || true
run_test "Git Tools API" "scripts/git-tools-smoke.sh" || true
run_test "Staged Diff Mode" "scripts/staged-diff-smoke.sh" || true

# Optional smoke tests (may skip if dependencies missing)
run_test "Editor API" "scripts/editor-smoke.sh" || true
run_test "Multi-Workspace" "scripts/multi-workspace-smoke.sh" || true

# Summary
print_header "Test Summary"

echo -e "\n${GREEN}Passed:  $PASSED${NC}"
echo -e "${RED}Failed:  $FAILED${NC}"
echo -e "${YELLOW}Skipped: $SKIPPED${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  🎉 RELEASE SANITY PASSED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ⚠️  RELEASE SANITY FAILED - $FAILED test(s) failed${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi
