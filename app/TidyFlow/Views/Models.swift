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
    case idea = "IDEA"
    case androidStudio = "Android Studio"
    case xcode = "Xcode"
    case devecoStudio = "DevEco Studio"

    var bundleId: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .trae: return "com.trae.app"
        case .idea: return "com.jetbrains.intellij"
        case .androidStudio: return "com.google.android.studio"
        case .xcode: return "com.apple.dt.Xcode"
        case .devecoStudio: return "com.huawei.devecostudio.ds"
        }
    }

    var assetName: String {
        switch self {
        case .vscode: return "vscode-icon"
        case .cursor: return "cursor-icon"
        case .trae: return "trae-icon"
        case .idea: return "idea-icon"
        case .androidStudio: return "android-studio-icon"
        case .xcode: return "xcode-icon"
        case .devecoStudio: return "deveco-studio-icon"
        }
    }

    var fallbackIconName: String {
        switch self {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .trae: return "sparkles"
        case .idea: return "lightbulb"
        case .androidStudio: return "apps.iphone"
        case .xcode: return "hammer"
        case .devecoStudio: return "star"
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
    case settings
    
    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .editor: return "doc.text"
        case .diff: return "arrow.left.arrow.right"
        case .settings: return "gearshape"
        }
    }
}

struct TabModel: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let kind: TabKind
    let workspaceKey: String
    var payload: String  // 使用 var 以便执行后清空自定义命令

    // Phase C1-2: Terminal session ID (only for terminal tabs)
    // Stored separately from payload to maintain Codable compatibility
    var terminalSessionId: String?

    // Phase C2-1: Diff mode (only for diff tabs)
    // "working" = unstaged changes, "staged" = staged changes
    var diffMode: String?

    // Phase C2-2b: Diff view mode (only for diff tabs)
    // "unified" = single column, "split" = side-by-side
    var diffViewMode: String?

    // 编辑器 dirty 状态（文件有未保存更改）
    var isDirty: Bool = false
}

// Phase C2-1: Diff mode enum for type safety
enum DiffMode: String, Codable {
    case working
    case staged
}

typealias TabSet = [TabModel]

// MARK: - 自定义终端命令

/// 自定义终端命令配置
struct CustomCommand: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var icon: String  // SF Symbol 名称或 "custom:filename" 格式的自定义图标
    var command: String
    
    /// 创建新命令时生成唯一 ID
    init(id: String = UUID().uuidString, name: String = "", icon: String = "terminal", command: String = "") {
        self.id = id
        self.name = name
        self.icon = icon
        self.command = command
    }
}

/// 客户端设置
struct ClientSettings: Codable {
    var customCommands: [CustomCommand]
    /// 工作空间快捷键映射：key 为 "0"-"9"，value 为 "projectName/workspaceName"
    var workspaceShortcuts: [String: String]
    
    enum CodingKeys: String, CodingKey {
        case customCommands
        case workspaceShortcuts
    }
    
    init(customCommands: [CustomCommand] = [], workspaceShortcuts: [String: String] = [:]) {
        self.customCommands = customCommands
        self.workspaceShortcuts = workspaceShortcuts
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customCommands = try container.decodeIfPresent([CustomCommand].self, forKey: .customCommands) ?? []
        workspaceShortcuts = try container.decodeIfPresent([String: String].self, forKey: .workspaceShortcuts) ?? [:]
    }
}

/// 品牌图标枚举（用于自定义命令图标选择）
enum BrandIcon: String, CaseIterable {
    case cursor = "cursor"
    case vscode = "vscode"
    case trae = "trae"
    case claude = "claude"
    case codex = "codex"
    case gemini = "gemini"
    case opencode = "opencode"
    
    var assetName: String {
        switch self {
        case .cursor: return "cursor-icon"
        case .vscode: return "vscode-icon"
        case .trae: return "trae-icon"
        case .claude: return "claude-icon"
        case .codex: return "codex-icon"
        case .gemini: return "gemini-icon"
        case .opencode: return "opencode-icon"
        }
    }
    
    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .trae: return "Trae"
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        }
    }

    /// 是否有 AI Agent 功能（VS Code 和 Trae 没有）
    var hasAIAgent: Bool {
        switch self {
        case .vscode, .trae: return false
        default: return true
        }
    }

    /// 建议的正常模式命令
    var suggestedCommand: String? {
        switch self {
        case .cursor: return "cursor-agent"
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        case .vscode, .trae: return nil
        }
    }

    /// 建议的 Yolo 模式命令（自动执行，跳过确认）
    var yoloCommand: String? {
        switch self {
        case .claude: return "claude --dangerously-skip-permissions"
        case .codex: return "codex --full-auto"
        default: return nil
        }
    }
}

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
    var isDefault: Bool = false  // 是否为默认工作空间（虚拟，指向项目根目录）
}

/// Represents a project containing multiple workspaces
struct ProjectModel: Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String?
    var workspaces: [WorkspaceModel]
    var isExpanded: Bool = true
}

// MARK: - Git 状态索引（资源管理器用）

/// Git 状态索引，支持 O(1) 路径查找和文件夹状态聚合
struct GitStatusIndex {
    /// 文件路径 -> 状态码（M, A, D, ??, R, C, U）
    private var fileStatus: [String: String] = [:]
    /// 文件夹路径 -> 聚合状态码（子文件中优先级最高的状态）
    private var folderStatus: [String: String] = [:]

    /// 状态优先级（数字越大优先级越高）
    private static let statusPriority: [String: Int] = [
        "U": 7,   // 冲突
        "M": 6,   // 修改
        "A": 5,   // 新增
        "D": 4,   // 删除
        "R": 3,   // 重命名
        "C": 2,   // 复制
        "??": 1,  // 未跟踪
        "!!": 0,  // 忽略
    ]

    /// 从 GitStatusCache 构建索引
    init(from cache: GitStatusCache) {
        // 1. 索引所有文件状态
        for item in cache.items {
            fileStatus[item.path] = item.status
        }

        // 2. 向上传播状态到父目录
        for item in cache.items {
            propagateToParents(path: item.path, status: item.status)
        }
    }

    /// 空索引
    init() {}

    /// 向上传播状态到所有父目录
    private mutating func propagateToParents(path: String, status: String) {
        // 不传播到父目录的状态：
        // !! 忽略文件：用户关心的是有变更的文件
        // D 删除文件：删除状态无需向上传递，避免父目录显示删除标记
        // ?? 未跟踪文件：未纳入版本控制的文件不应影响父目录状态
        if status == "!!" || status == "D" || status == "??" { return }

        var currentPath = path
        while let lastSlash = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[..<lastSlash])
            if currentPath.isEmpty { break }

