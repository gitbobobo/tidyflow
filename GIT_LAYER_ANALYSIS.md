# TidyFlow Swift Shared Git Layer - Comprehensive Analysis

## Executive Summary

The TidyFlow project implements a cross-platform Git layer with a **shared protocol model** (TidyFlowShared) and **platform-specific implementations** (macOS AppKit, iOS UIKit). The architecture follows a **Redux-like state management pattern** using `GitWorkspaceStateDriver` for shared state mutations and separate platforms for UI rendering and effect handling.

---

## 1. Shared Protocol Layer (TidyFlowShared)

### 1.1 Core Git Protocol Models

Located in: `app/TidyFlowShared/Protocol/GitProtocolModels.swift`

#### **Diff Management**
- **GitDiffResult**: Server response for git diff requests
  - Fields: `project`, `workspace`, `path`, `code` (status), `format`, `text`, `isBinary`, `truncated`, `mode`
  - Used for: working tree and staged diffs
  
- **DiffCache**: Client-side caching wrapper
  - Fields: `text`, `parsedLines: [DiffLine]`, `isLoading`, `error`, `isBinary`, `truncated`, `code`, `updatedAt`
  - Expiry: 30 seconds
  - Parsed asynchronously on background thread to avoid UI blocking

- **DiffLine**: Single parsed line from unified diff
  - Kinds: `.header`, `.hunk`, `.context`, `.add`, `.del`
  - Fields: `id`, `kind`, `oldLineNumber?`, `newLineNumber?`, `text`, `isNavigable`

- **DiffViewMode**: `unified | split`

- **SplitBuilder**: Converts unified diff lines to split view rows
  - Max lines for split: 5000 lines

- **DiffDescriptor**: Cross-platform diff cache key
  - Key: `"project:workspace:path:mode"`
  - Ensures macOS/iOS use identical keying scheme

#### **Status & Branches**
- **GitStatusItem**: Individual file status
  - Fields: `id: String`, `path`, `status` (e.g., "M", "A", "D", "??"), `additions`, `deletions`, `isStaged`

- **GitStatusResult**: Server response for git status
  - Fields: `items`, `error?`, `isGitRepo`, `hasStagedChanges`, `stagedCount`, `currentBranch?`, `defaultBranch?`, `aheadBy?`, `behindBy?`, `comparedBranch?`

- **GitStatusCache**: Client cache with expiry (60 seconds)

- **GitPanelSemanticSnapshot**: Unified semantic snapshot for both platforms
  - Classifies files into: `stagedItems`, `trackedUnstagedItems`, `untrackedItems`
  - Derived properties: `hasStagedChanges`, `hasUntrackedChanges`, etc.

- **GitBranchItem**: Single branch metadata
- **GitBranchesResult** & **GitBranchCache**: Branch list management

#### **History & Commits**
- **GitLogEntry**: Single commit in history
  - Fields: `id`, `sha`, `message`, `author`, `date`, `relativeDate`, `refs: [String]`
  - Max entries: 50 (default limit)

- **GitLogResult** & **GitLogCache**: Commit history caching
  - Includes "HEAD" detection for current branch highlighting

- **GitShowResult**: Single commit details (file changes)
  - Fields: `sha`, `message`, `author`, `files: [GitShowFileEntry]`

- **GitShowFileEntry**: File changed in a commit
  - Fields: `path`, `status` (M/A/D/R/C), `additions`, `deletions`

#### **Rebase/Merge Operations**
- **GitOpState** enum: `normal | rebasing | merging`
- **GitRebaseResult**: Rebase operation result with conflict detection
- **GitOpStatusResult**: Operation status with conflict files
- **GitOpStatusCache**: Client cache for operation state

- **IntegrationState** enum: `idle | conflict | rebasing | merging | rebaseConflict`
- **GitMergeToDefaultResult**: Merge to default branch result
- **GitIntegrationStatusResult**: Integration worktree status
- **GitIntegrationStatusCache**: Project-level integration state

