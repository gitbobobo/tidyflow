import Foundation
import Combine
import SwiftUI

// MARK: - Notifications

extension Notification.Name {
    static let saveEditorFile = Notification.Name("saveEditorFile")
}

enum RightTool: String, CaseIterable {
    case explorer
    case search
    case git
}

enum ConnectionState {
    case connected
    case disconnected
}

// Phase C1-1: Terminal state for native binding
enum TerminalState: Equatable {
    case idle
    case connecting
    case ready(sessionId: String)
    case error(message: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

enum TabKind: String, Codable {
    case terminal
    case editor
    case diff
    
    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .editor: return "doc.text"
        case .diff: return "arrow.left.arrow.right"
        }
    }
}

struct TabModel: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let kind: TabKind
    let workspaceKey: String
    let payload: String

    // Phase C1-2: Terminal session ID (only for terminal tabs)
    // Stored separately from payload to maintain Codable compatibility
    var terminalSessionId: String?

    // Phase C2-1: Diff mode (only for diff tabs)
    // "working" = unstaged changes, "staged" = staged changes
    var diffMode: String?

    // Phase C2-2b: Diff view mode (only for diff tabs)
    // "unified" = single column, "split" = side-by-side
    var diffViewMode: String?
}

// Phase C2-1: Diff mode enum for type safety
enum DiffMode: String, Codable {
    case working
    case staged
}

typealias TabSet = [TabModel]

// MARK: - Command Palette Models

enum PaletteMode {
    case command
    case file
}

enum CommandScope {
    case global
    case workspace
}

struct Command: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let scope: CommandScope
    let keyHint: String?
    let action: (AppState) -> Void
}

class AppState: ObservableObject {
    @Published var selectedWorkspaceKey: String?
    @Published var activeRightTool: RightTool? = .explorer
    @Published var connectionState: ConnectionState = .disconnected

    @Published var workspaceTabs: [String: TabSet] = [:]
    @Published var activeTabIdByWorkspace: [String: UUID] = [:]

    // Command Palette State
    @Published var commandPalettePresented: Bool = false
    @Published var commandPaletteMode: PaletteMode = .command
    @Published var commandQuery: String = ""
    @Published var paletteSelectionIndex: Int = 0

    // Debug Panel State (Cmd+Shift+D)
    @Published var debugPanelPresented: Bool = false

    // File Index Cache (workspace key -> cache)
    @Published var fileIndexCache: [String: FileIndexCache] = [:]

    // Phase C2-2a: Diff Cache (key: "workspace:path:mode" -> DiffCache)
    @Published var diffCache: [String: DiffCache] = [:]

    // Phase C3-1: Git Status Cache (workspace key -> GitStatusCache)
    @Published var gitStatusCache: [String: GitStatusCache] = [:]

    // Phase C3-2a: Git operation in-flight tracking (workspace key -> Set<GitOpInFlight>)
    @Published var gitOpsInFlight: [String: Set<GitOpInFlight>] = [:]
    // Phase C3-2a: Git operation toast message
    @Published var gitOpToast: String?
    @Published var gitOpToastIsError: Bool = false

    // Phase C3-3a: Git Branch Cache (workspace key -> GitBranchCache)
    @Published var gitBranchCache: [String: GitBranchCache] = [:]
    // Phase C3-3a: Branch switch in-flight (workspace key -> target branch)
    @Published var branchSwitchInFlight: [String: String] = [:]
    // Phase C3-3b: Branch create in-flight (workspace key -> new branch name)
    @Published var branchCreateInFlight: [String: String] = [:]

    // Phase C3-4a: Commit message per workspace
    @Published var commitMessage: [String: String] = [:]
    // Phase C3-4a: Commit in-flight (workspace key -> true)
    @Published var commitInFlight: [String: Bool] = [:]

    // Phase C2-2a: Flag to use native diff (set to false to fallback to Web diff)
    var useNativeDiff: Bool = true

    // Editor Bridge State
    @Published var editorWebReady: Bool = false
    @Published var lastEditorPath: String?
    @Published var editorStatus: String = ""
    @Published var editorStatusIsError: Bool = false

    // Phase C2-1.5: Pending editor line reveal (path, line, highlightMs)
    // Set when diff click requests line navigation before editor is ready
    @Published var pendingEditorReveal: (path: String, line: Int, highlightMs: Int)?

    // Phase C1-1: Terminal Bridge State (global, for status display)
    @Published var terminalState: TerminalState = .idle

