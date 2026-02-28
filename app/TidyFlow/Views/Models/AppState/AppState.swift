import Foundation
import Combine

// MARK: - v1.24: 剪贴板模型

struct EvidenceReadRequestState {
    struct PagePayload {
        let mimeType: String
        let content: [UInt8]
        let offset: UInt64
        let nextOffset: UInt64
        let totalSizeBytes: UInt64
        let eof: Bool
    }

    let project: String
    let workspace: String
    let itemID: String
    let limit: UInt32?
    let autoContinue: Bool
    var expectedOffset: UInt64
    var totalSizeBytes: UInt64?
    var mimeType: String
    var content: [UInt8]
    let fullCompletion: (_ payload: (mimeType: String, content: [UInt8])?, _ errorMessage: String?) -> Void
    let pageCompletion: (_ payload: PagePayload?, _ errorMessage: String?) -> Void
}

enum StartupPhase: Equatable {
    case loading
    case ready
    case failed(message: String)
}

class AppState: ObservableObject {
    private static let perfTerminalAutoDetachEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["PERF_TERMINAL_AUTO_DETACH"]?.lowercased() {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }()
    private static let perfAISelectionDebugLogEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["PERF_AI_SELECTION_DEBUG_LOG"]?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }()

    @Published var selectedWorkspaceKey: String?
    @Published var activeRightTool: RightTool? = .explorer
    @Published var connectionState: ConnectionState = .disconnected
    /// mac 启动门禁：首次 WS 连通前仅展示启动页
    @Published var startupPhase: StartupPhase = .loading
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

    // 编辑器领域状态（独立 ObservableObject，减少编辑器状态变化对全局视图的影响）
    let editorStore = EditorStore()

    // 后台任务管理器
    let taskManager = BackgroundTaskManager()
    private var coreProcessManagerCancellable: AnyCancellable?
    private var evolutionReplayStoreCancellable: AnyCancellable?
    private var subAgentViewerStoreCancellable: AnyCancellable?
    // WS 领域 handler 强引用（WSClient 侧为 weak）
    var wsGitMessageHandler: GitMessageHandler?
    var wsProjectMessageHandler: ProjectMessageHandler?
    var wsFileMessageHandler: FileMessageHandler?
    var wsSettingsMessageHandler: SettingsMessageHandler?
    var wsTerminalMessageHandler: TerminalMessageHandler?
    var wsAIMessageHandler: AIMessageHandler?
    var wsEvidenceMessageHandler: EvidenceMessageHandler?
    var wsEvolutionMessageHandler: EvolutionMessageHandler?
    var wsErrorMessageHandler: ErrorMessageHandler?

    // 项目命令诊断快照（key: projectName:workspaceName）
    @Published var workspaceDiagnostics: [String: WorkspaceDiagnosticsSnapshot] = [:]

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
        }
    }

    /// 右侧面板会话列表当前筛选的 AI 工具
    @Published var sessionPanelFilterTool: AIChatTool = .opencode
    /// 正在加载会话列表的 AI 工具集合
    @Published var aiSessionListLoadingTools: Set<AIChatTool> = []

    /// 右侧面板会话操作（由 SessionsPanelView 发起，AITabView 响应）
    enum SessionPanelAction: Equatable {
        case loadSession(AISessionInfo)
        case deleteSession(AISessionInfo)
        case createNewSession
    }
    @Published var sessionPanelAction: SessionPanelAction?

    /// 获取指定工具的会话列表
    func aiSessionsForTool(_ tool: AIChatTool) -> [AISessionInfo] {
        aiSessionsByTool[tool] ?? []
    }

    // AI Provider / Model / Agent 状态（当前工具上下文）
    @Published var aiProviders: [AIProviderInfo] = [] {
        didSet { aiProvidersByTool[aiChatTool] = aiProviders }
    }
    @Published var aiSelectedModel: AIModelSelection? {
        didSet {
            aiSelectedModelByTool[aiChatTool] = aiSelectedModel
            syncModelConfigOptionForCurrentTool()
        }
    }
    @Published var aiAgents: [AIAgentInfo] = [] {
        didSet { aiAgentsByTool[aiChatTool] = aiAgents }
    }
    @Published var aiSelectedAgent: String? {
        didSet {
            aiSelectedAgentByTool[aiChatTool] = aiSelectedAgent
            syncModeConfigOptionForCurrentTool()
        }
    }
    @Published var aiSlashCommands: [AISlashCommandInfo] = []
    @Published var aiSessionConfigOptions: [AIProtocolSessionConfigOptionInfo] = [] {
        didSet { aiSessionConfigOptionsByTool[aiChatTool] = aiSessionConfigOptions }
    }
    @Published var aiSelectedThoughtLevel: String? {
        didSet {
            aiSelectedThoughtLevelByTool[aiChatTool] = aiSelectedThoughtLevel
            syncThoughtLevelConfigOptionForCurrentTool()
        }
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
    /// Evolution 全局默认阶段配置（替代 per-workspace 配置，由设置页面管理）
    @Published var evolutionDefaultProfiles: [EvolutionEditableProfile] = []
    @Published var evolutionReplayTitle: String = ""
    @Published var evolutionReplayMessages: [AIChatMessage] = []
    @Published var evolutionReplayLoading: Bool = false
    @Published var evolutionReplayError: String?
    @Published var evolutionReplayStore: AIChatStore = AIChatStore()
    @Published var evolutionBlockingRequired: EvolutionBlockingRequiredV2?
    @Published var evolutionBlockers: [EvolutionBlockerItemV2] = []
    @Published var evolutionHandoffContent: String?
    @Published var evolutionHandoffLoading: Bool = false
    @Published var evolutionHandoffError: String?
    var pendingHandoffReadPath: String?
    @Published var evidenceSnapshotsByWorkspace: [String: EvidenceSnapshotV2] = [:]
    @Published var evidenceLoadingByWorkspace: [String: Bool] = [:]
    @Published var evidenceErrorByWorkspace: [String: String] = [:]
    @Published var aiChatOneShotHintByWorkspace: [String: String] = [:]
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
    private var aiSlashCommandsBySessionByTool: [AIChatTool: [String: [AISlashCommandInfo]]] = [:]
    private var aiSessionConfigOptionsByTool: [AIChatTool: [AIProtocolSessionConfigOptionInfo]] = [:]
    /// 当前工具已选择的配置项值（option_id -> value），用于 send 时透传 config_overrides。
    private var aiSelectedConfigOptionsByTool: [AIChatTool: [String: Any]] = [:]
    private var aiSelectedThoughtLevelByTool: [AIChatTool: String?] = [:]
    enum AISelectorResourceKind {
        case providerList
        case agentList
    }
    /// 历史会话自动恢复输入框选择的待应用提示（key: sessionId）
    private var aiPendingSessionSelectionHintsByTool: [AIChatTool: [String: AISessionSelectionHint]] = [:]
    /// 设置页在“未选中工作空间”场景触发 AI 列表请求时，按工具记录请求上下文。
    var aiSelectorBootstrapContextByTool: [AIChatTool: (
        project: String,
        workspace: String,
        providerPending: Bool,
        agentPending: Bool
    )] = [:]
    /// 待 ack 的 AI 会话订阅上下文（key: AIChatTool）
    /// subscribe 发出后暂存，ack 收到时消费：addSubscription + 拉消息 + unsubscribe 旧会话
    var pendingSubscribeContextByTool: [AIChatTool: AIPendingSubscribeContext] = [:]
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
    /// Evolution：记录某工作空间等待重试的动作（start/resume）。
    var evolutionPendingActionByWorkspace: [String: String] = [:]
    /// Evidence：等待中的重建提示词请求（按 workspace key 聚合）
    var evidencePromptCompletionByWorkspace: [String: (_ prompt: EvidenceRebuildPromptV2?, _ errorMessage: String?) -> Void] = [:]
    /// Evidence：分块读取上下文（按 workspace key，仅串行读取）
    var evidenceReadRequestByWorkspace: [String: EvidenceReadRequestState] = [:]

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
    /// SessionId → Tab 映射，避免终端输出路径每次线性扫描全部 Tab。
    var terminalTabIdBySessionId: [String: UUID] = [:]
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
    #if os(macOS)
    weak var terminalSink: MacTerminalOutputSink?
    var terminalSinkTabId: UUID?
    #endif
    var pendingTerminalOutput: [[UInt8]] = []
    let pendingOutputChunkLimit = 128
    var termOutputUnackedBytesByTermId: [String: Int] = [:]
    let termOutputAckThreshold = 50 * 1024
    var terminalAttachRequestedAtByTermId: [String: Date] = [:]
    var terminalDetachRequestedAtByTermId: [String: Date] = [:]

    // 系统唤醒通知观察者
    var wakeObserver: NSObjectProtocol?
    // 自动重连状态
    var reconnectAttempt = 0
    // 重连后延迟拉取非当前 AI 工具会话列表的任务（用于削峰）
    var deferredAISessionReloadWorkItem: DispatchWorkItem?

    // WebSocket Client
    let wsClient = WSClient()

    // Core Process Manager
    let coreProcessManager = CoreProcessManager()

    // Project name (for WS protocol)
    var selectedProjectName: String = "default"
    /// 首次进入 ready 后锁定，不再回退到启动页
    private var hasFinishedStartupPhase = false

    var commands: [Command] = []

    init() {
        // Start with empty projects list
        self.projects = []
        self.selectedProjectId = nil
        self.selectedWorkspaceKey = nil
        self.configureAIToolBuckets()
        self.switchAIContext(to: aiChatTool)

        setupCommands()

        // 从 UserDefaults 加载 Evolution 全局默认配置
        loadEvolutionDefaultProfiles()

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

    var isPerfTerminalAutoDetachEnabled: Bool {
        Self.perfTerminalAutoDetachEnabled
    }

    func markStartupReadyIfNeeded() {
        guard !hasFinishedStartupPhase else { return }
        hasFinishedStartupPhase = true
        startupPhase = .ready
    }

    func markStartupFailedIfNeeded(message: String) {
        guard !hasFinishedStartupPhase else { return }
        startupPhase = .failed(message: message)
    }

    func retryStartup() {
        guard !hasFinishedStartupPhase else { return }
        startupPhase = .loading
        restartCore()
    }

    var isPerfAISelectionDebugLogEnabled: Bool {
        Self.perfAISelectionDebugLogEnabled
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
            aiSlashCommandsBySessionByTool[tool] = [:]
            aiSessionConfigOptionsByTool[tool] = []
            aiSelectedConfigOptionsByTool[tool] = [:]
            aiSelectedThoughtLevelByTool[tool] = nil
            aiPendingSessionSelectionHintsByTool[tool] = [:]
            aiToolBadges[tool] = AIToolBadgeState()
            aiSessionStatusesByTool[tool] = [:]
        }
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
        aiSlashCommands = slashCommandsForContext(
            tool: tool,
            sessionId: aiStore(for: tool).currentSessionId
        )
        aiSessionConfigOptions = aiSessionConfigOptionsByTool[tool] ?? []
        aiSelectedThoughtLevel = aiSelectedThoughtLevelByTool[tool] ?? nil

        clearUnreadBadge(for: tool)
    }

    func setAISessions(_ sessions: [AISessionInfo], for tool: AIChatTool) {
        let sortedSessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
        aiSessionsByTool[tool] = sortedSessions
        aiSessionListLoadingTools.remove(tool)
        if aiChatTool == tool {
            aiSessions = sortedSessions
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

        let normalizedStatus = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedErrorMessage: String? = {
            let trimmed = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }()

        if let existing = dict[key],
           existing.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "busy",
           normalizedStatus == "busy",
           existing.errorMessage == normalizedErrorMessage {
            return
        }

        let next = AISessionStatusSnapshot(
            status: normalizedStatus.isEmpty ? status : normalizedStatus,
            errorMessage: normalizedErrorMessage,
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

    /// 选择一个可用于拉取 AI 选择器资源（agent/model）的上下文。
    /// 优先使用当前选中的项目/工作空间；若未选中，则回退到第一个可用工作空间。
    func preferredAISelectorContext() -> (project: String, workspace: String)? {
        let selectedProject = selectedProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedWorkspace = selectedWorkspaceKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedWorkspace.isEmpty,
           !selectedProject.isEmpty {
            return (selectedProject, selectedWorkspace)
        }

        for project in projects {
            let projectName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectName.isEmpty else { continue }
            let preferredWorkspace = project.workspaces.first(where: { $0.isDefault }) ?? project.workspaces.first
            guard let preferredWorkspace else { continue }
            let workspace = preferredWorkspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workspace.isEmpty else { continue }
            return (projectName, workspace)
        }

        return nil
    }

    /// 供设置页调用：批量拉取所有 AI 工具的模型/模式列表。
    @discardableResult
    func requestAISelectorResourcesForSettings() -> Bool {
        guard connectionState == .connected else { return false }
        guard let context = preferredAISelectorContext() else { return false }

        for tool in AIChatTool.allCases {
            aiSelectorBootstrapContextByTool[tool] = (
                project: context.project,
                workspace: context.workspace,
                providerPending: true,
                agentPending: true
            )
            wsClient.requestAIProviderList(
                projectName: context.project,
                workspaceName: context.workspace,
                aiTool: tool
            )
            wsClient.requestAIAgentList(
                projectName: context.project,
                workspaceName: context.workspace,
                aiTool: tool
            )
            wsClient.requestAISessionConfigOptions(
                projectName: context.project,
                workspaceName: context.workspace,
                aiTool: tool,
                sessionId: aiStore(for: tool).currentSessionId
            )
        }
        return true
    }

    /// AI provider/agent 列表事件是否应被当前 UI 消费。
    func shouldAcceptAISelectorEvent(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        kind: AISelectorResourceKind
    ) -> Bool {
        if selectedProjectName == projectName, selectedWorkspaceKey == workspaceName {
            return true
        }
        guard let pending = aiSelectorBootstrapContextByTool[aiTool] else { return false }
        guard pending.project == projectName, pending.workspace == workspaceName else { return false }
        switch kind {
        case .providerList:
            return pending.providerPending
        case .agentList:
            return pending.agentPending
        }
    }

    /// 若该事件对应设置页触发的临时请求，则在消费后清理上下文，避免后续串台。
    func consumeAISelectorBootstrapContextIfNeeded(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        kind: AISelectorResourceKind
    ) {
        guard var pending = aiSelectorBootstrapContextByTool[aiTool] else { return }
        guard pending.project == projectName, pending.workspace == workspaceName else { return }

        switch kind {
        case .providerList:
            pending.providerPending = false
        case .agentList:
            pending.agentPending = false
        }

        if pending.providerPending || pending.agentPending {
            aiSelectorBootstrapContextByTool[aiTool] = pending
        } else {
            aiSelectorBootstrapContextByTool[aiTool] = nil
        }
    }

    func clearAISelectorBootstrapContexts() {
        aiSelectorBootstrapContextByTool.removeAll()
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
        if let optionID = optionIDForCategory("mode", in: aiSessionConfigOptions(for: tool)) {
            let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized, !normalized.isEmpty {
                updateConfigOptionValue(optionID: optionID, value: normalized, for: tool)
            } else {
                updateConfigOptionValue(optionID: optionID, value: nil, for: tool)
            }
        }
    }

    func selectedAgent(for tool: AIChatTool) -> String? {
        aiSelectedAgentByTool[tool] ?? nil
    }

    func selectedModel(for tool: AIChatTool) -> AIModelSelection? {
        aiSelectedModelByTool[tool] ?? nil
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
        if let optionID = optionIDForCategory("model", in: aiSessionConfigOptions(for: tool)) {
            if let model {
                updateConfigOptionValue(optionID: optionID, value: modelConfigValue(from: model), for: tool)
            } else {
                updateConfigOptionValue(optionID: optionID, value: nil, for: tool)
            }
        }
    }

    func aiSessionConfigOptions(for tool: AIChatTool) -> [AIProtocolSessionConfigOptionInfo] {
        aiSessionConfigOptionsByTool[tool] ?? []
    }

    func thoughtLevelOptions(for tool: AIChatTool) -> [String] {
        guard let option = aiSessionConfigOptions(for: tool).first(where: {
            normalizedConfigCategory($0.category, optionID: $0.optionID) == "thought_level"
        }) else {
            return []
        }
        var seen: Set<String> = []
        var values: [String] = []
        for choice in option.options {
            if let value = configValueAsString(choice.value), seen.insert(value).inserted {
                values.append(value)
            }
        }
        for group in option.optionGroups {
            for choice in group.options {
                if let value = configValueAsString(choice.value), seen.insert(value).inserted {
                    values.append(value)
                }
            }
        }
        return values
    }

    func setAISessionConfigOptions(_ options: [AIProtocolSessionConfigOptionInfo], for tool: AIChatTool) {
        aiSessionConfigOptionsByTool[tool] = options
        var selected = aiSelectedConfigOptionsByTool[tool] ?? [:]
        var validOptionIDs: Set<String> = []
        for option in options {
            validOptionIDs.insert(option.optionID)
            if let current = option.currentValue {
                selected[option.optionID] = current
            } else if selected[option.optionID] == nil {
                if let first = option.options.first {
                    selected[option.optionID] = first.value
                } else if let firstGroup = option.optionGroups.first,
                          let first = firstGroup.options.first {
                    selected[option.optionID] = first.value
                }
            }
        }
        if let modeOptionID = optionIDForCategory("mode", in: options),
           let selectedAgent = selectedAgent(for: tool)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedAgent.isEmpty {
            selected[modeOptionID] = selectedAgent
        }
        if let modelOptionID = optionIDForCategory("model", in: options),
           let selectedModel = selectedModel(for: tool) {
            selected[modelOptionID] = modelConfigValue(from: selectedModel)
        }
        if let thoughtOptionID = optionIDForCategory("thought_level", in: options),
           let thoughtLevel = selectedThoughtLevel(for: tool)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thoughtLevel.isEmpty {
            selected[thoughtOptionID] = thoughtLevel
        }
        selected = selected.filter { validOptionIDs.contains($0.key) }
        aiSelectedConfigOptionsByTool[tool] = selected
        refreshThoughtLevelFromConfig(for: tool)
        if aiChatTool == tool {
            aiSessionConfigOptions = options
        } else {
            objectWillChange.send()
        }
    }

    func selectedThoughtLevel(for tool: AIChatTool) -> String? {
        aiSelectedThoughtLevelByTool[tool] ?? nil
    }

    func setAISelectedThoughtLevel(
        _ value: String?,
        for tool: AIChatTool,
        syncConfigOption: Bool = true
    ) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalValue = (normalized?.isEmpty == true) ? nil : normalized
        aiSelectedThoughtLevelByTool[tool] = finalValue
        if aiChatTool == tool {
            aiSelectedThoughtLevel = finalValue
        } else {
            objectWillChange.send()
        }
        guard syncConfigOption,
              let optionID = optionIDForCategory("thought_level", in: aiSessionConfigOptions(for: tool)) else {
            return
        }
        if let finalValue {
            updateConfigOptionValue(optionID: optionID, value: finalValue, for: tool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: tool)
        }
    }

    func aiConfigOverrides(for tool: AIChatTool) -> [String: Any]? {
        let options = aiSessionConfigOptions(for: tool)
        guard !options.isEmpty else { return nil }
        var overrides = aiSelectedConfigOptionsByTool[tool] ?? [:]

        if let modeOptionID = optionIDForCategory("mode", in: options),
           let selectedAgent = selectedAgent(for: tool)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedAgent.isEmpty {
            overrides[modeOptionID] = selectedAgent
        }
        if let modelOptionID = optionIDForCategory("model", in: options),
           let selectedModel = selectedModel(for: tool) {
            overrides[modelOptionID] = modelConfigValue(from: selectedModel)
        }
        if let thoughtOptionID = optionIDForCategory("thought_level", in: options),
           let thoughtLevel = selectedThoughtLevel(for: tool)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thoughtLevel.isEmpty {
            overrides[thoughtOptionID] = thoughtLevel
        }
        return overrides.isEmpty ? nil : overrides
    }

    func applyConfigOptionsHint(_ configOptions: [String: Any], for tool: AIChatTool) {
        guard !configOptions.isEmpty else { return }
        var selected = aiSelectedConfigOptionsByTool[tool] ?? [:]
        for (optionID, value) in configOptions {
            selected[optionID] = value
        }
        aiSelectedConfigOptionsByTool[tool] = selected

        // 优先按 category 同步输入栏状态，mode/model 仍保留旧字段回退。
        for option in aiSessionConfigOptions(for: tool) {
            guard let rawValue = selected[option.optionID] else { continue }
            let category = normalizedConfigCategory(option.category, optionID: option.optionID)
            if category == "mode",
               let rawMode = configValueAsString(rawValue),
               let resolvedAgent = resolveAIAgentName(rawMode, for: tool) {
                setAISelectedAgent(resolvedAgent, for: tool)
            } else if category == "model" {
                let providerHint = configValueAsProviderHint(rawValue)
                if let rawModel = configValueAsModelID(rawValue),
                   let resolvedModel = resolveAIModelSelection(
                       modelID: rawModel,
                       providerHint: providerHint,
                       for: tool
                   ) {
                    setAISelectedModel(resolvedModel, for: tool)
                }
            } else if category == "thought_level" {
                setAISelectedThoughtLevel(configValueAsString(rawValue), for: tool, syncConfigOption: false)
            }
        }
        refreshThoughtLevelFromConfig(for: tool)
    }

    private func updateConfigOptionValue(optionID: String, value: Any?, for tool: AIChatTool) {
        var selected = aiSelectedConfigOptionsByTool[tool] ?? [:]
        if let value {
            selected[optionID] = value
        } else {
            selected.removeValue(forKey: optionID)
        }
        aiSelectedConfigOptionsByTool[tool] = selected
    }

    private func refreshThoughtLevelFromConfig(for tool: AIChatTool) {
        let options = aiSessionConfigOptions(for: tool)
        guard let option = options.first(where: {
            normalizedConfigCategory($0.category, optionID: $0.optionID) == "thought_level"
        }) else {
            setAISelectedThoughtLevel(nil, for: tool, syncConfigOption: false)
            return
        }
        let selected = aiSelectedConfigOptionsByTool[tool] ?? [:]
        let value = selected[option.optionID] ?? option.currentValue
        setAISelectedThoughtLevel(configValueAsString(value), for: tool, syncConfigOption: false)
    }

    private func optionIDForCategory(_ category: String, in options: [AIProtocolSessionConfigOptionInfo]) -> String? {
        options.first(where: {
            normalizedConfigCategory($0.category, optionID: $0.optionID) == category
        })?.optionID
    }

    private func normalizedConfigCategory(_ category: String?, optionID: String) -> String {
        let trimmedCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !trimmedCategory.isEmpty {
            return trimmedCategory
        }
        return optionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func modelConfigValue(from model: AIModelSelection) -> String {
        "\(model.providerID)/\(model.modelID)"
    }

    private func configValueAsString(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let dict as [String: Any]:
            if let nested = dict["id"] ?? dict["value"] ?? dict["mode_id"] ?? dict["modeId"] {
                return configValueAsString(nested)
            }
            return nil
        default:
            return nil
        }
    }

    private func configValueAsModelID(_ value: Any?) -> String? {
        if let text = configValueAsString(value) {
            if let slash = text.firstIndex(of: "/") {
                let suffix = String(text[text.index(after: slash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty {
                    return suffix
                }
            }
            return text
        }
        if let dict = value as? [String: Any] {
            return configValueAsString(dict["model_id"] ?? dict["modelId"] ?? dict["id"] ?? dict["value"])
        }
        return nil
    }

    private func configValueAsProviderHint(_ value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            return configValueAsString(dict["provider_id"] ?? dict["providerId"] ?? dict["model_provider_id"] ?? dict["modelProviderId"])
        }
        return nil
    }

    private func syncModeConfigOptionForCurrentTool() {
        guard let optionID = optionIDForCategory("mode", in: aiSessionConfigOptions(for: aiChatTool)) else { return }
        let normalized = aiSelectedAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            updateConfigOptionValue(optionID: optionID, value: normalized, for: aiChatTool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: aiChatTool)
        }
    }

    private func syncModelConfigOptionForCurrentTool() {
        guard let optionID = optionIDForCategory("model", in: aiSessionConfigOptions(for: aiChatTool)) else { return }
        if let model = aiSelectedModel {
            updateConfigOptionValue(optionID: optionID, value: modelConfigValue(from: model), for: aiChatTool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: aiChatTool)
        }
    }

    private func syncThoughtLevelConfigOptionForCurrentTool() {
        guard let optionID = optionIDForCategory("thought_level", in: aiSessionConfigOptions(for: aiChatTool)) else { return }
        let normalized = aiSelectedThoughtLevel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            updateConfigOptionValue(optionID: optionID, value: normalized, for: aiChatTool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: aiChatTool)
        }
    }

    private func aiSelectionHintDict(_ hint: AISessionSelectionHint?) -> [String: Any]? {
        guard let hint, !hint.isEmpty else { return nil }
        var dict: [String: Any] = [:]
        if let agent = hint.agent { dict["agent"] = agent }
        if let provider = hint.modelProviderID { dict["model_provider_id"] = provider }
        if let model = hint.modelID { dict["model_id"] = model }
        if let configOptions = hint.configOptions, !configOptions.isEmpty {
            dict["config_options"] = configOptions
        }
        return dict.isEmpty ? nil : dict
    }

    private func aiSelectionModelDict(_ model: AIModelSelection?) -> [String: Any]? {
        guard let model else { return nil }
        return [
            "provider_id": model.providerID,
            "model_id": model.modelID
        ]
    }

    private func aiSelectionSyncDetailString(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func emitAISelectionSyncLog(
        event: String,
        tool: AIChatTool,
        sessionId: String,
        trigger: String,
        hint: AISessionSelectionHint?,
        beforeAgent: String?,
        beforeModel: AIModelSelection?,
        afterAgent: String?,
        afterModel: AIModelSelection?,
        unresolved: AISessionSelectionHint?,
        extra: [String: Any]
    ) {
        guard isPerfAISelectionDebugLogEnabled else { return }

        var detail: [String: Any] = [
            "event": event,
            "trigger": trigger,
            "tool": tool.rawValue,
            "session_id": sessionId,
            "selected_tool": aiChatTool.rawValue,
            "before_agent": beforeAgent ?? "",
            "after_agent": afterAgent ?? ""
        ]
        if let hint = aiSelectionHintDict(hint) {
            detail["hint"] = hint
        }
        if let beforeModel = aiSelectionModelDict(beforeModel) {
            detail["before_model"] = beforeModel
        }
        if let afterModel = aiSelectionModelDict(afterModel) {
            detail["after_model"] = afterModel
        }
        if let unresolved = aiSelectionHintDict(unresolved) {
            detail["unresolved"] = unresolved
        }
        for (key, value) in extra {
            detail[key] = value
        }

        wsClient.sendLogEntry(
            level: "DEBUG",
            category: "ai_selection_sync",
            msg: "ai selection sync \(event)",
            detail: aiSelectionSyncDetailString(detail)
        )
    }

    /// 尝试应用历史会话的输入选择提示；若模型/代理列表尚未准备好则缓存待重试。
    func applyAISessionSelectionHint(
        _ hint: AISessionSelectionHint?,
        sessionId: String,
        for tool: AIChatTool,
        trigger: String = "unknown"
    ) {
        let trimmedSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else { return }

        let beforeAgent = selectedAgent(for: tool)
        let beforeModel = selectedModel(for: tool)

        guard let hint, !hint.isEmpty else {
            aiPendingSessionSelectionHintsByTool[tool]?[trimmedSession] = nil
            emitAISelectionSyncLog(
                event: "skip_empty_hint",
                tool: tool,
                sessionId: trimmedSession,
                trigger: trigger,
                hint: nil,
                beforeAgent: beforeAgent,
                beforeModel: beforeModel,
                afterAgent: beforeAgent,
                afterModel: beforeModel,
                unresolved: nil,
                extra: [:]
            )
            TFLog.app.debug(
                "AI selection_hint skipped: empty hint, ai_tool=\(tool.rawValue, privacy: .public), session_id=\(trimmedSession, privacy: .public)"
            )
            return
        }

        let store = aiStore(for: tool)
        let currentSessionId = store.currentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrentSession = currentSessionId == trimmedSession
        let isSessionBindingPending =
            (currentSessionId == nil || currentSessionId?.isEmpty == true) &&
            store.subscribedSessionIds.contains(trimmedSession)

        guard isCurrentSession || isSessionBindingPending else {
            // 只对当前会话生效，防止跨会话串台。
            aiPendingSessionSelectionHintsByTool[tool]?[trimmedSession] = nil
            let currentSession = currentSessionId ?? ""
            emitAISelectionSyncLog(
                event: "skip_session_mismatch",
                tool: tool,
                sessionId: trimmedSession,
                trigger: trigger,
                hint: hint,
                beforeAgent: beforeAgent,
                beforeModel: beforeModel,
                afterAgent: beforeAgent,
                afterModel: beforeModel,
                unresolved: nil,
                extra: [
                    "current_session_id": currentSession,
                    "binding_pending": isSessionBindingPending
                ]
            )
            TFLog.app.debug(
                "AI selection_hint skipped: session mismatch, ai_tool=\(tool.rawValue, privacy: .public), event_session_id=\(trimmedSession, privacy: .public), current_session_id=\(currentSession, privacy: .public)"
            )
            return
        }

        let unresolved = applyAISessionSelectionHintResolved(hint, for: tool)
        let afterAgent = selectedAgent(for: tool)
        let afterModel = selectedModel(for: tool)
        if let unresolved, !unresolved.isEmpty {
            aiPendingSessionSelectionHintsByTool[tool]?[trimmedSession] = unresolved
            emitAISelectionSyncLog(
                event: "pending_unresolved",
                tool: tool,
                sessionId: trimmedSession,
                trigger: trigger,
                hint: hint,
                beforeAgent: beforeAgent,
                beforeModel: beforeModel,
                afterAgent: afterAgent,
                afterModel: afterModel,
                unresolved: unresolved,
                extra: [:]
            )
            TFLog.app.info(
                "AI selection_hint pending: ai_tool=\(tool.rawValue, privacy: .public), session_id=\(trimmedSession, privacy: .public), unresolved_agent=\(unresolved.agent ?? "", privacy: .public), unresolved_provider=\(unresolved.modelProviderID ?? "", privacy: .public), unresolved_model=\(unresolved.modelID ?? "", privacy: .public)"
            )
        } else {
            aiPendingSessionSelectionHintsByTool[tool]?[trimmedSession] = nil
            emitAISelectionSyncLog(
                event: "applied",
                tool: tool,
                sessionId: trimmedSession,
                trigger: trigger,
                hint: hint,
                beforeAgent: beforeAgent,
                beforeModel: beforeModel,
                afterAgent: afterAgent,
                afterModel: afterModel,
                unresolved: nil,
                extra: [:]
            )
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

    private func normalizeSlashCommandsSessionID(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func slashCommandsForContext(
        tool: AIChatTool,
        sessionId: String?
    ) -> [AISlashCommandInfo] {
        if let sessionId = normalizeSlashCommandsSessionID(sessionId),
           let bySession = aiSlashCommandsBySessionByTool[tool],
           let sessionCommands = bySession[sessionId] {
            return sessionCommands
        }
        return aiSlashCommandsByTool[tool] ?? []
    }

    func refreshCurrentAISlashCommands(for tool: AIChatTool? = nil) {
        let targetTool = tool ?? aiChatTool
        guard aiChatTool == targetTool else { return }
        aiSlashCommands = slashCommandsForContext(
            tool: targetTool,
            sessionId: aiStore(for: targetTool).currentSessionId
        )
    }

    func setAISlashCommands(
        _ commands: [AISlashCommandInfo],
        for tool: AIChatTool,
        sessionId: String? = nil
    ) {
        if let sessionId = normalizeSlashCommandsSessionID(sessionId) {
            var bySession = aiSlashCommandsBySessionByTool[tool] ?? [:]
            bySession[sessionId] = commands
            aiSlashCommandsBySessionByTool[tool] = bySession
        } else {
            aiSlashCommandsByTool[tool] = commands
        }
        guard aiChatTool == tool else { return }
        let currentSessionId = normalizeSlashCommandsSessionID(aiStore(for: tool).currentSessionId)
        if let eventSessionID = normalizeSlashCommandsSessionID(sessionId) {
            guard eventSessionID == currentSessionId else { return }
            aiSlashCommands = commands
            return
        }
        aiSlashCommands = slashCommandsForContext(tool: tool, sessionId: currentSessionId)
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
        var unresolvedConfigOptions: [String: Any] = [:]
        var resolvedAgentInfo: AIAgentInfo?

        if let configOptions = hint.configOptions, !configOptions.isEmpty {
            applyConfigOptionsHint(configOptions, for: tool)
            let optionsByID = Dictionary(uniqueKeysWithValues: aiSessionConfigOptions(for: tool).map { ($0.optionID, $0) })
            for (optionID, value) in configOptions {
                let category = normalizedConfigCategory(optionsByID[optionID]?.category, optionID: optionID)
                if category == "mode" {
                    if let rawMode = configValueAsString(value),
                       let resolvedAgent = resolveAIAgentName(rawMode, for: tool) {
                        setAISelectedAgent(resolvedAgent, for: tool)
                        resolvedAgentInfo = aiAgents(for: tool).first(where: { $0.name == resolvedAgent })
                        unresolvedAgent = nil
                    } else if let rawMode = configValueAsString(value) {
                        unresolvedAgent = rawMode
                        unresolvedConfigOptions[optionID] = value
                    }
                    continue
                }
                if category == "model" {
                    let providerHint = configValueAsProviderHint(value)
                    if let rawModel = configValueAsModelID(value),
                       let resolvedModel = resolveAIModelSelection(
                           modelID: rawModel,
                           providerHint: providerHint,
                           for: tool
                       ) {
                        setAISelectedModel(resolvedModel, for: tool)
                        unresolvedProvider = nil
                        unresolvedModel = nil
                    } else {
                        if let providerHint {
                            unresolvedProvider = providerHint
                        }
                        if let rawModel = configValueAsModelID(value) {
                            unresolvedModel = rawModel
                        }
                        unresolvedConfigOptions[optionID] = value
                    }
                    continue
                }
                if category == "thought_level" {
                    setAISelectedThoughtLevel(configValueAsString(value), for: tool, syncConfigOption: false)
                }
            }
        }

        if let rawAgent = hint.agent, let resolvedAgent = resolveAIAgentName(rawAgent, for: tool) {
            setAISelectedAgent(resolvedAgent, for: tool)
            resolvedAgentInfo = aiAgents(for: tool).first(where: { $0.name == resolvedAgent })
            unresolvedAgent = nil
        }

        if hint.modelID == nil, let resolvedAgentInfo {
            applyAgentDefaultModel(resolvedAgentInfo, for: tool)
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
            modelID: unresolvedModel,
            configOptions: unresolvedConfigOptions.isEmpty ? nil : unresolvedConfigOptions
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
        let normalizedRaw = normalizeSelectionHintKey(trimmed)
        if let normalizedNameMatched = agents.first(where: {
            normalizeSelectionHintKey($0.name) == normalizedRaw
        }) {
            return normalizedNameMatched.name
        }
        if let modeMatched = agents.first(where: {
            guard let mode = $0.mode, !mode.isEmpty else { return false }
            return mode.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return modeMatched.name
        }
        if let normalizedModeMatched = agents.first(where: {
            guard let mode = $0.mode, !mode.isEmpty else { return false }
            return normalizeSelectionHintKey(mode) == normalizedRaw
        }) {
            return normalizedModeMatched.name
        }
        if let containsMatched = agents.first(where: {
            let nameKey = normalizeSelectionHintKey($0.name)
            if !nameKey.isEmpty,
               (normalizedRaw.contains(nameKey) || nameKey.contains(normalizedRaw)) {
                return true
            }
            guard let mode = $0.mode else { return false }
            let modeKey = normalizeSelectionHintKey(mode)
            return !modeKey.isEmpty &&
                (normalizedRaw.contains(modeKey) || modeKey.contains(normalizedRaw))
        }) {
            return containsMatched.name
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

        if rawProviderHint == nil,
           let slash = modelID.firstIndex(of: "/") {
            let providerCandidate = String(modelID[..<slash]).trimmingCharacters(in: .whitespacesAndNewlines)
            let modelCandidate = String(modelID[modelID.index(after: slash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !providerCandidate.isEmpty,
               !modelCandidate.isEmpty,
               let selection = resolveAIModelSelection(
                   modelID: modelCandidate,
                   providerHint: providerCandidate,
                   for: tool
               ) {
                return selection
            }
        }

        let providerHint = rawProviderHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelID = self.normalizeSelectionHintKey(modelID)
        let modelMatches: (AIModelInfo) -> Bool = { model in
            if model.id == modelID || model.id.caseInsensitiveCompare(modelID) == .orderedSame {
                return true
            }
            if !normalizedModelID.isEmpty, self.normalizeSelectionHintKey(model.id) == normalizedModelID {
                return true
            }
            if model.name.caseInsensitiveCompare(modelID) == .orderedSame {
                return true
            }
            return !normalizedModelID.isEmpty && self.normalizeSelectionHintKey(model.name) == normalizedModelID
        }

        let providerMatchesHint: (AIProviderInfo, String) -> Bool = { provider, hint in
            if provider.id == hint || provider.id.caseInsensitiveCompare(hint) == .orderedSame {
                return true
            }
            if provider.name.caseInsensitiveCompare(hint) == .orderedSame {
                return true
            }
            let normalizedHint = self.normalizeSelectionHintKey(hint)
            guard !normalizedHint.isEmpty else { return false }
            return self.normalizeSelectionHintKey(provider.id) == normalizedHint ||
                self.normalizeSelectionHintKey(provider.name) == normalizedHint
        }

        if let providerHint, !providerHint.isEmpty {
            let matchedProvider = providers.first { providerMatchesHint($0, providerHint) }
            guard let provider = matchedProvider else { return nil }
            if let model = provider.models.first(where: modelMatches) {
                return AIModelSelection(providerID: provider.id, modelID: model.id)
            }
            return nil
        }

        var matches: [AIModelSelection] = []
        for provider in providers {
            for model in provider.models where modelMatches(model) {
                matches.append(AIModelSelection(providerID: provider.id, modelID: model.id))
            }
        }
        if matches.count == 1 {
            return matches[0]
        }
        return nil
    }

    func applyAISessionSelectionHintFromPart(
        _ part: AIProtocolPartInfo,
        sessionId: String,
        for tool: AIChatTool,
        trigger: String = "part_updated"
    ) {
        guard let hint = inferAISessionSelectionHint(from: part), !hint.isEmpty else { return }
        applyAISessionSelectionHint(hint, sessionId: sessionId, for: tool, trigger: trigger)
    }

    func inferAISessionSelectionHintFromMessages(_ messages: [AIProtocolMessageInfo]) -> AISessionSelectionHint? {
        for message in messages.reversed() where message.role.caseInsensitiveCompare("user") == .orderedSame {
            let hint = AISessionSelectionHint(
                agent: message.agent,
                modelProviderID: message.modelProviderID,
                modelID: message.modelID,
                configOptions: nil
            )
            if !hint.isEmpty {
                return hint
            }
        }
        for message in messages.reversed() {
            let hint = AISessionSelectionHint(
                agent: message.agent,
                modelProviderID: message.modelProviderID,
                modelID: message.modelID,
                configOptions: nil
            )
            if !hint.isEmpty {
                return hint
            }
        }

        for message in messages.reversed() where message.role.caseInsensitiveCompare("user") == .orderedSame {
            for part in message.parts.reversed() {
                if let hint = inferAISessionSelectionHint(from: part), !hint.isEmpty {
                    return hint
                }
            }
        }
        for message in messages.reversed() {
            for part in message.parts.reversed() {
                if let hint = inferAISessionSelectionHint(from: part), !hint.isEmpty {
                    return hint
                }
            }
        }
        return nil
    }

    private func inferAISessionSelectionHint(from part: AIProtocolPartInfo) -> AISessionSelectionHint? {
        var resolvedAgent: String?
        var resolvedProvider: String?
        var resolvedModel: String?

        let sources: [[String: Any]] = [part.source, part.toolPartMetadata, part.toolState].compactMap { $0 }
        for source in sources {
            if resolvedAgent == nil {
                resolvedAgent = findSelectionHintValue(
                    in: source,
                    keys: [
                        "agent",
                        "agent_name",
                        "selected_agent",
                        "current_agent",
                        "mode",
                        "mode_id",
                        "current_mode_id",
                        "selected_mode_id",
                        "collaboration_mode",
                    ]
                )
            }
            if resolvedProvider == nil {
                resolvedProvider = findSelectionHintValue(
                    in: source,
                    keys: [
                        "model_provider_id",
                        "provider_id",
                        "provider",
                        "model_provider",
                    ]
                )
            }
            if resolvedModel == nil {
                resolvedModel = findSelectionHintValue(
                    in: source,
                    keys: [
                        "model_id",
                        "model",
                        "current_model_id",
                        "selected_model_id",
                    ]
                )
            }
            if resolvedAgent != nil && resolvedModel != nil {
                break
            }
        }

        let hint = AISessionSelectionHint(
            agent: resolvedAgent,
            modelProviderID: resolvedProvider,
            modelID: resolvedModel,
            configOptions: nil
        )
        return hint.isEmpty ? nil : hint
    }

    private func findSelectionHintValue(in value: Any?, keys: [String]) -> String? {
        guard let value else { return nil }
        let normalizedKeys = Set(keys.map(normalizeSelectionHintKey))
        var queue: [Any] = [value]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1

            if let dict = current as? [String: Any] {
                for (key, nested) in dict {
                    if normalizedKeys.contains(normalizeSelectionHintKey(key)),
                       let parsed = parseSelectionHintScalar(nested) {
                        return parsed
                    }
                    queue.append(nested)
                }
                continue
            }
            if let array = current as? [Any] {
                queue.append(contentsOf: array)
            }
        }
        return nil
    }

    private func parseSelectionHintScalar(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            let text = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    private func normalizeSelectionHintKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

}