#### **Conflict Resolution (v1.40+)**
- **ConflictFileEntry**: Single conflict file
  - Fields: `path`, `conflictType` (content|add_add|delete_modify|modify_delete), `staged` (resolved?)

- **ConflictSnapshot**: Complete conflict context
  - Fields: `context` (workspace|integration), `files: [ConflictFileEntry]`, `allResolved`

- **GitConflictDetailResult**: Four-way conflict diff
  - Fields: `baseContent?`, `oursContent?`, `theirsContent?`, `currentContent`, `conflictMarkersCount`, `isBinary`
  - Used by both macOS GitConflictWizardView and iOS GitConflictWizardSheet

- **GitConflictDetailResultCache**: Cache wrapper for conflict details

- **ConflictWizardCache**: Combined state for conflict wizard
  - Fields: `snapshot?`, `selectedFilePath?`, `currentDetail?`, `isLoading`, `updatedAt`
  - macOS caches by `"project:workspace"` or `"project:integration"`
  - iOS uses same keying scheme

#### **Stash (v1.50+)**
- **GitStashEntry**: Stash metadata
- **GitStashFileEntry**: File in stash with stats
- **GitStashListResult** & **GitStashListCache**: Stash list management
- **GitStashShowResult** & **GitStashShowCache**: Stash diff details
- **GitStashOpResult**: Apply/pop/drop operation results

---

### 1.2 Shared State Driver

Located in: `app/TidyFlowShared/Presentation/GitWorkspaceStateDriver.swift`

#### **Purpose**
Pure functional state machine for Git workspace state:
- No platform dependencies (no SwiftUI/AppKit/UIKit)
- No network dependencies (no WSClient references)
- All state mutations described as **effects** instead of direct network calls
- **Completely Sendable** for thread-safe concurrency

#### **Core Types**

**GitWorkspaceContext**: Identifies workspace scope
```swift
public struct GitWorkspaceContext: Equatable, Hashable, Sendable {
    public let projectName: String
    public let workspaceName: String
    public let globalKey: String  // "project:workspace"
}
```

**GitWorkspaceInput**: All possible state mutations
- User intents: `refreshStatus`, `stage`, `unstage`, `discard`, `commit`, `switchBranch`, `createBranch`
- Server results: `gitStatusResult`, `gitBranchesResult`, `gitOpResult`, `gitCommitResult`
- Notifications: `gitStatusChanged`
- Environment: `connectionChanged`

**GitWorkspaceEffect**: Describes side effects (network requests)
- `requestStatus`, `requestBranches`, `requestStage`, `requestUnstage`, `requestDiscard`
- `requestCommit`, `requestSwitchBranch`, `requestCreateBranch`
- Used by platform layer to translate to WSClient calls

**GitWorkspaceState**: Single workspace Git state
- `statusCache`: Current file status from `git status`
- `branchCache`: Available branches from `git branch`
- `opsInFlight`: Set of stage/unstage/discard operations in progress
- `branchSwitchInFlight?`: Branch name if switch in progress
- `branchCreateInFlight?`: Branch name if create in progress
- `commitInFlight`: Whether commit is in progress
- `commitMessage`: Current commit message (UI-managed)
- `commitResult?`: Last commit result message
- `hasResolvedStatus`: Whether status fetched at least once

**GitWorkspaceStateDriver.reduce()**: Pure function
```swift
public static func reduce(
    state: GitWorkspaceState,
    input: GitWorkspaceInput,
    context: GitWorkspaceContext
) -> (GitWorkspaceState, [GitWorkspaceEffect])
```

#### **Key Features**
1. **State-only on success**: Operations only remove from `opsInFlight` on success
2. **Auto-refresh**: Successful stage/unstage/discard triggers status refresh
3. **Branch switches trigger both**: `requestStatus` + `requestBranches` on success
4. **Canary checks**: `canCommit`, `canSwitchBranch`, `canCreateBranch` computed properties prevent invalid state
5. **Disconnection handling**: Clears all in-flight operations, preserves last snapshot
6. **No message clearing on error**: Keep error messages visible