    // Phase C1-2: Per-tab terminal session mapping
    // Maps tabId -> sessionId for terminal tabs
    @Published var terminalSessionByTabId: [UUID: String] = [:]
    // Track stale sessions (disconnected but tab still exists)
    @Published var staleTerminalTabs: Set<UUID> = []
    // Callback for terminal kill (set by CenterContentView)
    var onTerminalKill: ((String, String) -> Void)?

    // WebSocket Client
    let wsClient = WSClient()

    // Core Process Manager
    let coreProcessManager = CoreProcessManager()

    // Project name (for WS protocol)
    var selectedProjectName: String = "default"

    // Mock data for workspaces
    let workspaces = [
        "default": "Default Workspace",
        "project-alpha": "Project Alpha",
        "project-beta": "Project Beta"
    ]

    // Mock files for Quick Open (fallback when disconnected)
    let mockFiles: [String: [String]] = [
        "default": ["README.md", "src/main.rs", "Cargo.toml", ".gitignore", "docs/DESIGN.md"],
        "project-alpha": ["Alpha.swift", "AppDelegate.swift", "Info.plist"],
        "project-beta": ["index.html", "style.css", "script.js", "package.json"]
    ]

    var commands: [Command] = []

    init() {
        // Set default workspace
        self.selectedWorkspaceKey = "default"
        ensureDefaultTab(for: "default")
        setupCommands()

        // Setup Core process callbacks
        setupCoreCallbacks()

        // Start Core process first (WS will connect when Core is ready)
        startCoreIfNeeded()
    }

    // MARK: - Core Process Management

    /// Setup callbacks for Core process events
    private func setupCoreCallbacks() {
        coreProcessManager.onCoreReady = { [weak self] port in
            print("[AppState] Core ready on port \(port), connecting WebSocket")
            self?.setupWSClient(port: port)
        }

        coreProcessManager.onCoreFailed = { [weak self] message in
            print("[AppState] Core failed: \(message)")
            self?.connectionState = .disconnected
        }

        coreProcessManager.onCoreRestarting = { [weak self] attempt, maxAttempts in
            print("[AppState] Core restarting (attempt \(attempt)/\(maxAttempts))")
            // Disconnect WebSocket during restart
            self?.wsClient.disconnect()
            self?.connectionState = .disconnected
        }

        coreProcessManager.onCoreRestartLimitReached = { [weak self] message in
            print("[AppState] Core restart limit reached: \(message)")
            self?.connectionState = .disconnected
        }
    }

    /// Start Core process if not already running
    func startCoreIfNeeded() {
        guard !coreProcessManager.isRunning else {
            print("[AppState] Core already running")
            return
        }
        coreProcessManager.start()
    }

    /// Restart Core process (for Cmd+R recovery)
    /// Resets auto-restart counter for manual recovery
    func restartCore() {
        print("[AppState] Restarting Core (manual, resetting counter)...")
        wsClient.disconnect()
        coreProcessManager.restart(resetCounter: true)
    }

    /// Stop Core process (called on app termination)
    func stopCore() {
        coreProcessManager.stop()
    }

    // MARK: - WebSocket Setup

    private func setupWSClient(port: Int) {
        wsClient.onConnectionStateChanged = { [weak self] connected in
            self?.connectionState = connected ? .connected : .disconnected
        }

        wsClient.onFileIndexResult = { [weak self] result in
            self?.handleFileIndexResult(result)
        }

        // Phase C2-2a: Handle git diff results
        wsClient.onGitDiffResult = { [weak self] result in
            self?.handleGitDiffResult(result)
        }

        // Phase C3-1: Handle git status results
        wsClient.onGitStatusResult = { [weak self] result in
            self?.handleGitStatusResult(result)
        }

        // Phase C3-2a: Handle git operation results
        wsClient.onGitOpResult = { [weak self] result in
            self?.handleGitOpResult(result)
        }

        // Phase C3-3a: Handle git branches results
        wsClient.onGitBranchesResult = { [weak self] result in
            self?.handleGitBranchesResult(result)
        }

        // Phase C3-4a: Handle git commit results
        wsClient.onGitCommitResult = { [weak self] result in
            self?.handleGitCommitResult(result)
        }

        wsClient.onError = { [weak self] errorMsg in
            // Update cache with error if we were loading
            if let ws = self?.selectedWorkspaceKey {
                var cache = self?.fileIndexCache[ws] ?? FileIndexCache.empty()
                if cache.isLoading {
                    cache.isLoading = false
                    cache.error = errorMsg
                    self?.fileIndexCache[ws] = cache
                }
            }
        }

        // Connect to the dynamic port
        wsClient.connect(port: port)
    }

    private func handleFileIndexResult(_ result: FileIndexResult) {
        let cache = FileIndexCache(
            items: result.items,
            truncated: result.truncated,
            updatedAt: Date(),
            isLoading: false,
            error: nil
        )
        fileIndexCache[result.workspace] = cache
    }

