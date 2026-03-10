import Foundation
import Combine
import TidyFlowShared

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

enum EvolutionControlAction: String, Equatable {
    case start
    case stop
    case resume
}

struct EvolutionPendingActionState: Equatable {
    let action: EvolutionControlAction
    let requestedAt: Date
    let requestedLoopRoundLimit: Int?

    init(
        action: EvolutionControlAction,
        requestedAt: Date = Date(),
        requestedLoopRoundLimit: Int? = nil
    ) {
        self.action = action
        self.requestedAt = requestedAt
        self.requestedLoopRoundLimit = requestedLoopRoundLimit
    }

    func resolvedLoopRoundLimit(fallback: Int) -> Int {
        max(1, requestedLoopRoundLimit ?? fallback)
    }
}

struct AIPendingHistoryLoadRequest: Equatable {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let limit: Int
}

struct EvolutionControlCapability: Equatable {
    let canStart: Bool
    let canStop: Bool
    let canResume: Bool
    let isStartPending: Bool
    let isStopPending: Bool
    let isResumePending: Bool
    let startReason: String?
    let stopReason: String?
    let resumeReason: String?

    static func evaluate(
        workspaceReady: Bool,
        currentStatus: String?,
        pendingAction: EvolutionPendingActionState?
    ) -> EvolutionControlCapability {
        guard workspaceReady else {
            return EvolutionControlCapability(
                canStart: false,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: "请先选择工作空间",
                stopReason: "请先选择工作空间",
                resumeReason: "请先选择工作空间"
            )
        }

        // 待确认操作未过期时阻塞所有控制（超过 30 秒视为已超时，跌回正常状态求值）
        if let pendingAction, Date().timeIntervalSince(pendingAction.requestedAt) <= 30 {
            let pendingReason = "操作进行中，请稍候"
            return EvolutionControlCapability(
                canStart: false,
                canStop: false,
                canResume: false,
                isStartPending: pendingAction.action == .start,
                isStopPending: pendingAction.action == .stop,
                isResumePending: pendingAction.action == .resume,
                startReason: pendingReason,
                stopReason: pendingReason,
                resumeReason: pendingReason
            )
        }

        guard let status = normalizedStatus(currentStatus) else {
            return EvolutionControlCapability(
                canStart: true,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: nil,
                stopReason: "当前无可停止的循环",
                resumeReason: "当前状态不可恢复"
            )
        }

        switch status {
        case "queued", "running":
            return EvolutionControlCapability(
                canStart: false,
                canStop: true,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: "当前循环未结束，无法启动新一轮",
                stopReason: nil,
                resumeReason: "当前状态不可恢复"
            )
        case "interrupted", "stopped":
            return EvolutionControlCapability(
                canStart: false,
                canStop: false,
                canResume: true,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: "当前循环未结束，无法启动新一轮",
                stopReason: "当前无可停止的循环",
                resumeReason: nil
            )
        case "completed", "failed_exhausted", "failed_system":
            return EvolutionControlCapability(
                canStart: true,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: nil,
                stopReason: "当前无可停止的循环",
                resumeReason: "当前状态不可恢复"
            )
        default:
            return EvolutionControlCapability(
                canStart: false,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: "当前状态不可启动",
                stopReason: "当前无可停止的循环",
                resumeReason: "当前状态不可恢复"
            )
        }
    }

    static func shouldClearPendingAction(
        _ pendingAction: EvolutionPendingActionState,
        currentStatus: String?
    ) -> Bool {
        // 超时的待确认操作无论状态如何都应清除
        if Date().timeIntervalSince(pendingAction.requestedAt) > 30 {
            return true
        }
        let normalized = normalizedStatus(currentStatus)
        switch pendingAction.action {
        case .start:
            return normalized != nil
        case .stop:
            guard let normalized else { return false }
            return [
                "interrupted",
                "stopped",
                "completed",
                "failed_exhausted",
                "failed_system",
            ].contains(normalized)
        case .resume:
            guard let normalized else { return false }
            return normalized == "queued" || normalized == "running"
        }
    }