---

### 1.3 WebSocket Send Methods

Located in: `app/TidyFlowShared/Networking/WSClient+Send.swift`

#### **Read Operations (HTTP-backed, via requestReadViaHTTP)**
```swift
requestGitDiff(project, workspace, path, mode, cacheMode)
requestGitStatus(project, workspace, cacheMode)
requestGitLog(project, workspace, limit, cacheMode)
requestGitShow(project, workspace, sha, cacheMode)
requestGitBranches(project, workspace, cacheMode)
requestGitOpStatus(project, workspace, cacheMode)
requestGitIntegrationStatus(project, cacheMode)
requestGitCheckBranchUpToDate(project, workspace, cacheMode)
```

#### **Write Operations (WS-based, via sendTyped)**
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
requestEvoAutoCommit(project, workspace)
requestGitAIMerge(project, workspace, aiAgent?, defaultBranch?)

// Rebase
requestGitFetch(project, workspace)
requestGitRebase(project, workspace, ontoBranch)
requestGitRebaseContinue(project, workspace)
requestGitRebaseAbort(project, workspace)

// Merge to default (integration)
requestGitMergeToDefault(project, workspace, defaultBranch)
requestGitMergeContinue(project)
requestGitMergeAbort(project)

// Rebase onto default (integration)
requestGitRebaseOntoDefault(project, workspace, defaultBranch)
requestGitRebaseOntoDefaultContinue(project)
requestGitRebaseOntoDefaultAbort(project)
requestGitResetIntegrationWorktree(project)

// Conflict resolution
requestGitConflictDetail(project, workspace, path, context, cacheMode)
requestGitConflictAcceptOurs(project, workspace, path, context)
requestGitConflictAcceptTheirs(project, workspace, path, context)
requestGitConflictAcceptBoth(project, workspace, path, context)
requestGitConflictMarkResolved(project, workspace, path, context)

// Stash
requestGitStashList(project, workspace, cacheMode)
requestGitStashShow(project, workspace, stashId, cacheMode)
requestGitStashSave(project, workspace, message?, includeUntracked?, keepIndex?, paths?)
requestGitStashApply(project, workspace, stashId)
requestGitStashPop(project, workspace, stashId)
requestGitStashDrop(project, workspace, stashId)
requestGitStashRestorePaths(project, workspace, stashId, paths)
```

#### **Typed Request Structures** (used by sendTyped)
```swift
GitStageRequest           // action: "git_stage"
GitUnstageRequest         // action: "git_unstage"
GitDiscardRequest         // action: "git_discard"
GitBranchRequest          // action: "git_switch_branch" or "git_create_branch"
GitCommitRequest          // action: "git_commit"
GitAIMergeRequest         // action: "git_ai_merge"
GitOntoBranchRequest      // action: "git_rebase" or "git_rebase_onto_default"
GitDefaultBranchRequest   // action: "git_merge_to_default" or "git_rebase_onto_default"
GitStashSaveRequest       // action: "git_stash_save"
GitStashIdRequest         // action: "git_stash_apply" etc.
ProjectWorkspacePathContextTypedWSRequest  // action: conflict resolution ops
```

---

## 2. macOS Platform Layer

### 2.1 GitCacheState

Located in: `app/TidyFlow/Views/GitCacheState+Operations.swift` (650 lines+)

#### **Purpose**
Platform-specific cache management for Git operations on macOS with diff/log/show support.

#### **Caching Strategy**
```
gitStatusCache[key: String]              // By workspace
gitBranchesCache[key: String]            // By workspace
gitLogCache[key: String]                 // By workspace
gitShowCache[key: String]                // By SHA
diffCache[key: String]                   // By "project:workspace:path:mode"
gitOpStatusCache[key: String]            // By workspace
gitIntegrationStatusCache[key: String]   // By project
conflictWizardCache[key: String]         // By "project:workspace" or "project:integration"
stashListCache[key: String]              // By "project:workspace"
stashShowCache[key: String]              // By "project:workspace:stash:stashId"
```

#### **Key Operations**

**Diff Management**
```swift
func handleGitDiffResult(_ result: GitDiffResult)
    // Parses diff on background thread (userInitiated)
    // Updates cache + triggers UI refresh
    