            // 比较优先级，保留更高优先级的状态
            if let existing = folderStatus[currentPath] {
                let existingPriority = Self.statusPriority[existing] ?? 0
                let newPriority = Self.statusPriority[status] ?? 0
                if newPriority > existingPriority {
                    folderStatus[currentPath] = status
                }
            } else {
                folderStatus[currentPath] = status
            }
        }
    }

    /// 获取文件的 Git 状态
    func getFileStatus(_ path: String) -> String? {
        return fileStatus[path]
    }

    /// 获取文件夹的聚合 Git 状态
    func getFolderStatus(_ path: String) -> String? {
        return folderStatus[path]
    }

    /// 获取任意路径的状态（文件或文件夹）
    func getStatus(path: String, isDir: Bool) -> String? {
        if isDir {
            return folderStatus[path]
        } else {
            return fileStatus[path]
        }
    }

    /// 根据状态码返回对应颜色
    static func colorForStatus(_ status: String?) -> Color? {
        guard let status = status else { return nil }
        switch status {
        case "M": return .orange      // 修改
        case "A": return .green       // 新增
        case "D": return .red         // 删除
        case "??": return .gray       // 未跟踪
        case "R": return .blue        // 重命名
        case "C": return .cyan        // 复制
        case "U": return .purple      // 冲突
        case "!!": return .secondary.opacity(0.5)  // 忽略
        default: return nil
        }
    }
}

// MARK: - 文件浏览器模型

