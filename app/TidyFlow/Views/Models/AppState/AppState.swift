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
    /// 工作空间级主内容页面（聊天/自主进化），不占用 Tab 栏
    @Published var workspaceSpecialPageByWorkspace: [String: WorkspaceSpecialPage] = [:]

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
    /// 最近一次收到的 WS v6 包络序号（用于调试）
    @Published var wsLastEnvelopeSeq: UInt64 = 0
    /// 最近一次收到的 WS v6 包络摘要（domain/action/kind）
    @Published var wsLastEnvelopeSummary: String = ""

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
    private var evolutionReplayStoreCancellable: AnyCancellable?
    private var subAgentViewerStoreCancellable: AnyCancellable?
    // WS 领域 handler 强引用（WSClient 侧为 weak）
    var wsGitMessageHandler: GitMessageHandler?
    var wsProjectMessageHandler: ProjectMessageHandler?
    var wsFileMessageHandler: FileMessageHandler?
    var wsSettingsMessageHandler: SettingsMessageHandler?
    var wsTerminalMessageHandler: TerminalMessageHandler?
    var wsLspMessageHandler: LspMessageHandler?
    var wsAIMessageHandler: AIMessageHandler?
    var wsEvolutionMessageHandler: EvolutionMessageHandler?
    var wsErrorMessageHandler: ErrorMessageHandler?

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

    // AI Chat 状态（按 ai_tool 分桶，当前工具上下文映射到这些兼容字段）
    @Published var aiChatStore: AIChatStore = AIChatStore()
    @Published var aiChatTool: AIChatTool = .opencode {
        didSet {
            guard oldValue != aiChatTool else { return }
            switchAIContext(to: aiChatTool)
        }
    }
    @Published var aiSessions: [AISessionInfo] = [] {
        didSet {
            aiSessionsByTool[aiChatTool] = aiSessions
            refreshMergedAISessions()
        }
    }
    @Published var aiMergedSessions: [AISessionInfo] = []

    // AI Provider / Model / Agent 状态（当前工具上下文）
    @Published var aiProviders: [AIProviderInfo] = [] {
        didSet { aiProvidersByTool[aiChatTool] = aiProviders }
    }
    @Published var aiSelectedModel: AIModelSelection? {
        didSet { aiSelectedModelByTool[aiChatTool] = aiSelectedModel }
    }
    @Published var aiAgents: [AIAgentInfo] = [] {
        didSet { aiAgentsByTool[aiChatTool] = aiAgents }
    }
    @Published var aiSelectedAgent: String? {
        didSet { aiSelectedAgentByTool[aiChatTool] = aiSelectedAgent }
    }
    @Published var aiSlashCommands: [AISlashCommandInfo] = [] {
        didSet { aiSlashCommandsByTool[aiChatTool] = aiSlashCommands }
    }
    @Published var isAILoadingModels: Bool = false
    @Published var isAILoadingAgents: Bool = false
    @Published var aiToolBadges: [AIChatTool: AIToolBadgeState] = [:]
    /// AI 会话状态缓存（按工具分桶；key: "projectName::workspaceName::sessionId"）
    @Published var aiSessionStatusesByTool: [AIChatTool: [String: AISessionStatusSnapshot]] = [:]
    // Evolution 状态
    @Published var evolutionScheduler: EvolutionSchedulerInfoV2 = .empty
    @Published var evolutionWorkspaceItems: [EvolutionWorkspaceItemV2] = []
    @Published var evolutionStageProfilesByWorkspace: [String: [EvolutionStageProfileInfoV2]] = [:]
    @Published var evolutionReplayTitle: String = ""
    @Published var evolutionReplayMessages: [AIChatMessage] = []
    @Published var evolutionReplayLoading: Bool = false
    @Published var evolutionReplayError: String?
    @Published var evolutionReplayStore: AIChatStore = AIChatStore()
    @Published var subAgentViewerTitle: String = ""
    @Published var subAgentViewerMessages: [AIChatMessage] = []
    @Published var subAgentViewerLoading: Bool = false
    @Published var subAgentViewerError: String?
    @Published var subAgentViewerStore: AIChatStore = AIChatStore()

    private var aiChatStoresByTool: [AIChatTool: AIChatStore] = [:]
    private var aiSessionsByTool: [AIChatTool: [AISessionInfo]] = [:]
    private var aiProvidersByTool: [AIChatTool: [AIProviderInfo]] = [:]
    private var aiSelectedModelByTool: [AIChatTool: AIModelSelection?] = [:]
    private var aiAgentsByTool: [AIChatTool: [AIAgentInfo]] = [:]
    private var aiSelectedAgentByTool: [AIChatTool: String?] = [:]
    private var aiSlashCommandsByTool: [AIChatTool: [AISlashCommandInfo]] = [:]
    /// 历史会话自动恢复输入框选择的待应用提示（key: sessionId）
    private var aiPendingSessionSelectionHintsByTool: [AIChatTool: [String: AISessionSelectionHint]] = [:]
    /// Evolution 阶段聊天回放请求
    var evolutionReplayRequest: (
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String,
        cycleId: String,
        stage: String
    )?
    /// 子代理会话查看请求（主会话中 task 工具跳转的子会话）。
    var subAgentViewerRequest: (
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    )?
    /// Evolution：按工作空间追踪 provider/agent 列表是否都已返回（用于串联 profile 请求时序）。
    var evolutionSelectorLoadStateByWorkspace: [String: [AIChatTool: (providerLoaded: Bool, agentLoaded: Bool)]] = [:]
    /// Evolution：等待在选择器资源就绪后发起 profile 请求的工作空间 key 集合。
    var evolutionPendingProfileReloadWorkspaces: Set<String> = []
    /// Evolution：profile 请求兜底定时器，防止某个列表事件丢失导致一直不拉配置。
    var evolutionProfileReloadFallbackTimers: [String: DispatchWorkItem] = [:]

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
    var editorDocumentsByWorkspace: [String: [String: EditorDocumentState]] {
        get { editorStore.editorDocumentsByWorkspace }
        set { editorStore.editorDocumentsByWorkspace = newValue }
    }
    var pendingFileReadRequests: Set<EditorRequestKey> {
        get { editorStore.pendingFileReadRequests }
        set { editorStore.pendingFileReadRequests = newValue }
    }
    var pendingFileWriteRequests: Set<EditorRequestKey> {
        get { editorStore.pendingFileWriteRequests }
        set { editorStore.pendingFileWriteRequests = newValue }
    }
    var lastDiffNavigationContext: DiffNavigationContext? {
        get { editorStore.lastDiffNavigationContext }
        set { editorStore.lastDiffNavigationContext = newValue }
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
        self.configureAIToolBuckets()
        self.switchAIContext(to: aiChatTool)

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

        // 转发阶段聊天回放 store 的消息，兼容旧的数组状态读取路径。
        evolutionReplayStoreCancellable = evolutionReplayStore.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                self?.evolutionReplayMessages = messages
            }
        subAgentViewerStoreCancellable = subAgentViewerStore.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                self?.subAgentViewerMessages = messages
            }

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

    private func configureAIToolBuckets() {
        for tool in AIChatTool.allCases {
            aiChatStoresByTool[tool] = AIChatStore()
            aiSessionsByTool[tool] = []
            aiProvidersByTool[tool] = []
            aiSelectedModelByTool[tool] = nil
            aiAgentsByTool[tool] = []
            aiSelectedAgentByTool[tool] = nil
            aiSlashCommandsByTool[tool] = []
            aiPendingSessionSelectionHintsByTool[tool] = [:]
            aiToolBadges[tool] = AIToolBadgeState()
            aiSessionStatusesByTool[tool] = [:]
        }
        refreshMergedAISessions()
    }

    func aiStore(for tool: AIChatTool) -> AIChatStore {
        if let store = aiChatStoresByTool[tool] {
            return store
        }
        let store = AIChatStore()
        aiChatStoresByTool[tool] = store
        return store
    }

    func switchAIContext(to tool: AIChatTool) {
        let store = aiStore(for: tool)
        if aiChatStore !== store {
            aiChatStore = store
        }

        aiSessions = aiSessionsByTool[tool] ?? []
        aiProviders = aiProvidersByTool[tool] ?? []
        aiSelectedModel = aiSelectedModelByTool[tool] ?? nil
        aiAgents = aiAgentsByTool[tool] ?? []
        aiSelectedAgent = aiSelectedAgentByTool[tool] ?? nil
        aiSlashCommands = aiSlashCommandsByTool[tool] ?? []

        clearUnreadBadge(for: tool)
    }

    func setAISessions(_ sessions: [AISessionInfo], for tool: AIChatTool) {
        aiSessionsByTool[tool] = sessions
        if aiChatTool == tool {
            aiSessions = sessions
        } else {
            refreshMergedAISessions()
        }
    }

    func upsertAISession(_ session: AISessionInfo, for tool: AIChatTool) {
        var sessions = aiSessionsByTool[tool] ?? []
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        setAISessions(sessions, for: tool)
    }

    func removeAISession(_ sessionId: String, for tool: AIChatTool) {
        var sessions = aiSessionsByTool[tool] ?? []
        sessions.removeAll { $0.id == sessionId }
        setAISessions(sessions, for: tool)

        // 同步清理状态缓存（仅按 sessionId 删除可能误删其他工作空间，因此这里做“全表扫描”）。
        let prefix = "::\(sessionId)"
        var dict = aiSessionStatusesByTool[tool] ?? [:]
        dict = dict.filter { !$0.key.hasSuffix(prefix) }
        aiSessionStatusesByTool[tool] = dict
    }

    // MARK: - AI 会话状态

    private func aiSessionStatusKey(projectName: String, workspaceName: String, sessionId: String) -> String {
        "\(projectName)::\(workspaceName)::\(sessionId)"
    }

    func aiSessionStatus(for session: AISessionInfo) -> AISessionStatusSnapshot? {
        aiSessionStatusesByTool[session.aiTool]?[aiSessionStatusKey(projectName: session.projectName, workspaceName: session.workspaceName, sessionId: session.id)]
    }

    func upsertAISessionStatus(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        status: String,
        errorMessage: String?,
        contextRemainingPercent: Double?
    ) {
        let key = aiSessionStatusKey(projectName: projectName, workspaceName: workspaceName, sessionId: sessionId)
        var dict = aiSessionStatusesByTool[aiTool] ?? [:]
        let next = AISessionStatusSnapshot(
            status: status,
            errorMessage: errorMessage,
            contextRemainingPercent: contextRemainingPercent
        )
        if dict[key] == next {
            return
        }
        dict[key] = next
        aiSessionStatusesByTool[aiTool] = dict
    }

    func clearAISessionStatuses() {
        for tool in AIChatTool.allCases {
            aiSessionStatusesByTool[tool] = [:]
        }
    }

    func setAIProviders(_ providers: [AIProviderInfo], for tool: AIChatTool) {
        aiProvidersByTool[tool] = providers
        if aiChatTool == tool {
            aiProviders = providers
        } else {
            objectWillChange.send()
        }
    }

    func setAIAgents(_ agents: [AIAgentInfo], for tool: AIChatTool) {
        aiAgentsByTool[tool] = agents
        if aiChatTool == tool {
            aiAgents = agents
        } else {
            objectWillChange.send()
        }
    }

    func setAISelectedAgent(_ name: String?, for tool: AIChatTool) {
        aiSelectedAgentByTool[tool] = name
        if aiChatTool == tool {
            aiSelectedAgent = name
        }
    }

    func selectedAgent(for tool: AIChatTool) -> String? {
        aiSelectedAgentByTool[tool] ?? nil
    }

    func aiProviders(for tool: AIChatTool) -> [AIProviderInfo] {
        aiProvidersByTool[tool] ?? []
    }

    func aiAgents(for tool: AIChatTool) -> [AIAgentInfo] {
        aiAgentsByTool[tool] ?? []
    }

    func setAISelectedModel(_ model: AIModelSelection?, for tool: AIChatTool) {
        aiSelectedModelByTool[tool] = model
        if aiChatTool == tool {
            aiSelectedModel = model
        }
    }

    /// 尝试应用历史会话的输入选择提示；若模型/代理列表尚未准备好则缓存待重试。
    func applyAISessionSelectionHint(
        _ hint: AISessionSelectionHint?,
        sessionId: String,
        for tool: AIChatTool
    ) {
        let trimmedSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else { return }

        guard let hint, !hint.isEmpty else {
            aiPendingSessionSelectionHintsByTool[tool]?[trimmedSession] = nil
            TFLog.app.debug(
                "AI selection_hint skipped: empty hint, ai_tool=\(tool.rawValue, privacy: .public), session_id=\(trimmedSession, privacy: .public)"
            )
            return
        }

        guard aiStore(for: tool).currentSessionId == trimmedSession else {
            // 只对当前会话生效，防止跨会话串台。
            aiPendingSessionSelectionHintsByTool[tool]?[trimmedSession] = nil
            let currentSession = self.aiStore(for: tool).currentSessionId ?? ""
            TFLog.app.debug(
                "AI selection_hint skipped: session mismatch, ai_tool=\(tool.rawValue, privacy: .public), event_session_id=\(trimmedSession, privacy: .public), current_session_id=\(currentSession, privacy: .public)"
            )
            return
        }

        let unresolved = applyAISessionSelectionHintResolved(hint, for: tool)
        if let unresolved, !unresolved.isEmpty {
            aiPendingSessionSelectionHintsByTool[tool]?[trimmedSession] = unresolved
            TFLog.app.info(
                "AI selection_hint pending: ai_tool=\(tool.rawValue, privacy: .public), session_id=\(trimmedSession, privacy: .public), unresolved_agent=\(unresolved.agent ?? "", privacy: .public), unresolved_provider=\(unresolved.modelProviderID ?? "", privacy: .public), unresolved_model=\(unresolved.modelID ?? "", privacy: .public)"
            )
        } else {
            aiPendingSessionSelectionHintsByTool[tool]?[trimmedSession] = nil
            TFLog.app.info(
                "AI selection_hint applied: ai_tool=\(tool.rawValue, privacy: .public), session_id=\(trimmedSession, privacy: .public), agent=\(hint.agent ?? "", privacy: .public), provider=\(hint.modelProviderID ?? "", privacy: .public), model=\(hint.modelID ?? "", privacy: .public)"
            )
        }
    }

    /// 在 provider/agent 列表刷新后重试待应用的会话选择提示。
    func retryPendingAISessionSelectionHint(for tool: AIChatTool) {
        guard var pending = aiPendingSessionSelectionHintsByTool[tool], !pending.isEmpty else { return }
        let currentSessionId = aiStore(for: tool).currentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentSessionId, !currentSessionId.isEmpty else {
            aiPendingSessionSelectionHintsByTool[tool] = [:]
            return
        }

        for (sessionId, hint) in pending {
            if sessionId != currentSessionId {
                pending[sessionId] = nil
                continue
            }
            let unresolved = applyAISessionSelectionHintResolved(hint, for: tool)
            if let unresolved, !unresolved.isEmpty {
                pending[sessionId] = unresolved
                TFLog.app.debug(
                    "AI selection_hint retry pending: ai_tool=\(tool.rawValue, privacy: .public), session_id=\(sessionId, privacy: .public), unresolved_agent=\(unresolved.agent ?? "", privacy: .public), unresolved_provider=\(unresolved.modelProviderID ?? "", privacy: .public), unresolved_model=\(unresolved.modelID ?? "", privacy: .public)"
                )
            } else {
                pending[sessionId] = nil
                TFLog.app.info(
                    "AI selection_hint retry applied: ai_tool=\(tool.rawValue, privacy: .public), session_id=\(sessionId, privacy: .public)"
                )
            }
        }
        aiPendingSessionSelectionHintsByTool[tool] = pending
    }

    func setAISlashCommands(_ commands: [AISlashCommandInfo], for tool: AIChatTool) {
        aiSlashCommandsByTool[tool] = commands
        if aiChatTool == tool {
            aiSlashCommands = commands
        }
    }

    func setBadgeRunning(_ running: Bool, for tool: AIChatTool) {
        var badge = aiToolBadges[tool] ?? AIToolBadgeState()
        guard badge.hasRunning != running else { return }
        badge.hasRunning = running
        aiToolBadges[tool] = badge
    }

    func markUnreadBadge(for tool: AIChatTool) {
        guard tool != aiChatTool else { return }
        var badge = aiToolBadges[tool] ?? AIToolBadgeState()
        guard !badge.hasUnread else { return }
        badge.hasUnread = true
        aiToolBadges[tool] = badge
    }

    func clearUnreadBadge(for tool: AIChatTool) {
        var badge = aiToolBadges[tool] ?? AIToolBadgeState()
        guard badge.hasUnread else { return }
        badge.hasUnread = false
        aiToolBadges[tool] = badge
    }

    func shouldShowAIBadge(for tool: AIChatTool) -> Bool {
        (aiToolBadges[tool] ?? AIToolBadgeState()).showDot
    }

    /// 根据 agent 的默认模型自动设置 aiSelectedModel
    func applyAgentDefaultModel(_ agent: AIAgentInfo?, for tool: AIChatTool) {
        guard let agent,
              let providerID = agent.defaultProviderID,
              let modelID = agent.defaultModelID,
              !providerID.isEmpty, !modelID.isEmpty else { return }
        setAISelectedModel(AIModelSelection(providerID: providerID, modelID: modelID), for: tool)
    }

    /// 兼容旧调用：默认作用于当前工具
    func applyAgentDefaultModel(_ agent: AIAgentInfo?) {
        applyAgentDefaultModel(agent, for: aiChatTool)
    }

    private func applyAISessionSelectionHintResolved(
        _ hint: AISessionSelectionHint,
        for tool: AIChatTool
    ) -> AISessionSelectionHint? {
        var unresolvedAgent = hint.agent
        var unresolvedProvider = hint.modelProviderID
        var unresolvedModel = hint.modelID

        if let rawAgent = hint.agent, let resolvedAgent = resolveAIAgentName(rawAgent, for: tool) {
            setAISelectedAgent(resolvedAgent, for: tool)
            unresolvedAgent = nil
        }

        if let rawModel = hint.modelID {
            if let resolvedModel = resolveAIModelSelection(
                modelID: rawModel,
                providerHint: hint.modelProviderID,
                for: tool
            ) {
                setAISelectedModel(resolvedModel, for: tool)
                unresolvedProvider = nil
                unresolvedModel = nil
            }
        }

        let unresolved = AISessionSelectionHint(
            agent: unresolvedAgent,
            modelProviderID: unresolvedProvider,
            modelID: unresolvedModel
        )
        return unresolved.isEmpty ? nil : unresolved
    }

    private func resolveAIAgentName(_ raw: String, for tool: AIChatTool) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let agents = aiAgentsByTool[tool] ?? []
        if let exact = agents.first(where: { $0.name == trimmed }) {
            return exact.name
        }
        if let caseInsensitive = agents.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return caseInsensitive.name
        }
        return nil
    }

    private func resolveAIModelSelection(
        modelID rawModelID: String,
        providerHint rawProviderHint: String?,
        for tool: AIChatTool
    ) -> AIModelSelection? {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return nil }
        let providers = aiProvidersByTool[tool] ?? []
        guard !providers.isEmpty else { return nil }

        let providerHint = rawProviderHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let providerHint, !providerHint.isEmpty {
            let matchedProvider = providers.first {
                $0.id == providerHint || $0.id.caseInsensitiveCompare(providerHint) == .orderedSame
            }
            guard let provider = matchedProvider else { return nil }
            if let model = provider.models.first(where: {
                $0.id == modelID || $0.id.caseInsensitiveCompare(modelID) == .orderedSame
            }) {
                return AIModelSelection(providerID: provider.id, modelID: model.id)
            }
            return nil
        }

        var matches: [AIModelSelection] = []
        for provider in providers {
            for model in provider.models where model.id == modelID || model.id.caseInsensitiveCompare(modelID) == .orderedSame {
                matches.append(AIModelSelection(providerID: provider.id, modelID: model.id))
            }
        }
        if matches.count == 1 {
            return matches[0]
        }
        return nil
    }

    private func refreshMergedAISessions() {
        aiMergedSessions = AIChatTool.allCases
            .flatMap { aiSessionsByTool[$0] ?? [] }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

}