func fetchGitDiff(workspaceKey, path, mode, cacheMode)
    // Validates connection, sets loading state, sends request
    
func isFileDeleted(workspaceKey, path, mode) -> Bool
    // Helper: checks if file status code starts with "D"
```

**Status & Branches**
```swift
func handleGitStatusResult(_ result: GitStatusResult)
    // Drives applyGitInput(.gitStatusResult)
    
func fetchGitStatus(workspaceKey, cacheMode)
    // Triggers shared driver via applyGitInput(.refreshStatus)
    
func getGitStatusIndex(workspaceKey) -> GitStatusIndex
    // Derived index with counts (cached)
```

**History & Details**
```swift
func handleGitLogResult(_ result: GitLogResult)
    // Stores commit list, cache expires in 120 seconds
    
func fetchGitLog(workspaceKey, limit=50, cacheMode)
    // Loads recent commits
    
func handleGitShowResult(_ result: GitShowResult)
    // Caches single commit details (no expiry once fetched)
    
func fetchGitShow(workspaceKey, sha, cacheMode)
    // Loads diff for specific commit
```

**Rebase Operations**
```swift
func handleGitRebaseResult(_ result: GitRebaseResult)
    // Updates opStatus cache, syncs conflictWizardCache on conflict
    
func gitRebase(workspaceKey, ontoBranch)
    // Sets rebaseInFlight flag, sends request
```

**Merge to Default (Integration)**
```swift
func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult)
    // Sets integrationStatusCache state, syncs conflict wizard
    
func gitMergeToDefault(workspaceKey, defaultBranch)
    // Project-level merge operation
```

**Conflict Wizard**
```swift
func handleGitConflictDetailResult(_ result: GitConflictDetailResult)
    // Stores current conflict file details + content
    
func handleGitConflictActionResult(_ result: GitConflictActionResult)
    // Updates snapshot after accept/mark-resolved action
    
func fetchConflictDetail(project, workspace, path, context)
    // Loads four-way diff for conflict file
    
func conflictAcceptOurs/Theirs/Both(project, workspace, path, context)
    // Sends conflict resolution requests
    
func conflictMarkResolved(project, workspace, path, context)
    // Marks file as resolved