/// 文件条目信息（对应 Core 的 FileEntryInfo）
struct FileEntry: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String      // 相对路径
    let isDir: Bool
    let size: UInt64
    let isIgnored: Bool   // 是否被 .gitignore 忽略
    let isSymlink: Bool   // 是否为符号链接

    /// 从 JSON 解析
    static func from(json: [String: Any], parentPath: String) -> FileEntry? {
        guard let name = json["name"] as? String,
              let isDir = json["is_dir"] as? Bool else {
            return nil
        }
        let size = json["size"] as? UInt64 ?? 0
        let isIgnored = json["is_ignored"] as? Bool ?? false
        let isSymlink = json["is_symlink"] as? Bool ?? false
        let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        return FileEntry(name: name, path: path, isDir: isDir, size: size, isIgnored: isIgnored, isSymlink: isSymlink)
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

// MARK: - v1.24: 剪贴板模型

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

    // Git 状态索引缓存（资源管理器用，workspace key -> GitStatusIndex）
    private var gitStatusIndexCache: [String: GitStatusIndex] = [:]

    // Git Log Cache (workspace key -> GitLogCache)
    @Published var gitLogCache: [String: GitLogCache] = [:]

    // Git Show Cache (workspace key + sha -> GitShowCache)
    @Published var gitShowCache: [String: GitShowCache] = [:]

    // v1.24: 剪贴板是否有文件（驱动粘贴菜单显示）
    @Published var clipboardHasFiles: Bool = false

    // Phase C3-2a: Git operation in-flight tracking (workspace key -> Set<GitOpInFlight>)
    @Published var gitOpsInFlight: [String: Set<GitOpInFlight>] = [:]

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

    // 客户端设置（自定义命令等）
    @Published var clientSettings: ClientSettings = ClientSettings()
    // 设置是否已从服务端加载
    @Published var clientSettingsLoaded: Bool = false

    // Editor Bridge State
    @Published var editorWebReady: Bool = false
    @Published var lastEditorPath: String?
    @Published var editorStatus: String = ""
    @Published var editorStatusIsError: Bool = false

    // 未保存更改确认对话框状态
    @Published var showUnsavedChangesAlert: Bool = false
    var pendingCloseTabId: UUID?
    var pendingCloseWorkspaceKey: String?
    var pendingCloseAfterSave: (workspaceKey: String, tabId: UUID)?

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

    /// 工作空间首次打开终端的时间记录（内存中，不持久化）
    /// key: globalWorkspaceKey (如 "projectName:workspaceName")
    @Published var workspaceTerminalOpenTime: [String: Date] = [:]
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
    // Callback for editor tab close (通知 JS 层清理编辑器缓存)
    // Parameters: path
    var onEditorTabClose: ((String) -> Void)?
    // Callback for editor file changed on disk (通知 JS 层文件在磁盘上发生变化)
    // Parameters: project, workspace, paths, isDirtyFlags, kind
    var onEditorFileChanged: ((String, String, [String], [Bool], String) -> Void)?

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
        
        // Update selectedProjectName for WS protocol
        // 注意：使用原始项目名称，不进行格式转换，因为服务端使用原始名称索引项目
        if let project = projects.first(where: { $0.id == projectId }) {
            selectedProjectName = project.name
        }
        
        // 使用全局工作空间键（包含项目名称）来区分不同项目的同名工作空间
        guard let globalKey = currentGlobalWorkspaceKey else {
            print("[AppState] Warning: Could not generate global workspace key")
            return
        }
        print("[AppState] Global workspace key: \(globalKey)")
        
        // 确保有默认 Tab（使用全局键）
        ensureDefaultTab(for: globalKey)

        // 连接后请求数据（使用原始 workspaceName，因为 fetchXXX 方法内部会用 selectedProjectName 构建完整键）
        // 切换项目但 workspace 名相同时（如 A-default → B-default）selectedWorkspaceKey 不变，onChange 不触发，
        // Git 面板的 loadDataIfNeeded 不会执行，因此这里一并请求分支与提交历史，保证切换后 Git 面板有数据。
        if connectionState == .connected {
            // 订阅文件监控（切换工作空间时自动切换监控目标）
            subscribeCurrentWorkspace()

            // 每次切换都请求最新数据（保留旧缓存先显示，新数据返回后自动刷新 UI）
            fetchFileList(workspaceKey: workspaceName, path: ".")
            fetchGitStatus(workspaceKey: workspaceName)
            fetchGitBranches(workspaceKey: workspaceName)
            fetchGitLog(workspaceKey: workspaceName)
        }
    }
    
    /// 生成全局唯一的工作空间键（包含项目名称）
    /// 用于所有需要区分不同项目同名工作空间的缓存
    func globalWorkspaceKey(projectName: String, workspaceName: String) -> String {
        return "\(projectName):\(workspaceName)"
    }
    
    /// 获取当前选中的全局工作空间键
    var currentGlobalWorkspaceKey: String? {
        guard let workspaceName = selectedWorkspaceKey else {
            return nil
        }
        return globalWorkspaceKey(projectName: selectedProjectName, workspaceName: workspaceName)
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
                print("[AppState] WebSocket connected, requesting project list and client settings")
                self?.wsClient.requestListProjects()
                self?.wsClient.requestGetClientSettings()
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

        // Handle git show results (single commit details)
        wsClient.onGitShowResult = { [weak self] result in
            self?.handleGitShowResult(result)
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
                print("[AppState] 项目 '\(result.name)' 已移除")
            } else {
                print("[AppState] 移除项目失败: \(result.message ?? "未知错误")")
            }
        }

        // Handle workspace removed results
        wsClient.onWorkspaceRemoved = { [weak self] result in
            self?.handleWorkspaceRemoved(result)
        }

        // 处理客户端设置结果
        wsClient.onClientSettingsResult = { [weak self] settings in
            self?.clientSettings = settings
            self?.clientSettingsLoaded = true
            print("[AppState] 已加载 \(settings.customCommands.count) 个自定义命令, \(settings.workspaceShortcuts.count) 个工作空间快捷键")
        }

        wsClient.onClientSettingsSaved = { ok, message in
            if ok {
                print("[AppState] 客户端设置已保存")
            } else {
                print("[AppState] 保存设置失败: \(message ?? "未知错误")")
            }
        }

        // v1.22: 文件监控回调
        wsClient.onWatchSubscribed = { [weak self] result in
            print("[AppState] 已订阅文件监控: project=\(result.project), workspace=\(result.workspace)")
        }

        wsClient.onWatchUnsubscribed = {
            print("[AppState] 已取消文件监控订阅")
        }

        wsClient.onFileChanged = { [weak self] notification in
            print("[AppState] 文件变化: \(notification.paths.count) 个文件, kind=\(notification.kind)")
            // 使相关缓存失效
            self?.invalidateFileCache(project: notification.project, workspace: notification.workspace)
            // 通知编辑器层文件变化
            self?.notifyEditorFileChanged(notification: notification)
        }

        wsClient.onGitStatusChanged = { [weak self] notification in
            print("[AppState] Git 状态变化: project=\(notification.project), workspace=\(notification.workspace)")
            // 自动刷新 Git 状态
            self?.fetchGitStatus(workspaceKey: notification.workspace)
            // 同时刷新分支信息（可能有新分支创建）
            self?.fetchGitBranches(workspaceKey: notification.workspace)
        }

        // v1.23: 文件重命名结果
        wsClient.onFileRenameResult = { [weak self] result in
            self?.handleFileRenameResult(result)
        }

        // v1.23: 文件删除结果
        wsClient.onFileDeleteResult = { [weak self] result in
            self?.handleFileDeleteResult(result)
        }

        // v1.24: 文件复制结果
        wsClient.onFileCopyResult = { [weak self] result in
            self?.handleFileCopyResult(result)
        }

        // v1.25: 文件移动结果
        wsClient.onFileMoveResult = { [weak self] result in
            self?.handleFileMoveResult(result)
        }

        // 文件写入结果（新建文件）
        wsClient.onFileWriteResult = { [weak self] result in
            self?.handleFileWriteResult(result)
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

    // MARK: - v1.22: 文件监控 API

    /// 订阅当前工作空间的文件监控
    func subscribeCurrentWorkspace() {
        guard let workspaceKey = selectedWorkspaceKey else { return }
        wsClient.requestWatchSubscribe(project: selectedProjectName, workspace: workspaceKey)
    }

    /// 取消文件监控订阅
    func unsubscribeWatch() {
        wsClient.requestWatchUnsubscribe()
    }

    /// 使文件缓存失效（收到文件变化通知时调用）
    /// 采用增量更新策略：不清除缓存，直接获取新数据覆盖旧数据，避免界面闪烁
    func invalidateFileCache(project: String, workspace: String) {
        let prefix = "\(project):\(workspace):"

        // 收集所有展开的目录路径
        let expandedPaths = directoryExpandState
            .filter { $0.key.hasPrefix(prefix) && $0.value }
            .map { String($0.key.dropFirst(prefix.count)) }

        // 清除文件索引缓存（搜索用）
        fileIndexCache.removeValue(forKey: workspace)

        // 如果是当前选中的工作空间，刷新根目录和所有展开的目录
        // 注意：不清除文件列表缓存，新数据会直接覆盖旧数据
        if workspace == selectedWorkspaceKey && project == selectedProjectName {
            fetchFileList(workspaceKey: workspace, path: ".")
            for path in expandedPaths {
                fetchFileList(workspaceKey: workspace, path: path)
            }
        }
    }

    /// 通知编辑器层文件在磁盘上发生变化
    func notifyEditorFileChanged(notification: FileChangedNotification) {
        let globalKey = globalWorkspaceKey(projectName: notification.project, workspaceName: notification.workspace)
        guard let tabs = workspaceTabs[globalKey] else { return }

        let affectedTabs = tabs.filter { $0.kind == .editor && notification.paths.contains($0.payload) }
        guard !affectedTabs.isEmpty else { return }

        let paths = affectedTabs.map { $0.payload }
        let dirtyFlags = affectedTabs.map { $0.isDirty }
        onEditorFileChanged?(notification.project, notification.workspace, paths, dirtyFlags, notification.kind)
    }

    // MARK: - 文件列表 API

    /// 生成文件列表缓存键（包含项目名称以区分不同项目的同名工作空间）
    private func fileListCacheKey(project: String, workspace: String, path: String) -> String {
        return "\(project):\(workspace):\(path)"
    }

    /// 处理文件列表结果
    private func handleFileListResult(_ result: FileListResult) {
        let key = fileListCacheKey(project: result.project, workspace: result.workspace, path: result.path)
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
        let projectName = selectedProjectName
        let key = fileListCacheKey(project: projectName, workspace: workspaceKey, path: path)
        
        guard connectionState == .connected else {
            var cache = fileListCache[key] ?? FileListCache.empty()
            cache.error = "connection.disconnected".localized
            cache.isLoading = false
            fileListCache[key] = cache
            return
        }

        // 设置加载状态
        var cache = fileListCache[key] ?? FileListCache.empty()
        cache.isLoading = true
        cache.error = nil
        fileListCache[key] = cache

        // 发送请求
        wsClient.requestFileList(project: projectName, workspace: workspaceKey, path: path)
    }

    /// 获取缓存的文件列表
    func getFileListCache(workspaceKey: String, path: String) -> FileListCache? {
        let key = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: path)
        return fileListCache[key]
    }

    /// 刷新当前工作空间的文件列表（包括根目录和所有展开的目录）
    func refreshFileList() {
        guard let ws = selectedWorkspaceKey else { return }
        let prefix = "\(selectedProjectName):\(ws):"

        // 收集所有展开的目录路径
        let expandedPaths = directoryExpandState
            .filter { $0.key.hasPrefix(prefix) && $0.value }
            .map { String($0.key.dropFirst(prefix.count)) }

        // 刷新根目录和所有展开的目录
        fetchFileList(workspaceKey: ws, path: ".")
        for path in expandedPaths {
            fetchFileList(workspaceKey: ws, path: path)
        }
    }

    /// 切换目录展开状态
    func toggleDirectoryExpanded(workspaceKey: String, path: String) {
        let key = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: path)
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
        let key = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: path)
        return directoryExpandState[key] ?? false
    }

    // MARK: - v1.23: File Rename/Delete API

    /// 处理文件重命名结果
    private func handleFileRenameResult(_ result: FileRenameResult) {
        if result.success {
            print("[AppState] 文件重命名成功: \(result.oldPath) -> \(result.newPath)")
            // 刷新文件列表
            refreshFileList()
            // 如果重命名的文件正在编辑器中打开，更新标签
            updateEditorTabAfterRename(oldPath: result.oldPath, newPath: result.newPath)
        } else {
            print("[AppState] 文件重命名失败: \(result.message ?? "未知错误")")
        }
    }

    /// 处理文件删除结果
    private func handleFileDeleteResult(_ result: FileDeleteResult) {
        if result.success {
            print("[AppState] 文件删除成功: \(result.path)")
            // 刷新文件列表
            refreshFileList()
            // 如果删除的文件正在编辑器中打开，关闭标签
            closeEditorTabAfterDelete(path: result.path)
        } else {
            print("[AppState] 文件删除失败: \(result.message ?? "未知错误")")
        }
    }

    /// 请求重命名文件或目录
    func renameFile(workspaceKey: String, path: String, newName: String) {
        guard connectionState == .connected else {
            print("[AppState] 无法重命名：未连接")
            return
        }
        wsClient.requestFileRename(
            project: selectedProjectName,
            workspace: workspaceKey,
            oldPath: path,
            newName: newName
        )
    }

    /// 请求删除文件或目录（移到回收站）
    func deleteFile(workspaceKey: String, path: String) {
        guard connectionState == .connected else {
            print("[AppState] 无法删除：未连接")
            return
        }
        wsClient.requestFileDelete(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path
        )
    }

    /// v1.25: 请求移动文件或目录到新目录
    func moveFile(workspaceKey: String, oldPath: String, newDir: String) {
        guard connectionState == .connected else {
            print("[AppState] 无法移动：未连接")
            return
        }
        wsClient.requestFileMove(
            project: selectedProjectName,
            workspace: workspaceKey,
            oldPath: oldPath,
            newDir: newDir
        )
    }

    /// 处理文件移动结果
    private func handleFileMoveResult(_ result: FileMoveResult) {
        if result.success {
            print("[AppState] 文件移动成功: \(result.oldPath) -> \(result.newPath)")
            refreshFileList()
            updateEditorTabAfterRename(oldPath: result.oldPath, newPath: result.newPath)
        } else {
            print("[AppState] 文件移动失败: \(result.message ?? "未知错误")")
        }
    }

    // MARK: - 新建文件

    /// 请求新建文件
    func createNewFile(workspaceKey: String, parentDir: String, fileName: String) {
        guard connectionState == .connected else {
            print("[AppState] 无法新建文件：未连接")
            return
        }
        // 拼接路径
        let filePath = parentDir == "." ? fileName : "\(parentDir)/\(fileName)"
        // 检查文件列表缓存中是否已有同名文件
        let cacheKey = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: parentDir)
        if let cache = fileListCache[cacheKey] {
            if cache.items.contains(where: { $0.name == fileName }) {
                print("[AppState] 新建文件失败：文件已存在 \(filePath)")
                return
            }
        }
        wsClient.requestFileWrite(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: filePath,
            content: Data()
        )
    }

    /// 处理文件写入结果
    private func handleFileWriteResult(_ result: FileWriteResult) {
        if result.success {
            print("[AppState] 新建文件成功: \(result.path)")
            refreshFileList()
        } else {
            print("[AppState] 新建文件失败: \(result.path)")
        }
    }

    /// 重命名后更新编辑器标签
    private func updateEditorTabAfterRename(oldPath: String, newPath: String) {
        guard let globalKey = currentGlobalWorkspaceKey else { return }
        guard var tabs = workspaceTabs[globalKey] else { return }
        // 检查是否有打开的编辑器标签匹配旧路径
        if let index = tabs.firstIndex(where: { $0.kind == .editor && $0.payload == oldPath }) {
            // 更新标签路径（payload）和标题
            tabs[index].payload = newPath
            let newFileName = String(newPath.split(separator: "/").last ?? Substring(newPath))
            tabs[index].title = newFileName
            workspaceTabs[globalKey] = tabs
        }
    }

    /// 删除后关闭编辑器标签
    private func closeEditorTabAfterDelete(path: String) {
        guard let globalKey = currentGlobalWorkspaceKey else { return }
        guard let tabs = workspaceTabs[globalKey] else { return }
        // 检查是否有打开的编辑器标签匹配路径（包括子路径，因为可能删除的是目录）
        let tabsToClose = tabs.filter { tab in
            tab.kind == .editor && (tab.payload == path || tab.payload.hasPrefix(path + "/"))
        }

        for tab in tabsToClose {
            performCloseTab(workspaceKey: globalKey, tabId: tab.id)
        }
    }

    // MARK: - v1.24: 文件复制粘贴（使用系统剪贴板）

    /// 复制文件到系统剪贴板（Finder 兼容格式）
    func copyFileToClipboard(workspaceKey: String, path: String, isDir: Bool, name: String) {
        #if canImport(AppKit)
        guard let workspacePath = selectedWorkspacePath else {
            print("[AppState] 无法复制：未找到工作空间路径")
            return
        }
        let absolutePath = (workspacePath as NSString).appendingPathComponent(path)
        let fileURL = URL(fileURLWithPath: absolutePath)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        clipboardHasFiles = true
        print("[AppState] 已复制到系统剪贴板: \(absolutePath)")
        #endif
    }

    /// 从系统剪贴板读取文件 URL 列表
    private func readFileURLsFromClipboard() -> [URL] {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        // 优先使用 urlReadingFileURLsOnly 确保只读取文件 URL
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        // 兜底：从 pasteboardItems 中直接读取 public.file-url
        var result: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let urlString = item.string(forType: .fileURL),
               let url = URL(string: urlString),
               url.isFileURL {
                result.append(url)
            }
        }
        return result
        #else
        return []
        #endif
    }

    /// 从系统剪贴板粘贴文件到指定目录
    func pasteFiles(workspaceKey: String, destDir: String) {
        guard connectionState == .connected else {
            print("[AppState] 无法粘贴：未连接")
            return
        }

        let urls = readFileURLsFromClipboard()
        guard !urls.isEmpty else {
            print("[AppState] 剪贴板中没有文件")
            return
        }

        for url in urls {
            let absolutePath = url.path
            print("[AppState] 粘贴文件: \(absolutePath) -> \(destDir)")
            wsClient.requestFileCopy(
                destProject: selectedProjectName,
                destWorkspace: workspaceKey,
                sourceAbsolutePath: absolutePath,
                destDir: destDir
            )
        }
    }

    /// 检查系统剪贴板是否有文件（同时同步 clipboardHasFiles 状态）
    func checkClipboardForFiles() {
        clipboardHasFiles = !readFileURLsFromClipboard().isEmpty
    }

    /// 处理文件复制结果
    private func handleFileCopyResult(_ result: FileCopyResult) {
        if result.success {
            print("[AppState] 文件复制成功: \(result.sourceAbsolutePath) -> \(result.destPath)")
            // 刷新目标目录的文件列表
            let destDir = (result.destPath as NSString).deletingLastPathComponent
            let refreshPath = destDir.isEmpty ? "." : destDir
            fetchFileList(workspaceKey: result.workspace, path: refreshPath)
        } else {
            print("[AppState] 文件复制失败: \(result.message ?? "未知错误")")
        }
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
    /// 生成 Git 状态缓存键（包含项目名称）
    private func gitStatusCacheKey(project: String, workspace: String) -> String {
        return "\(project):\(workspace)"
    }

    private func handleGitStatusResult(_ result: GitStatusResult) {
        let key = gitStatusCacheKey(project: result.project, workspace: result.workspace)
        let cache = GitStatusCache(
            items: result.items,
            isLoading: false,
            error: result.error,
            isGitRepo: result.isGitRepo,
            updatedAt: Date(),
            hasStagedChanges: result.hasStagedChanges,
            stagedCount: result.stagedCount
        )
        gitStatusCache[key] = cache
        // 清除索引缓存，下次访问时重新构建
        gitStatusIndexCache.removeValue(forKey: key)
    }

    /// Fetch git status for a workspace
    func fetchGitStatus(workspaceKey: String) {
        let projectName = selectedProjectName
        let key = gitStatusCacheKey(project: projectName, workspace: workspaceKey)
        
        guard connectionState == .connected else {
            var cache = gitStatusCache[key] ?? GitStatusCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitStatusCache[key] = cache
            return
        }

        // Set loading state
        var cache = gitStatusCache[key] ?? GitStatusCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitStatusCache[key] = cache

        // Send request
        wsClient.requestGitStatus(project: projectName, workspace: workspaceKey)
    }

    /// Refresh git status for current workspace
    func refreshGitStatus() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitStatus(workspaceKey: ws)
    }

    /// Get cached git status for a workspace
    func getGitStatusCache(workspaceKey: String) -> GitStatusCache? {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        return gitStatusCache[key]
    }

    /// 获取 Git 状态索引（资源管理器用，懒加载）
    func getGitStatusIndex(workspaceKey: String) -> GitStatusIndex {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        // 如果已有缓存，直接返回
        if let index = gitStatusIndexCache[key] {
            return index
        }
        // 从 GitStatusCache 构建索引
        if let cache = gitStatusCache[key] {
            let index = GitStatusIndex(from: cache)
            gitStatusIndexCache[key] = index
            return index
        }
        // 没有状态数据，返回空索引
        return GitStatusIndex()
    }

    /// Check if git status cache is empty or expired
    func shouldFetchGitStatus(workspaceKey: String) -> Bool {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        guard let cache = gitStatusCache[key] else { return true }
        return cache.isExpired && !cache.isLoading
    }

    // MARK: - Git Log (Commit History) API

    /// 生成 Git Log 缓存键（包含项目名称）
    private func gitLogCacheKey(project: String, workspace: String) -> String {
        return "\(project):\(workspace)"
    }

    /// Handle git log result from WebSocket
    private func handleGitLogResult(_ result: GitLogResult) {
        let key = gitLogCacheKey(project: result.project, workspace: result.workspace)
        let cache = GitLogCache(
            entries: result.entries,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        gitLogCache[key] = cache
    }

    /// Fetch git log for a workspace
    func fetchGitLog(workspaceKey: String, limit: Int = 50) {
        let projectName = selectedProjectName
        let key = gitLogCacheKey(project: projectName, workspace: workspaceKey)
        
        guard connectionState == .connected else {
            var cache = gitLogCache[key] ?? GitLogCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitLogCache[key] = cache
            return
        }

        // Set loading state
        var cache = gitLogCache[key] ?? GitLogCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitLogCache[key] = cache

        // Send request
        wsClient.requestGitLog(project: projectName, workspace: workspaceKey, limit: limit)
    }

    /// Refresh git log for current workspace
    func refreshGitLog() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitLog(workspaceKey: ws)
    }

    /// Get cached git log for a workspace
    func getGitLogCache(workspaceKey: String) -> GitLogCache? {
        let key = gitLogCacheKey(project: selectedProjectName, workspace: workspaceKey)
        return gitLogCache[key]
    }

    /// Check if git log cache is empty or expired
    func shouldFetchGitLog(workspaceKey: String) -> Bool {
        let key = gitLogCacheKey(project: selectedProjectName, workspace: workspaceKey)
        guard let cache = gitLogCache[key] else { return true }
        return cache.isExpired && !cache.isLoading
    }

    // MARK: - Git Show (单个 commit 详情) API

    /// Handle git show result from WebSocket
    private func handleGitShowResult(_ result: GitShowResult) {
        let cacheKey = "\(result.workspace):\(result.sha)"
        let cache = GitShowCache(
            result: result,
            isLoading: false,
            error: nil
        )
        gitShowCache[cacheKey] = cache
    }

    /// Fetch git show for a specific commit
    func fetchGitShow(workspaceKey: String, sha: String) {
        let cacheKey = "\(workspaceKey):\(sha)"
        
        guard connectionState == .connected else {
            gitShowCache[cacheKey] = GitShowCache(
                result: nil,
                isLoading: false,
                error: "Disconnected"
            )
            return
        }

        // 检查缓存是否已存在
        if let existing = gitShowCache[cacheKey], existing.result != nil {
            return  // 已有缓存，无需重新请求
        }

        // Set loading state
        gitShowCache[cacheKey] = GitShowCache(
            result: nil,
            isLoading: true,
            error: nil
        )

        // Send request
        wsClient.requestGitShow(project: selectedProjectName, workspace: workspaceKey, sha: sha)
    }

    /// Get cached git show result for a commit
    func getGitShowCache(workspaceKey: String, sha: String) -> GitShowCache? {
        let cacheKey = "\(workspaceKey):\(sha)"
        return gitShowCache[cacheKey]
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
                // Refresh branches and status after switch
                fetchGitBranches(workspaceKey: result.workspace)
                fetchGitStatus(workspaceKey: result.workspace)
                // Close any open diff tabs (they're now stale)
                closeAllDiffTabs(workspaceKey: result.workspace)
            }
            return
        }

        // Handle branch create specially
        if result.op == "create_branch" {
            branchCreateInFlight.removeValue(forKey: result.workspace)
            if result.ok {
                // Refresh branches and status after create
                fetchGitBranches(workspaceKey: result.workspace)
                fetchGitStatus(workspaceKey: result.workspace)
                // Close any open diff tabs (they're now stale)
                closeAllDiffTabs(workspaceKey: result.workspace)
            }
            return
        }

        if result.ok {
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
        }
    }

    /// Stage a file or all files
    func gitStage(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else { return }

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
        guard connectionState == .connected else { return }

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
        guard connectionState == .connected else { return }

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
        guard connectionState == .connected else { return }

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
        guard connectionState == .connected else { return }

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
        guard let tabs = workspaceTabs[workspaceKey] else { return }
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

            // Refresh git status
            fetchGitStatus(workspaceKey: result.workspace)
        }
    }

    /// Commit staged changes
    func gitCommit(workspaceKey: String, message: String) {
        guard connectionState == .connected else { return }

        // Validate message
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

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

        // Refresh git status
        fetchGitStatus(workspaceKey: result.workspace)
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
        guard connectionState == .connected else { return }

        wsClient.requestGitFetch(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    /// Rebase current branch onto another branch
    func gitRebase(workspaceKey: String, ontoBranch: String) {
        guard connectionState == .connected else { return }

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
        guard connectionState == .connected else { return }

        rebaseInFlight[workspaceKey] = true

        wsClient.requestGitRebaseContinue(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    /// Abort a rebase in progress
    func gitRebaseAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }

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

        // Refresh git status
        fetchGitStatus(workspaceKey: result.project)
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
        guard connectionState == .connected else { return }

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
        guard connectionState == .connected else { return }

        mergeInFlight[workspaceKey] = true

        wsClient.requestGitMergeContinue(
            project: selectedProjectName
        )
    }

    /// Abort a merge in progress in integration worktree
    func gitMergeAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }

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

        // Refresh git status
        fetchGitStatus(workspaceKey: result.project)
    }

    /// Rebase current workspace branch onto default branch via integration worktree
    func gitRebaseOntoDefault(workspaceKey: String, defaultBranch: String = "main") {
        guard connectionState == .connected else { return }

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
        guard connectionState == .connected else { return }

        rebaseOntoDefaultInFlight[workspaceKey] = true

        wsClient.requestGitRebaseOntoDefaultContinue(
            project: selectedProjectName
        )
    }

    /// Abort a rebase in progress in integration worktree
    func gitRebaseOntoDefaultAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }

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
            // 服务端现在会返回 "default" 虚拟工作空间，将其标记为 isDefault
            let newWorkspaces = result.items.map { item in
                WorkspaceModel(
                    name: item.name,
                    root: item.root,
                    status: item.status,
                    isDefault: item.name == "default"
                )
            }
            
            projects[index].workspaces = newWorkspaces
        }
    }

    /// Handle project imported result from WebSocket
    func handleProjectImported(_ result: ProjectImportedResult) {
        projectImportInFlight = false
        projectImportError = nil

        // 创建默认工作空间（虚拟，指向项目根目录）
        let defaultWs = WorkspaceModel(
            name: "default",
            root: result.root,
            status: "ready",
            isDefault: true
        )

        let newProject = ProjectModel(
            id: UUID(),
            name: result.name,
            path: result.root,
            workspaces: [defaultWs],
            isExpanded: true
        )

        // Add to state
        projects.append(newProject)

        // 自动选中默认工作空间
        selectWorkspace(projectId: newProject.id, workspaceName: defaultWs.name)
    }

    /// Handle workspace created result from WebSocket
    private func handleWorkspaceCreated(_ result: WorkspaceCreatedResult) {
        // Find the project and add the workspace
        if let index = projects.firstIndex(where: { $0.name == result.project }) {
            let newWorkspace = WorkspaceModel(
                name: result.workspace.name,
                root: result.workspace.root,
                status: result.workspace.status,
                isDefault: false
            )
            projects[index].workspaces.append(newWorkspace)

            // Auto-select the new workspace
            selectWorkspace(projectId: projects[index].id, workspaceName: result.workspace.name)
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
        }
    }

    /// Import a project from local path
    func importProject(name: String, path: String) {
        guard connectionState == .connected else {
            projectImportError = "Disconnected"
            return
        }

        projectImportInFlight = true
        projectImportError = nil

        wsClient.requestImportProject(
            name: name,
            path: path
        )
    }

    /// 移除项目
    func removeProject(id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        guard connectionState == .connected else { return }

        // 先从 UI 移除
        projects.removeAll { $0.id == id }

        // 发送请求到 Core 进行持久化移除
        wsClient.requestRemoveProject(name: project.name)
    }

    /// Create a new workspace in a project（名称由 Core 用 petname 生成）
    func createWorkspace(projectName: String, fromBranch: String? = nil) {
        guard connectionState == .connected else { return }

        wsClient.requestCreateWorkspace(project: projectName, fromBranch: fromBranch)
    }

    /// Remove a workspace from a project
    func removeWorkspace(projectName: String, workspaceName: String) {
        guard connectionState == .connected else { return }
        wsClient.requestRemoveWorkspace(project: projectName, workspace: workspaceName)
    }

    /// 在指定编辑器中打开路径（项目根或工作空间根）
    func openPathInEditor(_ path: String, editor: ExternalEditor) -> Bool {
        #if canImport(AppKit)
        guard editor.isInstalled else {
            print("[AppState] \(editor.rawValue) 未安装")
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", editor.bundleId, path]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                print("[AppState] 无法启动 \(editor.rawValue)")
                return false
            }
            return true
        } catch {
            print("[AppState] 启动失败: \(error.localizedDescription)")
            return false
        }
        #else
        return false
        #endif
    }

    /// Reset integration worktree to clean state
    func gitResetIntegrationWorktree(workspaceKey: String) {
        guard connectionState == .connected else { return }

        wsClient.requestGitResetIntegrationWorktree(
            project: selectedProjectName
        )
    }

    // MARK: - Phase UX-6: Git Check Branch Up To Date API

    /// Check if branch is up to date with default branch
    func gitCheckBranchUpToDate(workspaceKey: String) {
        guard connectionState == .connected else { return }

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
            Command(id: "global.toggleExplorer", title: "Show Explorer", subtitle: nil, scope: .global, keyHint: nil) { app in
                app.activeRightTool = .explorer
            },
            Command(id: "global.toggleSearch", title: "Show Search", subtitle: nil, scope: .global, keyHint: nil) { app in
                app.activeRightTool = .search
            },
            Command(id: "global.toggleGit", title: "Show Git", subtitle: nil, scope: .global, keyHint: nil) { app in
                app.activeRightTool = .git
            },
            Command(id: "global.reconnect", title: "Reconnect", subtitle: "Restart Core and reconnect", scope: .global, keyHint: "Cmd+R") { app in
                app.restartCore()
            },
            Command(id: "workspace.refreshFileIndex", title: "Refresh File Index", subtitle: "Reload file list from Core", scope: .workspace, keyHint: nil) { app in
                app.refreshFileIndex()
            },
            Command(id: "workspace.newTerminal", title: "New Terminal", subtitle: nil, scope: .workspace, keyHint: "Cmd+T") { app in
                guard let ws = app.currentGlobalWorkspaceKey else { return }
                app.addTerminalTab(workspaceKey: ws)
            },
            Command(id: "workspace.closeTab", title: "Close Active Tab", subtitle: nil, scope: .workspace, keyHint: "Cmd+W") { app in
                guard let ws = app.currentGlobalWorkspaceKey,
                      let tabId = app.activeTabIdByWorkspace[ws] else { return }
                app.closeTab(workspaceKey: ws, tabId: tabId)
            },
            Command(id: "workspace.closeOtherTabs", title: "Close Other Tabs", subtitle: nil, scope: .workspace, keyHint: "Opt+Cmd+T") { app in
                guard let ws = app.currentGlobalWorkspaceKey,
                      let tabId = app.activeTabIdByWorkspace[ws] else { return }
                app.closeOtherTabs(workspaceKey: ws, keepTabId: tabId)
            },
            Command(id: "workspace.closeSavedTabs", title: "Close Saved Tabs", subtitle: nil, scope: .workspace, keyHint: "Cmd+K Cmd+U") { app in
                guard let ws = app.currentGlobalWorkspaceKey else { return }
                app.closeSavedTabs(workspaceKey: ws)
            },
            Command(id: "workspace.closeAllTabs", title: "Close All Tabs", subtitle: nil, scope: .workspace, keyHint: "Cmd+K Cmd+W") { app in
                guard let ws = app.currentGlobalWorkspaceKey else { return }
                app.closeAllTabs(workspaceKey: ws)
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
                guard let ws = app.currentGlobalWorkspaceKey else { return }
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
        // 不再自动创建终端，仅确保字典有对应的键
        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
    }
    
    func activateTab(workspaceKey: String, tabId: UUID) {
        activeTabIdByWorkspace[workspaceKey] = tabId
    }
    
    func closeTab(workspaceKey: String, tabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }

        // 编辑器 Tab 且有未保存更改时，弹出确认对话框
        if tab.kind == .editor && tab.isDirty {
            pendingCloseWorkspaceKey = workspaceKey
            pendingCloseTabId = tabId
            showUnsavedChangesAlert = true
            return
        }

        performCloseTab(workspaceKey: workspaceKey, tabId: tabId)
    }

    /// 关闭其他标签页（保留指定 tab）
    func closeOtherTabs(workspaceKey: String, keepTabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        for tab in tabs where tab.id != keepTabId {
            closeTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 关闭右侧标签页
    func closeTabsToRight(workspaceKey: String, ofTabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey],
              let index = tabs.firstIndex(where: { $0.id == ofTabId }) else { return }
        let rightTabs = tabs.suffix(from: tabs.index(after: index))
        for tab in rightTabs {
            closeTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 关闭已保存的标签页（跳过 dirty 的编辑器 tab）
    func closeSavedTabs(workspaceKey: String) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        for tab in tabs {
            if tab.kind == .editor && tab.isDirty { continue }
            performCloseTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 全部关闭（dirty 的编辑器 tab 会弹确认）
    func closeAllTabs(workspaceKey: String) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        for tab in tabs {
            closeTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 实际执行关闭 Tab（跳过 dirty 检查）
    func performCloseTab(workspaceKey: String, tabId: UUID) {
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

        // 编辑器 Tab 关闭时通知 JS 层清理缓存
        if tab.kind == .editor {
            onEditorTabClose?(tab.payload)
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

        // 关闭终端后检查是否需要清除时间记录（用于自动快捷键）
        if tab.kind == .terminal {
            let remainingTerminals = workspaceTabs[workspaceKey]?.filter { $0.kind == .terminal }.count ?? 0
            if remainingTerminals == 0 {
                workspaceTerminalOpenTime.removeValue(forKey: workspaceKey)
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

        // 记录工作空间首次打开终端的时间（用于自动快捷键排序）
        if kind == .terminal && workspaceTerminalOpenTime[workspaceKey] == nil {
            workspaceTerminalOpenTime[workspaceKey] = Date()
        }

        // 当创建终端 Tab 且已有其他终端时，直接通知 WebBridge spawn 新终端
        // （第一个终端由 TerminalContentView.onAppear 处理）
        if kind == .terminal && hasExistingTerminalTab {
            // 标记为 pending spawn，防止 handleTabSwitch 重复 spawn
            pendingSpawnTabs.insert(newTab.id)
            
            // 协议要求传 (projectName, workspaceName)。TabStrip 传入的是 globalKey "project:workspace"，需解析为纯 workspace 名
            let (rpcProject, rpcWorkspace): (String, String)
            if let colonIdx = workspaceKey.firstIndex(of: ":") {
                rpcProject = String(workspaceKey[..<colonIdx])
                rpcWorkspace = String(workspaceKey[workspaceKey.index(after: colonIdx)...])
            } else {
                rpcProject = selectedProjectName
                rpcWorkspace = workspaceKey
            }
            onTerminalSpawn?(newTab.id.uuidString, rpcProject, rpcWorkspace)
        }
    }
    
    func addTerminalTab(workspaceKey: String) {
        addTab(workspaceKey: workspaceKey, kind: .terminal, title: "Terminal", payload: "")
    }

    /// 创建终端并执行自定义命令
    func addTerminalWithCustomCommand(workspaceKey: String, command: CustomCommand) {
        // 创建终端 tab，使用命令名称作为标题，命令内容存入 payload
        let newTab = TabModel(
            id: UUID(),
            title: command.name,
            kind: .terminal,
            workspaceKey: workspaceKey,
            payload: command.command  // 存储命令以便终端就绪后执行
        )

        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
        workspaceTabs[workspaceKey]?.append(newTab)
        activeTabIdByWorkspace[workspaceKey] = newTab.id

        // 记录工作空间首次打开终端的时间（用于自动快捷键排序）
        if workspaceTerminalOpenTime[workspaceKey] == nil {
            workspaceTerminalOpenTime[workspaceKey] = Date()
        }

        // 终端视图会在 spawn 后检查 payload 并执行命令
    }

    // MARK: - 设置页面

    /// 从服务端加载客户端设置
    func loadClientSettings() {
        wsClient.requestGetClientSettings()
    }

    /// 保存客户端设置到服务端
    func saveClientSettings() {
        wsClient.requestSaveClientSettings(settings: clientSettings)
    }

    /// 添加自定义命令
    func addCustomCommand(_ command: CustomCommand) {
        clientSettings.customCommands.append(command)
        saveClientSettings()
    }

    /// 更新自定义命令
    func updateCustomCommand(_ command: CustomCommand) {
        if let index = clientSettings.customCommands.firstIndex(where: { $0.id == command.id }) {
            clientSettings.customCommands[index] = command
            saveClientSettings()
        }
    }

    /// 删除自定义命令
    func deleteCustomCommand(id: String) {
        clientSettings.customCommands.removeAll { $0.id == id }
        saveClientSettings()
    }
    
    // MARK: - 自动工作空间快捷键

    /// 获取按终端打开时间排序的工作空间快捷键映射
    /// 最早打开终端的工作空间获得 ⌘1，依次类推
    var autoWorkspaceShortcuts: [String: String] {
        let sortedWorkspaces = workspaceTerminalOpenTime
            .sorted { $0.value < $1.value }
            .prefix(9)

        let shortcutKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        var result: [String: String] = [:]
        for (index, (workspaceKey, _)) in sortedWorkspaces.enumerated() {
            result[shortcutKeys[index]] = workspaceKey
        }
        return result
    }

    /// 获取工作空间的快捷键（基于终端打开时间自动分配）
    /// - Parameter workspaceKey: 工作空间标识
    /// - Returns: 快捷键数字 "1"-"9" 或 "0"，如果没有打开终端则返回 nil
    func getWorkspaceShortcutKey(workspaceKey: String) -> String? {
        // 将 "project/workspace" 格式转换为 "project:workspace"
        let globalKey: String
        if workspaceKey.contains(":") {
            globalKey = workspaceKey
        } else {
            let components = workspaceKey.split(separator: "/", maxSplits: 1)
            if components.count == 2 {
                var wsName = String(components[1])
                if wsName == "(default)" { wsName = "default" }
                globalKey = "\(components[0]):\(wsName)"
            } else {
                globalKey = workspaceKey
            }
        }

        for (shortcutKey, wsKey) in autoWorkspaceShortcuts {
            if wsKey == globalKey {
                return shortcutKey
            }
        }
        return nil
    }

    /// 根据快捷键切换工作空间
    /// - Parameter shortcutKey: 快捷键数字 "1"-"9"
    func switchToWorkspaceByShortcut(shortcutKey: String) {
        guard let workspaceKey = autoWorkspaceShortcuts[shortcutKey] else {
            return
        }

        // workspaceKey 格式为 "projectName:workspaceName"
        let components = workspaceKey.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else { return }

        let projectName = String(components[0])
        let workspaceName = String(components[1])

        guard let project = projects.first(where: { $0.name == projectName }) else {
            return
        }

        selectWorkspace(projectId: project.id, workspaceName: workspaceName)
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

        // 记录工作空间首次打开终端的时间（用于自动快捷键排序）
        if workspaceTerminalOpenTime[workspaceKey] == nil {
            workspaceTerminalOpenTime[workspaceKey] = Date()
        }

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
        guard let ws = currentGlobalWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty,
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId }) else { return }
        
        let nextIndex = (index + 1) % tabs.count
        activeTabIdByWorkspace[ws] = tabs[nextIndex].id
    }
    
    func prevTab() {
        guard let ws = currentGlobalWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty,
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId }) else { return }

        let prevIndex = (index - 1 + tabs.count) % tabs.count
        activeTabIdByWorkspace[ws] = tabs[prevIndex].id
    }

    /// 按索引切换 Tab，index 1-9 对应第 1-9 个 Tab
    func switchToTabByIndex(_ index: Int) {
        guard let ws = currentGlobalWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty else { return }

        let targetIndex = index - 1

        guard targetIndex >= 0 && targetIndex < tabs.count else { return }
        activeTabIdByWorkspace[ws] = tabs[targetIndex].id
    }

    // MARK: - Editor Bridge Helpers

    /// Get the active tab for the current workspace
    func getActiveTab() -> TabModel? {
        guard let ws = currentGlobalWorkspaceKey,
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
        // 保存成功后清除 dirty 状态
        updateEditorDirtyState(path: path, isDirty: false)
        // 如果有待关闭的 Tab（保存后关闭流程），执行关闭
        if let pending = pendingCloseAfterSave {
            pendingCloseAfterSave = nil
            performCloseTab(workspaceKey: pending.workspaceKey, tabId: pending.tabId)
        }
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
        // 保存失败时清除待关闭状态
        pendingCloseAfterSave = nil
    }

    /// 更新编辑器 Tab 的 dirty 状态
    func updateEditorDirtyState(path: String, isDirty: Bool) {
        guard let globalKey = currentGlobalWorkspaceKey else { return }
        guard var tabs = workspaceTabs[globalKey] else { return }
        if let index = tabs.firstIndex(where: { $0.kind == .editor && $0.payload == path }) {
            tabs[index].isDirty = isDirty
            workspaceTabs[globalKey] = tabs
        }
    }

    /// 保存并关闭 Tab（用于未保存确认对话框的"保存"按钮）
    func saveAndCloseTab(workspaceKey: String, tabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey],
              let tab = tabs.first(where: { $0.id == tabId }),
              tab.kind == .editor else { return }
        pendingCloseAfterSave = (workspaceKey: workspaceKey, tabId: tabId)
        // 触发保存
        lastEditorPath = tab.payload
        editorStatus = "Saving..."
        editorStatusIsError = false
        NotificationCenter.default.post(name: .saveEditorFile, object: tab.payload)
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
        guard let ws = currentGlobalWorkspaceKey,
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
        guard let ws = currentGlobalWorkspaceKey,
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
    func handleTerminalReady(tabId: String, sessionId: String, project: String, workspace: String, webBridge: WebBridge?) {
        guard let uuid = UUID(uuidString: tabId) else {
            print("[AppState] Invalid tabId: \(tabId)")
            return
        }

        // 兜底：若某些入口未提前记录，则在终端 ready 时补齐首次打开时间
        let globalKey = globalWorkspaceKey(projectName: project, workspaceName: workspace)
        if workspaceTerminalOpenTime[globalKey] == nil {
            workspaceTerminalOpenTime[globalKey] = Date()
        }

        // Update session mapping
        terminalSessionByTabId[uuid] = sessionId
        staleTerminalTabs.remove(uuid)
        pendingSpawnTabs.remove(uuid)  // 移除 pending 标记

        // Update tab's terminalSessionId（使用服务端返回的 project 和 workspace 生成全局键）
        if var tabs = workspaceTabs[globalKey],
           let index = tabs.firstIndex(where: { $0.id == uuid }) {
            tabs[index].terminalSessionId = sessionId
            workspaceTabs[globalKey] = tabs
            
            // 检查 tab 的 payload，如果非空则执行自定义命令
            let payload = tabs[index].payload
            if !payload.isEmpty, let bridge = webBridge {
                print("[AppState] Executing custom command: \(payload)")
                bridge.terminalSendInput(sessionId: sessionId, input: payload)
                
                // 清空 payload，防止 attach 时重复执行命令
                tabs[index].payload = ""
                workspaceTabs[globalKey] = tabs
            }
        }

        // Update global terminal state for status bar
        terminalState = .ready(sessionId: sessionId)
        print("[AppState] Terminal ready: tabId=\(tabId), sessionId=\(sessionId), globalKey=\(globalKey)")
    }

    /// Handle terminal closed event from WebBridge
    func handleTerminalClosed(tabId: String, sessionId: String, code: Int?) {
        guard let uuid = UUID(uuidString: tabId) else { return }

        // Remove session mapping
        terminalSessionByTabId.removeValue(forKey: uuid)

        // Update tab's terminalSessionId（搜索所有工作空间的 tabs）
        for (globalKey, var tabs) in workspaceTabs {
            if let index = tabs.firstIndex(where: { $0.id == uuid }) {
                tabs[index].terminalSessionId = nil
                workspaceTabs[globalKey] = tabs
                break
            }
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
