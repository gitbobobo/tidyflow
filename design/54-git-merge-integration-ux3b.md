# UX-3b: Safe Merge to Default Branch via Integration Worktree

## Overview

This design implements a safe "Merge to default branch" feature that uses a dedicated integration worktree to perform merge operations, avoiding pollution of the user's active workspace.

## Core Concept: Integration Worktree

For each project (repo), we maintain a dedicated worktree directory:
```
~/.tidyflow/worktrees/<project-name>/__integration
```

This worktree:
- Always checks out the default branch (e.g., `main`)
- Handles all merge/rebase operations to default branch
- Isolates dangerous operations from user's workspace
- Preserves user's terminal/agent environment

## State Machine

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
                    ▼                                         │
┌──────────┐   ┌─────────┐   ┌──────────┐   ┌───────────┐   │
│   idle   │──▶│ merging │──▶│ conflict │──▶│ completed │───┘
└──────────┘   └─────────┘   └──────────┘   └───────────┘
     ▲              │              │              │
     │              │              │              │
     │              ▼              ▼              │
     │         ┌─────────┐   ┌─────────┐         │
     └─────────│  abort  │◀──│  abort  │         │
               └─────────┘   └─────────┘         │
                    │                            │
                    └────────────────────────────┘
```

### States

| State | Description |
|-------|-------------|
| `idle` | Integration worktree is clean, ready for operations |
| `merging` | Merge in progress (no conflicts yet) |
| `conflict` | Merge paused due to conflicts |
| `completed` | Merge successfully completed |
| `failed` | Operation failed (error state) |

## Protocol Messages (v1.12)

### Client → Server

```typescript
// Ensure integration worktree exists and is clean
GitEnsureIntegrationWorktree {
  project: string
}

// Start merge from workspace branch to default
GitMergeToDefault {
  project: string
  workspace: string           // Source workspace name
  default_branch: string      // Target branch (e.g., "main")
}

// Continue merge after conflict resolution
GitMergeContinue {
  project: string
}

// Abort merge and restore clean state
GitMergeAbort {
  project: string
}

// Get integration worktree status
GitIntegrationStatus {
  project: string
}
```

### Server → Client

```typescript
GitMergeToDefaultResult {
  project: string
  ok: bool
  state: string              // "idle" | "merging" | "conflict" | "completed" | "failed"
  conflicts?: string[]       // List of conflicted file paths
  head_sha?: string          // New HEAD SHA after merge
  message?: string           // Status/error message
  integration_path?: string  // Path to integration worktree
}

GitIntegrationStatusResult {
  project: string
  state: string              // "idle" | "merging" | "conflict"
  conflicts: string[]
  head: string?              // Current HEAD SHA
  default_branch: string     // Default branch name
  path: string               // Integration worktree path
  is_clean: bool             // Whether worktree is clean
}
```

## Merge Flow

### 1. Ensure Integration Worktree

```
User clicks "Merge to Default"
    │
    ▼
Check if integration worktree exists
    │
    ├── No: Create worktree
    │       git worktree add ~/.tidyflow/worktrees/<project>/__integration <default_branch>
    │
    └── Yes: Check if clean
            │
            ├── Clean: Proceed
            │
            └── Dirty: Return error "Clean/Abort integration first"
```

### 2. Perform Merge

```
In integration worktree:
    │
    ▼
git checkout <default_branch>
    │
    ▼
git merge <source_branch>
    │
    ├── Success (no conflicts)
    │       Return: { ok: true, state: "completed", head_sha: <new_sha> }
    │
    └── Conflicts
            Return: { ok: false, state: "conflict", conflicts: [...] }
```

### 3. Conflict Resolution

```
User resolves conflicts (via opencode in integration worktree)
    │
    ▼
User clicks "Continue Merge"
    │
    ▼
git add -A && git commit
    │
    ├── Success
    │       Return: { ok: true, state: "completed" }
    │
    └── Still has conflicts
            Return: { ok: false, state: "conflict", conflicts: [...] }
```

### 4. Abort

```
User clicks "Abort Merge"
    │
    ▼
git merge --abort
    │
    ▼
Return: { ok: true, state: "idle" }
```

## Git Commands Used

| Operation | Command |
|-----------|---------|
| Create worktree | `git worktree add <path> <branch>` |
| Check clean | `git status --porcelain` (empty = clean) |
| Check merge state | Check `.git/MERGE_HEAD` existence |
| Merge | `git merge <branch>` |
| Get conflicts | `git diff --name-only --diff-filter=U` |
| Continue merge | `git commit` (after staging resolved files) |
| Abort merge | `git merge --abort` |
| Get HEAD | `git rev-parse --short HEAD` |

## Integration Worktree Path Convention

```
~/.tidyflow/worktrees/<project-name>/__integration
```

Where `<project-name>` is sanitized (alphanumeric + hyphen only).

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Workspace is detached HEAD | Reject with "Create/switch to branch first" |
| Integration worktree dirty | Reject with "Clean/Abort integration first" |
| Source branch doesn't exist | Reject with "Branch not found" |
| Merge already in progress | Return current conflict state |
| Git command fails | Return error with stderr message |

## UI Flow

### Normal (No Conflicts)

1. User clicks "Merge to Default"
2. Toast: "Merging feature-x into main..."
3. Toast: "Merge completed! (abc1234)"
4. Hint: "Consider cleaning up workspace"

### With Conflicts

1. User clicks "Merge to Default"
2. Toast: "Merge has conflicts"
3. UI shows conflict list with file paths
4. "AI Resolve" button spawns terminal with opencode (cwd = integration worktree)
5. User resolves conflicts
6. User clicks "Continue Merge"
7. Toast: "Merge completed!"

### Abort

1. User clicks "Abort Merge"
2. Toast: "Merge aborted"
3. Integration worktree returns to clean state

## Security Considerations

- Integration worktree is isolated from user's workspace
- No branch switching in user's workspace
- User's terminal/agent environment preserved
- Abort always available to recover

## Future Extensions (Not in MVP)

- Configurable default branch per project
- Rebase-first option before merge
- Push to remote after merge
- Cleanup workspace after merge (UX-3c)
