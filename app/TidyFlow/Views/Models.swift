import Foundation
import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Notifications

extension Notification.Name {
    static let saveEditorFile = Notification.Name("saveEditorFile")
}

enum RightTool: String, CaseIterable {
    case explorer
    case search
    case git
}

// MARK: - 外部编辑器（侧边栏与工具栏共用）
enum ExternalEditor: String, CaseIterable {
    case vscode = "VSCode"
    case cursor = "Cursor"
    case trae = "Trae"

    var bundleId: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .trae: return "com.trae.app"
        }
    }

    var assetName: String {
        switch self {
        case .vscode: return "vscode-icon"
        case .cursor: return "cursor-icon"
        case .trae: return "trae-icon"
        }
    }

    var fallbackIconName: String {
        switch self {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .trae: return "sparkles"
        }
    }

    #if canImport(AppKit)
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
    #else
    var isInstalled: Bool { false }
    #endif
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

// MARK: - UX-1: Project/Workspace Models

/// Represents a workspace within a project
struct WorkspaceModel: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var root: String?  // 工作空间路径
    var status: String?
}

/// Represents a project containing multiple workspaces
struct ProjectModel: Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String?
    var workspaces: [WorkspaceModel]
    var isExpanded: Bool = true
}

// MARK: - 文件浏览器模型

/// 文件条目信息（对应 Core 的 FileEntryInfo）
struct FileEntry: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String      // 相对路径
    let isDir: Bool
    let size: UInt64
    
    /// 从 JSON 解析
    static func from(json: [String: Any], parentPath: String) -> FileEntry? {
        guard let name = json["name"] as? String,
              let isDir = json["is_dir"] as? Bool else {
            return nil
        }
        let size = json["size"] as? UInt64 ?? 0
        let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        return FileEntry(name: name, path: path, isDir: isDir, size: size)
    }
}

/// 文件列表请求结果
struct FileListResult {
    let project: String
    let workspace: String
    let path: String
    let items: [FileEntry]
    
    static func from(json: [String: Any]) -> FileListResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let path = json["path"] as? String,
              let itemsJson = json["items"] as? [[String: Any]] else {
            return nil
        }
        
        let parentPath = path == "." ? "" : path
        let items = itemsJson.compactMap { FileEntry.from(json: $0, parentPath: parentPath) }
        return FileListResult(project: project, workspace: workspace, path: path, items: items)
    }
}

/// 目录节点模型（用于展开/折叠状态管理）
class DirectoryNode: Identifiable, ObservableObject {
    let id: String
    let name: String
    let path: String
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false
    @Published var children: [FileEntry] = []
    @Published var error: String?
    
    init(name: String, path: String) {
        self.id = path.isEmpty ? "." : path
        self.name = name
        self.path = path
    }
}

/// 文件列表缓存（按目录路径缓存）
struct FileListCache {
    var items: [FileEntry]
    var isLoading: Bool
    var error: String?
    var updatedAt: Date?
    
    static func empty() -> FileListCache {
        FileListCache(items: [], isLoading: false, error: nil, updatedAt: nil)
    }
    
    var isExpired: Bool {
        guard let updatedAt = updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > 60 // 60秒后过期
    }
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

    // Right Sidebar State
    @Published var rightSidebarCollapsed: Bool = false

    // UX-1: Project Tree State
    @Published var projects: [ProjectModel] = []
    @Published var selectedProjectId: UUID?
    @Published var addProjectSheetPresented: Bool = false

    // File Index Cache (workspace key -> cache)
    @Published var fileIndexCache: [String: FileIndexCache] = [:]

    // 文件列表缓存 (key: "workspace:path" -> FileListCache)
    @Published var fileListCache: [String: FileListCache] = [:]
    // 目录展开状态 (key: "workspace:path" -> isExpanded)
    @Published var directoryExpandState: [String: Bool] = [:]

    // Phase C2-2a: Diff Cache (key: "workspace:path:mode" -> DiffCache)
    @Published var diffCache: [String: DiffCache] = [:]

    // Phase C3-1: Git Status Cache (workspace key -> GitStatusCache)
    @Published var gitStatusCache: [String: GitStatusCache] = [:]

    // Git Log Cache (workspace key -> GitLogCache)
    @Published var gitLogCache: [String: GitLogCache] = [:]

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

