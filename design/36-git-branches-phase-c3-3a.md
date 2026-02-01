# Phase C3-3a: Git Branch List + Switch

## Overview

This phase implements branch listing and switching functionality in the Native Git panel. Users can view the current branch, browse available local branches, and switch between them.

## Protocol Extensions

### New Client Messages

```rust
// Request branch list
GitBranches {
    project: String,
    workspace: String,
}

// Request branch switch
GitSwitchBranch {
    project: String,
    workspace: String,
    branch: String,
}
```

### New Server Messages

```rust
// Branch list response
GitBranchesResult {
    project: String,
    workspace: String,
    current: String,           // Current branch name
    branches: Vec<GitBranchInfo>,
}

// Branch info
GitBranchInfo {
    name: String,
}

// Switch result uses existing GitOpResult with op="switch_branch"
```

## Core Implementation

### git_tools.rs

**git_branches(workspace_root)**
- Uses `git rev-parse --abbrev-ref HEAD` to get current branch
- Uses `git for-each-ref refs/heads --format="%(refname:short)"` to list local branches
- Returns `GitBranchesResult { current, branches }`

**git_switch_branch(workspace_root, branch)**
- Tries `git switch <branch>` first (Git 2.23+)
- Falls back to `git checkout <branch>` for older Git versions
- Returns `GitOpResult` with op="switch_branch"

### Error Handling

| Scenario | Error Message |
|----------|---------------|
| Not a git repo | "Not a git repository" |
| Uncommitted changes | "error: Your local changes to the following files would be overwritten..." |
| Branch not found | "error: pathspec 'xxx' did not match any file(s) known to git" |

## Native UI

### Branch Selector (GitPanelToolbar)

Location: Below the Git title row, above Stage All buttons

```
┌─────────────────────────────────────┐
│ Git                    🔍  ↻        │
├─────────────────────────────────────┤
│ ⎇ main ▼                            │  <- Branch selector
├─────────────────────────────────────┤
│ [Stage All] [Unstage All] [Discard] │
├─────────────────────────────────────┤
│ ... file list ...                   │
└─────────────────────────────────────┘
```

### Branch Picker Popover (BranchPickerView)

```
┌─────────────────────────────────────┐
│ 🔍 Search branches...               │
├─────────────────────────────────────┤
│ ✓ main                              │  <- Current (checkmark)
│   feature/auth                      │
│   feature/ui-redesign               │
│   bugfix/login-error                │
│   ...                               │
└─────────────────────────────────────┘
```

Features:
- Search/filter branches by name
- Current branch marked with checkmark
- Click to switch (disabled for current branch)
- Loading spinner during switch operation

## State Management

### GitBranchCache

```swift
struct GitBranchCache {
    var current: String
    var branches: [GitBranchItem]
    var isLoading: Bool
    var error: String?
    var updatedAt: Date
}
```

### In-Flight Tracking

```swift
// Track branch switch in progress
@Published var branchSwitchInFlight: [String: String] = [:]  // workspace -> target branch
```

## Switch Success Behavior

When branch switch succeeds:
1. Show toast: "Switched to branch 'xxx'"
2. Refresh git branches (update current)
3. Refresh git status (file list changes)
4. Close all open diff tabs (they're now stale)

## Switch Failure Behavior

When branch switch fails:
1. Show error toast with git error message
2. Keep current branch unchanged
3. Keep diff tabs open (no change occurred)

Common failure: "Your local changes would be overwritten"
- User must commit, stash, or discard changes first

## Files Modified

### Core (Rust)
- `core/src/server/protocol.rs` - New messages and types
- `core/src/server/git_tools.rs` - git_branches(), git_switch_branch()
- `core/src/server/ws.rs` - Message handlers

### App (Swift)
- `app/TidyFlow/Networking/ProtocolModels.swift` - GitBranchesResult, GitBranchCache
- `app/TidyFlow/Networking/WSClient.swift` - requestGitBranches(), requestGitSwitchBranch()
- `app/TidyFlow/Views/Models.swift` - Branch cache, fetch/switch methods
- `app/TidyFlow/Views/BranchPickerView.swift` - New file
- `app/TidyFlow/Views/NativeGitPanelView.swift` - Branch selector UI

## Scope Boundaries

### In Scope (C3-3a)
- List local branches
- Display current branch
- Switch between local branches
- Search/filter branches
- Error handling for dirty repo

### Out of Scope (Future Phases)
- Create new branch (C3-3b)
- Delete branch
- Remote branches / tracking
- Stash / auto-commit before switch
- Merge / rebase