    private static func normalizedStatus(_ status: String?) -> String? {
        guard let status else { return nil }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
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
    /// 共享连接语义层：单一入口表达所有连接阶段，视图和组件应优先读取此属性。
    @Published var connectionPhase: ConnectionPhase = .intentionallyDisconnected
    /// 向后兼容导出（二值）；新代码请使用 `connectionPhase`。
    var connectionState: ConnectionState { connectionPhase.legacyConnectionState }
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
    /// 工作区当前选中的底部面板类别。
    @Published var activeBottomPanelCategoryByWorkspace: [String: BottomPanelCategory] = [:]
    /// 工作区内各类别最近一次激活的实例 tab。
    @Published var lastActiveTabIdByWorkspaceByCategory: [String: [BottomPanelCategory: UUID]] = [:]
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
    /// 最近一次收到的 WS v8 包络序号（仅调试用，无视图观察，去掉 @Published 避免每条 WS 消息触发全局刷新）
    var wsLastEnvelopeSeq: UInt64 = 0
    /// 最近一次收到的 WS v8 包络摘要（domain/action/kind）
    var wsLastEnvelopeSummary: String = ""

    // 远程终端追踪
    @Published var remoteTerminals: [RemoteTerminalInfo] = []

    // Right Sidebar State
    @Published var rightSidebarCollapsed: Bool = false

    #if os(macOS)
    /// Tab 面板是否展开（false 时仅显示底部收起的 Tab 条）
    @Published var tabPanelExpanded: Bool = false
    /// Tab 面板展开时的高度（会话内记忆，不持久化）
    @Published var tabPanelHeight: CGFloat = 0
    /// 最近一次有效展开高度，用于收起后恢复。
    @Published var tabPanelLastExpandedHeight: CGFloat?
    #endif

    // UX-1: Project Tree State
    @Published var projects: [ProjectModel] = []
    @Published var selectedProjectId: UUID?
    @Published var addProjectSheetPresented: Bool = false

    /// 跨平台工作区视图状态机（与 iOS MobileAppState 共享同一套状态迁移语义）。
    /// 平台层的 selectedProjectId / selectedProjectName / selectedWorkspaceKey 保持向后兼容；
    /// 新业务逻辑通过此状态机读取选中状态，不再各自拼装 project + workspace 组合。
    let workspaceViewStateMachine = WorkspaceViewStateMachine()
    // UX-2: Project Import State
    @Published var projectImportInFlight: Bool = false
    @Published var projectImportError: String?
    // v1.40: 工作流模板
    @Published var templates: [TemplateInfo] = []

    // 文件缓存状态（独立 ObservableObject，避免文件高频更新触发全局视图刷新）
    let fileCache = FileCacheState()
    /// 文件树请求去重与最小节流（key: project:workspace:path）。
    var fileListRequestLastSentAt: [String: Date] = [:]

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

    // 共享终端会话存储（按 project/workspace/termId 隔离，macOS/iOS 双端通用）
    let terminalSessionStore = TerminalSessionStore()

    // 编辑器领域状态（独立 ObservableObject，减少编辑器状态变化对全局视图的影响）
    let editorStore = EditorStore()

    // 后台任务管理器
    let taskManager = BackgroundTaskManager()

    /// 共享性能追踪器，macOS/iOS 双端通过此对象暴露统一的性能观测结果。
    let performanceTracer = TFPerformanceTracer()
    let aiSessionListStore = AISessionListStore()
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

    // v1.41: 系统健康快照（Core 权威真源）
    @Published var systemHealthSnapshot: SystemHealthSnapshot?
    /// 按 (project, workspace) 分桶的 incident 修复状态（key: "project:workspace:incidentId"）
    @Published var incidentRepairStates: [String: IncidentRepairState] = [:]
    /// 工作区恢复状态摘要（key: "project:workspace"，从 system_snapshot workspace_items 提取）
    @Published var workspaceRecoverySummaries: [String: WorkspaceRecoverySummary] = [:]

    // 项目命令执行跟踪（用于基于 task_id 路由 started/output/completed）
    var projectCommandExecutions: [UUID: ProjectCommandExecutionState] = [:]
    var pendingProjectCommandExecutionIdsByKey: [String: [UUID]] = [:]
    var projectCommandExecutionIdByRemoteTaskId: [String: UUID] = [:]

    // AI 任务 continuation（key: "project:workspace"）
    var aiCommitContinuations: [String: (AICommitResult) -> Void] = [:]
    var aiMergeContinuations: [String: (AIMergeResult) -> Void] = [:]

    // AI Chat 状态（按 ai_tool 分桶，当前工具上下文映射到这些兼容字段）
    private(set) var aiChatStore: AIChatStore = AIChatStore()
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

    /// 右侧面板会话列表当前筛选条件，默认展示全部工具。
    @Published var sessionPanelFilter: AISessionListFilter = .all

    /// 右侧面板会话操作（由 SessionsPanelView 发起，AITabView 响应）
    enum SessionPanelAction: Equatable {
        case loadSession(AISessionInfo)
        case deleteSession(AISessionInfo)
        case createNewSession
        case renameSession(AISessionInfo, String)
    }
    @Published var sessionPanelAction: SessionPanelAction?

    /// 获取指定工具的辅助索引会话列表。
    func aiSessionsForTool(_ tool: AIChatTool) -> [AISessionInfo] {
        aiSessionsByTool[tool] ?? []
    }

    func displayedAISessions(for filter: AISessionListFilter) -> [AISessionInfo] {
        sessionListPageState(for: filter).sessions
    }

    func sessionListPageState(for filter: AISessionListFilter) -> AISessionListPageState {
        guard let workspace = selectedWorkspaceKey, !workspace.isEmpty else {
            return .empty()
        }
        return aiSessionListStore.pageState(project: selectedProjectName, workspace: workspace, filter: filter)
    }

    var displayedAISessionListState: AISessionListPageState {
        sessionListPageState(for: sessionPanelFilter)
    }

    /// 请求指定筛选的 AI 会话列表，并统一维护分页 loading 状态。
    @discardableResult
    func requestAISessionList(
        for filter: AISessionListFilter,
        limit: Int = 50,
        cursor: String? = nil,
        append: Bool = false,
        force: Bool = false
    ) -> Bool {
        guard let workspace = selectedWorkspaceKey,
              !workspace.isEmpty,
              connectionState == .connected else {
            return false
        }

        return aiSessionListStore.request(
            project: selectedProjectName,
            workspace: workspace,
            filter: filter,
            limit: limit,
            cursor: cursor,
            append: append,
            force: force,
            performanceTracer: performanceTracer
        ) {
            wsClient.requestAISessionList(
                projectName: selectedProjectName,
                workspaceName: workspace,
                filter: filter.tool,
                cursor: cursor,
                limit: limit
            )
        }
    }

    @discardableResult
    func loadNextAISessionListPage(for filter: AISessionListFilter, limit: Int = 50) -> Bool {
        let pageState = sessionListPageState(for: filter)
        guard pageState.hasMore,
              let nextCursor = pageState.nextCursor,
              !nextCursor.isEmpty else { return false }
        guard let workspace = selectedWorkspaceKey, !workspace.isEmpty else { return false }
        return aiSessionListStore.loadNextPage(
            project: selectedProjectName,
            workspace: workspace,
            filter: filter,
            limit: limit,
            performanceTracer: performanceTracer
        ) { nextCursor in
            wsClient.requestAISessionList(
                projectName: selectedProjectName,
                workspaceName: workspace,
                filter: filter.tool,
                cursor: nextCursor,
                limit: limit
            )
        }
    }

    @discardableResult
    func bootstrapAISessionListIfNeeded(limit: Int = 50) -> Bool {
        guard let workspace = selectedWorkspaceKey, !workspace.isEmpty else { return false }
        return aiSessionListStore.bootstrapIfNeeded(
            project: selectedProjectName,
            workspace: workspace,
            resetFilter: { [weak self] in
                guard let self, self.sessionPanelFilter != .all else { return }
                self.sessionPanelFilter = .all
            },
            requestInitialPage: { [weak self] in
                guard let self else { return false }
                return self.requestAISessionList(for: .all, limit: limit, force: true)
            }
        )
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
    /// 内部 badge 状态，无视图直接观察，去掉 @Published 避免不必要的 objectWillChange
    var aiToolBadges: [AIChatTool: AIToolBadgeState] = [:]
    /// AI 会话状态缓存（按工具分桶；key: "projectName::workspaceName::sessionId"）
    @Published var aiSessionStatusesByTool: [AIChatTool: [String: AISessionStatusSnapshot]] = [:]
    // Evolution 状态
    @Published var evolutionScheduler: EvolutionSchedulerInfoV2 = .empty
    @Published var evolutionWorkspaceItems: [EvolutionWorkspaceItemV2] = []
    @Published var evolutionStageProfilesByWorkspace: [String: [EvolutionStageProfileInfoV2]] = [:]
    /// Evolution 全局默认阶段配置（替代 per-workspace 配置，由设置页面管理）
    @Published var evolutionDefaultProfiles: [EvolutionEditableProfile] = []
    @Published var evolutionReplayTitle: String = ""
    @Published var evolutionReplayLoading: Bool = false
    @Published var evolutionReplayError: String?
    let evolutionReplayStore: AIChatStore = AIChatStore()
    @Published var evolutionBlockingRequired: EvolutionBlockingRequiredV2?
    @Published var evolutionBlockers: [EvolutionBlockerItemV2] = []
    @Published var evolutionPlanDocumentContent: String?
    @Published var evolutionPlanDocumentLoading: Bool = false
    @Published var evolutionPlanDocumentError: String?
    @Published var evolutionCycleHistories: [String: [EvolutionCycleHistoryItemV2]] = [:]
    @Published var evidenceSnapshotsByWorkspace: [String: EvidenceSnapshotV2] = [:]
    @Published var evidenceLoadingByWorkspace: [String: Bool] = [:]
    @Published var evidenceErrorByWorkspace: [String: String] = [:]
    /// 内部 one-shot hint，无视图直接观察
    var aiChatOneShotHintByWorkspace: [String: String] = [:]
    /// 内部 one-shot 输入预填，无视图直接观察
    var aiChatOneShotPrefillByWorkspace: [String: String] = [:]
    @Published var subAgentViewerTitle: String = ""
    @Published var subAgentViewerLoading: Bool = false
    @Published var subAgentViewerError: String?
    let subAgentViewerStore: AIChatStore = AIChatStore()
    /// 最近一次 AI 代码审查结果（用于 Git 面板触发后跳转）
    @Published var latestAICodeReviewResult: AICodeReviewResult?
    @Published var isSceneActive: Bool = true
    /// 当前 AI 代码补全分片流（requestId -> 累计文本）
    @Published var codeCompletionChunks: [String: String] = [:]
    /// 最近完成的 AI 代码补全结果
    @Published var latestCodeCompletionResult: AICodeCompletionDone?
    /// AI 会话上下文快照缓存：`contextSnapshotKey(project:workspace:aiTool:sessionId:)` -> 快照
    /// 在 `ai_context_snapshot_updated` 事件到达时更新，用于会话恢复和选择提示推导。
    @Published var aiSessionContextSnapshots: [String: AISessionContextSnapshot] = [:]

    private var aiChatStoresByTool: [AIChatTool: AIChatStore] = [:]
    private var aiSessionsByTool: [AIChatTool: [AISessionInfo]] = [:]
    private var aiSessionIndexByKey: [String: AISessionInfo] = [:]
    private var aiProvidersByTool: [AIChatTool: [AIProviderInfo]] = [:]
    private var aiSelectedModelByTool: [AIChatTool: AIModelSelection?] = [:]
    private var aiAgentsByTool: [AIChatTool: [AIAgentInfo]] = [:]
    private var aiSelectedAgentByTool: [AIChatTool: String?] = [:]
    private var aiSlashCommandsByTool: [AIChatTool: [AISlashCommandInfo]] = [:]
    private var aiSlashCommandsBySessionByTool: [AIChatTool: [String: [AISlashCommandInfo]]] = [:]
    private var aiSessionConfigOptionsByTool: [AIChatTool: [AIProtocolSessionConfigOptionInfo]] = [:]
    /// 记录会话 active 状态（key: "tool::project::workspace::session"），用于抑制侧边栏重复刷新。
    private var lastActiveBySessionKey: [String: Bool] = [:]
    /// 当前工具已选择的配置项值（option_id -> value），用于 send 时透传 config_overrides。
    private var aiSelectedConfigOptionsByTool: [AIChatTool: [String: Any]] = [:]
    private var aiSelectedThoughtLevelByTool: [AIChatTool: String?] = [:]
    enum AISelectorResourceKind {
        case providerList
        case agentList
    }
    /// 历史会话自动恢复输入框选择的待应用提示（key: sessionId）
    private var aiPendingSessionSelectionHintsByTool: [AIChatTool: [String: AISessionSelectionHint]] = [:]
    /// v1.42：按 project::workspace::aiTool::session 存储最新路由决策（供 UI 展示与追踪）
    private var aiSessionRouteDecisionByKey: [String: AIRouteDecisionInfo] = [:]
    /// v1.42：按 project::workspace 存储最新预算状态
    private var aiWorkspaceBudgetStatusByKey: [String: AIBudgetStatus] = [:]
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
    /// Evolution 回放会话等待 subscribe ack 后的历史拉取兜底。
    var pendingEvolutionReplayHistoryLoadRequest: AIPendingHistoryLoadRequest?
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
    /// Evolution：记录某工作空间等待重试/等待确认的动作。
    @Published var evolutionPendingActionByWorkspace: [String: EvolutionPendingActionState] = [:]
    /// Evolution：工作区运行态权威索引，避免每次事件都重建整数组。
    var evolutionWorkspaceItemIndexByKey: [String: EvolutionWorkspaceItemV2] = [:]
    var evolutionSnapshotFallbackWorkItems: [String: DispatchWorkItem] = [:]
    var evolutionTargetedSnapshotMergeKeys: Set<String> = []
    var evolutionSnapshotFallbackTotal: Int = 0
    /// Evidence：等待中的重建提示词请求（按 workspace key 聚合）
    var evidencePromptCompletionByWorkspace: [String: (_ prompt: EvidenceRebuildPromptV2?, _ errorMessage: String?) -> Void] = [:]
    /// Evidence：分块读取上下文（按 workspace key，仅串行读取）
    var evidenceReadRequestByWorkspace: [String: EvidenceReadRequestState] = [:]
    /// Evolution：计划文档读取上下文（按 cycle 文件路径识别）
    var pendingEvolutionPlanDocumentReadPath: String?

    // 远程项目命令任务跟踪（key: remoteTaskId）
    var remoteProjectCommandTasks: [String: BackgroundTask] = [:]

    // Toast 通知管理器
    let toastManager = ToastManager()

    // v1.24: 剪贴板是否有文件（驱动粘贴菜单显示）
    @Published var clipboardHasFiles: Bool = false

    /// 正在删除中的工作空间（globalWorkspaceKey 集合），用于阻塞 UI 交互
    @Published var deletingWorkspaces: Set<String> = []
    /// 侧边栏状态刷新防抖（按项目维度）
    var workspaceSidebarStatusRefreshWorkItemByProject: [String: DispatchWorkItem] = [:]

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
    var pendingTerminalOutputByTermId: [String: [[UInt8]]] = [:]
    let pendingOutputChunkLimit = 128
    let terminalOutputFlushInterval: TimeInterval = 0.016
    let terminalOutputMaxBytesPerFlush = 32 * 1024
    var terminalOutputFlushWorkItem: DispatchWorkItem?
    var termOutputUnackedBytesByTermId: [String: Int] = [:]
    let termOutputAckThreshold = 50 * 1024
    var terminalAttachRequestedAtByTermId: [String: Date] = [:]
    var terminalDetachRequestedAtByTermId: [String: Date] = [:]

    /// 自动重连内部计数（机制层）；连接语义状态通过 `connectionPhase` 对外暴露。
    var reconnectAttempt = 0
    /// 当前已配置到 WSClient 的 Core 连接目标，用于屏蔽重复 setup。
    var configuredWSConnectionTarget: String?
    /// 当前已完成初始化请求批次的连接身份；同一 socket 只执行一次首连同步。
    var initializedWSConnectionIdentity: String?
    // 重连后延迟拉取非当前 AI 工具会话列表的任务（用于削峰）
    var deferredAISessionReloadWorkItem: DispatchWorkItem?

    // WebSocket Client
    let wsClient = WSClient()

    // Core Process Manager
    let coreProcessManager = CoreProcessManager()

    // Project name (for WS protocol)
    @Published var selectedProjectName: String = "default"
    /// 首次进入 ready 后锁定，不再回退到启动页
    private var hasFinishedStartupPhase = false

    var commands: [Command] = []

    init() {
        // Start with empty projects list
        self.projects = []
        self.selectedProjectId = nil
        self.selectedWorkspaceKey = nil
        configureAIStorePerformance(evolutionReplayStore)
        configureAIStorePerformance(subAgentViewerStore)
        self.configureAIToolBuckets()
        self.switchAIContext(to: aiChatTool)

        setupCommands()

        // 先用内置默认值初始化，连接 Core 后再同步真实的 Evolution 全局默认配置
        loadEvolutionDefaultProfiles()

        // 接线 GitCacheState 依赖
        setupGitCache()

        // Setup Core process callbacks
        setupCoreCallbacks()

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
            let store = AIChatStore()
            configureAIStorePerformance(store)
            aiChatStoresByTool[tool] = store
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

    func sessionListPageKey(
        project: String,
        workspace: String,
        filter: AISessionListFilter
    ) -> String {
        AISessionListSemantics.pageKey(project: project, workspace: workspace, filter: filter)
    }

    func updateSessionListPageState(
        _ state: AISessionListPageState,
        project: String,
        workspace: String,
        filter: AISessionListFilter
    ) {
        _ = aiSessionListStore.handleResponse(
            project: project,
            workspace: workspace,
            filter: filter,
            sessions: state.sessions,
            hasMore: state.hasMore,
            nextCursor: state.nextCursor,
            performanceTracer: performanceTracer
        )
    }

    func clearAISessionListPageStates() {
        aiSessionListStore.clear()
    }

    func replaceToolSessionIndex(_ sessions: [AISessionInfo], for tool: AIChatTool) {
        let filteredExisting = aiSessionIndexByKey.filter {
            $0.value.aiTool != tool || !$0.value.isVisibleInDefaultSessionList
        }
        aiSessionIndexByKey = filteredExisting
        for session in sessions {
            aiSessionIndexByKey[session.sessionKey] = session
        }
    }

    func aiStore(for tool: AIChatTool) -> AIChatStore {
        if let store = aiChatStoresByTool[tool] {
            return store
        }
        let store = AIChatStore()
        configureAIStorePerformance(store)
        aiChatStoresByTool[tool] = store
        return store
    }

    private func configureAIStorePerformance(_ store: AIChatStore) {
        store.performanceTracer = performanceTracer
        store.performanceContextProvider = { [weak self] in
            guard let self, let workspace = self.selectedWorkspaceKey, !workspace.isEmpty else { return nil }
            return (self.selectedProjectName, workspace)
        }
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
        let visibleSessions = sortedSessions.filter(\.isVisibleInDefaultSessionList)
        aiSessionsByTool[tool] = visibleSessions
        replaceToolSessionIndex(sortedSessions, for: tool)
        if aiChatTool == tool {
            aiSessions = visibleSessions
        }
    }

    func upsertAISession(_ session: AISessionInfo, for tool: AIChatTool) {
        var sessions = aiSessionsByTool[tool] ?? []
        sessions.removeAll { $0.sessionKey == session.sessionKey }
        sessions.insert(session, at: 0)
        setAISessions(sessions, for: tool)
        aiSessionListStore.upsertVisibleSession(session)
    }

    func mergeKnownAISessions(_ sessions: [AISessionInfo]) {
        let grouped = Dictionary(grouping: sessions, by: \.aiTool)
        for (tool, incomingSessions) in grouped {
            var merged = aiSessionsByTool[tool] ?? []
            for session in incomingSessions {
                merged.removeAll { $0.sessionKey == session.sessionKey }
                merged.append(session)
            }
            setAISessions(merged, for: tool)
        }
    }

    func removeAISession(_ sessionId: String, for tool: AIChatTool) {
        var sessions = aiSessionsByTool[tool] ?? []
        sessions.removeAll { $0.id == sessionId }
        setAISessions(sessions, for: tool)
        aiSessionIndexByKey = aiSessionIndexByKey.filter {
            !($0.value.aiTool == tool && $0.value.id == sessionId)
        }
        aiSessionListStore.removeSession(sessionId: sessionId, tool: tool)

        // 同步清理状态缓存（仅按 sessionId 删除可能误删其他工作空间，因此这里做“全表扫描”）。
        let prefix = "::\(sessionId)"
        var dict = aiSessionStatusesByTool[tool] ?? [:]
        dict = dict.filter { !$0.key.hasSuffix(prefix) }
        aiSessionStatusesByTool[tool] = dict

        let activityPrefix = "\(tool.rawValue)::"
        lastActiveBySessionKey = lastActiveBySessionKey.filter {
            !($0.key.hasPrefix(activityPrefix) && $0.key.hasSuffix(prefix))
        }
    }

    func renameSession(_ session: AISessionInfo, newTitle: String) {
        var sessions = aiSessionsByTool[session.aiTool] ?? []
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            let updated = AISessionInfo(projectName: session.projectName,
                                        workspaceName: session.workspaceName,
                                        aiTool: session.aiTool,
                                        id: session.id,
                                        title: newTitle,
                                        updatedAt: session.updatedAt,
                                        origin: session.origin)
            sessions[idx] = updated
            setAISessions(sessions, for: session.aiTool)
        }
        if let cached = aiSessionIndexByKey[session.sessionKey] {
            aiSessionIndexByKey[session.sessionKey] = AISessionInfo(
                projectName: cached.projectName,
                workspaceName: cached.workspaceName,
                aiTool: cached.aiTool,
                id: cached.id,
                title: newTitle,
                updatedAt: session.updatedAt,
                origin: cached.origin
            )
        }
        aiSessionListStore.renameSession(session, newTitle: newTitle)
    }

    func cachedAISession(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> AISessionInfo? {
        aiSessionIndexByKey[AISessionSemantics.sessionKey(project: projectName, workspace: workspaceName, aiTool: aiTool, sessionId: sessionId)]
    }

    func cachedAISession(sessionId: String) -> AISessionInfo? {
        aiSessionIndexByKey.values.first { $0.id == sessionId }
    }

    // MARK: - AI 会话状态

    private func aiSessionStatusKey(projectName: String, workspaceName: String, sessionId: String) -> String {
        "\(projectName)::\(workspaceName)::\(sessionId)"
    }

    private func aiSessionStatusActivityKey(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> String {
        "\(aiTool.rawValue)::\(aiSessionStatusKey(projectName: projectName, workspaceName: workspaceName, sessionId: sessionId))"
    }

    func aiSessionStatus(for session: AISessionInfo) -> AISessionStatusSnapshot? {
        aiSessionStatusesByTool[session.aiTool]?[aiSessionStatusKey(projectName: session.projectName, workspaceName: session.workspaceName, sessionId: session.id)]
    }

    @discardableResult
    func upsertAISessionStatus(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        status: String,
        errorMessage: String?,
        contextRemainingPercent: Double?
    ) -> Bool {
        let key = aiSessionStatusKey(projectName: projectName, workspaceName: workspaceName, sessionId: sessionId)
        let activityKey = aiSessionStatusActivityKey(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId
        )
        var dict = aiSessionStatusesByTool[aiTool] ?? [:]
        let previousActive = dict[key]?.isActive ?? (lastActiveBySessionKey[activityKey] ?? false)

        let normalizedStatus = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedErrorMessage: String? = {
            let trimmed = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }()

        let next = AISessionStatusSnapshot(
            status: normalizedStatus.isEmpty ? status : normalizedStatus,
            errorMessage: normalizedErrorMessage,
            contextRemainingPercent: contextRemainingPercent
        )
        let nextActive = next.isActive
        lastActiveBySessionKey[activityKey] = nextActive
        if dict[key] == next {
            return previousActive != nextActive
        }
        dict[key] = next
        aiSessionStatusesByTool[aiTool] = dict
        return previousActive != nextActive
    }

    func clearAISessionStatuses() {
        for tool in AIChatTool.allCases {
            aiSessionStatusesByTool[tool] = [:]
        }
        lastActiveBySessionKey.removeAll()
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
        }
        // 验证当前选中的模型在新 provider 列表中是否仍然有效；
        // 若已失效则清除选择，避免发送时携带不存在的模型导致请求出错。
        let currentModel = aiSelectedModelByTool[tool] ?? nil
        if let model = currentModel {
            let allModels = providers.flatMap { $0.models }
            let stillValid = allModels.contains(where: {
                $0.id == model.modelID && $0.providerID == model.providerID
            })
            if !stillValid {
                setAISelectedModel(nil, for: tool)
            }
        }
    }

    func setAIAgents(_ agents: [AIAgentInfo], for tool: AIChatTool) {
        aiAgentsByTool[tool] = agents
        if aiChatTool == tool {
            aiAgents = agents
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
        if let option = aiSessionConfigOptions(for: tool).first(where: {
            normalizedConfigCategory($0.category, optionID: $0.optionID) == "thought_level"
        }) {
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
            if !values.isEmpty { return values }
        }
        // Codex 静态兜底：无动态配置时提供 reasoning_effort 三档选项
        if tool == .codex {
            return ["low", "medium", "high"]
        }
        return []
    }

    /// 返回当前工具的 thought_level 配置项 option_id；Codex 使用静态兜底。
    func thoughtLevelOptionID(for tool: AIChatTool) -> String? {
        if let optionID = optionIDForCategory("thought_level", in: aiSessionConfigOptions(for: tool)) {
            return optionID
        }
        if tool == .codex {
            return "thought_level"
        }
        return nil
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

    // MARK: - v1.42 路由决策与预算状态

    /// 按 project/workspace/aiTool/session 构造路由状态 key（用于隔离存储）
    private func aiSessionRouteKey(
        projectName: String, workspaceName: String,
        aiTool: AIChatTool, sessionId: String
    ) -> String {
        "\(projectName)::\(workspaceName)::\(aiTool.rawValue)::\(sessionId)"
    }

    /// 按 project/workspace 构造工作区预算 key
    private func aiWorkspaceBudgetKey(projectName: String, workspaceName: String) -> String {
        "\(projectName)::\(workspaceName)"
    }

    /// 存储会话路由决策（chat_done / chat_error 时调用）
    func upsertAISessionRouteDecision(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        routeDecision: AIRouteDecisionInfo?
    ) {
        guard let routeDecision else { return }
        let key = aiSessionRouteKey(
            projectName: projectName, workspaceName: workspaceName,
            aiTool: aiTool, sessionId: sessionId
        )
        aiSessionRouteDecisionByKey[key] = routeDecision
    }

    /// 读取会话路由决策
    func currentRouteDecision(
        projectName: String, workspaceName: String,
        aiTool: AIChatTool, sessionId: String
    ) -> AIRouteDecisionInfo? {
        let key = aiSessionRouteKey(
            projectName: projectName, workspaceName: workspaceName,
            aiTool: aiTool, sessionId: sessionId
        )
        return aiSessionRouteDecisionByKey[key]
    }

    /// 存储工作区预算状态
    func upsertAIWorkspaceBudgetStatus(
        projectName: String, workspaceName: String,
        budgetStatus: AIBudgetStatus?
    ) {
        guard let budgetStatus else { return }
        let key = aiWorkspaceBudgetKey(projectName: projectName, workspaceName: workspaceName)
        aiWorkspaceBudgetStatusByKey[key] = budgetStatus
    }

    /// 读取工作区预算状态
    func currentBudgetStatus(projectName: String, workspaceName: String) -> AIBudgetStatus? {
        let key = aiWorkspaceBudgetKey(projectName: projectName, workspaceName: workspaceName)
        return aiWorkspaceBudgetStatusByKey[key]
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
        let normalizedRaw = AISessionSemantics.normalizeSelectionHintKey(trimmed)
        if let normalizedNameMatched = agents.first(where: {
            AISessionSemantics.normalizeSelectionHintKey($0.name) == normalizedRaw
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
            return AISessionSemantics.normalizeSelectionHintKey(mode) == normalizedRaw
        }) {
            return normalizedModeMatched.name
        }
        if let containsMatched = agents.first(where: {
            let nameKey = AISessionSemantics.normalizeSelectionHintKey($0.name)
            if !nameKey.isEmpty,
               (normalizedRaw.contains(nameKey) || nameKey.contains(normalizedRaw)) {
                return true
            }
            guard let mode = $0.mode else { return false }
            let modeKey = AISessionSemantics.normalizeSelectionHintKey(mode)
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
        let normalizedModelID = AISessionSemantics.normalizeSelectionHintKey(modelID)
        let modelMatches: (AIModelInfo) -> Bool = { model in
            if model.id == modelID || model.id.caseInsensitiveCompare(modelID) == .orderedSame {
                return true
            }
            if !normalizedModelID.isEmpty, AISessionSemantics.normalizeSelectionHintKey(model.id) == normalizedModelID {
                return true
            }
            if model.name.caseInsensitiveCompare(modelID) == .orderedSame {
                return true
            }
            return !normalizedModelID.isEmpty && AISessionSemantics.normalizeSelectionHintKey(model.name) == normalizedModelID
        }

        let providerMatchesHint: (AIProviderInfo, String) -> Bool = { provider, hint in
            if provider.id == hint || provider.id.caseInsensitiveCompare(hint) == .orderedSame {
                return true
            }
            if provider.name.caseInsensitiveCompare(hint) == .orderedSame {
                return true
            }
            let normalizedHint = AISessionSemantics.normalizeSelectionHintKey(hint)
            guard !normalizedHint.isEmpty else { return false }
            return AISessionSemantics.normalizeSelectionHintKey(provider.id) == normalizedHint ||
                AISessionSemantics.normalizeSelectionHintKey(provider.name) == normalizedHint
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
        guard let hint = AISessionSemantics.inferSelectionHintFromPart(part), !hint.isEmpty else { return }
        applyAISessionSelectionHint(hint, sessionId: sessionId, for: tool, trigger: trigger)
    }

    func inferAISessionSelectionHintFromMessages(_ messages: [AIProtocolMessageInfo]) -> AISessionSelectionHint? {
        AISessionSemantics.inferSelectionHintFromMessages(messages)
    }

}
