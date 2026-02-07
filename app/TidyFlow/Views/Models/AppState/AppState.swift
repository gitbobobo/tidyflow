import Foundation
import Combine

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
    // UX-2: Project Import State
    @Published var projectImportInFlight: Bool = false
    @Published var projectImportError: String?

    // File Index Cache (workspace key -> cache)
    @Published var fileIndexCache: [String: FileIndexCache] = [:]

    // 文件列表缓存 (key: "workspace:path" -> FileListCache)
    @Published var fileListCache: [String: FileListCache] = [:]
    // 目录展开状态 (key: "workspace:path" -> isExpanded)
    @Published var directoryExpandState: [String: Bool] = [:]

    // Git 缓存状态（独立 ObservableObject，避免 Git 高频更新触发全局视图刷新）
    let gitCache = GitCacheState()

    // 后台任务管理器
    let taskManager = BackgroundTaskManager()
    private var taskManagerCancellable: AnyCancellable?

    // v1.24: 剪贴板是否有文件（驱动粘贴菜单显示）
    @Published var clipboardHasFiles: Bool = false

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

        // 转发 taskManager 变更到 AppState，驱动侧边栏等视图刷新
        taskManagerCancellable = taskManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // 接线 GitCacheState 依赖
        setupGitCache()

        // Setup Core process callbacks
        setupCoreCallbacks()

        // Start Core process first (WS will connect when Core is ready)
        startCoreIfNeeded()
    }

}