    // MARK: - File Index API

    func fetchFileIndex(workspaceKey: String) {
        guard connectionState == .connected else {
            var cache = fileIndexCache[workspaceKey] ?? FileIndexCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            fileIndexCache[workspaceKey] = cache
            return
        }

        // Set loading state
        var cache = fileIndexCache[workspaceKey] ?? FileIndexCache.empty()
        cache.isLoading = true
        cache.error = nil
        fileIndexCache[workspaceKey] = cache

        // Send request
        wsClient.requestFileIndex(project: selectedProjectName, workspace: workspaceKey)
    }

    func refreshFileIndex() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchFileIndex(workspaceKey: ws)
    }

    func reconnectAndRefresh() {
        wsClient.reconnect()
    }

    // MARK: - Phase C2-2a: Git Diff API

    /// Generate cache key for diff
    private func diffCacheKey(workspace: String, path: String, mode: String) -> String {
        return "\(workspace):\(path):\(mode)"
    }

    /// Handle git diff result from WebSocket
    private func handleGitDiffResult(_ result: GitDiffResult) {
        let key = diffCacheKey(workspace: result.workspace, path: result.path, mode: result.mode)
        let parsedLines = DiffParser.parse(result.text)

        let cache = DiffCache(
            text: result.text,
            parsedLines: parsedLines,
            isLoading: false,
            error: nil,
            isBinary: result.isBinary,
            truncated: result.truncated,
            code: result.code,
            updatedAt: Date()
        )
        diffCache[key] = cache
    }

    /// Fetch git diff for a file
    func fetchGitDiff(workspaceKey: String, path: String, mode: DiffMode) {
        guard connectionState == .connected else {
            let key = diffCacheKey(workspace: workspaceKey, path: path, mode: mode.rawValue)
            var cache = diffCache[key] ?? DiffCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            diffCache[key] = cache
            return
        }

        let key = diffCacheKey(workspace: workspaceKey, path: path, mode: mode.rawValue)

        // Set loading state
        var cache = diffCache[key] ?? DiffCache.empty()
        cache.isLoading = true
        cache.error = nil
        diffCache[key] = cache

        // Send request
        wsClient.requestGitDiff(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            mode: mode.rawValue
        )
    }

    /// Get cached diff for a file/mode
    func getDiffCache(workspaceKey: String, path: String, mode: DiffMode) -> DiffCache? {
        let key = diffCacheKey(workspace: workspaceKey, path: path, mode: mode.rawValue)
        return diffCache[key]
    }

    /// Refresh diff for active diff tab
    func refreshActiveDiff() {
        guard let ws = selectedWorkspaceKey,
              let path = activeDiffPath else { return }
        fetchGitDiff(workspaceKey: ws, path: path, mode: activeDiffMode)
    }

    /// Check if file is deleted (code starts with D)
    func isFileDeleted(workspaceKey: String, path: String, mode: DiffMode) -> Bool {
        guard let cache = getDiffCache(workspaceKey: workspaceKey, path: path, mode: mode) else {
            return false
        }
        return cache.code.hasPrefix("D")
    }

    // MARK: - Phase C3-1: Git Status API

    /// Handle git status result from WebSocket
    private func handleGitStatusResult(_ result: GitStatusResult) {
        let cache = GitStatusCache(
            items: result.items,
            isLoading: false,
            error: result.error,
            isGitRepo: result.isGitRepo,
            updatedAt: Date(),
            hasStagedChanges: result.hasStagedChanges,
            stagedCount: result.stagedCount
        )
        gitStatusCache[result.workspace] = cache
    }

    /// Fetch git status for a workspace
    func fetchGitStatus(workspaceKey: String) {
        guard connectionState == .connected else {
            var cache = gitStatusCache[workspaceKey] ?? GitStatusCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitStatusCache[workspaceKey] = cache
            return
        }

        // Set loading state
        var cache = gitStatusCache[workspaceKey] ?? GitStatusCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitStatusCache[workspaceKey] = cache

        // Send request
        wsClient.requestGitStatus(project: selectedProjectName, workspace: workspaceKey)
    }

    /// Refresh git status for current workspace
    func refreshGitStatus() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitStatus(workspaceKey: ws)
    }

    /// Get cached git status for a workspace
    func getGitStatusCache(workspaceKey: String) -> GitStatusCache? {
        return gitStatusCache[workspaceKey]
    }

    /// Check if git status cache is empty or expired
    func shouldFetchGitStatus(workspaceKey: String) -> Bool {
        guard let cache = gitStatusCache[workspaceKey] else { return true }
        return cache.isExpired && !cache.isLoading
    }

    // MARK: - Phase C3-2a: Git Stage/Unstage API

    /// Handle git operation result from WebSocket
    private func handleGitOpResult(_ result: GitOpResult) {
        // Remove from in-flight
        let opKey = GitOpInFlight(op: result.op, path: result.path, scope: result.scope)
        gitOpsInFlight[result.workspace]?.remove(opKey)

        // Handle branch switch specially
        if result.op == "switch_branch" {
            branchSwitchInFlight.removeValue(forKey: result.workspace)
            if result.ok {
                gitOpToast = result.message ?? "Switched branch"
                gitOpToastIsError = false
                // Refresh branches and status after switch
                fetchGitBranches(workspaceKey: result.workspace)
                fetchGitStatus(workspaceKey: result.workspace)
                // Close any open diff tabs (they're now stale)
                closeAllDiffTabs(workspaceKey: result.workspace)
            } else {
                gitOpToast = result.message ?? "Switch failed"
                gitOpToastIsError = true
            }
            // Auto-dismiss toast after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.gitOpToast = nil
            }
            return
        }

        // Handle branch create specially
        if result.op == "create_branch" {
            branchCreateInFlight.removeValue(forKey: result.workspace)
            if result.ok {
                gitOpToast = result.message ?? "Created branch"
                gitOpToastIsError = false
                // Refresh branches and status after create
                fetchGitBranches(workspaceKey: result.workspace)
                fetchGitStatus(workspaceKey: result.workspace)
                // Close any open diff tabs (they're now stale)
                closeAllDiffTabs(workspaceKey: result.workspace)
            } else {
                gitOpToast = result.message ?? "Create branch failed"
                gitOpToastIsError = true
            }
            // Auto-dismiss toast after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.gitOpToast = nil
            }
            return
        }

        if result.ok {
            // Show success toast
            let pathDesc = result.path ?? "all files"
            if result.op == "discard" {
                // Special message for discard
                if result.message == "File deleted" {
                    gitOpToast = "Deleted \(pathDesc)"
                } else {
                    gitOpToast = "Discarded changes in \(pathDesc)"
                }
            } else {
                gitOpToast = "\(result.op.capitalized)d \(pathDesc)"
            }
            gitOpToastIsError = false

            // Refresh git status
            fetchGitStatus(workspaceKey: result.workspace)

            // If active diff is for this path, handle it
            if let path = result.path,
               selectedWorkspaceKey == result.workspace,
               activeDiffPath == path {
                if result.op == "discard" {
                    // Close the diff tab since file is restored/deleted
                    closeDiffTab(workspaceKey: result.workspace, path: path)
                } else {
                    refreshActiveDiff()
                }
            }
        } else {
            // Show error toast
            gitOpToast = result.message ?? "\(result.op.capitalized) failed"
            gitOpToastIsError = true
        }

        // Auto-dismiss toast after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    /// Stage a file or all files
    func gitStage(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Track in-flight
        let opKey = GitOpInFlight(op: "stage", path: path, scope: scope)
        if gitOpsInFlight[workspaceKey] == nil {
            gitOpsInFlight[workspaceKey] = []
        }
        gitOpsInFlight[workspaceKey]?.insert(opKey)

        wsClient.requestGitStage(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope
        )
    }

    /// Unstage a file or all files
    func gitUnstage(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Track in-flight
        let opKey = GitOpInFlight(op: "unstage", path: path, scope: scope)
        if gitOpsInFlight[workspaceKey] == nil {
            gitOpsInFlight[workspaceKey] = []
        }
        gitOpsInFlight[workspaceKey]?.insert(opKey)

        wsClient.requestGitUnstage(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope
        )
    }

    /// Discard working tree changes for a file or all files
    /// WARNING: This is destructive and cannot be undone!
    func gitDiscard(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Track in-flight
        let opKey = GitOpInFlight(op: "discard", path: path, scope: scope)
        if gitOpsInFlight[workspaceKey] == nil {
            gitOpsInFlight[workspaceKey] = []
        }
        gitOpsInFlight[workspaceKey]?.insert(opKey)

        wsClient.requestGitDiscard(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope
        )
    }

    /// Check if a git operation is in-flight for a path
    func isGitOpInFlight(workspaceKey: String, path: String?, op: String) -> Bool {
        guard let ops = gitOpsInFlight[workspaceKey] else { return false }
        return ops.contains { $0.op == op && $0.path == path }
    }

    /// Check if any git operation is in-flight for a workspace
    func hasAnyGitOpInFlight(workspaceKey: String) -> Bool {
        guard let ops = gitOpsInFlight[workspaceKey] else { return false }
        return !ops.isEmpty
    }

    // MARK: - Phase C3-3a: Git Branch API

    /// Handle git branches result from WebSocket
    private func handleGitBranchesResult(_ result: GitBranchesResult) {
        let cache = GitBranchCache(
            current: result.current,
            branches: result.branches,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        gitBranchCache[result.workspace] = cache
    }

    /// Fetch git branches for a workspace
    func fetchGitBranches(workspaceKey: String) {
        guard connectionState == .connected else {
            var cache = gitBranchCache[workspaceKey] ?? GitBranchCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitBranchCache[workspaceKey] = cache
            return
        }

        // Set loading state
        var cache = gitBranchCache[workspaceKey] ?? GitBranchCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitBranchCache[workspaceKey] = cache

        // Send request
        wsClient.requestGitBranches(project: selectedProjectName, workspace: workspaceKey)
    }

    /// Refresh git branches for current workspace
    func refreshGitBranches() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitBranches(workspaceKey: ws)
    }

    /// Get cached git branches for a workspace
    func getGitBranchCache(workspaceKey: String) -> GitBranchCache? {
        return gitBranchCache[workspaceKey]
    }

    /// Switch to a different branch
    func gitSwitchBranch(workspaceKey: String, branch: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Track in-flight
        branchSwitchInFlight[workspaceKey] = branch

        wsClient.requestGitSwitchBranch(
            project: selectedProjectName,
            workspace: workspaceKey,
            branch: branch
        )
    }

    /// Create and switch to a new branch
    func gitCreateBranch(workspaceKey: String, branch: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Track in-flight
        branchCreateInFlight[workspaceKey] = branch

        wsClient.requestGitCreateBranch(
            project: selectedProjectName,
            workspace: workspaceKey,
            branch: branch
        )
    }

    /// Check if branch create is in-flight for a workspace
    func isBranchCreateInFlight(workspaceKey: String) -> Bool {
        return branchCreateInFlight[workspaceKey] != nil
    }

    /// Check if branch switch is in-flight for a workspace
    func isBranchSwitchInFlight(workspaceKey: String) -> Bool {
        return branchSwitchInFlight[workspaceKey] != nil
    }

    /// Close all diff tabs for a workspace (used after branch switch)
    func closeAllDiffTabs(workspaceKey: String) {
        guard var tabs = workspaceTabs[workspaceKey] else { return }
        let diffTabIds = tabs.filter { $0.kind == .diff }.map { $0.id }
        for tabId in diffTabIds {
            closeTab(workspaceKey: workspaceKey, tabId: tabId)
        }
    }

    // MARK: - Phase C3-4a: Git Commit API

    /// Handle git commit result from WebSocket
    private func handleGitCommitResult(_ result: GitCommitResult) {
        // Remove from in-flight
        commitInFlight.removeValue(forKey: result.workspace)

        if result.ok {
            // Clear commit message on success
            commitMessage.removeValue(forKey: result.workspace)

            // Show success toast
            gitOpToast = result.message ?? "Committed"
            gitOpToastIsError = false

            // Refresh git status
            fetchGitStatus(workspaceKey: result.workspace)
        } else {
            // Show error toast
            gitOpToast = result.message ?? "Commit failed"
            gitOpToastIsError = true
        }

        // Auto-dismiss toast after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    /// Commit staged changes
    func gitCommit(workspaceKey: String, message: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Validate message
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            gitOpToast = "Commit message cannot be empty"
            gitOpToastIsError = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.gitOpToast = nil
            }
            return
        }

        // Track in-flight
        commitInFlight[workspaceKey] = true

        wsClient.requestGitCommit(
            project: selectedProjectName,
            workspace: workspaceKey,
            message: trimmedMessage
        )
    }

    /// Check if commit is in-flight for a workspace
    func isCommitInFlight(workspaceKey: String) -> Bool {
        return commitInFlight[workspaceKey] == true
    }

    /// Check if workspace has staged changes (from cache)
    func hasStagedChanges(workspaceKey: String) -> Bool {
        return gitStatusCache[workspaceKey]?.hasStagedChanges ?? false
    }

    /// Get staged count for workspace (from cache)
    func stagedCount(workspaceKey: String) -> Int {
        return gitStatusCache[workspaceKey]?.stagedCount ?? 0
    }

    private func setupCommands() {
        self.commands = [
            Command(id: "global.palette", title: "Show Command Palette", subtitle: nil, scope: .global, keyHint: "Cmd+Shift+P") { app in
                app.commandPaletteMode = .command
                app.commandPalettePresented = true
                app.commandQuery = ""
                app.paletteSelectionIndex = 0
            },
            Command(id: "global.quickOpen", title: "Quick Open", subtitle: "Go to file", scope: .global, keyHint: "Cmd+P") { app in
                app.commandPaletteMode = .file
                app.commandPalettePresented = true
                app.commandQuery = ""
                app.paletteSelectionIndex = 0
            },
            Command(id: "global.toggleExplorer", title: "Show Explorer", subtitle: nil, scope: .global, keyHint: "Cmd+1") { app in
                app.activeRightTool = .explorer
            },
            Command(id: "global.toggleSearch", title: "Show Search", subtitle: nil, scope: .global, keyHint: "Cmd+2") { app in
                app.activeRightTool = .search
            },
            Command(id: "global.toggleGit", title: "Show Git", subtitle: nil, scope: .global, keyHint: "Cmd+3") { app in
                app.activeRightTool = .git
            },
            Command(id: "global.reconnect", title: "Reconnect", subtitle: "Restart Core and reconnect", scope: .global, keyHint: "Cmd+R") { app in
                app.restartCore()
            },
            Command(id: "workspace.refreshFileIndex", title: "Refresh File Index", subtitle: "Reload file list from Core", scope: .workspace, keyHint: nil) { app in
                app.refreshFileIndex()
            },
            Command(id: "workspace.newTerminal", title: "New Terminal", subtitle: nil, scope: .workspace, keyHint: "Cmd+T") { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.addTerminalTab(workspaceKey: ws)
            },
            Command(id: "workspace.closeTab", title: "Close Active Tab", subtitle: nil, scope: .workspace, keyHint: "Cmd+W") { app in
                guard let ws = app.selectedWorkspaceKey,
                      let tabId = app.activeTabIdByWorkspace[ws] else { return }
                app.closeTab(workspaceKey: ws, tabId: tabId)
            },
            Command(id: "workspace.nextTab", title: "Next Tab", subtitle: nil, scope: .workspace, keyHint: "Ctrl+Tab") { app in
                app.nextTab()
            },
            Command(id: "workspace.prevTab", title: "Previous Tab", subtitle: nil, scope: .workspace, keyHint: "Ctrl+Shift+Tab") { app in
                app.prevTab()
            },
            Command(id: "workspace.save", title: "Save File", subtitle: nil, scope: .workspace, keyHint: "Cmd+S") { app in
                 app.saveActiveEditorFile()
            }
        ]
    }
    
    // MARK: - Tab Helpers
    
    func ensureDefaultTab(for workspaceKey: String) {
        if workspaceTabs[workspaceKey]?.isEmpty ?? true {
            let newTab = TabModel(
                id: UUID(),
                title: "Terminal",
                kind: .terminal,
                workspaceKey: workspaceKey,
                payload: ""
            )
            workspaceTabs[workspaceKey] = [newTab]
            activeTabIdByWorkspace[workspaceKey] = newTab.id
        }
    }
    
    func activateTab(workspaceKey: String, tabId: UUID) {
        activeTabIdByWorkspace[workspaceKey] = tabId
    }
    
    func closeTab(workspaceKey: String, tabId: UUID) {
        guard var tabs = workspaceTabs[workspaceKey] else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }

        let tab = tabs[index]
        let isActive = activeTabIdByWorkspace[workspaceKey] == tabId

        // Phase C1-2: Send terminal kill and clean up session mapping
        if tab.kind == .terminal {
            if let sessionId = terminalSessionByTabId[tabId] {
                onTerminalKill?(tabId.uuidString, sessionId)
            }
            terminalSessionByTabId.removeValue(forKey: tabId)
            staleTerminalTabs.remove(tabId)
        }

        tabs.remove(at: index)
        workspaceTabs[workspaceKey] = tabs

        if isActive {
            if tabs.isEmpty {
                activeTabIdByWorkspace[workspaceKey] = nil
            } else {
                // Select previous tab if possible, else next
                let newIndex = max(0, min(index, tabs.count - 1))
                activeTabIdByWorkspace[workspaceKey] = tabs[newIndex].id
            }
        }
    }
    
    func addTab(workspaceKey: String, kind: TabKind, title: String, payload: String) {
        let newTab = TabModel(
            id: UUID(),
            title: title,
            kind: kind,
            workspaceKey: workspaceKey,
            payload: payload
        )
        
        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
        
        workspaceTabs[workspaceKey]?.append(newTab)
        activeTabIdByWorkspace[workspaceKey] = newTab.id
    }
    
    func addTerminalTab(workspaceKey: String) {
        addTab(workspaceKey: workspaceKey, kind: .terminal, title: "Terminal", payload: "")
    }
    
    func addEditorTab(workspaceKey: String, path: String, line: Int? = nil) {
        // Check if editor tab for this path already exists
        if let tabs = workspaceTabs[workspaceKey],
           let existingTab = tabs.first(where: { $0.kind == .editor && $0.payload == path }) {
            // Activate existing tab
            activeTabIdByWorkspace[workspaceKey] = existingTab.id
            // Set pending reveal if line specified
            if let line = line {
                pendingEditorReveal = (path: path, line: line, highlightMs: 2000)
            }
            return
        }
        // Create new tab
        addTab(workspaceKey: workspaceKey, kind: .editor, title: path, payload: path)
        // Set pending reveal if line specified
        if let line = line {
            pendingEditorReveal = (path: path, line: line, highlightMs: 2000)
        }
    }
    
    func addDiffTab(workspaceKey: String, path: String, mode: DiffMode = .working) {
        // Check if diff tab for this path already exists
        if let tabs = workspaceTabs[workspaceKey],
           let existingTab = tabs.first(where: { $0.kind == .diff && $0.payload == path }) {
            // Activate existing tab and update mode
            activeTabIdByWorkspace[workspaceKey] = existingTab.id
            // Update diff mode if different
            if existingTab.diffMode != mode.rawValue {
                if var tabs = workspaceTabs[workspaceKey],
                   let index = tabs.firstIndex(where: { $0.id == existingTab.id }) {
                    tabs[index].diffMode = mode.rawValue
                    workspaceTabs[workspaceKey] = tabs
                }
            }
            return
        }

        // Create new diff tab
        var newTab = TabModel(
            id: UUID(),
            title: "Diff: \(path.split(separator: "/").last ?? Substring(path))",
            kind: .diff,
            workspaceKey: workspaceKey,
            payload: path
        )
        newTab.diffMode = mode.rawValue

        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }

        workspaceTabs[workspaceKey]?.append(newTab)
        activeTabIdByWorkspace[workspaceKey] = newTab.id
    }

    /// Close diff tab for a specific path (used when file is discarded)
    func closeDiffTab(workspaceKey: String, path: String) {
        guard let tabs = workspaceTabs[workspaceKey],
              let tab = tabs.first(where: { $0.kind == .diff && $0.payload == path }) else {
            return
        }
        closeTab(workspaceKey: workspaceKey, tabId: tab.id)
    }

    func nextTab() {
        guard let ws = selectedWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty,
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId }) else { return }
        
        let nextIndex = (index + 1) % tabs.count
        activeTabIdByWorkspace[ws] = tabs[nextIndex].id
    }
    
    func prevTab() {
        guard let ws = selectedWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty,
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId }) else { return }

        let prevIndex = (index - 1 + tabs.count) % tabs.count
        activeTabIdByWorkspace[ws] = tabs[prevIndex].id
    }

    // MARK: - Editor Bridge Helpers

    /// Get the active tab for the current workspace
    func getActiveTab() -> TabModel? {
        guard let ws = selectedWorkspaceKey,
              let activeId = activeTabIdByWorkspace[ws],
              let tabs = workspaceTabs[ws] else { return nil }
        return tabs.first { $0.id == activeId }
    }

    /// Check if active tab is an editor tab
    var isActiveTabEditor: Bool {
        getActiveTab()?.kind == .editor
    }

    /// Get the file path of the active editor tab
    var activeEditorPath: String? {
        guard let tab = getActiveTab(), tab.kind == .editor else { return nil }
        return tab.payload
    }

    /// Save the active editor file (called by Cmd+S)
    func saveActiveEditorFile() {
        guard let path = activeEditorPath else {
            print("[AppState] No active editor tab to save")
            return
        }
        // The actual save is triggered via WebBridge in CenterContentView
        // This just sets the intent; the view will handle the bridge call
        lastEditorPath = path
        editorStatus = "Saving..."
        editorStatusIsError = false
        NotificationCenter.default.post(name: .saveEditorFile, object: path)
    }

    /// Update editor status after save result
    func handleEditorSaved(path: String) {
        editorStatus = "Saved"
        editorStatusIsError = false
        // Clear status after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.editorStatus == "Saved" {
                self?.editorStatus = ""
            }
        }
    }

    func handleEditorSaveError(path: String, message: String) {
        editorStatus = "Error: \(message)"
        editorStatusIsError = true
    }

    /// Check if active tab is a diff tab
    var isActiveTabDiff: Bool {
        getActiveTab()?.kind == .diff
    }

    /// Get the file path of the active diff tab
    var activeDiffPath: String? {
        guard let tab = getActiveTab(), tab.kind == .diff else { return nil }
        return tab.payload
    }

    /// Get the diff mode of the active diff tab
    var activeDiffMode: DiffMode {
        guard let tab = getActiveTab(), tab.kind == .diff,
              let modeStr = tab.diffMode,
              let mode = DiffMode(rawValue: modeStr) else { return .working }
        return mode
    }

    /// Update diff mode for active diff tab
    func setActiveDiffMode(_ mode: DiffMode) {
        guard let ws = selectedWorkspaceKey,
              var tabs = workspaceTabs[ws],
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId && $0.kind == .diff }) else { return }

        tabs[index].diffMode = mode.rawValue
        workspaceTabs[ws] = tabs
    }

    /// Get the diff view mode of the active diff tab
    var activeDiffViewMode: DiffViewMode {
        guard let tab = getActiveTab(), tab.kind == .diff,
              let modeStr = tab.diffViewMode,
              let mode = DiffViewMode(rawValue: modeStr) else { return .unified }
        return mode
    }

    /// Update diff view mode for active diff tab
    func setActiveDiffViewMode(_ mode: DiffViewMode) {
        guard let ws = selectedWorkspaceKey,
              var tabs = workspaceTabs[ws],
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId && $0.kind == .diff }) else { return }

        tabs[index].diffViewMode = mode.rawValue
        workspaceTabs[ws] = tabs
    }

    // MARK: - Phase C1-2: Terminal State Helpers (Multi-Session)

    /// Check if active tab is a terminal tab
    var isActiveTabTerminal: Bool {
        getActiveTab()?.kind == .terminal
    }

    /// Get the session ID for a specific terminal tab
    func getTerminalSessionId(for tabId: UUID) -> String? {
        return terminalSessionByTabId[tabId]
    }

    /// Get the session ID for the active terminal tab
    var activeTerminalSessionId: String? {
        guard let tab = getActiveTab(), tab.kind == .terminal else { return nil }
        return terminalSessionByTabId[tab.id]
    }

    /// Handle terminal ready event from WebBridge (with tabId)
    func handleTerminalReady(tabId: String, sessionId: String, project: String, workspace: String) {
        guard let uuid = UUID(uuidString: tabId) else {
            print("[AppState] Invalid tabId: \(tabId)")
            return
        }

        // Update session mapping
        terminalSessionByTabId[uuid] = sessionId
        staleTerminalTabs.remove(uuid)

        // Update tab's terminalSessionId
        if let ws = selectedWorkspaceKey,
           var tabs = workspaceTabs[ws],
           let index = tabs.firstIndex(where: { $0.id == uuid }) {
            tabs[index].terminalSessionId = sessionId
            workspaceTabs[ws] = tabs
        }

        // Update global terminal state for status bar
        terminalState = .ready(sessionId: sessionId)
        print("[AppState] Terminal ready: tabId=\(tabId), sessionId=\(sessionId)")
    }

    /// Handle terminal closed event from WebBridge
    func handleTerminalClosed(tabId: String, sessionId: String, code: Int?) {
        guard let uuid = UUID(uuidString: tabId) else { return }

        // Remove session mapping
        terminalSessionByTabId.removeValue(forKey: uuid)

        // Update tab's terminalSessionId
        if let ws = selectedWorkspaceKey,
           var tabs = workspaceTabs[ws],
           let index = tabs.firstIndex(where: { $0.id == uuid }) {
            tabs[index].terminalSessionId = nil
            workspaceTabs[ws] = tabs
        }

        print("[AppState] Terminal closed: tabId=\(tabId), code=\(code ?? -1)")
    }

    /// Handle terminal error event from WebBridge
    func handleTerminalError(tabId: String?, message: String) {
        terminalState = .error(message: message)
        print("[AppState] Terminal error: \(message)")
    }

    /// Handle terminal connected event
    func handleTerminalConnected() {
        // Clear error state when reconnected
        if case .error = terminalState {
            terminalState = .idle
        }
    }

    /// Mark all terminal sessions as stale (on disconnect)
    func markAllTerminalSessionsStale() {
        for tabId in terminalSessionByTabId.keys {
            staleTerminalTabs.insert(tabId)
        }
        terminalSessionByTabId.removeAll()
        terminalState = .idle
        print("[AppState] All terminal sessions marked as stale")
    }

    /// Check if a terminal tab needs respawn
    func terminalNeedsRespawn(_ tabId: UUID) -> Bool {
        return staleTerminalTabs.contains(tabId) || terminalSessionByTabId[tabId] == nil
    }

    /// Request terminal for current workspace (legacy, for status)
    func requestTerminal() {
        terminalState = .connecting
    }
}
