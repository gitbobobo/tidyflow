# Native Quick Open File Index Check

## Prerequisites
- Core running: `./scripts/run-core.sh`
- App built and running

## Test Cases

1. **Auto-fetch on Quick Open**
   - Start Core, then App
   - Press Cmd+P
   - Expected: Loading spinner briefly, then file list appears

2. **Disconnected State**
   - Stop Core (Ctrl+C)
   - Press Cmd+P
   - Expected: "Disconnected from Core" message with icon

3. **Reconnect Flow**
   - With Core stopped, press Cmd+R
   - Start Core
   - Press Cmd+R again
   - Press Cmd+P
   - Expected: File list loads successfully

4. **Refresh File Index Command**
   - Press Cmd+Shift+P
   - Type "Refresh File Index"
   - Execute command
   - Press Cmd+P
   - Expected: Fresh file list with updated timestamp

5. **Filter Files**
   - Press Cmd+P
   - Type partial filename (e.g., "main")
   - Expected: List filters to matching files

6. **Open File (Placeholder)**
   - Press Cmd+P
   - Select a file, press Enter
   - Expected: New Editor tab opens with file path as title

7. **Truncated Indicator**
   - (Requires Core to return truncated=true)
   - Expected: Blue info banner at bottom of list

8. **No Workspace Selected**
   - Deselect workspace in sidebar
   - Press Cmd+P
   - Expected: "Select a workspace first" message

9. **Cache Expiration**
   - Open Quick Open, note files
   - Wait 10+ minutes (or modify cache expiry for testing)
   - Open Quick Open again
   - Expected: Auto-refresh triggered

10. **Error Handling**
    - (Requires Core to return error)
    - Expected: Warning icon with error message
