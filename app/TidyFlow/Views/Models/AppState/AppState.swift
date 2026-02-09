import Foundation
import Combine

// MARK: - v1.24: 剪贴板模型

class AppState: ObservableObject {
    @Published var selectedWorkspaceKey: String?
    @Published var activeRightTool: RightTool? = .explorer
    @Published var connectionState: ConnectionState = .disconnected

    @Published var workspaceTabs: [String: TabSet] = [:]
    @Published var activeTabIdByWorkspace: [String: UUID] = [:]

    // 命令面板状态（独立 ObservableObject，避免输入高频更新触发全局视图刷新）
    let paletteState = CommandPaletteState()

    // 向后兼容：保留原属性访问路径，代理到 paletteState
    var commandPalettePresented: Bool {
        get { paletteState.isPresented }
        set { paletteState.isPresented = newValue }
    }
    var commandPaletteMode: PaletteMode {
        get { paletteState.mode }
        set { paletteState.mode = newValue }
    }
    var commandQuery: String {
        get { paletteState.query }
        set { paletteState.query = newValue }
    }
    var paletteSelectionIndex: Int {
        get { paletteState.selectionIndex }
        set { paletteState.selectionIndex = newValue }
    }

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
    // 项目配置页面：当前选中配置的项目名称
    @Published var selectedProjectForConfig: String?

    // 文件缓存状态（独立 ObservableObject，避免文件高频更新触发全局视图刷新）
    let fileCache = FileCacheState()

    // 向后兼容：保留原属性访问路径，代理到 fileCache
    var fileIndexCache: [String: FileIndexCache] {
        get { fileCache.fileIndexCache }
        set { fileCache.fileIndexCache = newValue }
    }
    var fileListCache: [String: FileListCache] {
        get { fileCache.fileListCache }
        set { fileCache.fileListCache = newValue }
    }
    var directoryExpandState: [String: Bool] {
        get { fileCache.directoryExpandState }
        set { fileCache.directoryExpandState = newValue }
    }

    // Git 缓存状态（独立 ObservableObject，避免 Git 高频更新触发全局视图刷新）
    let gitCache = GitCacheState()

    // 终端领域状态（独立 ObservableObject，减少终端状态变化对全局视图的影响）
    let terminalStore = TerminalStore()
    private var terminalStoreCancellable: AnyCancellable?

    // 编辑器领域状态（独立 ObservableObject，减少编辑器状态变化对全局视图的影响）
    let editorStore = EditorStore()
    private var editorStoreCancellable: AnyCancellable?

    // 后台任务管理器
    let taskManager = BackgroundTaskManager()
    private var taskManagerCancellable: AnyCancellable?

    // Toast 通知管理器
    let toastManager = ToastManager()

    // v1.24: 剪贴板是否有文件（驱动粘贴菜单显示）
    @Published var clipboardHasFiles: Bool = false

    /// 正在删除中的工作空间（globalWorkspaceKey 集合），用于阻塞 UI 交互
    @Published var deletingWorkspaces: Set<String> = []

    // 客户端设置（自定义命令等）
    @Published var clientSettings: ClientSettings = ClientSettings()
    // 设置是否已从服务端加载
    @Published var clientSettingsLoaded: Bool = false

    // 向后兼容：编辑器状态代理到 editorStore
    var editorWebReady: Bool {
        get { editorStore.editorWebReady }
        set { editorStore.editorWebReady = newValue }
    }
    var lastEditorPath: String? {
        get { editorStore.lastEditorPath }
        set { editorStore.lastEditorPath = newValue }
    }
    var editorStatus: String {
        get { editorStore.editorStatus }
        set { editorStore.editorStatus = newValue }
    }
    var editorStatusIsError: Bool {
        get { editorStore.editorStatusIsError }
        set { editorStore.editorStatusIsError = newValue }
    }
    var showUnsavedChangesAlert: Bool {
        get { editorStore.showUnsavedChangesAlert }
        set { editorStore.showUnsavedChangesAlert = newValue }
    }
    var pendingCloseTabId: UUID? {
        get { editorStore.pendingCloseTabId }
        set { editorStore.pendingCloseTabId = newValue }
    }
    var pendingCloseWorkspaceKey: String? {
        get { editorStore.pendingCloseWorkspaceKey }
        set { editorStore.pendingCloseWorkspaceKey = newValue }
    }
    var pendingCloseAfterSave: (workspaceKey: String, tabId: UUID)? {
        get { editorStore.pendingCloseAfterSave }
        set { editorStore.pendingCloseAfterSave = newValue }
    }
    var pendingEditorReveal: (path: String, line: Int, highlightMs: Int)? {
        get { editorStore.pendingEditorReveal }
        set { editorStore.pendingEditorReveal = newValue }
    }
    var onEditorTabClose: ((String) -> Void)? {
        get { editorStore.onEditorTabClose }
        set { editorStore.onEditorTabClose = newValue }
    }
    var onEditorFileChanged: ((String, String, [String], [Bool], String) -> Void)? {
        get { editorStore.onEditorFileChanged }
        set { editorStore.onEditorFileChanged = newValue }
    }

    // 向后兼容：终端状态代理到 terminalStore
    var terminalState: TerminalState {
        get { terminalStore.terminalState }
        set { terminalStore.terminalState = newValue }
    }
    var terminalSessionByTabId: [UUID: String] {
        get { terminalStore.terminalSessionByTabId }
        set { terminalStore.terminalSessionByTabId = newValue }
    }
    var staleTerminalTabs: Set<UUID> {
        get { terminalStore.staleTerminalTabs }
        set { terminalStore.staleTerminalTabs = newValue }
    }
    var workspaceTerminalOpenTime: [String: Date] {
        get { terminalStore.workspaceTerminalOpenTime }
        set { terminalStore.workspaceTerminalOpenTime = newValue }
    }
    var pendingSpawnTabs: Set<UUID> {
        get { terminalStore.pendingSpawnTabs }
        set { terminalStore.pendingSpawnTabs = newValue }
    }
    var onTerminalKill: ((String, String) -> Void)? {
        get { terminalStore.onTerminalKill }
        set { terminalStore.onTerminalKill = newValue }
    }
    var onTerminalSpawn: ((String, String, String) -> Void)? {
        get { terminalStore.onTerminalSpawn }
        set { terminalStore.onTerminalSpawn = newValue }
    }
    var onTerminalAttach: ((String, String) -> Void)? {
        get { terminalStore.onTerminalAttach }
        set { terminalStore.onTerminalAttach = newValue }
    }

    // Callback for Core ready with port (set by CenterContentView to update WebBridge)
    var onCoreReadyWithPort: ((Int) -> Void)?
    // Callback for JS WebSocket reconnect (通知 JS 层重连 WebSocket)
    var onReconnectJS: (() -> Void)?

    // 系统唤醒通知观察者
    var wakeObserver: NSObjectProtocol?
    // 自动重连状态
    var reconnectAttempt = 0

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

        // 转发 terminalStore 变更到 AppState，保持向后兼容
        terminalStoreCancellable = terminalStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // 转发 editorStore 变更到 AppState，保持向后兼容
        editorStoreCancellable = editorStore.objectWillChange
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
