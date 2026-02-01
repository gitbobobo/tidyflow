# UX-3a Rebase + AI Resolve Check Script

## Core (Rust) Verification
1. [ ] `cargo build` succeeds in `core/`
2. [ ] Protocol v1.11 messages: GitFetch, GitRebase, GitRebaseContinue, GitRebaseAbort, GitOpStatus
3. [ ] git_tools.rs: git_fetch, git_rebase, git_rebase_continue, git_rebase_abort, git_op_status
4. [ ] ws.rs handlers for all new messages

## App (Swift) Verification
5. [ ] ProtocolModels.swift: GitRebaseResult, GitOpStatusResult, GitOpStatusCache
6. [ ] WSClient.swift: request methods + result handlers
7. [ ] Models.swift: gitOpStatusCache, rebaseInFlight, handler methods
8. [ ] NativeGitPanelView.swift: GitWorkspaceActionsSection with Fetch/Rebase/Continue/Abort/AI Resolve

## Functional Tests
9. [ ] No-conflict rebase: toast success, status clean
10. [ ] Conflict rebase: Git panel shows conflicts, AI Resolve spawns terminal
11. [ ] Continue after resolve: rebase completes
12. [ ] Abort: returns to normal state
