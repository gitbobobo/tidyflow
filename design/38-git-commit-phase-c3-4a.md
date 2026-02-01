# Phase C3-4a: Git Commit

## Overview

Native Git commit functionality for the Git panel. Allows users to commit staged changes with a commit message directly from the UI.

## Implementation

### Staged Changes Detection (方案 A)

Extended `git_status` to include staged changes information:
- `has_staged_changes: bool` - Whether there are any staged changes
- `staged_count: usize` - Number of staged files

This is computed using `git diff --cached --name-only` during status fetch.

### Protocol Messages

**Request:**
```json
{
  "type": "git_commit",
  "project": "default",
  "workspace": "main",
  "message": "feat: add new feature"
}
```

**Response:**
```json
{
  "type": "git_commit_result",
  "project": "default",
  "workspace": "main",
  "ok": true,
  "message": "Committed: abc1234",
  "sha": "abc1234"
}
```

### Core Implementation

`git_commit()` in `git_tools.rs`:
1. Validates message is not empty (trimmed)
2. Checks for staged changes
3. Runs `git commit -m <message>`
4. On success, gets short SHA via `git rev-parse --short HEAD`
5. Returns result with success/error message

### Error Handling

| Error | Message |
|-------|---------|
| Empty message | "Commit message cannot be empty" |
| No staged changes | "No staged changes to commit" |
| No git identity | "Git identity not configured. Run: git config user.name..." |
| Hook failure | "Pre-commit hook failed: <details>" |
| Other | Raw git error message |

### UI Components

**GitCommitSection:**
- TextField for commit message (single-line)
- Commit button with progress indicator
- Status hint showing staged file count
- Disabled state when no staged changes or empty message

**Commit Button States:**
- Enabled (blue): Has staged changes + non-empty message
- Disabled (gray): Missing staged changes or empty message
- Loading: Commit in progress

### State Management

Per-workspace state in AppState:
- `commitMessage: [String: String]` - Current message per workspace
- `commitInFlight: [String: Bool]` - Commit operation in progress

### Flow

1. User stages files (existing functionality)
2. User enters commit message
3. User clicks Commit or presses Enter
4. UI validates: staged changes exist + message not empty
5. Core validates again and runs `git commit`
6. On success: clear message, show toast with SHA, refresh status
7. On failure: show error toast, keep message

## Files Modified

### Core (Rust)
- `core/src/server/protocol.rs` - Added GitCommit, GitCommitResult, extended GitStatusResult
- `core/src/server/git_tools.rs` - Added git_commit(), check_staged_changes(), get_short_head_sha()
- `core/src/server/ws.rs` - Added GitCommit handler, updated GitStatusResult

### App (Swift)
- `app/TidyFlow/Networking/ProtocolModels.swift` - Added GitCommitResult, updated GitStatusResult/Cache
- `app/TidyFlow/Networking/WSClient.swift` - Added requestGitCommit(), onGitCommitResult
- `app/TidyFlow/Views/Models.swift` - Added commit state, gitCommit(), handleGitCommitResult()
- `app/TidyFlow/Views/NativeGitPanelView.swift` - Added GitCommitSection view

## Limitations (This Phase)

- Single-line commit message only (no body/description)
- No amend support
- No GPG signing
- No commit templates
- No hook management

## Testing

See `scripts/native-git-commit-check.md` for verification checklist.
