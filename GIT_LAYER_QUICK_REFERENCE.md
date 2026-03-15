# TidyFlow Git Layer - Quick Reference

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│         Shared Protocol Layer (TidyFlowShared)          │
│                                                         │
│  • GitProtocolModels.swift (2000+ lines)               │
│    - All model types (Diff, Status, Branches, etc)    │
│    - Shared by both platforms                         │
│                                                         │
│  • GitWorkspaceStateDriver.swift (330 lines)          │
│    - Pure state machine (Redux-like)                  │
│    - Input → State × Effects                          │
│    - No platform/network dependencies                 │
│                                                         │
│  • WSClient+Send.swift (2000+ lines)                   │
│    - ~50 request methods                              │
│    - HTTP-backed reads, WS-backed writes              │
└─────────────────────────────────────────────────────────┘
                           ↓
        ┌──────────────────┴──────────────────┐
        ↓                                     ↓
  ┌─────────────────────┐           ┌─────────────────────┐
  │   macOS Layer       │           │    iOS Layer        │
  │   (AppKit)          │           │    (UIKit)          │
  ├─────────────────────┤           ├─────────────────────┤
  │ GitCacheState       │           │ MobileAppState      │
  │ +Operations         │           │ +HandlerMethods     │
  │ +DiffStatus         │           │                     │
  │                     │           │ Native List UI      │
  │ Native Panels       │           │ (No history view)   │
  │ + Conflict Wizard   │           │ + Conflict Sheet    │
  │ + History Graph     │           │                     │
  │ + Split Diff        │           │ (GAPS)              │
  └─────────────────────┘           └─────────────────────┘
```

## Key Models

### Status & Changes
```
GitStatusItem              → Single file status (M/A/D/??)
GitStatusResult/Cache      → All files in workspace
GitPanelSemanticSnapshot   → Unified snapshot (both platforms)
  - stagedItems
  - trackedUnstagedItems
  - untrackedItems
```

### History (macOS only)
```
GitLogEntry                → Single commit (sha, msg, author, date)
GitLogCache                → List of commits
GitShowResult/Cache        → Files in single commit
```

### Diff
```
GitDiffResult              → Server response (unified diff text)
DiffLine                   → Parsed line (kind, line numbers)
DiffCache                  → Client cache (parsed + raw)
DiffDescriptor             → Cache key = "project:workspace:path:mode"
```

### Branches
```
GitBranchItem              → Single branch metadata
GitBranchesResult/Cache    → All branches
```

### Rebase/Merge
```
GitOpState enum            → normal | rebasing | merging
GitRebaseResult            → Rebase operation result
GitOpStatusResult/Cache    → Operation state with conflicts

IntegrationState enum      → idle | conflict | rebasing | merging | rebaseConflict
GitMergeToDefaultResult    → Merge-to-default result
GitIntegrationStatusCache  → Project-level integration state
```

### Conflict Resolution (v1.40+)
```
ConflictFileEntry          → Single conflict file (path, type, staged?)
ConflictSnapshot           → All conflicts (files[], allResolved?)
GitConflictDetailResult    → Four-way diff (base|ours|theirs|current)
ConflictWizardCache        → UI state (snapshot, selectedFile, detail)
  ⚠️  SHARED between macOS and iOS!
  Key: "project:workspace" or "project:integration"
```

### Stash (v1.50+)
```
GitStashEntry              → Stash metadata (id, title, branch, date)
GitStashListCache          → List of stashes
GitStashShowResult/Cache   → Stash diff details
GitStashOpResult           → Apply/pop/drop operation result
```

## Shared State Driver

### Purpose
Pure functional state machine for Git workspace:
- Input event → (New State, [Effects])
- **No network calls inside driver**
- Platform layer translates effects → WS requests
- Thread-safe (Sendable)

### Inputs
```swift
enum GitWorkspaceInput {
  // User intents
  case refreshStatus(cacheMode)
  case stage(path?, scope)
  case unstage(path?, scope)
  case discard(path?, scope, includeUntracked)
  case commit(message)
  case switchBranch(name)
  case createBranch(name)
  
  // Server results
  case gitStatusResult(GitStatusResult)
  case gitBranchesResult(GitBranchesResult)
  case gitOpResult(GitOpResult)
  case gitCommitResult(GitCommitResult)
  
  // Notifications
  case gitStatusChanged
  case connectionChanged(isConnected)
}
```

### Effects
```swift
enum GitWorkspaceEffect {
  case requestStatus(cacheMode)
  case requestBranches(cacheMode)
  case requestStage(path?, scope)
  case requestUnstage(path?, scope)
  case requestDiscard(path?, scope, includeUntracked)
  case requestCommit(message)
  case requestSwitchBranch(name)
  case requestCreateBranch(name)
}
```

### Reduce Function
```swift
GitWorkspaceStateDriver.reduce(
  state: GitWorkspaceState,
  input: GitWorkspaceInput,
  context: GitWorkspaceContext
) → (GitWorkspaceState, [GitWorkspaceEffect])
```

## WebSocket Send Methods

### HTTP-Backed Reads (Cached)
```swift
requestGitDiff(project, workspace, path, mode, cacheMode)
requestGitStatus(project, workspace, cacheMode)
requestGitLog(project, workspace, limit, cacheMode)
requestGitShow(project, workspace, sha, cacheMode)
requestGitBranches(project, workspace, cacheMode)
requestGitOpStatus(project, workspace, cacheMode)
requestGitIntegrationStatus(project, cacheMode)
```

### WS-Backed Writes (Ordered)
```swift
// Stage/Unstage
requestGitStage(project, workspace, path?, scope)
requestGitUnstage(project, workspace, path?, scope)
requestGitDiscard(project, workspace, path?, scope, includeUntracked?)