    // Phase UX-3a: Git operation status cache (workspace key -> GitOpStatusCache)
    @Published var gitOpStatusCache: [String: GitOpStatusCache] = [:]
    // Phase UX-3a: Rebase in-flight (workspace key -> true)
    @Published var rebaseInFlight: [String: Bool] = [:]

    // Phase UX-3b: Git integration status cache (workspace key -> GitIntegrationStatusCache)
    @Published var gitIntegrationStatusCache: [String: GitIntegrationStatusCache] = [:]
    // Phase UX-3b: Merge in-flight (workspace key -> true)
    @Published var mergeInFlight: [String: Bool] = [:]
    // Phase UX-4: Rebase onto default in-flight (workspace key -> true)
    @Published var rebaseOntoDefaultInFlight: [String: Bool] = [:]

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
    // Track tabs that are pending spawn (to skip handleTabSwitch)
    var pendingSpawnTabs: Set<UUID> = []
    // Callback for terminal kill (set by CenterContentView)
    var onTerminalKill: ((String, String) -> Void)?
    // Callback for terminal spawn (set by CenterContentView)
    // Parameters: tabId, project, workspace
    var onTerminalSpawn: ((String, String, String) -> Void)?
    // Callback for terminal attach (set by CenterContentView)
    // Parameters: tabId, sessionId
    var onTerminalAttach: ((String, String) -> Void)?
    // Callback for Core ready with port (set by CenterContentView to update WebBridge)
    var onCoreReadyWithPort: ((Int) -> Void)?

    // WebSocket Client
    let wsClient = WSClient()

    // Core Process Manager
    let coreProcessManager = CoreProcessManager()

    // Project name (for WS protocol)
    var selectedProjectName: String = "default"


    var commands: [Command] = []

    init() {
        // Start with empty projects list
        self.projects = []
        self.selectedProjectId = nil
        self.selectedWorkspaceKey = nil

        setupCommands()

        // Setup Core process callbacks
        setupCoreCallbacks()

        // Start Core process first (WS will connect when Core is ready)
        startCoreIfNeeded()
    }

    // MARK: - UX-1: Project/Workspace Selection

    /// Select a workspace within a project
    func selectWorkspace(projectId: UUID, workspaceName: String) {
        print("[AppState] selectWorkspace called: projectId=\(projectId), workspaceName=\(workspaceName)")
        selectedProjectId = projectId
        selectedWorkspaceKey = workspaceName
        print("[AppState] selectedWorkspaceKey set to: \(workspaceName)")
        ensureDefaultTab(for: workspaceName)

        // Update selectedProjectName for WS protocol
        if let project = projects.first(where: { $0.id == projectId }) {
            selectedProjectName = project.name.lowercased().replacingOccurrences(of: " ", with: "-")
        }

        // 自动请求根目录文件列表（如果缓存不存在或已过期）
        if connectionState == .connected {
            if getFileListCache(workspaceKey: workspaceName, path: ".") == nil {
                fetchFileList(workspaceKey: workspaceName, path: ".")
            }
        }
    }

    /// Refresh projects and workspaces from Core
    func refreshProjectsAndWorkspaces() {
        wsClient.requestListProjects()
    }

    /// 获取当前选中工作空间的根目录路径
    var selectedWorkspacePath: String? {
        guard let projectId = selectedProjectId,
              let workspaceKey = selectedWorkspaceKey,
              let project = projects.first(where: { $0.id == projectId }),
              let workspace = project.workspaces.first(where: { $0.name == workspaceKey }) else {
            return nil
        }
        return workspace.root
    }

    // MARK: - Core Process Management

