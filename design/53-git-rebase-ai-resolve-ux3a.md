# UX-3a: Git Rebase/Merge with AI Conflict Resolution

## Overview
Minimal closed-loop for Fetch + Rebase onto default branch with AI-assisted conflict resolution via external CLI (opencode).

## State Machine

```
┌─────────┐  fetch/rebase   ┌────────────┐  conflicts   ┌───────────┐
│  Idle   │ ───────────────>│ InProgress │ ───────────> │ Conflict  │
└─────────┘                 └────────────┘              └───────────┘
     ^                            │                          │
     │                            │ success                  │ resolve + continue
     │                            v                          │
     │                      ┌───────────┐                    │
     └──────────────────────│ Completed │<───────────────────┘
                            └───────────┘
                                  │
                                  │ abort
                                  v
                            ┌───────────┐
                            │  Aborted  │
                            └───────────┘
```

## Git Operation State Enum
```rust
pub enum GitOpState {
    Normal,           // No operation in progress
    Rebasing,         // git rebase in progress
    Merging,          // git merge in progress (future)
    Conflict,         // Operation paused due to conflicts
}
```

## Conflict Detection
1. Check exit code of `git rebase <branch>`
2. If non-zero, check for rebase state:
   - `.git/rebase-merge/` directory exists
   - `.git/rebase-apply/` directory exists
   - `git rev-parse --verify REBASE_HEAD` succeeds
3. List conflicted files via `git diff --name-only --diff-filter=U`

## Protocol Messages (v1.11)

### Client -> Server
- `GitFetch { project, workspace }` - Fetch from remote
- `GitRebase { project, workspace, onto_branch }` - Start rebase
- `GitRebaseContinue { project, workspace }` - Continue after conflict resolution
- `GitRebaseAbort { project, workspace }` - Abort rebase
- `GitOpStatus { project, workspace }` - Query current git operation state

### Server -> Client
- `GitRebaseResult { project, workspace, ok, state, message, conflicts }` - Rebase operation result
- `GitOpStatusResult { project, workspace, state, conflicts, head, onto }` - Current operation status

## AI Conflict Resolution Flow
1. User clicks "Rebase onto Default"
2. Core executes `git fetch && git rebase origin/main`
3. If conflicts detected:
   - Return `GitRebaseResult { ok: false, state: "conflict", conflicts: [...] }`
   - App shows conflict list in Git panel
   - App spawns terminal tab with `opencode` CLI
4. User resolves conflicts (manually or via AI)
5. User runs `git add <resolved_files>`
6. User clicks "Continue Rebase" in TidyFlow
7. Core executes `git rebase --continue`
8. Repeat until complete or user aborts

## MVP Merge Strategy
**Decision**: "Merge to default branch" is NOT implemented in this phase.

**Rationale**:
- Merging workspace branch into main requires switching branches in repo root
- This is risky in a worktree-based workflow
- Proper implementation needs an "integration worktree" pattern

**UX-3b Scope**: Safe merge via integration worktree + optional rebase-first

## Terminal AI Spawn
When conflicts occur, automatically:
1. Create new terminal tab for workspace
2. Set cwd to workspace path
3. Run `opencode` command
4. Show "AI resolving..." indicator in Git panel

## Files Modified
- `core/src/server/protocol.rs` - New messages
- `core/src/server/git_tools.rs` - Rebase/fetch/status functions
- `core/src/server/ws.rs` - Message handlers
- `app/TidyFlow/Networking/ProtocolModels.swift` - New result types
- `app/TidyFlow/Networking/WSClient.swift` - New request methods
- `app/TidyFlow/Views/NativeGitPanelView.swift` - Workspace actions UI
- `app/TidyFlow/Views/Models.swift` - Git op state tracking
