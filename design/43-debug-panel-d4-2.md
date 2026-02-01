# D4-2: Debug Panel Design

## Overview
Hidden developer panel accessible via Cmd+Shift+D for debugging Core process and WebSocket connection issues.

## Access
- **Shortcut**: Cmd+Shift+D (toggle)
- **No menu entry**: Developer-only feature, not exposed to regular users
- **Escape key**: Closes panel

## Panel Contents

### 1. Core Process Section
| Field | Source | Description |
|-------|--------|-------------|
| Status | `coreProcessManager.status` | Running/Stopped/Starting/Failed with color badge |
| Port | `coreProcessManager.currentPort` | Current port number |
| PID | Extracted from `.running` status | Process ID |
| Auto-Restart | `restartAttempts/autoRestartLimit` | e.g., "0/3" |
| Last Exit | `lastExitInfo` | Only shown if process crashed |

### 2. WebSocket Section
| Field | Source | Description |
|-------|--------|-------------|
| State | `wsClient.isConnected` | Connected/Disconnected with color badge |
| URL | `wsClient.currentURLString` | e.g., "ws://127.0.0.1:8080/ws" |

### 3. Log Viewer Section
- **Source**: `~/Library/Logs/TidyFlow/core.log`
- **Display**: Last 300 lines (tail read)
- **Actions**:
  - Refresh: Manual reload from file
  - Copy: Copy log content to clipboard
  - Reveal in Finder: Open log directory

## Performance Strategy

### Log Tail Reading
- **Max bytes**: 128KB from end of file
- **Max lines**: 300 lines
- **Background queue**: Read on `userInitiated` QoS
- **No auto-refresh**: Manual refresh only to avoid CPU usage

### File Reading Algorithm
1. Get file size
2. Seek to `max(0, fileSize - 128KB)`
3. Read remaining bytes
4. Decode UTF-8 with replacement for invalid bytes
5. Split by newlines, discard first partial line
6. Take last 300 lines

## Privacy Considerations
- Log file may contain file paths and workspace names
- No sensitive data (passwords, tokens) should be in logs
- Panel is hidden from regular users (no menu entry)

## Files Created/Modified

### New Files
- `app/TidyFlow/Debug/DebugPanelView.swift` - Main panel UI
- `app/TidyFlow/Debug/LogTailReader.swift` - Efficient tail reader

### Modified Files
- `app/TidyFlow/Views/Models.swift` - Added `debugPanelPresented` state
- `app/TidyFlow/Views/KeybindingHandler.swift` - Added Cmd+Shift+D binding
- `app/TidyFlow/ContentView.swift` - Added debug panel overlay
- `app/TidyFlow/Process/CoreProcessManager.swift` - Added `lastExitInfo` getter
- `app/TidyFlow/Networking/WSClient.swift` - Added `currentURLString` getter
- `app/TidyFlow.xcodeproj/project.pbxproj` - Added new files to target

## Future Enhancements (Not in D4-2)
- Log search/filter
- Multiple log file tabs
- Auto-refresh with rate limiting
- Export logs to file
- Memory usage display