```

#### **Key Observation: Dual State Management**
- **Shared driver state** (`workspaceGitState[key]`): Pure, effects-based
- **macOS-specific caches**:
  - Diff cache (parsed + unparsed)
  - Log/Show cache
  - Op status cache
  - Conflict wizard cache (shared with iOS)
  - Stash caches

The shared driver focuses on **status/branch/staging**, while macOS maintains **deep caches** for diff/history/conflicts.

---

### 2.2 macOS Conflict Wizard (GitConflictWizardView)

Located in: `app/TidyFlow/Views/GitConflictWizardView.swift` (546 lines)

#### **Design**
- Replaces normal Git panel when conflicts detected
- Two-pane layout: file list (left) + detail (right)
- Header shows progress (e.g., "1 of 5 resolved")
- Footer with Abort/Continue buttons

#### **Sections**
1. **Header**: Orange warning banner with conflict count + refresh button
2. **File List**: Left sidebar showing all conflict files
   - Icons: ✓ (resolved) | ⚠️ (unresolved)
   - Badges: AA (add-add), DM (delete-modify), MD (modify-delete), UU (default)
3. **Detail Panel**: Right side with four tabs
   - Tabs: Current | Ours | Theirs | Base
   - Buttons: Accept Ours/Theirs/Both | Mark Resolved | Open Editor
4. **All Resolved**: Placeholder view with checkmark when done

#### **Key State**
```swift
private var wizard: ConflictWizardCache
private var conflictFiles: [ConflictFileEntry]
private var resolvedCount: Int  // staged files
private var totalCount: Int
private var canContinue: Bool   // resolvedCount == totalCount
private var isContinueInFlight: Bool
```

#### **Actions**
```swift
selectFile(_ file)                    // Load conflict detail
acceptOurs/Theirs/Both()             // Resolve using strategy
markResolved()                        // Manual mark resolved
continueOperation()                   // git rebase/merge continue
abortOperation()                      // git rebase/merge abort
refreshWizard()                       // Re-fetch status
```

#### **Context Awareness**
- Detects context: "workspace" (rebase) vs "integration" (merge-to-default)
- Adapts continue/abort semantics based on context
- Syncs with opStatus cache for merge/rebase state

---

### 2.3 macOS Git History UI (GitGraphViews.swift)

Located: `app/TidyFlow/Views/GitGraphViews.swift` (323 lines)

#### **Components**
1. **GitGraphSection**: Collapsible history section
   - Shows recent commits (50 limit)
   - Expandable/collapsible
   - Auto-loads commit details on expand

2. **GitLogRow**: Single commit line
   - Chevron (expand/collapse)
   - Circle dot (head marker for current)
   - Message (one line)
   - Relative date
   - Hover triggers floating panel after 2 seconds
   - Expandable to show file list

3. **CommitFilesView**: Nested file list under expanded commit
   - Status indicators (M/A/D/R/C)
   - File icons
   - Directory paths

4. **CommitDetailPanelManager**: Floating panel on hover
   - Shows SHA (copyable), message, author, refs
   - Colored badges for branch/tag/HEAD
   - Non-activating NSPanel (doesn't steal focus)
   - 2-second hover delay before show
   - 250ms delay before hide

---

### 2.4 Native Git Panel (NativeGitPanelView.swift)

Located: `app/TidyFlow/Views/NativeGitPanelView.swift` (574 lines)

#### **Layout** (VSCode-style)
1. **Top Fixed**: Panel header + commit input box
2. **Middle Scrollable**: 
   - Staged changes section (collapsible)
   - Unstaged changes section (collapsible)
   - Stash section (collapsible)
3. **Bottom Fixed**: History/Graph section (collapsible)

#### **Dual Mode**
- **Normal mode**: Shows staged/unstaged/history
- **Conflict mode**: Switches to GitConflictWizardView automatically
- Restores normal panel after conflicts resolved

#### **AI Code Review Integration**
- Appears after staged changes
- Shows loading state while analyzing
- Links to review session

---

## 3. iOS Platform Layer

### 3.1 MobileAppState

Located in: `app/TidyFlow-iOS/MobileAppState.swift` (350+ lines for Git)

#### **Purpose**
iOS-specific state management using shared driver but with mobile-tailored caching.

#### **Key Differences from macOS**
1. **No deep diff parsing**: iOS caches entire diff text
2. **Flat cache structure**: Fewer nested caches
3. **Shared conflict wizard state**: Uses same cache keys as macOS
4. **Simplified branch handling**: No local branch create UI
5. **Task system integration**: Maps Git operations to task lifecycle

#### **iOS Git State**
```swift
@Published var workspaceGitState: [String: GitWorkspaceState]
    // Shared driver state (same as macOS)
    
@Published var workspaceGitDetailState: [String: MobileWorkspaceGitDetailState]
    // Mobile-specific: branches, staged, unstaged items
    
@Published var workspaceDiffCache: [String: DiffCache]
    // Simple diff cache by "project:workspace:path:mode"
    
@Published var conflictWizardCache: [String: ConflictWizardCache]
    // Shared with macOS!
    
