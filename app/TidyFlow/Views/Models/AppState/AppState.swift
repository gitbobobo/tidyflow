import Foundation
import Combine

// MARK: - v1.24: 剪贴板模型

class AppState: ObservableObject {
    @Published var selectedWorkspaceKey: String?
    @Published var activeRightTool: RightTool? = .explorer
    @Published var connectionState: ConnectionState = .disconnected
    /// 最近一次生成的移动端配对码（6 位）
    @Published var mobilePairCode: String?
    /// 配对码过期时间文案（ISO8601 原文）
    @Published var mobilePairCodeExpiresAt: String?
    /// 配对码生成错误文案
    @Published var mobilePairCodeError: String?
    /// 正在请求配对码
    @Published var mobilePairCodeLoading: Bool = false

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

    // 远程终端追踪
    @Published var remoteTerminals: [RemoteTerminalInfo] = []

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
    private var coreProcessManagerCancellable: AnyCancellable?

    // 项目命令诊断快照（key: projectName:workspaceName）
    @Published var workspaceDiagnostics: [String: WorkspaceDiagnosticsSnapshot] = [:]
    // LSP 运行状态快照（key: projectName:workspaceName）
    @Published var workspaceLspStatus: [String: WorkspaceLspStatusSnapshot] = [:]
    // LSP 诊断加载状态（key: projectName:workspaceName）
    @Published var workspaceLspLoading: [String: Bool] = [:]

    // 项目命令执行跟踪（用于基于 task_id 路由 started/output/completed）
    var projectCommandExecutions: [UUID: ProjectCommandExecutionState] = [:]
    var pendingProjectCommandExecutionIdsByKey: [String: [UUID]] = [:]
    var projectCommandExecutionIdByRemoteTaskId: [String: UUID] = [:]

    // AI 任务 continuation（key: "project:workspace"）
    var aiCommitContinuations: [String: (AICommitResult) -> Void] = [:]
    var aiMergeContinuations: [String: (AIMergeResult) -> Void] = [:]

    // AI Chat 状态（结构化 message/part 流）
    @Published var aiCurrentSessionId: String?
    @Published var aiChatMessages: [AIChatMessage] = []
    @Published var aiIsStreaming: Bool = false
    @Published var aiSessions: [AISessionInfo] = []

    // AI Provider / Model / Agent 状态
    @Published var aiProviders: [AIProviderInfo] = []
    @Published var aiSelectedModel: AIModelSelection?
    @Published var aiAgents: [AIAgentInfo] = []
    @Published var aiSelectedAgent: String?
    @Published var aiSlashCommands: [AISlashCommandInfo] = []

    // AI Chat 索引（用于按 messageId/partId 稳定更新，不依赖数组顺序）
    var aiMessageIndexByMessageId: [String: Int] = [:]
    var aiPartIndexByPartId: [String: (msgIdx: Int, partIdx: Int)] = [:]

    // AI Chat 工作空间快照缓存（key: "projectName/workspaceName"）
    var aiChatSnapshotCache: [String: AIChatSnapshot] = [:]

    // 远程项目命令任务跟踪（key: remoteTaskId）
    var remoteProjectCommandTasks: [String: BackgroundTask] = [:]

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
    /// Core 启动就绪后的窗口展示回调（由 App 注入）
    var onCoreReadyForWindow: (() -> Void)?

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

        // 转发 coreProcessManager 变更到 AppState，驱动依赖计算属性（如移动端端口文案）实时刷新
        coreProcessManagerCancellable = coreProcessManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // Start Core process first (WS will connect when Core is ready)
        startCoreIfNeeded()
    }

    /// 根据 agent 的默认模型自动设置 aiSelectedModel
    func applyAgentDefaultModel(_ agent: AIAgentInfo?) {
        guard let agent,
              let providerID = agent.defaultProviderID,
              let modelID = agent.defaultModelID,
              !providerID.isEmpty, !modelID.isEmpty else { return }
        aiSelectedModel = AIModelSelection(providerID: providerID, modelID: modelID)
    }

}
