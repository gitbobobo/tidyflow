# Diff Navigation Verification

## Prerequisites
- TidyFlow app running with WebSocket connection
- A workspace with modified files (git status shows changes)

## Test Cases

### 1. Open File Button
1. Open Git view → click a modified file → Diff Tab opens
2. Click "📄 Open file" button
3. **Expected**: Editor Tab opens with the file content

### 2. Line Click Navigation
1. In Diff Tab, click any green (`+`) line
2. **Expected**: Editor opens, scrolls to that line, yellow highlight for 2s

### 3. Deleted Line Navigation
1. Click a red (`-`) line in the diff
2. **Expected**: Editor opens at nearest context line (where deletion occurred)

### 4. Context Line Navigation
1. Click a white/gray context line (starts with space)
2. **Expected**: Editor opens at that exact line

### 5. Deleted File Handling
1. Delete a tracked file: `git rm somefile.txt`
2. Open its diff (status code `D`)
3. **Expected**: "Open file" button disabled, clicks do nothing

### 6. Existing Tab Reuse
1. Open a file in Editor Tab
2. Open its Diff Tab, click a line
3. **Expected**: Switches to existing Editor Tab, scrolls to line

### 7. Highlight Timeout
1. Click a diff line to navigate
2. Wait 2 seconds
3. **Expected**: Yellow highlight disappears automatically

## Quick Smoke Test
```bash
# 1. Make a change to any file
echo "// test" >> app/TidyFlow/Web/main.js

# 2. Open TidyFlow, select workspace, open Git view

# 3. Click main.js in git status list

# 4. Click the green "+ // test" line

# 5. Verify: Editor opens at that line with highlight
```
