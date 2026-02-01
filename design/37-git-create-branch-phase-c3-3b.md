# Phase C3-3b: Git Create Branch

## Overview
Add "Create new branch" functionality to the BranchPicker, allowing users to create and switch to a new branch from the current HEAD.

## Protocol Extension

### Client Message
```rust
GitCreateBranch {
    project: String,
    workspace: String,
    branch: String,
}
```

### Server Response
Reuses existing `GitOpResult` with `op: "create_branch"`, `scope: "branch"`.

## Branch Name Validation Rules

Following git-check-ref-format constraints:

| Rule | Invalid Example | Reason |
|------|-----------------|--------|
| No spaces | `"my branch"` | Spaces not allowed |
| No `~` | `"branch~1"` | Tilde is reflog syntax |
| No `^` | `"branch^2"` | Caret is parent syntax |
| No `:` | `"branch:foo"` | Colon is refspec separator |
| No `?` | `"branch?"` | Glob character |
| No `*` | `"branch*"` | Glob character |
| No `[` | `"branch[0]"` | Glob character |
| No `\` | `"branch\foo"` | Escape character |
| No `..` | `"branch..name"` | Range syntax |
| No trailing `.` | `"branch."` | Invalid ref ending |
| No leading `-` | `"-branch"` | Looks like option |
| Not empty | `""` | Must have name |
| `/` allowed | `"feature/foo"` | Hierarchical names OK |

## Core Implementation

### git_tools.rs: `git_create_branch()`
```rust
pub fn git_create_branch(workspace_root: &Path, branch: &str) -> Result<GitOpResult, GitError> {
    // 1. Check git repo
    // 2. Try: git switch -c <branch>
    // 3. Fallback: git checkout -b <branch>
    // 4. Return GitOpResult with op="create_branch", scope="branch"
}
```

### ws.rs Handler
```rust
ClientMessage::GitCreateBranch { project, workspace, branch } => {
    // Same pattern as GitSwitchBranch
    // Call git_tools::git_create_branch()
    // Return GitOpResult
}
```

## Native UI Flow

### BranchPickerView Changes

1. **Create Branch Entry**
   - Add "+ Create new branch..." row at top of branch list
   - Clicking opens inline create form

2. **Create Form (inline)**
   - TextField for branch name
   - Real-time validation with error message
   - Cancel / Create buttons
   - Create disabled when invalid

3. **States**
   - Idle: Show form
   - Creating: Show spinner, disable inputs
   - Success: Close picker, show toast
   - Error: Show error toast, keep form open

### Validation Function
```swift
func validateBranchName(_ name: String) -> (valid: Bool, error: String?) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return (false, "Branch name required") }
    if trimmed.hasPrefix("-") { return (false, "Cannot start with '-'") }
    if trimmed.hasSuffix(".") { return (false, "Cannot end with '.'") }
    if trimmed.contains("..") { return (false, "Cannot contain '..'") }
    let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
    if trimmed.unicodeScalars.contains(where: { forbidden.contains($0) }) {
        return (false, "Invalid characters")
    }
    return (true, nil)
}
```

## Error Scenarios

| Scenario | Detection | User Feedback |
|----------|-----------|---------------|
| Invalid name | Client-side validation | Inline error, Create disabled |
| Branch exists | Server returns ok=false | Toast: "Branch already exists" |
| Dirty repo conflict | Server returns ok=false | Toast: error message from git |
| Not a git repo | Server returns error | Toast: "Not a git repository" |

## Success Flow

1. User clicks "+ Create new branch..."
2. Form appears with TextField
3. User types "feature/my-feature"
4. Validation passes, Create enabled
5. User clicks Create
6. Spinner shows, inputs disabled
7. Server creates branch and switches
8. Client receives GitOpResult(ok=true)
9. Form closes
10. Branch list refreshes (shows new branch as current)
11. Git status refreshes
12. Toast: "Created and switched to 'feature/my-feature'"

## Files Modified

| File | Changes |
|------|---------|
| `core/src/server/protocol.rs` | Add `GitCreateBranch` message |
| `core/src/server/git_tools.rs` | Add `git_create_branch()` |
| `core/src/server/ws.rs` | Add handler for `GitCreateBranch` |
| `app/.../ProtocolModels.swift` | (No changes - reuses GitOpResult) |
| `app/.../WSClient.swift` | Add `requestGitCreateBranch()` |
| `app/.../Models.swift` | Add `gitCreateBranch()` method |
| `app/.../BranchPickerView.swift` | Add create branch UI |

## Out of Scope

- Remote branches / tracking
- Create from specific base branch (always from HEAD)
- Branch rename / delete
- Stash / auto-commit for dirty repo