    /// Setup callbacks for Core process events
    private func setupCoreCallbacks() {
        coreProcessManager.onCoreReady = { [weak self] port in
            print("[AppState] Core ready on port \(port), connecting WebSocket")
            self?.setupWSClient(port: port)
            // Notify CenterContentView to update WebBridge with the port
            self?.onCoreReadyWithPort?(port)
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
            if connected {
                print("[AppState] WebSocket connected, requesting project list")
                self?.wsClient.requestListProjects()
            }
        }

        wsClient.onFileIndexResult = { [weak self] result in
            self?.handleFileIndexResult(result)
        }

        // 处理文件列表结果
        wsClient.onFileListResult = { [weak self] result in
            self?.handleFileListResult(result)
        }

        // Phase C2-2a: Handle git diff results
        wsClient.onGitDiffResult = { [weak self] result in
            self?.handleGitDiffResult(result)
        }

        // Phase C3-1: Handle git status results
        wsClient.onGitStatusResult = { [weak self] result in
            self?.handleGitStatusResult(result)
        }

        // Handle git log results
        wsClient.onGitLogResult = { [weak self] result in
            self?.handleGitLogResult(result)
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

        // Phase UX-3a: Handle git rebase results
        wsClient.onGitRebaseResult = { [weak self] result in
            self?.handleGitRebaseResult(result)
        }

        // Phase UX-3a: Handle git op status results
        wsClient.onGitOpStatusResult = { [weak self] result in
            self?.handleGitOpStatusResult(result)
        }

        // Phase UX-3b: Handle git merge to default results
        wsClient.onGitMergeToDefaultResult = { [weak self] result in
            self?.handleGitMergeToDefaultResult(result)
        }

        // Phase UX-3b: Handle git integration status results
        wsClient.onGitIntegrationStatusResult = { [weak self] result in
            self?.handleGitIntegrationStatusResult(result)
        }

        // Phase UX-4: Handle git rebase onto default results
        wsClient.onGitRebaseOntoDefaultResult = { [weak self] result in
            self?.handleGitRebaseOntoDefaultResult(result)
        }

        // Phase UX-5: Handle git reset integration worktree results
        wsClient.onGitResetIntegrationWorktreeResult = { [weak self] result in
            self?.handleGitResetIntegrationWorktreeResult(result)
        }

        // UX-2: Handle project import results
        wsClient.onProjectImported = { [weak self] result in
            self?.handleProjectImported(result)
        }

        // UX-2: Handle project list results
        wsClient.onProjectsList = { [weak self] result in
            self?.handleProjectsList(result)
        }

        // Handle workspaces list results
        wsClient.onWorkspacesList = { [weak self] result in
            self?.handleWorkspacesList(result)
        }

        // UX-2: Handle workspace created results
        wsClient.onWorkspaceCreated = { [weak self] result in
            self?.handleWorkspaceCreated(result)
        }

        // Handle project removed results
        wsClient.onProjectRemoved = { [weak self] result in
            if result.ok {
                self?.gitOpToast = "项目 '\(result.name)' 已移除"
                self?.gitOpToastIsError = false
            } else {
                self?.gitOpToast = result.message ?? "移除项目失败"
                self?.gitOpToastIsError = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.gitOpToast = nil
            }
        }

        // Handle workspace removed results
        wsClient.onWorkspaceRemoved = { [weak self] result in
            self?.handleWorkspaceRemoved(result)
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

    // MARK: - 文件列表 API

    /// 生成文件列表缓存键
    private func fileListCacheKey(workspace: String, path: String) -> String {
        return "\(workspace):\(path)"
    }

    /// 处理文件列表结果
    private func handleFileListResult(_ result: FileListResult) {
        let key = fileListCacheKey(workspace: result.workspace, path: result.path)
        let cache = FileListCache(
            items: result.items,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        fileListCache[key] = cache
    }

    /// 获取目录文件列表
    func fetchFileList(workspaceKey: String, path: String = ".") {
        guard connectionState == .connected else {
            let key = fileListCacheKey(workspace: workspaceKey, path: path)
            var cache = fileListCache[key] ?? FileListCache.empty()
            cache.error = "未连接"
            cache.isLoading = false
            fileListCache[key] = cache
            return
        }

        let key = fileListCacheKey(workspace: workspaceKey, path: path)

        // 设置加载状态
        var cache = fileListCache[key] ?? FileListCache.empty()
        cache.isLoading = true
        cache.error = nil
        fileListCache[key] = cache

        // 发送请求
        wsClient.requestFileList(project: selectedProjectName, workspace: workspaceKey, path: path)
    }

    /// 获取缓存的文件列表
    func getFileListCache(workspaceKey: String, path: String) -> FileListCache? {
        let key = fileListCacheKey(workspace: workspaceKey, path: path)
        return fileListCache[key]
    }

    /// 刷新当前工作空间的根目录文件列表
    func refreshFileList() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchFileList(workspaceKey: ws, path: ".")
    }

    /// 切换目录展开状态
    func toggleDirectoryExpanded(workspaceKey: String, path: String) {
        let key = fileListCacheKey(workspace: workspaceKey, path: path)
        let currentState = directoryExpandState[key] ?? false
        directoryExpandState[key] = !currentState
        
        // 如果展开且没有缓存，则请求文件列表
        if !currentState {
            if fileListCache[key] == nil {
                fetchFileList(workspaceKey: workspaceKey, path: path)
            }
        }
    }

    /// 检查目录是否展开
    func isDirectoryExpanded(workspaceKey: String, path: String) -> Bool {
        let key = fileListCacheKey(workspace: workspaceKey, path: path)
        return directoryExpandState[key] ?? false
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

    // MARK: - Git Log (Commit History) API

    /// Handle git log result from WebSocket
    private func handleGitLogResult(_ result: GitLogResult) {
        let cache = GitLogCache(
            entries: result.entries,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        gitLogCache[result.workspace] = cache
    }

    /// Fetch git log for a workspace
    func fetchGitLog(workspaceKey: String, limit: Int = 50) {
        guard connectionState == .connected else {
            var cache = gitLogCache[workspaceKey] ?? GitLogCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitLogCache[workspaceKey] = cache
            return
        }

        // Set loading state
        var cache = gitLogCache[workspaceKey] ?? GitLogCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitLogCache[workspaceKey] = cache

        // Send request
        wsClient.requestGitLog(project: selectedProjectName, workspace: workspaceKey, limit: limit)
    }

    /// Refresh git log for current workspace
    func refreshGitLog() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitLog(workspaceKey: ws)
    }

    /// Get cached git log for a workspace
    func getGitLogCache(workspaceKey: String) -> GitLogCache? {
        return gitLogCache[workspaceKey]
    }

    /// Check if git log cache is empty or expired
    func shouldFetchGitLog(workspaceKey: String) -> Bool {
        guard let cache = gitLogCache[workspaceKey] else { return true }
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

    // MARK: - Phase UX-3a: Git Rebase API

    /// Handle git rebase result from WebSocket
    private func handleGitRebaseResult(_ result: GitRebaseResult) {
        // Remove from in-flight
        rebaseInFlight.removeValue(forKey: result.workspace)

        // Update op status cache
        var cache = gitOpStatusCache[result.workspace] ?? GitOpStatusCache.empty()
        cache.isLoading = false
        cache.updatedAt = Date()

        if result.state == "conflict" {
            cache.state = .rebasing
            cache.conflicts = result.conflicts
        } else if result.state == "completed" || result.state == "aborted" {
            cache.state = .normal
            cache.conflicts = []
        }
        gitOpStatusCache[result.workspace] = cache

        // Show toast
        if result.ok {
            gitOpToast = result.message ?? "Rebase completed"
            gitOpToastIsError = false
        } else if result.state == "conflict" {
            gitOpToast = "Conflicts detected (\(result.conflicts.count) files)"
            gitOpToastIsError = true
        } else {
            gitOpToast = result.message ?? "Rebase failed"
            gitOpToastIsError = true
        }

        // Refresh git status
        fetchGitStatus(workspaceKey: result.workspace)

        // Auto-dismiss toast after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    /// Handle git op status result from WebSocket
    private func handleGitOpStatusResult(_ result: GitOpStatusResult) {
        var cache = gitOpStatusCache[result.workspace] ?? GitOpStatusCache.empty()
        cache.state = result.state
        cache.conflicts = result.conflicts
        cache.isLoading = false
        cache.updatedAt = Date()
        gitOpStatusCache[result.workspace] = cache
    }

    /// Fetch from remote
    func gitFetch(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        wsClient.requestGitFetch(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    /// Rebase current branch onto another branch
    func gitRebase(workspaceKey: String, ontoBranch: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Track in-flight
        rebaseInFlight[workspaceKey] = true

        // Update cache to loading
        var cache = gitOpStatusCache[workspaceKey] ?? GitOpStatusCache.empty()
        cache.isLoading = true
        gitOpStatusCache[workspaceKey] = cache

        wsClient.requestGitRebase(
            project: selectedProjectName,
            workspace: workspaceKey,
            ontoBranch: ontoBranch
        )
    }

    /// Continue a paused rebase
    func gitRebaseContinue(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        rebaseInFlight[workspaceKey] = true

        wsClient.requestGitRebaseContinue(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    /// Abort a rebase in progress
    func gitRebaseAbort(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        rebaseInFlight[workspaceKey] = true

        wsClient.requestGitRebaseAbort(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    /// Fetch git operation status
    func fetchGitOpStatus(workspaceKey: String) {
        guard connectionState == .connected else { return }

        var cache = gitOpStatusCache[workspaceKey] ?? GitOpStatusCache.empty()
        cache.isLoading = true
        gitOpStatusCache[workspaceKey] = cache

        wsClient.requestGitOpStatus(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    /// Get git op status cache for workspace
    func getGitOpStatusCache(workspaceKey: String) -> GitOpStatusCache? {
        return gitOpStatusCache[workspaceKey]
    }

    /// Check if rebase is in-flight for a workspace
    func isRebaseInFlight(workspaceKey: String) -> Bool {
        return rebaseInFlight[workspaceKey] == true
    }

    // MARK: - Phase UX-3b: Git Integration Merge API

    /// Handle git merge to default result from WebSocket
    private func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) {
        // Remove from in-flight (use project as key since integration worktree is project-scoped)
        mergeInFlight.removeValue(forKey: result.project)

        // Update integration status cache
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = false
        cache.updatedAt = Date()

        if result.state == .conflict {
            cache.state = .conflict
            cache.conflicts = result.conflicts
        } else if result.state == .completed || result.state == .idle {
            cache.state = .idle
            cache.conflicts = []
        }
        gitIntegrationStatusCache[result.project] = cache

        // Show toast
        if result.ok {
            gitOpToast = result.message ?? "Merge completed"
            gitOpToastIsError = false
        } else if result.state == .conflict {
            gitOpToast = "Merge conflicts detected (\(result.conflicts.count) files)"
            gitOpToastIsError = true
        } else {
            gitOpToast = result.message ?? "Merge failed"
            gitOpToastIsError = true
        }

        // Refresh git status
        fetchGitStatus(workspaceKey: result.project)

        // Auto-dismiss toast after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    /// Handle git integration status result from WebSocket
    private func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult) {
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.state = result.state
        cache.conflicts = result.conflicts
        cache.isLoading = false
        cache.updatedAt = Date()
        // UX-6: Update branch divergence fields
        cache.branchAheadBy = result.branchAheadBy
        cache.branchBehindBy = result.branchBehindBy
        cache.comparedBranch = result.comparedBranch
        gitIntegrationStatusCache[result.project] = cache
    }

    /// Merge current workspace branch to default branch via integration worktree
    func gitMergeToDefault(workspaceKey: String, defaultBranch: String = "main") {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Track in-flight
        mergeInFlight[workspaceKey] = true

        // Update cache to loading
        var cache = gitIntegrationStatusCache[workspaceKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[workspaceKey] = cache

        wsClient.requestGitMergeToDefault(
            project: selectedProjectName,
            workspace: workspaceKey,
            defaultBranch: defaultBranch
        )
    }

    /// Continue a paused merge in integration worktree
    func gitMergeContinue(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        mergeInFlight[workspaceKey] = true

        wsClient.requestGitMergeContinue(
            project: selectedProjectName
        )
    }

    /// Abort a merge in progress in integration worktree
    func gitMergeAbort(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        mergeInFlight[workspaceKey] = true

        wsClient.requestGitMergeAbort(
            project: selectedProjectName
        )
    }

    /// Fetch git integration status
    func fetchGitIntegrationStatus(workspaceKey: String) {
        guard connectionState == .connected else { return }

        var cache = gitIntegrationStatusCache[workspaceKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[workspaceKey] = cache

        wsClient.requestGitIntegrationStatus(
            project: selectedProjectName
        )
    }

    /// Get git integration status cache for workspace
    func getGitIntegrationStatusCache(workspaceKey: String) -> GitIntegrationStatusCache? {
        return gitIntegrationStatusCache[workspaceKey]
    }

    /// Check if merge is in-flight for a workspace
    func isMergeInFlight(workspaceKey: String) -> Bool {
        return mergeInFlight[workspaceKey] == true
    }

    // MARK: - Phase UX-4: Git Rebase onto Default API

    /// Handle git rebase onto default result from WebSocket
    private func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult) {
        // Remove from in-flight
        rebaseOntoDefaultInFlight.removeValue(forKey: result.project)

        // Update integration status cache
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = false
        cache.updatedAt = Date()

        if result.state == .rebaseConflict {
            cache.state = .rebaseConflict
            cache.conflicts = result.conflicts
        } else if result.state == .rebasing {
            cache.state = .rebasing
            cache.conflicts = []
        } else if result.state == .completed || result.state == .idle {
            cache.state = .idle
            cache.conflicts = []
        }
        gitIntegrationStatusCache[result.project] = cache

        // Show toast
        if result.ok {
            gitOpToast = result.message ?? "Rebase completed"
            gitOpToastIsError = false
        } else if result.state == .rebaseConflict {
            gitOpToast = "Rebase conflicts detected (\(result.conflicts.count) files)"
            gitOpToastIsError = true
        } else {
            gitOpToast = result.message ?? "Rebase failed"
            gitOpToastIsError = true
        }

        // Refresh git status
        fetchGitStatus(workspaceKey: result.project)

        // Auto-dismiss toast after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    /// Rebase current workspace branch onto default branch via integration worktree
    func gitRebaseOntoDefault(workspaceKey: String, defaultBranch: String = "main") {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        // Track in-flight
        rebaseOntoDefaultInFlight[workspaceKey] = true

        // Update cache to loading
        var cache = gitIntegrationStatusCache[workspaceKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[workspaceKey] = cache

        wsClient.requestGitRebaseOntoDefault(
            project: selectedProjectName,
            workspace: workspaceKey,
            defaultBranch: defaultBranch
        )
    }

    /// Continue a paused rebase in integration worktree
    func gitRebaseOntoDefaultContinue(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        rebaseOntoDefaultInFlight[workspaceKey] = true

        wsClient.requestGitRebaseOntoDefaultContinue(
            project: selectedProjectName
        )
    }

    /// Abort a rebase in progress in integration worktree
    func gitRebaseOntoDefaultAbort(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        rebaseOntoDefaultInFlight[workspaceKey] = true

        wsClient.requestGitRebaseOntoDefaultAbort(
            project: selectedProjectName
        )
    }

    /// Check if rebase onto default is in-flight for a workspace
    func isRebaseOntoDefaultInFlight(workspaceKey: String) -> Bool {
        return rebaseOntoDefaultInFlight[workspaceKey] == true
    }

    // MARK: - Phase UX-5: Git Reset Integration Worktree API

    /// Handle git reset integration worktree result from WebSocket
    private func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult) {
        // Clear in-flight flags
        mergeInFlight.removeValue(forKey: result.project)
        rebaseOntoDefaultInFlight.removeValue(forKey: result.project)

        // Reset integration status cache to idle
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.state = .idle
        cache.conflicts = []
        cache.isLoading = false
        cache.updatedAt = Date()
        if let path = result.path {
            cache.integrationPath = path
        }
        gitIntegrationStatusCache[result.project] = cache

        // Show toast
        if result.ok {
            gitOpToast = result.message ?? "Integration worktree reset"
            gitOpToastIsError = false
        } else {
            gitOpToast = result.message ?? "Reset failed"
            gitOpToastIsError = true
        }

        // Auto-dismiss toast after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    // MARK: - UX-2: Project Import API

    /// Callback for project import in-flight tracking
    @Published var projectImportInFlight: Bool = false
    @Published var projectImportError: String?

    /// Handle projects list result from WebSocket
    func handleProjectsList(_ result: ProjectsListResult) {
        print("[AppState] Received project list with \(result.items.count) items")
        
        let oldProjects = self.projects
        
        self.projects = result.items.map { info in
            let oldProject = oldProjects.first(where: { $0.path == info.root })
            
            return ProjectModel(
                id: oldProject?.id ?? UUID(),
                name: info.name,
                path: info.root,
                workspaces: oldProject?.workspaces ?? [], // Keep old workspaces while loading
                isExpanded: oldProject?.isExpanded ?? true
            )
        }

        // Request workspaces for each project
        for project in result.items {
            print("[AppState] Requesting workspaces for project: \(project.name)")
            wsClient.requestListWorkspaces(project: project.name)
        }
    }

    /// Handle workspaces list result from WebSocket
    func handleWorkspacesList(_ result: WorkspacesListResult) {
        print("[AppState] Received workspaces for project: \(result.project) (\(result.items.count) items)")
        
        if let index = projects.firstIndex(where: { $0.name == result.project }) {
            let newWorkspaces = result.items.map { item in
                WorkspaceModel(name: item.name, root: item.root, status: item.status)
            }
            
            projects[index].workspaces = newWorkspaces
        }
    }

    /// Handle project imported result from WebSocket
    func handleProjectImported(_ result: ProjectImportedResult) {
        projectImportInFlight = false
        projectImportError = nil

        // Create local ProjectModel
        var workspaces: [WorkspaceModel] = []
        if let ws = result.workspace {
            workspaces.append(WorkspaceModel(name: ws.name, root: ws.root, status: ws.status))
        }

        let newProject = ProjectModel(
            id: UUID(),
            name: result.name,
            path: result.root,
            workspaces: workspaces,
            isExpanded: true
        )

        // Add to state
        projects.append(newProject)

        // Auto-select the new workspace if created
        if let ws = result.workspace {
            selectWorkspace(projectId: newProject.id, workspaceName: ws.name)
        }

        // Show success toast
        gitOpToast = "Project '\(result.name)' imported"
        gitOpToastIsError = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    /// Handle workspace created result from WebSocket
    private func handleWorkspaceCreated(_ result: WorkspaceCreatedResult) {
        // Find the project and add the workspace
        if let index = projects.firstIndex(where: { $0.name == result.project }) {
            let newWorkspace = WorkspaceModel(
                name: result.workspace.name,
                root: result.workspace.root,
                status: result.workspace.status
            )
            projects[index].workspaces.append(newWorkspace)

            // Auto-select the new workspace
            selectWorkspace(projectId: projects[index].id, workspaceName: result.workspace.name)
        }

        // Show success toast
        gitOpToast = "Workspace '\(result.workspace.name)' created"
        gitOpToastIsError = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    /// Handle workspace removed result from WebSocket
    private func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult) {
        if result.ok {
            if let index = projects.firstIndex(where: { $0.name == result.project }) {
                projects[index].workspaces.removeAll { $0.name == result.workspace }
                if selectedWorkspaceKey == result.workspace {
                    selectedWorkspaceKey = projects[index].workspaces.first?.name
                }
            }
            gitOpToast = "工作空间 '\(result.workspace)' 已删除"
            gitOpToastIsError = false
        } else {
            gitOpToast = result.message ?? "删除工作空间失败"
            gitOpToastIsError = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.gitOpToast = nil
        }
    }

    /// Import a project from local path
    func importProject(name: String, path: String, createDefaultWorkspace: Bool = true) {
        guard connectionState == .connected else {
            projectImportError = "Disconnected"
            return
        }

        projectImportInFlight = true
        projectImportError = nil

        wsClient.requestImportProject(
            name: name,
            path: path,
            createDefaultWorkspace: createDefaultWorkspace
        )
    }

    /// 移除项目
    func removeProject(id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }

        guard connectionState == .connected else {
            gitOpToast = "未连接，无法移除项目"
            gitOpToastIsError = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.gitOpToast = nil
            }
            return
        }

        // 先从 UI 移除
        projects.removeAll { $0.id == id }

        // 发送请求到 Core 进行持久化移除
        wsClient.requestRemoveProject(name: project.name)
    }

    /// Create a new workspace in a project（名称由 Core 用 petname 生成）
    func createWorkspace(projectName: String, fromBranch: String? = nil) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        wsClient.requestCreateWorkspace(project: projectName, fromBranch: fromBranch)
    }

    /// Remove a workspace from a project
    func removeWorkspace(projectName: String, workspaceName: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }
        wsClient.requestRemoveWorkspace(project: projectName, workspace: workspaceName)
    }

    /// 在指定编辑器中打开路径（项目根或工作空间根）
    func openPathInEditor(_ path: String, editor: ExternalEditor) -> Bool {
        #if canImport(AppKit)
        guard editor.isInstalled else {
            gitOpToast = "\(editor.rawValue) 未安装"
            gitOpToastIsError = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.gitOpToast = nil }
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", editor.bundleId, path]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                gitOpToast = "无法启动 \(editor.rawValue)"
                gitOpToastIsError = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.gitOpToast = nil }
                return false
            }
            return true
        } catch {
            gitOpToast = "启动失败: \(error.localizedDescription)"
            gitOpToastIsError = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.gitOpToast = nil }
            return false
        }
        #else
        return false
        #endif
    }

    /// Reset integration worktree to clean state
    func gitResetIntegrationWorktree(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        wsClient.requestGitResetIntegrationWorktree(
            project: selectedProjectName
        )
    }

    // MARK: - Phase UX-6: Git Check Branch Up To Date API

    /// Check if branch is up to date with default branch
    func gitCheckBranchUpToDate(workspaceKey: String) {
        guard connectionState == .connected else {
            gitOpToast = "Disconnected"
            gitOpToastIsError = true
            return
        }

        let parts = workspaceKey.split(separator: "/")
        let workspace = parts.count == 2 ? String(parts[1]) : workspaceKey

        wsClient.requestGitCheckBranchUpToDate(
            project: selectedProjectName,
            workspace: workspace
        )
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
            },
            // UX-3a: Git rebase commands
            Command(id: "git.fetch", title: "Git: Fetch", subtitle: "Fetch from remote", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitFetch(workspaceKey: ws)
            },
            Command(id: "git.rebase", title: "Git: Rebase onto Default Branch", subtitle: "Rebase onto origin/main", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitRebase(workspaceKey: ws, ontoBranch: "origin/main")
            },
            Command(id: "git.rebaseContinue", title: "Git: Continue Rebase", subtitle: "Continue after resolving conflicts", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitRebaseContinue(workspaceKey: ws)
            },
            Command(id: "git.rebaseAbort", title: "Git: Abort Rebase", subtitle: "Abort and return to original state", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitRebaseAbort(workspaceKey: ws)
            },
            Command(id: "git.aiResolve", title: "Git: Resolve Conflicts with AI", subtitle: "Open terminal with opencode", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.spawnTerminalWithCommand(workspaceKey: ws, command: "opencode")
            },
            // UX-4: Git rebase onto default (integration worktree) commands
            Command(id: "git.rebaseOntoDefault", title: "Git: Safe Rebase onto Default", subtitle: "Rebase in integration worktree", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitRebaseOntoDefault(workspaceKey: ws)
            },
            Command(id: "git.rebaseOntoDefaultContinue", title: "Git: Continue Safe Rebase", subtitle: "Continue rebase in integration worktree", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitRebaseOntoDefaultContinue(workspaceKey: ws)
            },
            Command(id: "git.rebaseOntoDefaultAbort", title: "Git: Abort Safe Rebase", subtitle: "Abort rebase in integration worktree", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitRebaseOntoDefaultAbort(workspaceKey: ws)
            },
            // UX-5: Git reset integration worktree command
            Command(id: "git.resetIntegrationWorktree", title: "Git: Reset Integration Worktree", subtitle: "Reset integration worktree to clean state", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitResetIntegrationWorktree(workspaceKey: ws)
            },
            // UX-6: Git check branch up to date command
            Command(id: "git.checkBranchUpToDate", title: "Git: Check Branch Up To Date", subtitle: "Check if branch is behind default", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCheckBranchUpToDate(workspaceKey: ws)
            }
        ]
    }
    
    // MARK: - Tab Helpers
    
    func ensureDefaultTab(for workspaceKey: String) {
        print("[AppState] ensureDefaultTab called for: \(workspaceKey)")
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
            print("[AppState] Created default terminal tab: \(newTab.id) for workspace: \(workspaceKey)")
        } else {
            print("[AppState] Workspace already has tabs: \(workspaceTabs[workspaceKey]?.count ?? 0)")
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
        // 检查是否已有终端 Tab（用于判断是否需要通过回调 spawn）
        let existingTabs = workspaceTabs[workspaceKey] ?? []
        let hasExistingTerminalTab = existingTabs.contains { $0.kind == .terminal }
        
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
        
        // 当创建终端 Tab 且已有其他终端时，直接通知 WebBridge spawn 新终端
        // （第一个终端由 TerminalContentView.onAppear 处理）
        if kind == .terminal && hasExistingTerminalTab {
            // 标记为 pending spawn，防止 handleTabSwitch 重复 spawn
            pendingSpawnTabs.insert(newTab.id)
            
            // workspaceKey 只是 workspace 名称，project 从 selectedProjectName 获取
            let project = selectedProjectName
            let workspace = workspaceKey
            onTerminalSpawn?(newTab.id.uuidString, project, workspace)
        }
    }
    
    func addTerminalTab(workspaceKey: String) {
        addTab(workspaceKey: workspaceKey, kind: .terminal, title: "Terminal", payload: "")
    }

    /// Spawn a terminal tab and run a command (UX-3a: AI Resolve)
    func spawnTerminalWithCommand(workspaceKey: String, command: String) {
        // Create a new terminal tab
        let newTab = TabModel(
            id: UUID(),
            title: "AI Resolve",
            kind: .terminal,
            workspaceKey: workspaceKey,
            payload: command  // Store command in payload for later execution
        )

        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
        workspaceTabs[workspaceKey]?.append(newTab)
        activeTabIdByWorkspace[workspaceKey] = newTab.id

        // The terminal view will check payload and execute the command after spawn
        // This is handled by the terminal bridge when it detects a non-empty payload
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
        pendingSpawnTabs.remove(uuid)  // 移除 pending 标记

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