@Published var stashListCache: [String: GitStashListCache]
    // Stash support (v1.50+)
```

#### **MobileWorkspaceGitDetailState**
```swift
struct MobileWorkspaceGitDetailState {
    var currentBranch: String?
    var defaultBranch: String?
    var branches: [GitBranchItem]
    var stagedItems: [GitStatusItem]
    var unstagedItems: [GitStatusItem]
    var isGitRepo: Bool
    var aheadBy: Int?
    var behindBy: Int?
    var isCommitting: Bool
    var commitResult: String?
    
    // Produces GitPanelSemanticSnapshot (macOS-compatible)
    var semanticSnapshot: GitPanelSemanticSnapshot
}
```

---

### 3.2 MobileAppState Handler Methods

Located in: `app/TidyFlow-iOS/MobileAppState+HandlerMethods.swift` (945 lines)

#### **Git Handlers**
```swift
func handleGitStatusResult(_ result: GitStatusResult)
    // Routes to applyGitInput(.gitStatusResult)
    
func handleGitBranchesResult(_ result: GitBranchesResult)
    // Routes to applyGitInput(.gitBranchesResult)
    
func handleGitCommitResult(_ result: GitCommitResult)
    // Routes to applyGitInput(.gitCommitResult)
    
func handleGitOpResult(_ result: GitOpResult)
    // Routes to applyGitInput(.gitOpResult)
    
func handleGitAIMergeResult(_ result: GitAIMergeResult)
    // Creates/updates task with status/message
    
func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult)
    // Updates task, syncs conflictWizardCache
    
func handleGitStatusChanged(_ notification: GitStatusChangedNotification)
    // Routes to applyGitInput(.gitStatusChanged)
```

#### **Conflict Handlers**
```swift
func handleGitConflictDetailResult(_ result: GitConflictDetailResult)
    // Updates conflictWizardCache[key].currentDetail
    // key = "project:integration" or "project:workspace"
    
func handleGitConflictActionResult(_ result: GitConflictActionResult)
    // Updates snapshot after resolution action
    
func fetchGitDetailForWorkspace(project, workspace)
    // Loads full Git state for workspace
```

#### **Stash Handlers**
```swift
func handleGitStashListResult(_ result: GitStashListResult)
    // Updates stashListCache + auto-selects first
    
func handleGitStashShowResult(_ result: GitStashShowResult)
    // Stores stash diff details
    
func handleGitStashOpResult(_ result: GitStashOpResult)
    // Updates stashOpInFlight, handles conflicts, refreshes status
```

#### **iOS-Specific: Direct WS Calls**
Unlike macOS which uses GitCacheState as intermediary:
```swift
appState.wsClient.requestGitStage(project, workspace, path, scope)
appState.wsClient.requestGitUnstage(project, workspace, path, scope)
appState.wsClient.requestGitConflictAcceptOurs(project, workspace, path, context)
```

---

### 3.3 iOS Conflict Wizard Sheet (GitConflictWizardSheet.swift)

Located: `app/TidyFlow-iOS/Views/GitConflictWizardSheet.swift` (418 lines)

#### **Design** (Mobile-optimized)
- Full-screen sheet (not sidebar)
- Navigation stack for detail navigation
- List for conflict file browsing
- Segmented picker for tab selection
- Bottom safeAreaInset for action buttons

#### **Structure**
1. **NavigationStack wrapper**
2. **List of conflict files** (NavigationLinks to detail)
3. **ConflictFileDetailView**: Nested detail page
   - Horizontal scroll of action buttons
   - Segmented picker for tabs
   - ScrollView for content
4. **Bottom action bar** (Abort | Continue)

#### **Key Differences from macOS**
- No floating panels
- Horizontal scroll for buttons (mobile-friendly)
- Segmented picker instead of tabs
- Navigation-based instead of split view
- Full-screen modal instead of sidebar replacement

#### **Mobile Conflict Actions**
```swift
conflictActionButton(label, icon, color)
    // Wrapped in horizontal scroll for small screens
    
