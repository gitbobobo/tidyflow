# Phase C2-2a: Native Unified Diff Rendering

## Overview

This phase implements native unified diff rendering in SwiftUI, replacing the WebView-based diff viewer for improved performance and native integration.

## Data Flow

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
│  NativeDiffView │────▶│   AppState   │────▶│    WSClient     │
│   (SwiftUI)     │     │  (diffCache) │     │ (requestGitDiff)│
└─────────────────┘     └──────────────┘     └─────────────────┘
        ▲                      │                      │
        │                      │                      ▼
        │                      │              ┌──────────────┐
        │                      │              │  Core Server │
        │                      │              │  (git_diff)  │
        │                      │              └──────────────┘
        │                      │                      │
        │                      ▼                      │
        │               ┌──────────────┐              │
        └───────────────│  DiffParser  │◀─────────────┘
                        │ (parse text) │   git_diff_result
                        └──────────────┘
```

## Protocol Messages

### Request (Native → Core)
```json
{
  "type": "git_diff",
  "project": "default",
  "workspace": "/path/to/workspace",
  "path": "src/file.ts",
  "mode": "working"  // or "staged"
}
```

### Response (Core → Native)
```json
{
  "type": "git_diff_result",
  "project": "default",
  "workspace": "/path/to/workspace",
  "path": "src/file.ts",
  "code": "M",           // Git status code
  "format": "unified",
  "text": "diff --git...", // Full diff text
  "is_binary": false,
  "truncated": false,
  "mode": "working"
}
```

## Diff Parsing Rules

### Line Types
| Prefix | Kind | Description |
|--------|------|-------------|
| `diff --git`, `---`, `+++`, `index` | header | File header lines |
| `@@` | hunk | Hunk header with line ranges |
| `+` | add | Added line |
| `-` | del | Removed line |
| ` ` (space) | context | Unchanged context line |

### Line Number Mapping
- **Hunk header**: Parse `@@ -oldStart,oldLen +newStart,newLen @@` to initialize counters
- **Context lines**: Increment both old and new line numbers
- **Added lines**: Increment only new line number
- **Removed lines**: Increment only old line number

### Navigation Target
| Line Kind | Target Line |
|-----------|-------------|
| context | newLineNumber |
| add | newLineNumber |
| del | newLineNumber (nearest context position) |
| header/hunk | Not navigable |

## Caching Strategy

### Cache Key
```
"{workspace}:{path}:{mode}"
```

### Cache Structure (DiffCache)
- `text`: Raw diff text
- `parsedLines`: Array of DiffLine models
- `isLoading`: Loading state
- `error`: Error message if failed
- `isBinary`: Binary file flag
- `truncated`: Truncation flag
- `code`: Git status code
- `updatedAt`: Timestamp for expiration

### Expiration
- Diff cache expires after 30 seconds (more volatile than file index)
- Manual refresh available via toolbar button

## Edge Cases

### Binary Files
- Core returns `is_binary: true`
- Native shows "Binary file - Cannot display diff" message
- No line navigation available

### Truncated Diffs
- Core truncates at 1MB
- Native shows warning banner + available content
- User informed that diff is incomplete

### Deleted Files
- Detected via `code.hasPrefix("D")`
- Line navigation disabled
- Tooltip shows "File deleted - cannot open in editor"

### Empty Diff
- Shows "No changes" message
- Different text for working vs staged mode

## Fallback Strategy

### Debug Flag
```swift
appState.useNativeDiff = true  // Default: native
appState.useNativeDiff = false // Fallback: WebView
```

### When to Use Fallback
- Set `useNativeDiff = false` in AppState for debugging
- Web diff code preserved but not active by default

## Files Modified

| File | Changes |
|------|---------|
| `ProtocolModels.swift` | Added GitDiffResult, DiffCache, DiffLine, DiffParser |
| `WSClient.swift` | Added requestGitDiff(), onGitDiffResult handler |
| `Models.swift` | Added diffCache, fetchGitDiff(), getDiffCache() |
| `TabContentHostView.swift` | Updated DiffContentView to use NativeDiffView |
| `NativeDiffView.swift` | New file - Native diff rendering |

## UI Components

### NativeDiffView
- Main container with toolbar, content, status bar
- Handles loading, error, binary, truncated states

### DiffLineRow
- Single diff line with line numbers and text
- Hover effect for navigable lines
- Click handler for editor navigation

### NativeDiffToolbar
- Working/Staged segmented picker
- Refresh button
- Help text

### NativeDiffStatusBar
- File path display
- Current mode indicator
