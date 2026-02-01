# Phase C3-2b: Git Discard Implementation

## Overview

This phase implements the Git Discard feature, allowing users to discard working tree changes with explicit confirmation dialogs to prevent accidental data loss.

## Safety Strategy

### Core Principles
1. **Never silent execution** - All discard operations require explicit user confirmation
2. **Clear messaging** - Users must understand what will be lost
3. **Differentiate file types** - Untracked files (deletion) vs tracked files (restore)
4. **No staged file discard** - Staged changes are protected by default

### File Type Handling

| File Status | Action | Git Command | Warning Level |
|-------------|--------|-------------|---------------|
| Modified (M) | Restore to HEAD | `git restore -- <path>` | Standard |
| Deleted (D) | Restore file | `git restore -- <path>` | Standard |
| Untracked (??) | Delete file | `git clean -f -- <path>` | High (explicit "delete" wording) |
| Staged only | Disabled | N/A | Tooltip explains limitation |

### Discard All Behavior
- Only affects **tracked** files with working tree changes
- Does NOT delete untracked files (safety measure)
- Uses `git restore .` command

## Protocol Extension

### New Message: GitDiscard
```rust
ClientMessage::GitDiscard {
    project: String,
    workspace: String,
    path: Option<String>,  // None = discard all
    scope: String,         // "file" or "all"
}
```

### Response: GitOpResult (reused)
```rust
ServerMessage::GitOpResult {
    project: String,
    workspace: String,
    op: "discard",
    ok: bool,
    message: Option<String>,  // "File deleted" for untracked
    path: Option<String>,
    scope: String,
}
```

## UI Specifications

### Single File Discard Button
- **Icon**: `arrow.uturn.backward` (tracked) or `trash` (untracked)
- **Color**: Red
- **Position**: Next to Stage button on hover
- **Disabled when**: File is staged-only

### Discard All Button
- **Location**: Toolbar, after Unstage All
- **Style**: Red background (0.15 opacity)
- **Disabled when**: No tracked changes exist

### Confirmation Dialogs

#### Single File (Tracked)
```
Title: "Discard Changes?"
Message: "This will discard all local changes in '<filename>'. This cannot be undone."
Buttons: [Cancel] [Discard (destructive)]
```

#### Single File (Untracked)
```
Title: "Delete File?"
Message: "This will permanently delete '<filename>'. This cannot be undone."
Buttons: [Cancel] [Delete (destructive)]
```

#### Discard All
```
Title: "Discard All Changes?"
Message: "This will discard all local changes in tracked files. This cannot be undone."
Buttons: [Cancel] [Discard (destructive)]
```

## Post-Operation Behavior

1. **Git Status Refresh**: Automatic after successful discard
2. **Diff Tab Handling**:
   - If discarded file's diff tab is open → Close the tab
   - Prevents showing stale/empty diff
3. **Toast Notification**:
   - Success: "Discarded changes in <path>" or "Deleted <path>"
   - Error: Shows error message from Core

## Error Handling

| Error | User Message | Recovery |
|-------|--------------|----------|
| Not a git repo | "Not a git repository" | N/A |
| Path escape | "Path escapes workspace root" | N/A |
| File not found | "File not found" | Refresh status |
| Permission denied | Shows system error | Check file permissions |

## Implementation Files

### Core (Rust)
- `core/src/server/protocol.rs` - GitDiscard message definition
- `core/src/server/git_tools.rs` - git_discard() implementation
- `core/src/server/ws.rs` - WebSocket handler

### App (Swift)
- `app/TidyFlow/Networking/WSClient.swift` - requestGitDiscard()
- `app/TidyFlow/Views/Models.swift` - gitDiscard(), closeDiffTab()
- `app/TidyFlow/Views/NativeGitPanelView.swift` - UI components

## Limitations (By Design)

1. **No Undo/Recycle Bin** - Discarded changes are permanently lost
2. **No Stash Integration** - Users must manually stash if needed
3. **No Partial Discard** - Cannot discard specific hunks
4. **No Staged Discard** - Must unstage first to discard
5. **Discard All excludes untracked** - Safety measure

## Future Enhancements (Not in Scope)

- Stash before discard option
- Partial/hunk-level discard
- Staged file discard with explicit mode
- Undo via reflog integration