acceptOurs/Theirs/Both()
markResolved()
    // Direct WS calls via appState.wsClient
```

---

### 3.4 iOS Git View (WorkspaceGitView.swift)

Located: `app/TidyFlow-iOS/Views/WorkspaceGitView.swift` (996 lines)

#### **Layout** (Mobile List-based)
1. **Conflict banner** (if active)
2. **Branch section** (picker)
3. **Stash section** (if has stashes)
4. **Staged section**
5. **Tracked unstaged section**
6. **Untracked section**
7. **Commit input**

#### **iOS Specific Features**
- **Branch picker sheet** (MobileBranchListSheet)
- **Stash detail sheet** (showStashDetail)
- **Stash save form** (showStashSaveForm)
  - Message input
  - Include untracked toggle
  - Keep index toggle
- **Confirmation dialogs** for discard operations

#### **Key Observation: No History/Graph**
**iOS is MISSING:**
- Commit history (git log)
- Commit details (git show)
- Floating panels
- Any visual graph representation

This is a significant UX gap compared to macOS.

---

## 4. Cross-Platform Semantics

### 4.1 GitPanelSemanticSnapshot (Shared)

Both platforms produce identical snapshots:
```swift
public struct GitPanelSemanticSnapshot: Equatable, Sendable {
    public let stagedItems: [GitStatusItem]
    public let trackedUnstagedItems: [GitStatusItem]
    public let untrackedItems: [GitStatusItem]
    public let isGitRepo: Bool
    public let isLoading: Bool
    public let currentBranch: String?
    public let defaultBranch: String?
    public let aheadBy: Int?
    public let behindBy: Int?
    public let semanticSnapshot: GitPanelSemanticSnapshot  // Self-reference for recursive projection
    
    public var hasStagedChanges: Bool
    public var hasUntrackedChanges: Bool
    public var isEmpty: Bool
}
```

**Semantic Projection** (GitWorkspaceProjectionSemantics):
```swift
func make(
    workspaceKey: String,
    snapshot: GitPanelSemanticSnapshot,
    isStageAllInFlight: Bool,
    hasResolvedStatus: Bool
) -> GitWorkspaceProjection
```

---

### 4.2 Conflict Wizard Cache (Shared)

Key: `"project:workspace"` (workspace context) or `"project:integration"` (integration context)

```swift
public struct ConflictWizardCache: Equatable {
    public var snapshot: ConflictSnapshot?              // Current files list
    public var selectedFilePath: String?                // Active file being viewed
    public var currentDetail: GitConflictDetailResultCache?  // Four-way diff
    public var isLoading: Bool
    public var updatedAt: Date
    
