# Phase C3-2a: Git Stage/Unstage

## Overview

Add Stage/Unstage functionality to the Native Git Panel, allowing users to stage and unstage files directly from the UI.

## Protocol (v1.6)

### Client Messages

```json
// Stage file or all
{
  "type": "git_stage",
  "project": "default",
  "workspace": "workspace-name",
  "path": "src/file.rs",  // optional, omit for "all" scope
  "scope": "file"         // "file" or "all"
}

// Unstage file or all
{
  "type": "git_unstage",
  "project": "default",
  "workspace": "workspace-name",
  "path": "src/file.rs",  // optional, omit for "all" scope
  "scope": "file"         // "file" or "all"
}
```

### Server Response

```json
{
  "type": "git_op_result",
  "project": "default",
  "workspace": "workspace-name",
  "op": "stage",          // "stage" or "unstage"
  "ok": true,
  "message": null,        // error message if ok=false
  "path": "src/file.rs",  // echoed back, null for "all"
  "scope": "file"         // "file" or "all"
}
```

## Git Commands

| Operation | Scope | Command |
|-----------|-------|---------|
| Stage | file | `git add -- <path>` |
| Stage | all | `git add -A` |
| Unstage | file | `git restore --staged -- <path>` (fallback: `git reset -- <path>`) |
| Unstage | all | `git restore --staged .` (fallback: `git reset`) |

## UI Behavior

### Toolbar
- **Stage All** button: Green background, stages all changes
- **Unstage All** button: Orange background, unstages all staged changes
- Buttons only visible when workspace is a git repo with changes
- Buttons disabled during in-flight operations

### File Row
- **Stage** button (green +): Appears on hover, stages single file
- Shows spinner during in-flight operation
- Click on row still opens diff tab

### Toast Notification
- Success: Green checkmark, "Staged <file>" or "Unstaged <file>"
- Error: Red warning, error message from git
- Auto-dismisses after 2 seconds

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Not a git repo | Buttons disabled (panel shows "Not a Git Repository") |
| Disconnected | Toast shows "Disconnected" |
| Git command fails | Toast shows error message |
| Path escape attempt | Rejected by core with error |

## State Management

### In-Flight Tracking
```swift
struct GitOpInFlight: Hashable {
    let op: String       // "stage" or "unstage"
    let path: String?    // nil for "all" scope
    let scope: String    // "file" or "all"
}

// Tracked per workspace
gitOpsInFlight: [String: Set<GitOpInFlight>]
```

### Auto-Refresh
After successful operation:
1. Refresh git status for workspace
2. If active diff tab matches the staged/unstaged path, refresh diff

## Files Modified

### Core (Rust)
- `core/src/server/protocol.rs`: Added GitStage, GitUnstage, GitOpResult messages
- `core/src/server/git_tools.rs`: Added git_stage(), git_unstage() functions
- `core/src/server/ws.rs`: Added handlers for git_stage, git_unstage

### App (Swift)
- `app/TidyFlow/Networking/ProtocolModels.swift`: Added GitOpResult, GitOpInFlight
- `app/TidyFlow/Networking/WSClient.swift`: Added requestGitStage(), requestGitUnstage(), onGitOpResult
- `app/TidyFlow/Views/Models.swift`: Added gitOpsInFlight, gitOpToast, gitStage(), gitUnstage()
- `app/TidyFlow/Views/NativeGitPanelView.swift`: Added Stage All/Unstage All toolbar, Stage button per row, toast UI

## Limitations

1. No partial staging (git add -p) - full file only
2. No Discard functionality (deferred to C3-2b)
3. No staged/unstaged distinction in status display (core returns simplified status)
