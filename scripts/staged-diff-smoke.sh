#!/bin/bash
# Staged Diff Smoke Test
# Verifies that working and staged diff modes return different results

set -e

echo "=== STAGED DIFF SMOKE TEST ==="

# Create temp directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
echo "Working in: $TEMP_DIR"

# Initialize git repo
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# Create and commit initial file
echo "line 1" > test.txt
git add test.txt
git commit -q -m "Initial commit"

echo ""
echo "--- Test 1: Unstaged changes ---"
# Modify file but don't stage
echo "line 2" >> test.txt

# Working diff should have content
WORKING_DIFF=$(git diff -- test.txt)
if [ -z "$WORKING_DIFF" ]; then
    echo "FAIL: Working diff should have content"
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "Working diff: has content ✓"

# Staged diff should be empty
STAGED_DIFF=$(git diff --cached -- test.txt)
if [ -n "$STAGED_DIFF" ]; then
    echo "FAIL: Staged diff should be empty"
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "Staged diff: empty ✓"

echo ""
echo "--- Test 2: Staged changes ---"
# Stage the file
git add test.txt

# Working diff should now be empty (changes are staged)
WORKING_DIFF=$(git diff -- test.txt)
if [ -n "$WORKING_DIFF" ]; then
    echo "FAIL: Working diff should be empty after staging"
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "Working diff: empty ✓"

# Staged diff should have content
STAGED_DIFF=$(git diff --cached -- test.txt)
if [ -z "$STAGED_DIFF" ]; then
    echo "FAIL: Staged diff should have content"
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "Staged diff: has content ✓"

echo ""
echo "--- Test 3: Untracked file in staged mode ---"
# Create untracked file
echo "new file" > untracked.txt

# Staged diff for untracked should be empty
STAGED_UNTRACKED=$(git diff --cached -- untracked.txt 2>/dev/null || echo "")
if [ -n "$STAGED_UNTRACKED" ]; then
    echo "FAIL: Staged diff for untracked should be empty"
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "Staged diff for untracked: empty ✓"

# Cleanup
cd /
rm -rf "$TEMP_DIR"

echo ""
echo "=== STAGED DIFF SMOKE PASSED ==="
