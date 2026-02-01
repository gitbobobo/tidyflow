# Phase C3-1: Native Git Status Panel (Read-Only)

## Overview

Replace the placeholder Git panel in the right tool panel with a native SwiftUI implementation that displays git status and allows opening diff tabs.

## Goals

1. Display git status list (M/A/D/??/R/C etc.) in native SwiftUI
2. Support refresh button and file name filtering
3. Show appropriate empty states (non-git repo, no changes, disconnected)
4. Click file to open Native Diff Tab (working mode)
5. Workspace-scoped: status updates when workspace changes

## Protocol Mapping

### Request: `git_status`

```json
{
  "type": "git_status",
  "project": "default",
  "workspace": "workspace-key"
}
```

### Response: `git_status_result`

```json
{
  "type": "git_status_result",
  "project": "default",
  "workspace": "workspace-key",
  "is_git_repo": true,
  "items": [
    {
      "path": "src/main.rs",
      "status": "M",
      "staged": false,
      "rename_from": null
    },
    {
      "path": "new-file.txt",
      "status": "??",
      "staged": null,
      "rename_from": null
    }
  ],
  "error": null
}
```

### Status Codes

| Code | Meaning |
|------|---------|
| M | Modified |
| A | Added |
| D | Deleted |
| ?? | Untracked |
| R | Renamed |
| C | Copied |
| U | Unmerged |
| ! | Ignored |

## Data Structures

### GitStatusItem

```swift
struct GitStatusItem: Identifiable {
    let id: String      // path as unique ID
    let path: String
    let status: String  // M, A, D, ??, R, C, etc.
    let staged: Bool?   // optional, from core
    let renameFrom: String?  // for renamed files
}
```

### GitStatusCache

```swift
struct GitStatusCache {
    var items: [GitStatusItem]
    var isLoading: Bool
    var error: String?
    var isGitRepo: Bool
    var updatedAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(updatedAt) > 60
    }
}
```

### AppState Extensions

```swift
// New property
@Published var gitStatusCache: [String: GitStatusCache] = [:]

// New methods
func fetchGitStatus(workspaceKey: String)
func refreshGitStatus()
func getGitStatusCache(workspaceKey: String) -> GitStatusCache?
func shouldFetchGitStatus(workspaceKey: String) -> Bool
```

## UI Components

### NativeGitPanelView

Main container view with:
- GitPanelToolbar (title, filter, refresh)
- GitPanelContent (list or empty state)

### GitPanelToolbar

- "Git" title
- Filter toggle/input (magnifying glass icon)
- Refresh button (arrow.clockwise icon)

### GitStatusList

- LazyVStack with GitStatusRow items
- Footer showing update time and file count

### GitStatusRow

- Status badge (colored single character)
- File name (bold)
- Directory path (secondary)
- Rename info if applicable
- Hover state with arrow indicator

### Empty States

| Condition | Icon | Title | Subtitle |
|-----------|------|-------|----------|
| Disconnected | wifi.slash | Disconnected | Connect to Core... |
| Not git repo | folder.badge.questionmark | Not a Git Repository | This workspace is not... |
| Error | exclamationmark.triangle | Error | {error message} |
| No changes | checkmark.circle | No Changes | Working tree is clean |
| No filter matches | magnifyingglass | No Matches | No files match '...' |

## Cache Strategy

1. **Auto-fetch on appear**: When Git panel becomes visible, fetch if cache is empty or expired (>60s)
2. **Workspace change**: Re-fetch when selectedWorkspaceKey changes
3. **Manual refresh**: Refresh button forces immediate fetch
4. **Loading state**: Show spinner while loading, preserve existing items

## File Operations

### Opening Diff Tab

When user clicks a file row:

```swift
appState.addDiffTab(workspaceKey: ws, path: item.path, mode: .working)
```

This reuses the existing diff tab infrastructure from Phase C2-2a/C2-2b.

### Deleted Files

Deleted files (status "D") can still be clicked to open diff tab. The NativeDiffView already handles deleted file state appropriately.

## Files Modified

| File | Changes |
|------|---------|
| `ProtocolModels.swift` | Add GitStatusItem, GitStatusResult, GitStatusCache |
| `WSClient.swift` | Add requestGitStatus(), onGitStatusResult handler |
| `Models.swift` | Add gitStatusCache, fetch/refresh methods |
| `NativeGitPanelView.swift` | New file - complete Git panel implementation |
| `RightToolPanelView.swift` | Switch Git tool to NativeGitPanelView |

## Not Implemented (Phase C3-2+)

- Stage/unstage files
- Discard changes
- Commit
- Branch operations
- Stash operations
- Virtual scrolling for large lists

## Testing Checklist

See `scripts/native-git-panel-check.md`

## Future Extensions

### Phase C3-2: Git Write Operations

- Stage/unstage individual files
- Discard changes
- Commit with message

### Phase C3-3: Git Branches

- Branch list
- Checkout branch
- Create branch
- Merge operations