// Branches
requestGitSwitchBranch(project, workspace, branch)
requestGitCreateBranch(project, workspace, branch)

// Commit
requestGitCommit(project, workspace, message)
requestGitAIMerge(project, workspace, aiAgent?, defaultBranch?)

// Rebase (workspace-level)
requestGitRebase(project, workspace, ontoBranch)
requestGitRebaseContinue(project, workspace)
requestGitRebaseAbort(project, workspace)

// Merge-to-Default (project-level integration)
requestGitMergeToDefault(project, workspace, defaultBranch)
requestGitMergeContinue(project)
requestGitMergeAbort(project)

// Rebase-onto-Default (project-level integration)
requestGitRebaseOntoDefault(project, workspace, defaultBranch)
requestGitRebaseOntoDefaultContinue(project)
requestGitRebaseOntoDefaultAbort(project)

// Conflict Resolution
requestGitConflictDetail(project, workspace, path, context, cacheMode)
requestGitConflictAcceptOurs(project, workspace, path, context)
requestGitConflictAcceptTheirs(project, workspace, path, context)
requestGitConflictAcceptBoth(project, workspace, path, context)
requestGitConflictMarkResolved(project, workspace, path, context)

// Stash
requestGitStashList(project, workspace, cacheMode)
requestGitStashShow(project, workspace, stashId, cacheMode)
requestGitStashSave(project, workspace, message?, includeUntracked?, keepIndex?, paths?)
requestGitStashApply/Pop/Drop(project, workspace, stashId)
requestGitStashRestorePaths(project, workspace, stashId, paths)
```

## Platform Differences

### macOS
**Advantages:**
- Full Git history with visual graph
- Floating panels on hover
- Split diff view
- Four-way conflict resolution with tabs
- Commit file list
- Rebase UI

**Implementation:**
- GitCacheState for diff/log/show caching
- NativeGitPanelView (main)
- GitConflictWizardView (conflict mode)
- FloatingPanelController (hover panels)
- GitGraphViews (history)

### iOS
**Features:**
- List-based Git panel
- Conflict wizard in sheet
- Stash support (v1.50+)
- No history/graph
- No rebase UI
- No split diff

**Implementation:**
- MobileAppState for state management
- WorkspaceGitView (main)
- GitConflictWizardSheet (conflict sheet)
- No deep caching (simpler)

## Caching Strategy

### Key Patterns
```
macOS diff cache key:        "project:workspace:path:mode"
macOS log cache key:         "project:workspace"
macOS show cache key:        "project:workspace:sha"
macOS opStatus cache key:    "project:workspace"
macOS conflict wizard key:   "project:workspace" or "project:integration"
iOS conflict wizard key:     "project:workspace" or "project:integration"  (SHARED!)
```

### Expiry Times
- Diff: 30 seconds
- Status: 60 seconds
- Log: 120 seconds
- Show: No expiry (once fetched)
- Branches: 60 seconds

## Common Operations

### Stage All Files
```swift
applyGitInput(.stage(path: nil, scope: "all"))  // macOS
wsClient.requestGitStage(project, workspace, path: nil, scope: "all")  // iOS
```

### Commit
```swift
applyGitInput(.commit(message: msg))  // macOS
wsClient.requestGitCommit(project, workspace, message: msg)  // iOS
```

### Resolve Conflict (Accept Ours)
```swift
wsClient?.requestGitConflictAcceptOurs(project, workspace, path, context)
// Both platforms use same method
```

### Continue Rebase
```swift
gitRebaseContinue(workspaceKey)  // macOS
wsClient.requestGitRebaseContinue(project, workspace)  // iOS
```

## iOS Gaps vs macOS

| Feature | Status | Impact |
|---------|--------|--------|
| Git History (log) | ❌ Missing | Can't see recent commits |
| Commit Details (show) | ❌ Missing | Can't see what changed in commit |
| Rebase UI | ❌ Missing | Can't perform rebase operations |
| Split Diff | ❌ Missing | Only unified diff available |
| Floating Panels | ❌ N/A | Not applicable to mobile |
| Branch Create | ~ Limited | Manual input only, no UI |

## Testing Strategy

### Unit Tests (Shared Driver)
```swift
// Test reducer
let input: GitWorkspaceInput = .stage(path: "file.txt", scope: "file")
let (newState, effects) = GitWorkspaceStateDriver.reduce(
  state: initialState,
  input: input,
  context: context
)

XCTAssertEqual(newState.opsInFlight.count, 1)
XCTAssertEqual(effects.count, 1)
if case .requestStage = effects[0] { } else { XCTFail() }
```

### Integration Tests (Platform Layer)
- Mock WSClient
- Verify state updates
- Verify WS calls

### UI Tests (Snapshot-based)
- ConflictWizardCache snapshots
- Before/after conflict resolution

---

## File Reference

| File | LOC | Purpose |
|------|-----|---------|
| GitProtocolModels.swift | 2000+ | All protocol types |
| GitWorkspaceStateDriver.swift | 330 | Pure state machine |
| WSClient+Send.swift | 2000+ | ~50 WS/HTTP methods |
| GitCacheState+Operations.swift | 550+ | macOS diff/log/show caching |
| GitCacheState+DiffStatus.swift | 250+ | macOS diff parsing |
| GitConflictWizardView.swift | 546 | macOS conflict UI |
| NativeGitPanelView.swift | 574 | macOS main panel |
| GitGraphViews.swift | 323 | macOS history UI |
| MobileAppState.swift | 350+ | iOS state management |
| MobileAppState+HandlerMethods.swift | 945 | iOS handlers |
| GitConflictWizardSheet.swift | 418 | iOS conflict sheet |
| WorkspaceGitView.swift | 996 | iOS main panel |