    public var hasActiveConflicts: Bool  // !snapshot?.allResolved
    public var conflictFileCount: Int
}
```

Both macOS and iOS:
1. Fetch snapshot via applyGitInput or wsClient
2. Fetch detail via fetchConflictDetail
3. Resolve via conflict action methods
4. Update cache immediately

---

## 5. Key Architectural Patterns

### 5.1 Effects-Based State Management
- **GitWorkspaceStateDriver**: Pure reducer pattern
- **GitWorkspaceEffect**: Describes side effects
- Platform layer converts effects → WS requests
- **Benefits**: Testable, Sendable, cross-platform

### 5.2 Three-Layer Caching
1. **Shared driver**: status, branches (short-lived)
2. **Platform-specific**: diff, log, show (long-lived)
3. **Conflict wizard**: Unified across platforms (key="project:workspace" or "project:integration")

### 5.3 HTTP-Backed Reads vs WS Writes
- **Reads** (status, diff, log, show, branches): HTTP with caching fallback
- **Writes** (stage, commit, branch ops, conflict resolution): WS only
- **Rationale**: HTTP reads scale better, WS writes need real-time ordering

### 5.4 Context-Aware Conflict Resolution
- **Workspace context**: Rebase/merge in single workspace
- **Integration context**: Merge-to-default in integration worktree
- Same handler methods, context passed through protocol

---

## 6. iOS Gaps (vs macOS)

| Feature | macOS | iOS | Status |
|---------|-------|-----|--------|
| Git History (log) | ✓ | ✗ | Missing |
| Commit Details (show) | ✓ | ✗ | Missing |
| Floating Panels | ✓ | ✗ | N/A |
| Split Diff View | ✓ | ✗ | Missing |
| Branch Create | ✓ | ~ Partial | Manual input only |
| Stash Support | ✓ | ✓ | v1.50+ |
| Conflict Wizard | ✓ | ✓ | Shared (v1.40+) |
| Rebase Support | ✓ | ✗ | Missing |

---

## 7. Protocol Models Summary Table

| Model | Purpose | Platform Scope |
|-------|---------|---------------|
| GitDiffResult | Server response for diff | Shared |
| DiffCache | Client diff cache | Shared structure, platform storage |
| GitStatusResult | Server git status | Shared |
| GitStatusCache | Client status cache | Shared structure |
| GitPanelSemanticSnapshot | Unified status snapshot | Shared (both platforms) |
| GitLogEntry | Single commit | Shared |
| GitLogCache | Commit history cache | macOS specific |
| GitShowResult | Commit details | Shared |
| GitShowCache | Commit details cache | macOS specific |
| ConflictFileEntry | Conflict file metadata | Shared |
| ConflictSnapshot | Complete conflict state | Shared |
| GitConflictDetailResult | Four-way diff | Shared |
| ConflictWizardCache | Conflict UI state | **Shared between platforms** |
| GitStashEntry | Stash metadata | Shared |
| GitStashListCache | Stash list cache | Shared structure |
| GitWorkspaceState | Shared driver state | Shared (both platforms) |

---

## 8. Recommended Next Steps

### For iOS Feature Parity
1. **Add Git History View**
   - Reuse GitLogEntry/GitLogCache models
   - Simple list (no floating panels needed)
   - Tap to show commit details sheet

2. **Add Commit Details Sheet**
   - Show files changed in commit
   - Link to file diffs if possible

3. **Add Rebase UI**
   - Select onto-branch
   - Conflict wizard integration
   - Continue/abort actions

4. **Implement Split Diff** (optional)
   - Horizontal scroll for small screens
   - Show left/right columns

### Architecture Improvements
1. **Centralize Diff Caching**: Move to shared layer with descriptor keys
2. **Sendable Protocol Models**: Ensure all models are Sendable for actor isolation
3. **WebSocket Batching**: Combine multiple operations in single message
4. **Conflict Wizard Testing**: Snapshot-based tests for state transitions

---

## Appendix: File Structure

```
app/
├── TidyFlowShared/
│   ├── Protocol/
│   │   └── GitProtocolModels.swift       (2000+ lines)
│   ├── Presentation/
│   │   └── GitWorkspaceStateDriver.swift (330 lines)
│   └── Networking/
│       └── WSClient+Send.swift           (2000+ lines)
│
├── TidyFlow/ (macOS)
│   └── Views/
│       ├── GitCacheState+Operations.swift       (550+ lines)
│       ├── GitCacheState+DiffStatus.swift      (250+ lines)
│       ├── GitConflictWizardView.swift         (546 lines)
│       ├── GitGraphViews.swift                 (323 lines)
│       ├── NativeGitPanelView.swift            (574 lines)
│       └── FloatingPanelController.swift       (298 lines)
│
└── TidyFlow-iOS/
    ├── MobileAppState.swift
    ├── MobileAppState+HandlerMethods.swift     (945 lines)
    └── Views/
        ├── GitConflictWizardSheet.swift        (418 lines)
        └── WorkspaceGitView.swift              (996 lines)
```

