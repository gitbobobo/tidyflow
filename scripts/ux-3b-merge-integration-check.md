# UX-3b Merge Integration Checklist

## Pre-Implementation Verification
- [x] Integration worktree path: `~/.tidyflow/worktrees/<project>/__integration`
- [x] Protocol version bumped to v1.12

## Core (Rust) Implementation
- [x] `git_tools.rs`: `ensure_integration_worktree()` creates/validates worktree
- [x] `git_tools.rs`: `integration_status()` returns state/conflicts/path
- [x] `git_tools.rs`: `merge_to_default()` performs merge operation
- [x] `git_tools.rs`: `merge_continue()` completes merge after conflict resolution
- [x] `git_tools.rs`: `merge_abort()` aborts and cleans up
- [x] `protocol.rs`: New message types added
- [x] `ws.rs`: Handlers for all new messages

## App (Swift) Implementation
- [x] `ProtocolModels.swift`: `GitMergeToDefaultResult` and `GitIntegrationStatusResult` models
- [x] `WSClient.swift`: Request methods for merge operations
- [x] `Models.swift`: Integration status cache and handlers
- [x] `NativeGitPanelView.swift`: Merge to Default button and conflict UI

## Acceptance Tests
- [ ] No-conflict merge: workspace branch ahead of main → success
- [ ] Conflict merge: conflicts detected → conflict state with file list
- [ ] Continue merge: after resolution → completed
- [ ] Abort merge: returns to idle/clean state
- [ ] Dirty integration: reject with clear error message
- [ ] Detached HEAD workspace: reject with "create branch first" message

