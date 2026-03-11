import Foundation
import SwiftUI
import UIKit
import TidyFlowShared

private struct PairExchangeHTTPBody: Encodable {
    let pairCode: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case pairCode = "pair_code"
        case deviceName = "device_name"
    }
}

private struct PairExchangeHTTPResponse: Decodable {
    let tokenId: String
    let wsToken: String
    let deviceName: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case wsToken = "ws_token"
        case deviceName = "device_name"
        case expiresAt = "expires_at"
    }
}

private struct PairErrorHTTPResponse: Decodable {
    let error: String
    let message: String
}

// MobileWorkspaceTaskType、MobileWorkspaceTaskStatus 和 MobileWorkspaceTask 已迁移至
// WorkspaceTaskSemantics.swift（WorkspaceTaskType / WorkspaceTaskStatus / WorkspaceTaskItem）

// ReconnectState 保留用于 DisconnectBannerView 向后兼容；
// 新代码应使用 MobileAppState.connectionPhase（见 ConnectionSemantics.swift）。
enum ReconnectState: Equatable {
    case idle
    case reconnecting(attempt: Int, maxAttempts: Int)
    case failed
}

// iOS 专属：从 ConnectionPhase 派生 ReconnectState（向后兼容桥接）
extension ConnectionPhase {
    var toReconnectState: ReconnectState {
        switch self {
        case .reconnecting(let attempt, let max):
            return .reconnecting(attempt: attempt, maxAttempts: max)
        case .reconnectFailed:
            return .failed
        default:
            return .idle
        }
    }
}

// MobileWorkspaceTask 已迁移至 WorkspaceTaskSemantics.swift 中的 WorkspaceTaskItem

struct MobileWorkspaceGitSummary: Equatable {
    let additions: Int
    let deletions: Int
    let defaultBranch: String?
}

/// iOS 端 Git 详细状态，复用共享协议模型中的 GitStatusItem / GitBranchItem
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

    static func empty() -> MobileWorkspaceGitDetailState {
        MobileWorkspaceGitDetailState(
            currentBranch: nil,
            defaultBranch: nil,
            branches: [],
            stagedItems: [],
            unstagedItems: [],
            isGitRepo: false,
            aheadBy: nil,
            behindBy: nil,
            isCommitting: false,
            commitResult: nil
        )
    }

    /// 产出与 macOS 共享相同分类规则的 Git 面板语义快照
    var semanticSnapshot: GitPanelSemanticSnapshot {
        GitPanelSemanticSnapshot(
            stagedItems: stagedItems,
            trackedUnstagedItems: unstagedItems.filter { $0.status != "??" },
            untrackedItems: unstagedItems.filter { $0.status == "??" },
            isGitRepo: isGitRepo,
            isLoading: false,
            currentBranch: currentBranch,
            defaultBranch: defaultBranch,
            aheadBy: aheadBy,
            behindBy: behindBy
        )
    }
}

private struct MobileTerminalPresentation {
    let icon: String
    let name: String
    let sourceCommand: String?
    var isPinned: Bool
}

struct MobileEvidenceReadRequestState {
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

@MainActor
protocol MobileTerminalOutputSink: AnyObject {
    func writeOutput(_ bytes: [UInt8])
    func focusTerminal()
    /// 切换 term_id 时必须重置本地终端视图，否则 SwiftUI 可能复用同一个 TerminalView，
    /// 导致新终端的 scrollback/输出追加到旧缓冲里，表现为“多终端数据混在一起”。
    func resetTerminal()
}

@MainActor
final class MobileAppState: ObservableObject {
    private static let perfTerminalAutoDetachEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["PERF_TERMINAL_AUTO_DETACH"]?.lowercased() {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }()
    private static let uiTestModeEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["UI_TEST_MODE"]?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }()

    // 连接表单
    @Published var host: String = ""
    @Published var port: String = "47999"
    @Published var pairCode: String = ""
    @Published var deviceName: String = UIDevice.current.name
    /// 是否通过 HTTPS/WSS 连接（反向代理场景）
    @Published var useHTTPS: Bool = false

    // 连接状态
    @Published var connecting: Bool = false
    @Published var autoConnecting: Bool = false
    @Published var hasSavedConnection: Bool = false
    /// 共享连接语义层：单一入口表达所有连接阶段，与 macOS 保持行为语义一致。
    @Published var connectionPhase: ConnectionPhase = .intentionallyDisconnected
    /// 是否已连接（从 connectionPhase 派生，向后兼容）
    var isConnected: Bool { connectionPhase.isConnected }
    /// 重连状态（从 connectionPhase 派生，向后兼容）
    var reconnectState: ReconnectState { connectionPhase.toReconnectState }
    @Published var connectionMessage: String = ""
    @Published var errorMessage: String = ""

    // 数据
    @Published var projects: [ProjectInfo] = []

    /// 所有已知项目的名称列表（用于 @@ 项目引用补全）
    var allProjectNames: [String] { projects.map { $0.name } }
    @Published var workspaces: [WorkspaceInfo] = []
    @Published var workspacesByProject: [String: [WorkspaceInfo]] = [:]
    @Published var activeTerminals: [TerminalSessionInfo] = []
    @Published var customCommands: [CustomCommand] = []
    @Published var workspaceShortcuts: [String: String] = [:]
    @Published var workspaceTerminalOpenTime: [String: Date] = [:]
    @Published var workspaceGitDetailState: [String: MobileWorkspaceGitDetailState] = [:]
    /// 工作区任务共享存储（取代原 workspaceTasksByKey，与 macOS 共享语义层对齐）
    let taskStore = WorkspaceTaskStore()
    @Published var workspaceTodosByKey: [String: [WorkspaceTodoItem]] = [:]
    @Published var keybindings: [KeybindingConfig] = KeybindingConfig.defaultKeybindings()
    // v1.40: 工作流模板
    @Published var templates: [TemplateInfo] = []
    // v1.40: 冲突向导缓存（key = "project:workspace" 或 "project:integration"）
    @Published var conflictWizardCache: [String: ConflictWizardCache] = [:]
    // 资源管理器（按 project/workspace/path 分桶）
    @Published var explorerFileListCache: [String: FileListCache] = [:]
    @Published var explorerDirectoryExpandState: [String: Bool] = [:]
    @Published var explorerPreviewPresented: Bool = false
    @Published var explorerPreviewLoading: Bool = false
    @Published var explorerPreviewPath: String?
    @Published var explorerPreviewContent: String = ""
    @Published var explorerPreviewError: String?
    @Published var mergeAIAgent: String?
    @Published var evolutionDefaultProfiles: [EvolutionStageProfileInfoV2] = []
    var clientFixedPort: Int = 0
    var clientRemoteAccessEnabled: Bool = false
    // AI Chat 状态（iOS 端完整对齐 macOS）
    @Published var aiActiveProject: String = ""
    @Published var aiActiveWorkspace: String = ""
    @Published var aiChatTool: AIChatTool = .opencode
    @Published var aiCurrentSessionId: String?
    /// AI 聊天舞台生命周期状态机（双端共享契约，统一驱动进入/恢复/切换/关闭迁移）
    let aiChatStageLifecycle = AIChatStageLifecycle()
    /// 主聊天状态统一由 AIChatStore 承载，避免重复数组写入。
    var aiChatMessages: [AIChatMessage] { aiChatStore.messages }
    var aiIsStreaming: Bool {
        get { aiChatStore.isStreaming }
        set { aiChatStore.isStreaming = newValue }
    }
    var aiIsSendingPending: Bool {
        get { aiChatStore.hasPendingFirstContent }
        set { aiChatStore.hasPendingFirstContent = newValue }
    }
    var aiAbortPendingSessionId: String? {
        get { aiChatStore.abortPendingSessionId }
        set { aiChatStore.abortPendingSessionId = newValue }
    }
    @Published var aiSessions: [AISessionInfo] = [] {
        didSet {
            aiSessionsByTool[aiChatTool] = aiSessions
        }
    }
    /// AI 会话状态缓存（按工具分桶；key: "project::workspace::sessionId"）
    @Published var aiSessionStatusesByTool: [AIChatTool: [String: AISessionStatusSnapshot]] = [:]
    /// 会话列表当前筛选条件，默认展示全部工具。
    @Published var sessionListFilter: AISessionListFilter = .all
    @Published var aiProviders: [AIProviderInfo] = []
    @Published var aiSelectedModel: AIModelSelection? {
        didSet {
            syncModelConfigOptionForCurrentTool()
        }
    }
    @Published var aiAgents: [AIAgentInfo] = []
    @Published var aiSelectedAgent: String? {
        didSet {
            syncModeConfigOptionForCurrentTool()
        }
    }
    @Published var aiSessionConfigOptions: [AIProtocolSessionConfigOptionInfo] = []
    @Published var aiSelectedModelVariant: String? {
        didSet {
            aiSelectedModelVariantByTool[aiChatTool] = aiSelectedModelVariant
            syncModelVariantConfigOptionForCurrentTool()
        }
    }
    @Published var aiSlashCommands: [AISlashCommandInfo] = []
    @Published var isAILoadingModels: Bool = false
    @Published var isAILoadingAgents: Bool = false
    /// AI 会话上下文快照缓存：`contextSnapshotKey(project:workspace:aiTool:sessionId:)` -> 快照
    @Published var aiSessionContextSnapshots: [String: AISessionContextSnapshot] = [:]
    @Published var aiFileIndexCache: [String: FileIndexCache] = [:]
    private var explorerFileRequestLastSentAt: [String: Date] = [:]
    // Evolution 状态
    @Published var evolutionScheduler: EvolutionSchedulerInfoV2 = .empty
    @Published var evolutionWorkspaceItems: [EvolutionWorkspaceItemV2] = []
    @Published var evolutionStageProfilesByWorkspace: [String: [EvolutionStageProfileInfoV2]] = [:]
    @Published var evolutionReplayTitle: String = ""
    @Published var evolutionReplayMessages: [AIChatMessage] = []
    @Published var evolutionReplayLoading: Bool = false
    @Published var evolutionReplayError: String?
    @Published var evolutionBlockingRequired: EvolutionBlockingRequiredV2?
    @Published var evolutionBlockers: [EvolutionBlockerItemV2] = []
    @Published var evolutionPlanDocumentContent: String?
    @Published var evolutionPlanDocumentLoading: Bool = false
    @Published var evolutionPlanDocumentError: String?
    @Published var evolutionCycleHistories: [String: [EvolutionCycleHistoryItemV2]] = [:]
    var pendingPlanDocumentReadPath: String?
    @Published var evidenceSnapshotsByWorkspace: [String: EvidenceSnapshotV2] = [:]
    @Published var evidenceLoadingByWorkspace: [String: Bool] = [:]
    @Published var evidenceErrorByWorkspace: [String: String] = [:]
    @Published var aiChatOneShotHintByWorkspace: [String: String] = [:]
    @Published var aiChatOneShotPrefillByWorkspace: [String: String] = [:]
    @Published var subAgentViewerTitle: String = ""
    @Published var subAgentViewerLoading: Bool = false
    @Published var subAgentViewerError: String?
    /// ClientSettings 下发的 Evolution 代理配置（key: "project/workspace"）
    var evolutionProfilesFromClientSettings: [String: [EvolutionStageProfileInfoV2]] = [:]
    @Published private var evolutionProvidersByWorkspace: [String: [AIChatTool: [AIProviderInfo]]] = [:]
    @Published private var evolutionAgentsByWorkspace: [String: [AIChatTool: [AIAgentInfo]]] = [:]
    /// Evolution：按工作空间追踪 provider/agent 列表是否齐全，用于串联 profile 加载时序。
    private var evolutionSelectorLoadStateByWorkspace: [String: [AIChatTool: (providerLoaded: Bool, agentLoaded: Bool)]] = [:]
    /// Evolution：等待在列表齐全后拉取 profile 的工作空间 key 集合。
    private var evolutionPendingProfileReloadWorkspaces: Set<String> = []
    /// Evolution：profile 请求兜底定时器。
    private var evolutionProfileReloadFallbackTimers: [String: DispatchWorkItem] = [:]
    @Published var evolutionPendingActionByWorkspace: [String: String] = [:]
    var evidencePromptCompletionByWorkspace: [String: (_ prompt: EvidenceRebuildPromptV2?, _ errorMessage: String?) -> Void] = [:]
    var evidenceReadRequestByWorkspace: [String: MobileEvidenceReadRequestState] = [:]

    // v1.41: 系统健康快照（Core 权威真源，与 macOS 使用同一套共享模型）
    @Published var systemHealthSnapshot: SystemHealthSnapshot?
    /// 按 incident key（"project:workspace:incidentId"）追踪修复状态
    @Published var incidentRepairStates: [String: IncidentRepairState] = [:]
    /// 工作区恢复状态摘要（key: "project:workspace"，从 system_snapshot workspace_items 提取）
    @Published var workspaceRecoverySummaries: [String: WorkspaceRecoverySummary] = [:]

    // v1.42: 统一可观测性快照（与 macOS 共享同一模型，Core 权威真源）
    @Published var observabilitySnapshot: ObservabilitySnapshot = .empty

    // MARK: - 调度优化与预测故障消费（v1.44）

    /// 获取指定工作区的预测投影。
    /// 双端通过 WorkspacePredictionProjectionSemantics 统一构建，不在 View 层推导。
    func predictionProjection(project: String, workspace: String) -> WorkspacePredictionProjection {
        WorkspacePredictionProjectionSemantics.make(
            from: systemHealthSnapshot,
            project: project,
            workspace: workspace
        )
    }

    let aiChatStore = AIChatStore()
    let subAgentViewerStore = AIChatStore()
    let aiSessionListStore = AISessionListStore()

    // AI Chat：按工具分桶存储会话
    var aiSessionsByTool: [AIChatTool: [AISessionInfo]] = [:]
    private var aiSessionIndexByKey: [String: AISessionInfo] = [:]
    private var aiSlashCommandsByTool: [AIChatTool: [AISlashCommandInfo]] = [:]
    private var aiSlashCommandsBySessionByTool: [AIChatTool: [String: [AISlashCommandInfo]]] = [:]
    private var aiSessionConfigOptionsByTool: [AIChatTool: [AIProtocolSessionConfigOptionInfo]] = [:]
    private var aiSelectedConfigOptionsByTool: [AIChatTool: [String: Any]] = [:]
    private var aiSelectedModelVariantByTool: [AIChatTool: String?] = [:]
    private var aiPendingSessionSelectionHintsByTool: [AIChatTool: [String: AISessionSelectionHint]] = [:]
    /// v1.42：按 project::workspace::aiTool::session 存储最新路由决策（按工作区隔离）
    private var aiSessionRouteDecisionByKey: [String: AIRouteDecisionInfo] = [:]
    /// v1.42：按 project::workspace 存储最新预算状态（按工作区隔离）
    private var aiWorkspaceBudgetStatusByKey: [String: AIBudgetStatus] = [:]
    private enum AISelectorResourceKind {
        case providerList
        case agentList
    }
    /// iOS 设置页在未进入聊天时的 AI 资源拉取上下文（按工具分桶）。
    private var settingsSelectorContextByTool: [AIChatTool: (
        project: String,
        workspace: String,
        providerPending: Bool,
        agentPending: Bool
    )] = [:]

    // 导航
    @Published var navigationPath = NavigationPath()

    // 终端
    @Published var currentTermId: String = ""
    @Published var terminalCols: Int = 80
    @Published var terminalRows: Int = 24
    /// 每个工作区的终端 AI 状态（六态），key 为 "project:workspace"。
    /// 与 macOS 共用 TerminalSessionSemantics 映射逻辑，保持双端语义一致。
    @Published var terminalAIStatusByWorkspaceKey: [String: TerminalAIStatus] = [:]
    /// 待创建终端的项目/工作空间（等终端视图 ready 后再真正创建）
    private var pendingTermProject: String = ""
    private var pendingTermWorkspace: String = ""
    /// 待附着的终端 ID（重连场景）
    private var pendingAttachTermId: String = ""
    /// 待执行的自定义命令（终端创建后自动发送）
    var pendingCustomCommand: String = ""
    /// 待执行命令图标（用于终端列表展示）
    var pendingCustomCommandIcon: String = ""
    /// 待执行命令名称（用于终端列表展示）
    var pendingCustomCommandName: String = ""
    /// Ctrl 一次性修饰状态（用于虚拟键盘输入）
    private var ctrlArmedForNextInput: Bool = false
    /// 终端视图是否已经拿到有效 cols/rows
    private var isTerminalViewReady: Bool = false
    /// ACK 阈值（50KB），与 macOS 原生终端端保持一致
    private let termOutputAckThreshold = 50 * 1024

    /// 共享终端会话存储：按 project/workspace/termId 隔离，统一管理展示信息、
    /// 置顶状态、attach/detach 请求时间和输出 ACK 计数，与 macOS 共享语义。
    let terminalSessionStore = TerminalSessionStore()

    /// 共享性能追踪器，与 macOS 暴露同一套观测语义。
    let performanceTracer = TFPerformanceTracer()

    /// 原生终端输出目标（SwiftTerm）
    weak var terminalSink: MobileTerminalOutputSink?
    /// 终端未 ready 或尚未绑定 sink 时暂存输出，避免首屏丢数据
    private var pendingOutputChunks: [[UInt8]] = []
    private let pendingOutputChunkLimit = 128
    /// 记录最近一次已重置并开始渲染的 term_id，用于避免 SwiftUI 复用视图导致内容串台
    private var lastRenderedTermId: String = ""
    /// AI 提交结果不带 project/workspace，按触发顺序匹配
    var aiCommitPendingTaskIds: [String] = []
    /// AI 合并按 project 匹配
    var aiMergePendingTaskIdByProject: [String: String] = [:]
    /// AI 会话状态请求限流（key: project/workspace/tool/session）。
    private var aiSessionStatusRequestLimiter = AISessionStatusRequestLimiter()
    private let aiSessionStatusMinInterval: TimeInterval = 1.2
    /// WI-004：共享 AIMessageHandler 适配器，确保 iOS 通过统一协议入口接收所有 AI 消息，
    /// 与 macOS 的 AppStateAIMessageHandlerAdapter 对称，不再依赖独立 wsClient.on* 闭包。
    private var _aiHandlerAdapter: MobileAppStateAIMessageHandlerAdapter?
    /// 领域消息处理适配器强引用（防止被 WSClient weak 引用回收）
    private var _gitHandlerAdapter: MobileAppStateGitMessageHandlerAdapter?
    private var _projectHandlerAdapter: MobileAppStateProjectMessageHandlerAdapter?
    private var _fileHandlerAdapter: MobileAppStateFileMessageHandlerAdapter?
    private var _terminalHandlerAdapter: MobileAppStateTerminalMessageHandlerAdapter?
    private var _evolutionHandlerAdapter: MobileAppStateEvolutionMessageHandlerAdapter?
    private var _evidenceHandlerAdapter: MobileAppStateEvidenceMessageHandlerAdapter?
    private var _errorHandlerAdapter: MobileAppStateErrorMessageHandlerAdapter?
    /// 工作区缓存可观测性指标（Core 权威输出，按 "project:workspace" 隔离）
    /// 由 onSystemSnapshot 回调更新，macOS 与 iOS 语义对齐，不在客户端本地推导。
    private(set) var workspaceCacheMetrics: SystemSnapshotCacheMetrics = SystemSnapshotCacheMetrics(index: [:])
    /// AI Chat：等待会话创建完成后的待发送请求（含上下文防串台）
    private var aiPendingSendRequest: (
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        kind: PendingAIRequestKind
    )?
    /// 项目命令 started/completed 路由（project|workspace|commandId -> taskId 队列）
    var projectCommandPendingTaskIdsByKey: [String: [String]] = [:]
    /// 项目命令 remote task_id -> 本地 taskId
    var projectCommandTaskIdByRemoteTaskId: [String: String] = [:]
    /// Evolution 阶段聊天回放请求
    var evolutionReplayRequest: (
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String,
        cycleId: String,
        stage: String
    )?
    private var subAgentViewerRequest: (
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    )?
    /// 当前详情页选中的项目名（兼容旧接口）
    var selectedProjectName: String = ""

    /// 当前选中工作区的名称（由导航传入，用于构建 WorkspaceIdentity）
    private var selectedWorkspaceName: String = ""

    /// 跨平台工作区视图状态机（与 macOS AppState 共享同一套状态迁移语义）。
    /// iOS 端在进入 WorkspaceDetailView 时通过 `selectWorkspaceContext(project:workspace:)` 驱动状态机，
    /// 外部读取器通过 `workspaceViewStateMachine.selected` 获取当前选中状态。
    let workspaceViewStateMachine = WorkspaceViewStateMachine()

    /// 当前选中的工作区身份标识（共享语义层），与 macOS 的 `selectedWorkspaceIdentity` 对齐。
    /// iOS 端在进入 WorkspaceDetailView 时通过 `selectWorkspaceContext(project:workspace:)` 设置。
    var selectedWorkspaceIdentity: WorkspaceIdentity? {
        guard !selectedProjectName.isEmpty, !selectedWorkspaceName.isEmpty else { return nil }
        // iOS 端项目无 UUID（使用 ProjectInfo 而非 ProjectModel），以名称哈希生成 deterministic UUID
        let projectId = deterministicProjectUUID(for: selectedProjectName)
        return WorkspaceIdentity(
            projectId: projectId,
            projectName: selectedProjectName,
            workspaceName: selectedWorkspaceName
        )
    }

    /// 设置当前工作区上下文（从 WorkspaceDetailView / 终端页进入时调用）。
    /// 集中管理选中态更新，同步驱动共享状态机，避免在视图层各自反推。
    func selectWorkspaceContext(project: String, workspace: String) {
        let isSwitch = selectedProjectName != project || selectedWorkspaceName != workspace
        selectedProjectName = project
        selectedWorkspaceName = workspace
        workspaceViewStateMachine.apply(.select(
            projectName: project,
            workspaceName: workspace,
            projectId: nil  // iOS 不携带 UUID
        ))
        // 工作区切换时强制重置 AI 聊天舞台，防止旧工作区的 active/resuming 投影到新上下文
        if isSwitch {
            forceResetAIChatStage()
            // 清理旧工作区的 AI 上下文投影残留
            cleanupOldAIContextProjection()
        }
    }
    /// 资源管理器预览请求（用于过滤过期回调）
    var pendingExplorerPreviewRequest: (project: String, workspace: String, path: String)?

    /// AI Chat 待发送请求类型
    private enum PendingAIRequestKind {
        case message(
            text: String,
            imageParts: [[String: Any]]?,
            model: [String: String]?,
            agent: String?,
            fileRefs: [String]?
        )
        case command(
            command: String,
            arguments: String,
            imageParts: [[String: Any]]?,
            model: [String: String]?,
            agent: String?,
            fileRefs: [String]?
        )
    }

    let wsClient = WSClient()
    /// 重连任务（指数退避）
    private var reconnectTask: Task<Void, Never>?
    init() {
        setupWSCallbacks()
        configureAIStorePerformance(aiChatStore)
        configureAIStorePerformance(subAgentViewerStore)
        for tool in AIChatTool.allCases {
            aiSessionsByTool[tool] = []
            aiSlashCommandsByTool[tool] = []
            aiSlashCommandsBySessionByTool[tool] = [:]
            aiSessionConfigOptionsByTool[tool] = []
            aiSelectedConfigOptionsByTool[tool] = [:]
            aiSelectedModelVariantByTool[tool] = nil
            aiPendingSessionSelectionHintsByTool[tool] = [:]
        }
        loadEvolutionDefaultProfiles()
        if Self.uiTestModeEnabled {
            ConnectionStorage.clear()
            hasSavedConnection = false
            return
        }
        // 恢复已保存的连接信息
        if let saved = ConnectionStorage.load() {
            host = saved.host
            port = "\(saved.port)"
            deviceName = saved.deviceName
            useHTTPS = saved.useHTTPS
            hasSavedConnection = true
        }
    }

    // MARK: - 前后台生命周期

    /// 进入后台时标记连接为 stale，确保回到前台时能正确触发探活/重连
    func handleEnterBackground() {
        guard !wsClient.isIntentionalDisconnect else { return }
        if Self.perfTerminalAutoDetachEnabled, !currentTermId.isEmpty {
            terminalSessionStore.recordDetachRequest(termId: currentTermId)
            wsClient.requestTermDetach(termId: currentTermId)
        }
        wsClient.markStaleIfConnected()
    }

    /// 回到前台：探活 → 重连 → 恢复键盘焦点
    func handleReturnToForeground() {
        // 恢复终端键盘焦点（无论连接状态，先让键盘弹出来）
        terminalSink?.focusTerminal()

        guard hasSavedConnection, !wsClient.isIntentionalDisconnect else { return }
        // 使用共享语义层：配对失败或重连耗尽时不自动重连，需用户手动介入
        guard connectionPhase.allowsAutoReconnect || connectionPhase.isConnected else { return }

        if wsClient.isStale || !isConnected {
            // 后台回来或已断开，直接重连
            reconnectWithBackoff()
            return
        }

        // 看起来还连着，ping 一下确认
        wsClient.sendPing(timeout: 2.0) { [weak self] alive in
            guard let self else { return }
            if alive {
                // 连接正常，重新附着终端输出（后台期间可能丢失订阅）
                self.reattachTerminalIfNeeded()
            } else {
                // ping 超时，连接已死
                self.reconnectWithBackoff()
            }
        }
    }

    /// 重连成功后或 ping 存活时，重新附着当前终端的输出订阅
    private func reattachTerminalIfNeeded() {
        guard !currentTermId.isEmpty else { return }
        terminalSessionStore.recordAttachRequest(termId: currentTermId)
        wsClient.requestTermAttach(termId: currentTermId)
    }

    // MARK: - 连接

    func pairAndConnect() async {
        errorMessage = ""
        connectionMessage = ""
        connecting = true
        defer { connecting = false }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            errorMessage = "请填写电脑地址"
            return
        }
        guard let portValue = Int(port), portValue > 0, portValue <= 65535 else {
            errorMessage = "端口无效"
            return
        }
        guard trimmedCode.count == 6 else {
            errorMessage = "配对码必须是 6 位数字"
            return
        }

        do {
            let token = try await exchangePairCode(
                host: trimmedHost,
                port: portValue,
                pairCode: trimmedCode,
                deviceName: trimmedDeviceName.isEmpty ? "iOS Device" : trimmedDeviceName,
                secure: useHTTPS
            )

            wsClient.disconnect()
            wsClient.updateAuthToken(token.wsToken)
            wsClient.updateBaseURL(
                AppConfig.makeWsURL(host: trimmedHost, port: portValue, token: token.wsToken, secure: useHTTPS),
                reconnect: false
            )
            wsClient.connect()
            connectionPhase = .connecting
            connectionMessage = "已配对，正在连接..."

            // 保存连接信息
            ConnectionStorage.save(SavedConnection(
                host: trimmedHost,
                port: portValue,
                wsToken: token.wsToken,
                deviceName: trimmedDeviceName.isEmpty ? "iOS Device" : trimmedDeviceName,
                savedAt: Date(),
                useHTTPS: useHTTPS
            ))
            hasSavedConnection = true
        } catch {
            connectionPhase = .pairingFailed(reason: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        cancelReconnect()
        wsClient.disconnect()
        connectionPhase = .intentionallyDisconnected
        currentTermId = ""
        setCtrlArmed(false)
        connectionMessage = "已断开"
    }

    /// 使用保存的 token 自动重连
    func autoReconnect() async {
        guard let saved = ConnectionStorage.load() else { return }
        errorMessage = ""
        connectionMessage = "正在自动连接..."
        autoConnecting = true
        defer { autoConnecting = false }

        wsClient.disconnect()
        wsClient.updateAuthToken(saved.wsToken)
        wsClient.updateBaseURL(
            AppConfig.makeWsURL(host: saved.host, port: saved.port, token: saved.wsToken, secure: saved.useHTTPS),
            reconnect: false
        )
        wsClient.connect()
        connectionPhase = .connecting

        // 等待连接结果，超时 5 秒
        let deadline = Date().addingTimeInterval(5)
        while !connectionPhase.isConnected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !connectionPhase.isConnected {
            connectionPhase = .intentionallyDisconnected
            connectionMessage = "自动连接超时，请手动配对"
        }
    }

    /// 使用指数退避重连（共享 ReconnectPolicy：5 次尝试，退避 0.5s/1s/2s/4s/8s）
    func reconnectWithBackoff() {
        // 配对失败或重连耗尽状态不应自动重连，需用户手动介入
        guard connectionPhase.allowsAutoReconnect || connectionPhase.isReconnecting else { return }
        reconnectTask?.cancel()

        reconnectTask = Task { [weak self] in
            guard let self else { return }

            let maxAttempts = ReconnectPolicy.maxAttempts

            for attempt in 1...maxAttempts {
                if Task.isCancelled { return }

                await MainActor.run {
                    self.connectionPhase = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
                }

                guard let saved = ConnectionStorage.load() else {
                    await MainActor.run {
                        self.connectionPhase = .reconnectFailed
                    }
                    return
                }

                await MainActor.run {
                    self.wsClient.disconnect()
                }

                // 等待旧连接完全清理
                try? await Task.sleep(nanoseconds: UInt64(ReconnectPolicy.disconnectDrainDelay * 1_000_000_000))

                await MainActor.run {
                    self.wsClient.updateAuthToken(saved.wsToken)
                    self.wsClient.updateBaseURL(
                        AppConfig.makeWsURL(host: saved.host, port: saved.port, token: saved.wsToken, secure: saved.useHTTPS),
                        reconnect: false
                    )
                    self.wsClient.connect()
                }

                // 等待连接结果，每轮最多等待 perAttemptTimeout 秒
                let pollDeadline = Date().addingTimeInterval(ReconnectPolicy.perAttemptTimeout)
                while !Task.isCancelled {
                    let connected = await MainActor.run { self.connectionPhase.isConnected }
                    if connected {
                        return
                    }
                    if Date() >= pollDeadline { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }

                if Task.isCancelled { return }

                // 如果还有下一次尝试，等待指数退避时间
                if attempt < maxAttempts {
                    let delay = ReconnectPolicy.delay(for: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }

            // 所有尝试都失败
            await MainActor.run {
                self.connectionPhase = .reconnectFailed
            }
        }
    }

    /// 重置状态并重新开始指数退避重连
    func retryReconnect() {
        connectionPhase = .intentionallyDisconnected
        reconnectWithBackoff()
    }

    /// 取消正在进行的重连任务
    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionPhase = .intentionallyDisconnected
    }

    /// 清除保存的连接信息
    func clearSavedConnection() {
        ConnectionStorage.clear()
        hasSavedConnection = false
    }

    // MARK: - 项目/工作空间

    /// 刷新项目树（项目、工作空间、终端、设置、任务历史）
    func refreshProjectTree() {
        wsClient.requestListProjects()
        wsClient.requestTermList()
        wsClient.requestGetClientSettings()
        wsClient.requestListTasks()
    }

    func saveClientSettings() {
        let payload = ClientSettings(
            customCommands: customCommands,
            workspaceShortcuts: workspaceShortcuts,
            mergeAIAgent: mergeAIAgent,
            fixedPort: clientFixedPort,
            remoteAccessEnabled: clientRemoteAccessEnabled,
            evolutionDefaultProfiles: evolutionDefaultProfiles,
            evolutionAgentProfiles: [:],
            workspaceTodos: workspaceTodosByKey,
            keybindings: keybindings
        )
        wsClient.requestSaveClientSettings(settings: payload)
    }

    func selectProject(_ projectName: String) {
        selectedProjectName = projectName
        workspaces = []
        wsClient.requestListWorkspaces(project: projectName)
        wsClient.requestTermList()
    }

    /// 工作空间详情页刷新
    func refreshWorkspaceDetail(project: String, workspace: String) {
        let perfTraceId = performanceTracer.begin(TFPerformanceContext(
            event: .workspaceSwitch,
            project: project,
            workspace: workspace
        ))
        wsClient.requestTermList()
        wsClient.requestGitStatus(project: project, workspace: workspace)
        wsClient.requestGitBranches(project: project, workspace: workspace)
        fetchExplorerFileList(project: project, workspace: workspace, path: ".")
        performanceTracer.end(perfTraceId)
    }

    /// 懒加载项目工作空间
    func requestWorkspacesIfNeeded(project: String) {
        if workspacesByProject[project] == nil {
            wsClient.requestListWorkspaces(project: project)
        }
    }

    // MARK: - 资源管理器

    func prepareExplorer(project: String, workspace: String) {
        fetchExplorerFileList(project: project, workspace: workspace, path: ".")
    }

    func refreshExplorer(project: String, workspace: String) {
        let prefix = explorerCachePrefix(project: project, workspace: workspace)
        let expandedPaths = explorerDirectoryExpandState
            .filter { $0.key.hasPrefix(prefix) && $0.value }
            .map { String($0.key.dropFirst(prefix.count)) }

        fetchExplorerFileList(project: project, workspace: workspace, path: ".", cacheMode: .forceRefresh)
        for path in expandedPaths where path != "." {
            fetchExplorerFileList(project: project, workspace: workspace, path: path, cacheMode: .forceRefresh)
        }
    }

    func explorerListCache(project: String, workspace: String, path: String) -> FileListCache? {
        explorerFileListCache[explorerCacheKey(project: project, workspace: workspace, path: path)]
    }

    /// 为资源管理器条目语义解析提供按工作区隔离的 Git 状态索引。
    /// 从当前工作区的 Git 详细状态（staged + unstaged）构建，保证多项目不互相串扰。
    func explorerGitStatusIndex(project: String, workspace: String) -> GitStatusIndex {
        let detail = gitDetailStateForWorkspace(project: project, workspace: workspace)
        let allItems = detail.stagedItems + detail.unstagedItems
        return GitStatusIndex(fromItems: allItems)
    }

    func fetchExplorerFileList(
        project: String,
        workspace: String,
        path: String = ".",
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        guard isConnected else {
            let key = explorerCacheKey(project: project, workspace: workspace, path: path)
            var cache = explorerFileListCache[key] ?? FileListCache.empty()
            cache.isLoading = false
            cache.error = "连接已断开"
            explorerFileListCache[key] = cache
            return
        }

        let key = explorerCacheKey(project: project, workspace: workspace, path: path)
        let perfEvent: TFPerformanceEvent = path == "." ? .fileTreeRequest : .fileTreeExpand
        let perfTraceId = performanceTracer.begin(TFPerformanceContext(
            event: perfEvent,
            project: project,
            workspace: workspace,
            metadata: ["path": path]
        ))
        let now = Date()
        if let lastSentAt = explorerFileRequestLastSentAt[key],
           now.timeIntervalSince(lastSentAt) < 0.35,
           explorerFileListCache[key]?.isLoading == true {
            performanceTracer.end(perfTraceId)
            return
        }
        var cache = explorerFileListCache[key] ?? FileListCache.empty()
        cache.isLoading = true
        cache.error = nil
        explorerFileListCache[key] = cache
        explorerFileRequestLastSentAt[key] = now
        wsClient.requestFileList(project: project, workspace: workspace, path: path, cacheMode: cacheMode)
        performanceTracer.end(perfTraceId)
    }

    func isExplorerDirectoryExpanded(project: String, workspace: String, path: String) -> Bool {
        explorerDirectoryExpandState[explorerCacheKey(project: project, workspace: workspace, path: path)] ?? false
    }

    func toggleExplorerDirectory(project: String, workspace: String, path: String) {
        let key = explorerCacheKey(project: project, workspace: workspace, path: path)
        let next = !(explorerDirectoryExpandState[key] ?? false)
        explorerDirectoryExpandState[key] = next
        guard next else { return }

        let cache = explorerFileListCache[key]
        if cache == nil || cache?.isExpired == true {
            fetchExplorerFileList(project: project, workspace: workspace, path: path)
        }
    }

    func createExplorerFile(project: String, workspace: String, parentDir: String, fileName: String) {
        guard isConnected else {
            errorMessage = "连接已断开"
            return
        }
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let filePath = parentDir == "." ? trimmed : "\(parentDir)/\(trimmed)"
        wsClient.requestFileWrite(project: project, workspace: workspace, path: filePath, content: Data())
    }

    func renameExplorerFile(project: String, workspace: String, path: String, newName: String) {
        guard isConnected else {
            errorMessage = "连接已断开"
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wsClient.requestFileRename(project: project, workspace: workspace, oldPath: path, newName: trimmed)
    }

    func deleteExplorerFile(project: String, workspace: String, path: String) {
        guard isConnected else {
            errorMessage = "连接已断开"
            return
        }
        wsClient.requestFileDelete(project: project, workspace: workspace, path: path)
    }

    func readFileForPreview(project: String, workspace: String, path: String) {
        guard isConnected else {
            errorMessage = "连接已断开"
            return
        }
        explorerPreviewPresented = true
        explorerPreviewLoading = true
        explorerPreviewPath = path
        explorerPreviewContent = ""
        explorerPreviewError = nil
        pendingExplorerPreviewRequest = (project, workspace, path)
        wsClient.requestFileRead(project: project, workspace: workspace, path: path)
    }

    func requestEvolutionPlanDocument(project: String, workspace: String, cycleID: String) {
        guard isConnected else {
            evolutionPlanDocumentError = "连接已断开"
            return
        }
        let path = ".tidyflow/evolution/\(cycleID)/plan.md"
        evolutionPlanDocumentContent = nil
        evolutionPlanDocumentLoading = true
        evolutionPlanDocumentError = nil
        pendingPlanDocumentReadPath = path
        wsClient.requestFileRead(project: project, workspace: workspace, path: path)
    }

    func requestEvolutionCycleHistory(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoListCycleHistory(project: project, workspace: normalizedWorkspace)
    }

    func requestEvolutionSnapshot(project: String? = nil, workspace: String? = nil) {
        let normalizedWorkspace = workspace.map { normalizeEvolutionWorkspaceName($0) }
        wsClient.requestEvoSnapshot(project: project, workspace: normalizedWorkspace)
    }

    func workspacesForProject(_ project: String) -> [WorkspaceInfo] {
        workspacesByProject[project] ?? []
    }

    func defaultWorkspaceForProject(_ project: String) -> WorkspaceInfo? {
        WorkspaceSelectionSemantics.defaultWorkspace(
            workspacesForProject(project),
            nameExtractor: \.name
        )
    }

    func sidebarVisibleWorkspacesForProject(_ project: String) -> [WorkspaceInfo] {
        WorkspaceSelectionSemantics.sidebarVisibleWorkspaces(
            workspacesForProject(project),
            nameExtractor: \.name
        )
    }

    func projectCommands(for project: String) -> [ProjectCommand] {
        projects.first(where: { $0.name == project })?.commands ?? []
    }

    /// 自动分配的工作空间快捷键（按终端首次打开时间）
    var autoWorkspaceShortcuts: [String: String] {
        let sorted = workspaceTerminalOpenTime.sorted { $0.value < $1.value }.prefix(9)
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        var result: [String: String] = [:]
        for (index, item) in sorted.enumerated() {
            result[keys[index]] = item.key
        }
        return result
    }

    func getWorkspaceShortcutKey(workspaceKey: String) -> String? {
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
        for (shortcut, key) in autoWorkspaceShortcuts where key == globalKey {
            return shortcut
        }
        return nil
    }

    /// iOS 侧与 macOS 共享的项目排序策略（委托到 ProjectSortingSemantics）。
    var sortedProjectsForSidebar: [ProjectInfo] {
        ProjectSortingSemantics.sortedProjects(
            projects,
            shortcutKeyFinder: { self.projectMinShortcutKey($0) },
            earliestTerminalTimeFinder: { self.projectEarliestTerminalTime($0) },
            nameExtractor: { $0.name }
        )
    }

    /// 获取指定项目+工作空间的活跃终端
    /// 通过共享语义层过滤并排序指定工作区的活跃终端，与 macOS 保持一致的置顶与稳定排序语义
    func terminalsForWorkspace(project: String, workspace: String) -> [TerminalSessionInfo] {
        TerminalSessionSemantics.terminalsForWorkspace(
            project: project,
            workspace: workspace,
            allTerminals: activeTerminals,
            pinnedIds: terminalSessionStore.pinnedIds
        )
    }

    func terminalPresentation(for termId: String) -> (icon: String, name: String, isPinned: Bool)? {
        guard let info = terminalSessionStore.displayInfo(for: termId) else { return nil }
        return (info.icon, info.name, info.isPinned)
    }

    func isTerminalPinned(termId: String) -> Bool {
        terminalSessionStore.isPinned(termId: termId)
    }

    func toggleTerminalPinned(termId: String) {
        terminalSessionStore.togglePinned(termId: termId)
    }

    func closeOtherTerminals(project: String, workspace: String, keepTermId: String) {
        let terminals = terminalsForWorkspace(project: project, workspace: workspace)
        for term in terminals where term.termId != keepTermId && !terminalSessionStore.isPinned(termId: term.termId) {
            closeTerminal(termId: term.termId)
        }
    }

    func closeTerminalsToRight(project: String, workspace: String, termId: String) {
        let terminals = terminalsForWorkspace(project: project, workspace: workspace)
        guard let index = terminals.firstIndex(where: { $0.termId == termId }) else { return }
        let right = terminals.suffix(from: terminals.index(after: index))
        for term in right where !terminalSessionStore.isPinned(termId: term.termId) {
            closeTerminal(termId: term.termId)
        }
    }

    /// 从共享语义快照派生工作区 Git 摘要，消除 workspaceGitSummary 的独立状态维护
    func gitSummaryForWorkspace(project: String, workspace: String) -> MobileWorkspaceGitSummary {
        let snapshot = gitDetailStateForWorkspace(project: project, workspace: workspace).semanticSnapshot
        return MobileWorkspaceGitSummary(
            additions: snapshot.totalAdditions,
            deletions: snapshot.totalDeletions,
            defaultBranch: snapshot.defaultBranch
        )
    }

    func gitDetailStateForWorkspace(project: String, workspace: String) -> MobileWorkspaceGitDetailState {
        workspaceGitDetailState[globalWorkspaceKey(project: project, workspace: workspace)] ??
        MobileWorkspaceGitDetailState.empty()
    }

    /// 向 Core 请求指定工作区的 Git 状态与分支列表
    func fetchGitDetailForWorkspace(project: String, workspace: String) {
        wsClient.requestGitStatus(project: project, workspace: workspace)
        wsClient.requestGitBranches(project: project, workspace: workspace)
    }

    /// Git 暂存操作
    func gitStage(project: String, workspace: String, path: String?, scope: String) {
        wsClient.requestGitStage(project: project, workspace: workspace, path: path, scope: scope)
    }

    /// Git 取消暂存操作
    func gitUnstage(project: String, workspace: String, path: String?, scope: String) {
        wsClient.requestGitUnstage(project: project, workspace: workspace, path: path, scope: scope)
    }

    /// Git 丢弃更改操作
    func gitDiscard(project: String, workspace: String, path: String?, scope: String) {
        wsClient.requestGitDiscard(project: project, workspace: workspace, path: path, scope: scope)
    }

    /// Git 提交操作
    func gitCommit(project: String, workspace: String, message: String) {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        var state = workspaceGitDetailState[key] ?? MobileWorkspaceGitDetailState.empty()
        state.isCommitting = true
        state.commitResult = nil
        workspaceGitDetailState[key] = state
        wsClient.requestGitCommit(project: project, workspace: workspace, message: message)
    }

    func tasksForWorkspace(project: String, workspace: String) -> [WorkspaceTaskItem] {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        return taskStore.allTasks(for: key).sorted { lhs, rhs in
            if lhs.status.sortWeight != rhs.status.sortWeight {
                return lhs.status.sortWeight < rhs.status.sortWeight
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func runningTasksForWorkspace(project: String, workspace: String) -> [WorkspaceTaskItem] {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        return taskStore.activeTasks(for: key)
    }

    func taskForWorkspace(project: String, workspace: String, taskID: String) -> WorkspaceTaskItem? {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        return taskStore.allTasks(for: key).first { $0.id == taskID }
    }

    func todosForWorkspace(project: String, workspace: String) -> [WorkspaceTodoItem] {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        return WorkspaceTodoStore.items(for: key, in: workspaceTodosByKey)
    }

    func pendingTodoCountForWorkspace(project: String, workspace: String) -> Int {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        return WorkspaceTodoStore.pendingCount(for: key, in: workspaceTodosByKey)
    }

    @discardableResult
    func addWorkspaceTodo(
        project: String,
        workspace: String,
        title: String,
        note: String?,
        status: WorkspaceTodoStatus = .pending
    ) -> WorkspaceTodoItem? {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        var storage = workspaceTodosByKey
        let created = WorkspaceTodoStore.add(
            workspaceKey: key,
            title: title,
            note: note,
            status: status,
            storage: &storage
        )
        guard created != nil else { return nil }
        workspaceTodosByKey = storage
        saveClientSettings()
        return created
    }

    @discardableResult
    func updateWorkspaceTodo(
        project: String,
        workspace: String,
        todoID: String,
        title: String,
        note: String?
    ) -> Bool {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        var storage = workspaceTodosByKey
        let updated = WorkspaceTodoStore.update(
            workspaceKey: key,
            todoID: todoID,
            title: title,
            note: note,
            storage: &storage
        )
        guard updated else { return false }
        workspaceTodosByKey = storage
        saveClientSettings()
        return true
    }

    @discardableResult
    func deleteWorkspaceTodo(project: String, workspace: String, todoID: String) -> Bool {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        var storage = workspaceTodosByKey
        let removed = WorkspaceTodoStore.remove(
            workspaceKey: key,
            todoID: todoID,
            storage: &storage
        )
        guard removed else { return false }
        workspaceTodosByKey = storage
        saveClientSettings()
        return true
    }

    @discardableResult
    func setWorkspaceTodoStatus(
        project: String,
        workspace: String,
        todoID: String,
        status: WorkspaceTodoStatus
    ) -> Bool {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        var storage = workspaceTodosByKey
        let changed = WorkspaceTodoStore.setStatus(
            workspaceKey: key,
            todoID: todoID,
            status: status,
            storage: &storage
        )
        guard changed else { return false }
        workspaceTodosByKey = storage
        saveClientSettings()
        return true
    }

    func moveWorkspaceTodos(
        project: String,
        workspace: String,
        status: WorkspaceTodoStatus,
        fromOffsets: IndexSet,
        toOffset: Int
    ) {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        var storage = workspaceTodosByKey
        WorkspaceTodoStore.move(
            workspaceKey: key,
            status: status,
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            storage: &storage
        )
        workspaceTodosByKey = storage
        saveClientSettings()
    }

    func hasWorkspaceStreamingChat(project: String, workspace: String) -> Bool {
        let prefix = "\(project)::\(workspace)::"
        for tool in AIChatTool.allCases {
            if let statuses = aiSessionStatusesByTool[tool],
               statuses.contains(where: { $0.key.hasPrefix(prefix) && $0.value.isActive }) {
                return true
            }
        }
        if aiActiveProject == project, aiActiveWorkspace == workspace {
            return aiIsStreaming || aiIsSendingPending || aiAbortPendingSessionId != nil
        }
        return false
    }

    func workspaceAIStatus(project: String, workspace: String) -> AISessionStatusSnapshot? {
        let prefix = "\(project)::\(workspace)::"
        var snapshots: [AISessionStatusSnapshot] = []
        for tool in AIChatTool.allCases {
            if let statuses = aiSessionStatusesByTool[tool] {
                snapshots.append(contentsOf: statuses
                    .filter { $0.key.hasPrefix(prefix) }
                    .map(\.value))
            }
        }
        guard !snapshots.isEmpty else { return nil }
        if let active = snapshots.first(where: { $0.isActive }) { return active }
        if let failure = snapshots.first(where: { $0.isError }) { return failure }
        if let success = snapshots.first(where: { $0.normalizedStatus == "success" }) { return success }
        if let cancelled = snapshots.first(where: { $0.normalizedStatus == "cancelled" }) { return cancelled }
        return snapshots.first
    }

    func hasWorkspaceActiveEvolutionLoop(project: String, workspace: String) -> Bool {
        guard let item = evolutionItem(project: project, workspace: workspace) else { return false }
        let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["queued", "running", "pending", "in_progress", "processing"].contains(status)
    }

    func activeTaskIconForWorkspace(project: String, workspace: String) -> String? {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        return taskStore.sidebarActiveIconName(for: key)
    }

    func canCancelTask(_ task: WorkspaceTaskItem) -> Bool {
        task.status.isActive
    }

    func canCancelTask(project: String, workspace: String, taskID: String) -> Bool {
        guard let task = taskForWorkspace(project: project, workspace: workspace, taskID: taskID) else {
            return false
        }
        return canCancelTask(task)
    }

    func cancelTask(_ task: WorkspaceTaskItem) {
        guard canCancelTask(task) else { return }

        switch task.type {
        case .projectCommand:
            if let commandId = task.commandId {
                wsClient.requestCancelProjectCommand(
                    project: task.project,
                    workspace: task.workspace,
                    commandId: commandId,
                    taskId: task.remoteTaskId
                )
            }
        case .aiCommit:
            wsClient.requestCancelAITask(
                project: task.project,
                workspace: task.workspace,
                operationType: "ai_commit"
            )
        case .aiMerge:
            wsClient.requestCancelAITask(
                project: task.project,
                workspace: task.workspace,
                operationType: "ai_merge"
            )
        }

        mutateTask(task.id) { item in
            item.status = .cancelled
            item.message = "已取消"
            item.completedAt = Date()
        }
    }

    func cancelTask(project: String, workspace: String, taskID: String) {
        guard let task = taskForWorkspace(project: project, workspace: workspace, taskID: taskID) else {
            return
        }
        cancelTask(task)
    }

    /// 清除指定工作空间的已完成任务
    func clearCompletedTasks(project: String, workspace: String) {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        taskStore.clearCompleted(for: key)
    }

    // MARK: - 统一重试

    /// 重试失败的后台任务。使用 `RetryDescriptor` 中的归属键路由到正确的 project/workspace，
    /// 不依赖当前选中工作区，与 macOS 共享同一套重试判定逻辑。
    func retryTask(descriptor: RetryDescriptor) {
        switch descriptor.taskType {
        case .aiCommit:
            runAICommit(project: descriptor.project, workspace: descriptor.workspace)
        case .aiMerge:
            runAIMerge(project: descriptor.project, workspace: descriptor.workspace)
        case .projectCommand:
            guard let commandId = descriptor.commandId else { return }
            guard let command = projectCommands(for: descriptor.project).first(where: { $0.id == commandId }) else { return }
            runProjectCommand(project: descriptor.project, workspace: descriptor.workspace, command: command)
        }
    }

    /// 重试失败的演化循环。使用描述符中的归属键路由，不依赖当前选中工作区。
    func retryEvolutionCycle(project: String, workspace: String) {
        resumeEvolution(project: project, workspace: workspace)
    }

    func runAICommit(project: String, workspace: String) {
        let task = createTask(
            project: project,
            workspace: workspace,
            type: .aiCommit,
            title: "一键提交",
            icon: "sparkles",
            message: "执行中..."
        )
        aiCommitPendingTaskIds.append(task.id)
        wsClient.requestEvoAutoCommit(project: project, workspace: workspace)
    }

    func runAIMerge(project: String, workspace: String) {
        let task = createTask(
            project: project,
            workspace: workspace,
            type: .aiMerge,
            title: "智能合并",
            icon: "cpu",
            message: "执行中..."
        )
        aiMergePendingTaskIdByProject[project] = task.id
        let summary = gitSummaryForWorkspace(project: project, workspace: workspace)
        wsClient.requestGitAIMerge(
            project: project,
            workspace: workspace,
            aiAgent: mergeAIAgent,
            defaultBranch: summary.defaultBranch ?? "main"
        )
    }

    func runProjectCommand(project: String, workspace: String, command: ProjectCommand) {
        if command.interactive {
            navigationPath.append(MobileRoute.terminal(
                project: project,
                workspace: workspace,
                command: command.command,
                commandIcon: command.icon,
                commandName: command.name
            ))
            return
        }

        let task = createTask(
            project: project,
            workspace: workspace,
            type: .projectCommand,
            title: command.name,
            icon: command.icon,
            message: "等待启动..."
        )
        mutateTask(task.id) { item in
            item.status = .pending
            item.startedAt = nil
            item.commandId = command.id
        }

        let routingKey = projectCommandRoutingKey(project: project, workspace: workspace, commandId: command.id)
        var queue = projectCommandPendingTaskIdsByKey[routingKey] ?? []
        queue.append(task.id)
        projectCommandPendingTaskIdsByKey[routingKey] = queue

        wsClient.requestRunProjectCommand(project: project, workspace: workspace, commandId: command.id)
    }

    // MARK: - Evolution

    func openEvolution(project: String, workspace: String) {
        refreshEvolution(project: project, workspace: workspace)
    }

    func refreshEvolution(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoSnapshot(project: project, workspace: normalizedWorkspace)
        // 进入页面时先立即请求一次 profile；selectors 全量返回后还会再补拉一次兜底。
        wsClient.requestEvoGetAgentProfile(project: project, workspace: normalizedWorkspace)
        requestEvolutionSelectorResources(
            project: project,
            workspace: normalizedWorkspace,
            requestProfileAfterLoaded: true
        )
    }

    func requestEvolutionSelectorResources(
        project: String,
        workspace: String,
        requestProfileAfterLoaded: Bool = false
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        beginEvolutionSelectorLoading(
            project: project,
            workspace: normalizedWorkspace,
            requestProfileAfterLoaded: requestProfileAfterLoaded
        )
        for tool in AIChatTool.allCases {
            wsClient.requestAIProviderList(projectName: project, workspaceName: normalizedWorkspace, aiTool: tool)
            wsClient.requestAIAgentList(projectName: project, workspaceName: normalizedWorkspace, aiTool: tool)
            wsClient.requestAISessionConfigOptions(
                projectName: project,
                workspaceName: normalizedWorkspace,
                aiTool: tool,
                sessionId: nil
            )
        }
    }

    func evolutionProviders(project: String, workspace: String, aiTool: AIChatTool) -> [AIProviderInfo] {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        return evolutionProvidersByWorkspace[key]?[aiTool] ?? []
    }

    func evolutionAgents(project: String, workspace: String, aiTool: AIChatTool) -> [AIAgentInfo] {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        return evolutionAgentsByWorkspace[key]?[aiTool] ?? []
    }

    func startEvolution(
        project: String,
        workspace: String,
        loopRoundLimit: Int,
        profiles: [EvolutionStageProfileInfoV2]
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        evolutionPendingActionByWorkspace[key] = "start"
        let normalizedProfiles = Self.normalizedEvolutionProfiles(profiles)
        wsClient.requestEvoStartWorkspace(
            project: project,
            workspace: normalizedWorkspace,
            priority: 0,
            loopRoundLimit: max(1, loopRoundLimit),
            stageProfiles: normalizedProfiles
        )
    }

    func stopEvolution(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoStopWorkspace(project: project, workspace: normalizedWorkspace)
    }

    func resumeEvolution(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        evolutionPendingActionByWorkspace[key] = "resume"
        wsClient.requestEvoResumeWorkspace(project: project, workspace: normalizedWorkspace)
    }

    /// WI-004：运行中动态调整循环轮次，至少支持 +1/-1
    func adjustEvolutionLoopRound(project: String, workspace: String, loopRoundLimit: Int) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoAdjustLoopRound(
            project: project,
            workspace: normalizedWorkspace,
            loopRoundLimit: loopRoundLimit
        )
    }

    func resolveEvolutionBlockers(
        project: String,
        workspace: String,
        resolutions: [EvolutionBlockerResolutionInputV2]
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoResolveBlockers(
            project: project,
            workspace: normalizedWorkspace,
            resolutions: resolutions
        )
    }

    func updateEvolutionAgentProfile(project: String, workspace: String, profiles: [EvolutionStageProfileInfoV2]) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let normalizedProfiles = Self.normalizedEvolutionProfiles(profiles)
        wsClient.requestEvoUpdateAgentProfile(
            project: project,
            workspace: normalizedWorkspace,
            stageProfiles: normalizedProfiles
        )
    }

    func evolutionProfiles(project: String, workspace: String) -> [EvolutionStageProfileInfoV2] {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        if let profiles = evolutionStageProfilesByWorkspace[key], !profiles.isEmpty {
            if let fallback = resolveEvolutionProfilesFromClientSettings(project: project, workspace: normalizedWorkspace),
               shouldPreferEvolutionProfiles(candidate: fallback, over: profiles) {
                return Self.normalizedEvolutionProfiles(fallback)
            }
            return Self.normalizedEvolutionProfiles(profiles)
        }
        if let profiles = resolveEvolutionProfilesFromClientSettings(project: project, workspace: normalizedWorkspace) {
            return Self.normalizedEvolutionProfiles(profiles)
        }
        if !evolutionDefaultProfiles.isEmpty {
            return Self.normalizedEvolutionProfiles(evolutionDefaultProfiles)
        }
        return Self.defaultEvolutionProfiles()
    }

    func evolutionItem(project: String, workspace: String) -> EvolutionWorkspaceItemV2? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        return evolutionWorkspaceItems.first {
            $0.project == project &&
                normalizeEvolutionWorkspaceName($0.workspace) == normalizedWorkspace
        }
    }

    func evolutionControlState(project: String, workspace: String) -> (
        canStart: Bool,
        canStop: Bool,
        canResume: Bool,
        isStartPending: Bool,
        isStopPending: Bool,
        isResumePending: Bool
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        if let pendingAction = evolutionPendingActionByWorkspace[key] {
            return (
                canStart: false,
                canStop: false,
                canResume: false,
                isStartPending: pendingAction == "start",
                isStopPending: pendingAction == "stop",
                isResumePending: pendingAction == "resume"
            )
        }

        let status = Self.normalizedEvolutionControlStatus(
            evolutionItem(project: project, workspace: normalizedWorkspace)?.status
        )
        switch status {
        case nil:
            return (
                canStart: true,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false
            )
        case "queued", "running":
            return (
                canStart: false,
                canStop: true,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false
            )
        case "interrupted", "stopped":
            return (
                canStart: false,
                canStop: false,
                canResume: true,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false
            )
        case "completed", "failed_exhausted", "failed_system":
            return (
                canStart: true,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false
            )
        default:
            return (
                canStart: false,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false
            )
        }
    }

    func requestEvidenceSnapshot(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        evidenceLoadingByWorkspace[key] = true
        evidenceErrorByWorkspace[key] = nil
        wsClient.requestEvidenceSnapshot(project: project, workspace: normalizedWorkspace)
    }

    func requestEvidenceRebuildPrompt(
        project: String,
        workspace: String,
        completion: @escaping (_ prompt: EvidenceRebuildPromptV2?, _ errorMessage: String?) -> Void
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        evidencePromptCompletionByWorkspace[key] = completion
        wsClient.requestEvidenceRebuildPrompt(project: project, workspace: normalizedWorkspace)
    }

    func readEvidenceItem(
        project: String,
        workspace: String,
        itemID: String,
        limit: UInt32? = 262_144,
        completion: @escaping (_ payload: (mimeType: String, content: [UInt8])?, _ errorMessage: String?) -> Void
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        if let inFlight = evidenceReadRequestByWorkspace[key],
           inFlight.itemID == itemID,
           inFlight.autoContinue {
            return
        }
        evidenceReadRequestByWorkspace[key] = MobileEvidenceReadRequestState(
            project: project,
            workspace: normalizedWorkspace,
            itemID: itemID,
            limit: limit,
            autoContinue: true,
            expectedOffset: 0,
            totalSizeBytes: nil,
            mimeType: "application/octet-stream",
            content: [],
            fullCompletion: completion,
            pageCompletion: { _, _ in }
        )
        wsClient.requestEvidenceReadItem(
            project: project,
            workspace: normalizedWorkspace,
            itemID: itemID,
            offset: 0,
            limit: limit
        )
    }

    func readEvidenceItemPage(
        project: String,
        workspace: String,
        itemID: String,
        offset: UInt64 = 0,
        limit: UInt32? = 131_072,
        completion: @escaping (_ payload: MobileEvidenceReadRequestState.PagePayload?, _ errorMessage: String?) -> Void
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        if let inFlight = evidenceReadRequestByWorkspace[key],
           inFlight.itemID == itemID,
           !inFlight.autoContinue,
           inFlight.expectedOffset == offset {
            return
        }
        evidenceReadRequestByWorkspace[key] = MobileEvidenceReadRequestState(
            project: project,
            workspace: normalizedWorkspace,
            itemID: itemID,
            limit: limit,
            autoContinue: false,
            expectedOffset: offset,
            totalSizeBytes: nil,
            mimeType: "application/octet-stream",
            content: [],
            fullCompletion: { _, _ in },
            pageCompletion: completion
        )
        wsClient.requestEvidenceReadItem(
            project: project,
            workspace: normalizedWorkspace,
            itemID: itemID,
            offset: offset,
            limit: limit
        )
    }

    func evidenceSnapshot(project: String, workspace: String) -> EvidenceSnapshotV2? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        return evidenceSnapshotsByWorkspace[key]
    }

    func isEvidenceLoading(project: String, workspace: String) -> Bool {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        return evidenceLoadingByWorkspace[key] ?? false
    }

    func evidenceError(project: String, workspace: String) -> String? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        return evidenceErrorByWorkspace[key]
    }

    func setAIChatOneShotHint(project: String, workspace: String, message: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        aiChatOneShotHintByWorkspace[key] = message
    }

    func setAIChatOneShotPrefill(project: String, workspace: String, text: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        aiChatOneShotPrefillByWorkspace[key] = text
    }

    func consumeAIChatOneShotHint(project: String, workspace: String) -> String? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        let hint = aiChatOneShotHintByWorkspace[key]
        aiChatOneShotHintByWorkspace.removeValue(forKey: key)
        return hint
    }

    func consumeAIChatOneShotPrefill(project: String, workspace: String) -> String? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        let text = aiChatOneShotPrefillByWorkspace[key]
        aiChatOneShotPrefillByWorkspace.removeValue(forKey: key)
        return text
    }

    func clearEvolutionReplay() {
        // WI-002：取消订阅旧回放会话，防止旧事件残留
        if let request = evolutionReplayRequest {
            wsClient.requestAISessionUnsubscribe(
                project: request.project,
                workspace: request.workspace,
                aiTool: request.aiTool.rawValue,
                sessionId: request.sessionId
            )
        }
        evolutionReplayRequest = nil
        evolutionReplayTitle = ""
        evolutionReplayMessages = []
        evolutionReplayError = nil
        evolutionReplayLoading = false
    }

    func openSubAgentSessionViewer(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String,
        sourceToolName: String?
    ) {
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty else { return }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        if let request = subAgentViewerRequest {
            wsClient.requestAISessionUnsubscribe(
                project: request.project,
                workspace: request.workspace,
                aiTool: request.aiTool.rawValue,
                sessionId: request.sessionId
            )
        }
        let source = (sourceToolName ?? "task").trimmingCharacters(in: .whitespacesAndNewlines)
        subAgentViewerTitle = source.isEmpty ? "子会话 · \(trimmedSessionId)" : "子会话(\(source)) · \(trimmedSessionId)"
        subAgentViewerLoading = true
        subAgentViewerError = nil
        subAgentViewerRequest = (
            project: project,
            workspace: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId
        )
        subAgentViewerStore.clearAll()
        subAgentViewerStore.setCurrentSessionId(trimmedSessionId)
        let subAgentContext = AISessionHistoryCoordinator.Context(
            project: project,
            workspace: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId
        )
        AISessionHistoryCoordinator.subscribeAndLoadRecent(
            context: subAgentContext,
            wsClient: wsClient,
            store: subAgentViewerStore
        )
        requestAISessionStatus(
            projectName: project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId,
            force: true
        )
    }

    func clearSubAgentSessionViewer() {
        if let request = subAgentViewerRequest {
            wsClient.requestAISessionUnsubscribe(
                project: request.project,
                workspace: request.workspace,
                aiTool: request.aiTool.rawValue,
                sessionId: request.sessionId
            )
        }
        subAgentViewerRequest = nil
        subAgentViewerTitle = ""
        subAgentViewerLoading = false
        subAgentViewerError = nil
        subAgentViewerStore.clearAll()
    }

    private static func evolutionStageOrder() -> [String] {
        [
            "direction",
            "plan",
            "implement_general",
            "implement_visual",
            "implement_advanced",
            "verify",
            "judge",
            "auto_commit",
        ]
    }

    private static func expandLegacyEvolutionStages(_ stage: String) -> [String] {
        let normalized = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "implement" {
            return ["implement_general", "implement_visual"]
        }
        return [normalized]
    }

    private static func normalizedEvolutionControlStatus(_ status: String?) -> String? {
        guard let status else { return nil }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func defaultEvolutionProfiles() -> [EvolutionStageProfileInfoV2] {
        evolutionStageOrder().map {
            EvolutionStageProfileInfoV2(stage: $0, aiTool: .codex, mode: nil, model: nil, configOptions: [:])
        }
    }

    private static func normalizedEvolutionProfiles(
        _ profiles: [EvolutionStageProfileInfoV2]
    ) -> [EvolutionStageProfileInfoV2] {
        if profiles.isEmpty {
            return defaultEvolutionProfiles()
        }

        let validStages = Set(evolutionStageOrder())
        var byStage: [String: EvolutionStageProfileInfoV2] = [:]
        for profile in profiles {
            let mappedStages = expandLegacyEvolutionStages(profile.stage)
            for stage in mappedStages where validStages.contains(stage) {
                if byStage[stage] != nil { continue }
                byStage[stage] = EvolutionStageProfileInfoV2(
                    stage: stage,
                    aiTool: profile.aiTool,
                    mode: profile.mode,
                    model: profile.model,
                    configOptions: profile.configOptions
                )
            }
        }

        return defaultEvolutionProfiles().map { item in
            byStage[item.stage] ?? item
        }
    }

    private func loadEvolutionDefaultProfiles() {
        evolutionDefaultProfiles = Self.defaultEvolutionProfiles()
    }

    func saveEvolutionDefaultProfiles(_ profiles: [EvolutionStageProfileInfoV2]) {
        let normalized = Self.normalizedEvolutionProfiles(profiles)
        evolutionDefaultProfiles = normalized
        applyEvolutionDefaultProfilesFromCore(normalized)
        saveClientSettings()
    }

    private func applyEvolutionDefaultProfilesFromCore(_ profiles: [EvolutionStageProfileInfoV2]) {
        let normalized = profiles.isEmpty
            ? Self.defaultEvolutionProfiles()
            : Self.normalizedEvolutionProfiles(profiles)
        evolutionDefaultProfiles = normalized
    }

    private func setEvolutionProviders(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        providers: [AIProviderInfo]
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        var byTool = evolutionProvidersByWorkspace[key] ?? [:]
        byTool[aiTool] = providers
        evolutionProvidersByWorkspace[key] = byTool
    }

    private func setEvolutionAgents(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        agents: [AIAgentInfo]
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        var byTool = evolutionAgentsByWorkspace[key] ?? [:]
        byTool[aiTool] = agents
        evolutionAgentsByWorkspace[key] = byTool
    }

    private func beginEvolutionSelectorLoading(
        project: String,
        workspace: String,
        requestProfileAfterLoaded: Bool
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        var byTool: [AIChatTool: (providerLoaded: Bool, agentLoaded: Bool)] = [:]
        for tool in AIChatTool.allCases {
            byTool[tool] = (providerLoaded: false, agentLoaded: false)
        }
        evolutionSelectorLoadStateByWorkspace[key] = byTool

        if requestProfileAfterLoaded {
            evolutionPendingProfileReloadWorkspaces.insert(key)
            scheduleEvolutionProfileReloadFallback(project: project, workspace: normalizedWorkspace)
        } else {
            finishEvolutionProfileReloadTracking(project: project, workspace: normalizedWorkspace)
        }
    }

    private func markEvolutionProviderListLoaded(project: String, workspace: String, aiTool: AIChatTool) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        guard var byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        var state = byTool[aiTool] ?? (providerLoaded: false, agentLoaded: false)
        state.providerLoaded = true
        byTool[aiTool] = state
        evolutionSelectorLoadStateByWorkspace[key] = byTool
        maybeRequestEvolutionProfileAfterSelectorsReady(project: project, workspace: normalizedWorkspace)
    }

    private func markEvolutionAgentListLoaded(project: String, workspace: String, aiTool: AIChatTool) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        guard var byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        var state = byTool[aiTool] ?? (providerLoaded: false, agentLoaded: false)
        state.agentLoaded = true
        byTool[aiTool] = state
        evolutionSelectorLoadStateByWorkspace[key] = byTool
        maybeRequestEvolutionProfileAfterSelectorsReady(project: project, workspace: normalizedWorkspace)
    }

    private func maybeRequestEvolutionProfileAfterSelectorsReady(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        guard evolutionPendingProfileReloadWorkspaces.contains(key) else { return }
        guard let byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        let allReady = AIChatTool.allCases.allSatisfy { tool in
            let state = byTool[tool]
            return (state?.providerLoaded == true) && (state?.agentLoaded == true)
        }
        guard allReady else { return }
        requestEvolutionProfileIfPending(project: project, workspace: normalizedWorkspace)
    }

    private func scheduleEvolutionProfileReloadFallback(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        evolutionProfileReloadFallbackTimers[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.requestEvolutionProfileIfPending(project: project, workspace: normalizedWorkspace)
        }
        evolutionProfileReloadFallbackTimers[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func requestEvolutionProfileIfPending(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        guard evolutionPendingProfileReloadWorkspaces.contains(key) else { return }
        finishEvolutionProfileReloadTracking(project: project, workspace: normalizedWorkspace)
        wsClient.requestEvoGetAgentProfile(project: project, workspace: normalizedWorkspace)
    }

    func finishEvolutionProfileReloadTracking(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        evolutionPendingProfileReloadWorkspaces.remove(key)
        if let work = evolutionProfileReloadFallbackTimers[key] {
            work.cancel()
            evolutionProfileReloadFallbackTimers[key] = nil
        }
    }

    func normalizeEvolutionWorkspaceName(_ workspace: String) -> String {
        return WorkspaceKeySemantics.normalizeWorkspaceName(workspace)
    }

    private func consumeEvolutionReplayMessagesIfNeeded(_ ev: AISessionMessagesV2) -> Bool {
        guard let request = evolutionReplayRequest else { return false }
        guard request.project == ev.projectName,
              normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(ev.workspaceName),
              request.aiTool == ev.aiTool,
              request.sessionId == ev.sessionId else { return false }
        evolutionReplayMessages = ev.toChatMessages()
        evolutionReplayLoading = false
        evolutionReplayError = nil
        return true
    }

    private func consumeSubAgentViewerMessagesIfNeeded(_ ev: AISessionMessagesV2) -> Bool {
        guard let request = subAgentViewerRequest else { return false }
        guard request.project == ev.projectName,
              normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(ev.workspaceName),
              request.aiTool == ev.aiTool,
              request.sessionId == ev.sessionId else { return false }
        subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        subAgentViewerStore.replaceMessages(ev.toChatMessages())
        subAgentViewerLoading = false
        subAgentViewerError = nil
        return true
    }

    private func consumeSubAgentViewerMessagesUpdateIfNeeded(_ ev: AISessionMessagesUpdateV2) -> Bool {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return false }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        if subAgentViewerStore.isAbortPending(for: ev.sessionId) { return true }
        guard subAgentViewerStore.shouldApplySessionCacheRevision(
            fromRevision: ev.fromRevision,
            toRevision: ev.toRevision,
            sessionId: ev.sessionId
        ) else {
            return true
        }

        if let messages = ev.messages {
            subAgentViewerStore.replaceMessagesFromSessionCache(messages, isStreaming: ev.isStreaming)
            let restoredQuestions = AISessionSemantics.rebuildPendingQuestionRequests(
                sessionId: ev.sessionId,
                messages: messages
            )
            subAgentViewerStore.replaceQuestionRequests(restoredQuestions)
        } else if let ops = ev.ops {
            subAgentViewerStore.applySessionCacheOps(ops, isStreaming: ev.isStreaming)
        } else if !ev.isStreaming {
            subAgentViewerStore.applySessionCacheOps([], isStreaming: false)
        }
        subAgentViewerLoading = false
        subAgentViewerError = nil
        return true
    }

    private func consumeSubAgentViewerDoneIfNeeded(_ ev: AIChatDoneV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        subAgentViewerStore.handleChatDone(sessionId: ev.sessionId)
        subAgentViewerLoading = false
    }

    private func consumeSubAgentViewerErrorIfNeeded(_ ev: AIChatErrorV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        subAgentViewerStore.handleChatError(sessionId: ev.sessionId, error: ev.error)
        subAgentViewerLoading = false
        subAgentViewerError = ev.error
    }

    private func matchesSubAgentViewerContext(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> Bool {
        guard let request = subAgentViewerRequest else { return false }
        return request.project == project &&
            normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(workspace) &&
            request.aiTool == aiTool &&
            request.sessionId == sessionId
    }

    // MARK: - AI 聊天

    /// 进入 AI 聊天页面：按 project/workspace 恢复上下文并刷新服务端会话数据
    func openAIChat(project: String, workspace: String) {
        let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProject.isEmpty, !trimmedWorkspace.isEmpty else { return }

        // 通过统一生命周期入口进入聊天上下文
        enterAIChatStage(project: trimmedProject, workspace: trimmedWorkspace)
        let stageEnteredEntering = aiChatStageLifecycle.state.phase == .entering

        let contextChanged = aiActiveProject != trimmedProject || aiActiveWorkspace != trimmedWorkspace
        if contextChanged {
            saveCurrentAISnapshotIfNeeded()
            aiPendingSendRequest = nil
            aiAbortPendingSessionId = nil
            clearAISessionListPageStates()
        }

        aiActiveProject = trimmedProject
        aiActiveWorkspace = trimmedWorkspace

        if contextChanged {
            restoreAISnapshot(project: trimmedProject, workspace: trimmedWorkspace)
        } else if aiChatMessages.isEmpty {
            restoreAISnapshot(project: trimmedProject, workspace: trimmedWorkspace)
        }

        aiProviders = []
        aiSelectedModel = nil
        aiAgents = []
        aiSelectedAgent = nil
        aiSessionConfigOptions = aiSessionConfigOptionsByTool[aiChatTool] ?? []
        aiSelectedModelVariant = aiSelectedModelVariantByTool[aiChatTool] ?? nil
        refreshCurrentAISlashCommands(for: aiChatTool)
        requestAIContextResources(refreshSessionList: true)
        reloadCurrentAISessionIfNeeded()

        // 进入完成后标记就绪（如果舞台确实进入了 entering 阶段）
        if stageEnteredEntering {
            markAIChatStageReady()
        }
    }

    /// 离开 AI 聊天页面：通过共享生命周期契约关闭舞台
    func closeAIChat() {
        closeAIChatStage()
        saveCurrentAISnapshotIfNeeded()
        aiPendingSendRequest = nil
        aiAbortPendingSessionId = nil
    }

    // MARK: - AI 聊天舞台生命周期入口（iOS，与 macOS AppState+AIActions 对称）

    /// 进入 AI 聊天舞台。iOS 在打开聊天页面或选中工作区时调用。
    func enterAIChatStage(project: String, workspace: String) {
        let result = aiChatStageLifecycle.apply(.enter(
            project: project, workspace: workspace, aiTool: aiChatTool
        ))
        if case .transitioned = result {
            NSLog(
                "[MobileAppState] AI chat stage entered: project=%@, workspace=%@, tool=%@",
                project, workspace, aiChatTool.rawValue
            )
        }
    }

    /// AI 聊天舞台就绪（订阅确认已收到、消息加载完成）。
    func markAIChatStageReady() {
        aiChatStageLifecycle.apply(.ready)
    }

    /// 关闭 AI 聊天舞台。iOS 在离开聊天页面或切换工作区时调用。
    func closeAIChatStage() {
        let result = aiChatStageLifecycle.apply(.close)
        if case .transitioned = result {
            NSLog("[MobileAppState] AI chat stage closed")
        }
    }

    /// 恢复 AI 聊天舞台会话（断线重连后补拉缺失消息）。
    func resumeAIChatStage(sessionId: String) {
        let result = aiChatStageLifecycle.apply(.resume(sessionId: sessionId))
        if case .transitioned = result {
            NSLog("[MobileAppState] AI chat stage resuming: sessionId=%@", sessionId)
        }
    }

    /// AI 聊天舞台恢复完成（缺失消息补齐，流式状态同步）。
    func markAIChatStageResumeCompleted() {
        aiChatStageLifecycle.apply(.resumeCompleted)
    }

    /// 流式中断后通知 AI 聊天舞台。网络丢失或流异常时调用。
    func streamInterruptedAIChatStage(sessionId: String) {
        let result = aiChatStageLifecycle.apply(.streamInterrupted(sessionId: sessionId))
        if case .transitioned = result {
            NSLog("[MobileAppState] AI chat stage stream interrupted: sessionId=%@", sessionId)
        }
    }

    /// 强制重置 AI 聊天舞台。断开连接或不可恢复场景时调用。
    func forceResetAIChatStage() {
        let result = aiChatStageLifecycle.apply(.forceReset)
        if case .transitioned = result {
            NSLog("[MobileAppState] AI chat stage force reset")
        }
    }

    /// AI 聊天舞台加载已有会话。统一入口。
    func loadSessionInStage(sessionId: String, aiTool: AIChatTool) {
        aiChatStageLifecycle.apply(.loadSession(sessionId: sessionId, aiTool: aiTool))
    }

    /// AI 聊天舞台新建空会话。统一入口。
    func newSessionInStage() {
        aiChatStageLifecycle.apply(.newSession)
    }

    /// 判断当前舞台是否接受指定上下文的流式事件。
    func aiChatStageAcceptsEvent(project: String, workspace: String, aiTool: AIChatTool) -> Bool {
        aiChatStageLifecycle.acceptsStreamEvent(project: project, workspace: workspace, aiTool: aiTool)
    }

    /// 新建空会话（本地清空态），通过共享生命周期契约通知舞台
    func createNewAISession() {
        newSessionInStage()
        aiPendingSendRequest = nil
        aiAbortPendingSessionId = nil
        aiCurrentSessionId = nil
        aiChatStore.setCurrentSessionId(nil)
        aiChatStore.clearMessages()
    }

    var canSwitchAIChatTool: Bool {
        aiCurrentSessionId == nil &&
        aiPendingSendRequest == nil &&
        aiAbortPendingSessionId == nil &&
        !aiIsStreaming
    }

    /// 切换 AI 工具（仅空白会话允许），通过共享生命周期契约迁移舞台状态
    func switchAIChatTool(_ newTool: AIChatTool) {
        guard newTool != aiChatTool else { return }
        guard canSwitchAIChatTool else { return }

        aiChatStageLifecycle.apply(.switchTool(newTool: newTool))

        // 切换工具时清理旧工具上下文的快照和投影
        cleanupOldAIContextProjection()

        saveCurrentAISnapshotIfNeeded()
        aiPendingSendRequest = nil
        aiAbortPendingSessionId = nil
        aiChatTool = newTool

        if !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty {
            restoreAISnapshot(project: aiActiveProject, workspace: aiActiveWorkspace)
            aiProviders = []
            aiSelectedModel = nil
            aiAgents = []
            aiSelectedAgent = nil
            aiSessionConfigOptions = aiSessionConfigOptionsByTool[newTool] ?? []
            aiSelectedModelVariant = aiSelectedModelVariantByTool[newTool] ?? nil
            refreshCurrentAISlashCommands(for: newTool)
            requestAIContextResources(refreshSessionList: false)
            reloadCurrentAISessionIfNeeded()
        }

        // 切换完成后标记就绪
        markAIChatStageReady()
    }

    /// 拉取当前工具的上下文资源；仅在进入聊天上下文时刷新会话列表。
    func requestAIContextResources(refreshSessionList: Bool = true) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        if refreshSessionList {
            _ = requestAISessionList(for: sessionListFilter)
        }
        isAILoadingModels = true
        isAILoadingAgents = true
        wsClient.requestAIProviderList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: aiChatTool)
        wsClient.requestAIAgentList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: aiChatTool)
        wsClient.requestAISlashCommands(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: aiCurrentSessionId
        )
        wsClient.requestAISessionConfigOptions(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: aiCurrentSessionId
        )
    }

    func displayedAISessions(for filter: AISessionListFilter) -> [AISessionInfo] {
        sessionListPageState(for: filter).sessions
    }

    func sessionListPageState(for filter: AISessionListFilter) -> AISessionListPageState {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else {
            return .empty()
        }
        return aiSessionListStore.pageState(project: aiActiveProject, workspace: aiActiveWorkspace, filter: filter)
    }

    /// 拉取指定筛选条件的 AI 会话列表
    @discardableResult
    func requestAISessionList(
        for filter: AISessionListFilter,
        limit: Int = 50,
        cursor: String? = nil,
        append: Bool = false,
        force: Bool = false
    ) -> Bool {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else {
            return false
        }

        return aiSessionListStore.request(
            project: aiActiveProject,
            workspace: aiActiveWorkspace,
            filter: filter,
            limit: limit,
            cursor: cursor,
            append: append,
            force: force,
            performanceTracer: performanceTracer
        ) {
            wsClient.requestAISessionList(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                filter: filter.tool,
                cursor: cursor,
                limit: limit,
                cacheMode: force ? .forceRefresh : .default
            )
        }
    }

    @discardableResult
    func loadNextAISessionListPage(for filter: AISessionListFilter, limit: Int = 50) -> Bool {
        let pageState = sessionListPageState(for: filter)
        guard pageState.hasMore,
              let nextCursor = pageState.nextCursor,
              !nextCursor.isEmpty else { return false }
        return aiSessionListStore.loadNextPage(
            project: aiActiveProject,
            workspace: aiActiveWorkspace,
            filter: filter,
            limit: limit,
            performanceTracer: performanceTracer
        ) { nextCursor in
            wsClient.requestAISessionList(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                filter: filter.tool,
                cursor: nextCursor,
                limit: limit,
                cacheMode: .default
            )
        }
    }

    /// 加载指定会话消息
    func loadAISession(_ session: AISessionInfo) {
        guard session.projectName == aiActiveProject,
              session.workspaceName == aiActiveWorkspace else { return }

        let targetTool = session.aiTool
        let previousTool = aiChatTool
        let previousSessionId = aiCurrentSessionId

        // 通过统一生命周期入口通知舞台状态机加载会话
        loadSessionInStage(sessionId: session.id, aiTool: targetTool)

        if targetTool != aiChatTool {
            // 跨工具打开历史会话时，允许在“非流式/非待发/非停止中”条件下切换工具，
            // 不依赖 aiCurrentSessionId（否则会出现已选中但详情不加载）。
            guard aiPendingSendRequest == nil,
                  aiAbortPendingSessionId == nil,
                  !aiIsStreaming else { return }

            saveCurrentAISnapshotIfNeeded()
            aiPendingSendRequest = nil
            aiAbortPendingSessionId = nil
            aiChatTool = targetTool
            restoreAISnapshot(project: aiActiveProject, workspace: aiActiveWorkspace)
            aiProviders = []
            aiSelectedModel = nil
            aiAgents = []
            aiSelectedAgent = nil
            aiSessionConfigOptions = aiSessionConfigOptionsByTool[targetTool] ?? []
            aiSelectedModelVariant = aiSelectedModelVariantByTool[targetTool] ?? nil
            refreshCurrentAISlashCommands(for: targetTool)
            isAILoadingModels = true
            isAILoadingAgents = true
            wsClient.requestAIProviderList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: targetTool)
            wsClient.requestAIAgentList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: targetTool)
            wsClient.requestAISlashCommands(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: targetTool,
                sessionId: aiCurrentSessionId
            )
        }

        if let previousSessionId,
           !previousSessionId.isEmpty,
           (previousTool != targetTool || previousSessionId != session.id) {
            wsClient.requestAISessionUnsubscribe(
                project: session.projectName,
                workspace: session.workspaceName,
                aiTool: previousTool.rawValue,
                sessionId: previousSessionId
            )
            aiChatStore.removeSubscription(previousSessionId)
        }

        aiCurrentSessionId = session.id
        aiChatStore.setCurrentSessionId(session.id)
        aiChatStore.setAbortPendingSessionId(nil)
        aiChatStore.clearMessages()

        let context = AISessionHistoryCoordinator.Context(
            project: session.projectName,
            workspace: session.workspaceName,
            aiTool: targetTool,
            sessionId: session.id
        )
        AISessionHistoryCoordinator.subscribeAndLoadRecent(
            context: context,
            wsClient: wsClient,
            store: aiChatStore
        )
        wsClient.requestAISessionConfigOptions(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: targetTool,
            sessionId: session.id
        )
        wsClient.requestAISlashCommands(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: targetTool,
            sessionId: session.id
        )
        requestAISessionStatus(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: targetTool,
            sessionId: session.id,
            force: true
        )
    }

    /// 删除会话
    func deleteAISession(_ session: AISessionInfo) {
        let targetTool = session.aiTool
        wsClient.requestAISessionUnsubscribe(
            project: session.projectName,
            workspace: session.workspaceName,
            aiTool: targetTool.rawValue,
            sessionId: session.id
        )
        aiChatStore.removeSubscription(session.id)
        wsClient.requestAISessionDelete(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: targetTool,
            sessionId: session.id
        )
        if var sessions = aiSessionsByTool[targetTool] {
            sessions.removeAll { $0.sessionKey == session.sessionKey }
            setAISessions(sessions, for: targetTool)
        }
        aiSessionIndexByKey.removeValue(forKey: session.sessionKey)
        aiSessionListStore.removeSession(sessionId: session.id, tool: targetTool)
        if aiCurrentSessionId == session.id && aiChatTool == targetTool {
            aiCurrentSessionId = nil
            aiChatStore.setCurrentSessionId(nil)
            aiChatStore.setAbortPendingSessionId(nil)
            aiChatStore.clearMessages()
        }
    }

    /// 加载更早的 AI 聊天消息（历史分页）
    func loadOlderAIChatMessages() {
        guard let sessionId = aiCurrentSessionId, !sessionId.isEmpty else { return }
        let context = AISessionHistoryCoordinator.Context(
            project: aiActiveProject,
            workspace: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId
        )
        AISessionHistoryCoordinator.loadOlderPage(
            context: context,
            wsClient: wsClient,
            store: aiChatStore
        )
    }

    /// 发送消息；返回 true 表示已受理（包括本地命令）
    @discardableResult
    func sendAIMessage(text: String, imageAttachments: [ImageAttachment]) -> Bool {
        // 上一次停止尚未收敛时，不允许发新消息，避免事件串扰。
        if aiAbortPendingSessionId != nil {
            return false
        }
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageAttachments.isEmpty else { return false }

        let slashCommand = parseSlashCommand(from: text)
        let slashAction: String? = {
            guard let slashCommand else { return nil }
            return aiSlashCommands.first(where: {
                $0.name.caseInsensitiveCompare(slashCommand.name) == .orderedSame
            })?.action
        }()

        if let slashCommand {
            let resolvedAction = slashAction ?? (
                slashCommand.name.caseInsensitiveCompare("new") == .orderedSame ? "client" : "agent"
            )
            if resolvedAction == "client" {
                switch slashCommand.name.lowercased() {
                case "new":
                    createNewAISession()
                default:
                    aiChatStore.appendMessage(
                        AIChatMessage(
                            role: .assistant,
                            parts: [AIChatPart(
                                id: UUID().uuidString,
                                kind: .text,
                                text: "暂不支持本地命令：/\(slashCommand.name)",
                                toolName: nil
                            )],
                            isStreaming: false
                        )
                    )
                }
                return true
            }
        }

        let fileRefs = extractFileRefs(from: text)
        let fileRefsParam: [String]? = fileRefs.isEmpty ? nil : fileRefs
        let imageParts: [[String: Any]]? = imageAttachments.isEmpty ? nil : imageAttachments.map { img in
            [
                "filename": img.filename,
                "mime": img.mime,
                "data": img.data
            ]
        }
        let model: [String: String]? = aiSelectedModel.map {
            ["provider_id": $0.providerID, "model_id": $0.modelID]
        }
        let agentName = aiSelectedAgent
        let aiTool = aiChatTool
        let configOverrides = aiConfigOverrides(for: aiTool)

        if slashCommand == nil {
            aiChatStore.beginAwaitingUserEcho()
        } else {
            aiChatStore.beginAwaitingAssistantOnly()
        }
        aiChatStore.isStreaming = true

        if let sessionId = aiCurrentSessionId {
            AISessionHistoryCoordinator.ensureSubscribed(
                context: .init(
                    project: aiActiveProject,
                    workspace: aiActiveWorkspace,
                    aiTool: aiTool,
                    sessionId: sessionId
                ),
                wsClient: wsClient,
                store: aiChatStore
            )
            if let slash = slashCommand {
                wsClient.requestAIChatCommand(
                    projectName: aiActiveProject,
                    workspaceName: aiActiveWorkspace,
                    aiTool: aiTool,
                    sessionId: sessionId,
                    command: slash.name,
                    arguments: slash.arguments,
                    fileRefs: fileRefsParam,
                    imageParts: imageParts,
                    model: model,
                    agent: agentName,
                    configOverrides: configOverrides
                )
            } else {
                wsClient.requestAIChatSend(
                    projectName: aiActiveProject,
                    workspaceName: aiActiveWorkspace,
                    aiTool: aiTool,
                    sessionId: sessionId,
                    message: text,
                    fileRefs: fileRefsParam,
                    imageParts: imageParts,
                    model: model,
                    agent: agentName,
                    configOverrides: configOverrides
                )
            }
        } else {
            if let slash = slashCommand {
                aiPendingSendRequest = (
                    aiActiveProject,
                    aiActiveWorkspace,
                    aiTool,
                    .command(
                        command: slash.name,
                        arguments: slash.arguments,
                        imageParts: imageParts,
                        model: model,
                        agent: agentName,
                        fileRefs: fileRefsParam
                    )
                )
            } else {
                aiPendingSendRequest = (
                    aiActiveProject,
                    aiActiveWorkspace,
                    aiTool,
                    .message(
                        text: text,
                        imageParts: imageParts,
                        model: model,
                        agent: agentName,
                        fileRefs: fileRefsParam
                    )
                )
            }
            wsClient.requestAIChatStart(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: aiTool,
                title: String(text.prefix(50))
            )
        }

        return true
    }

    func requestCurrentAISessionStatus(force: Bool = false) {
        guard let sessionId = aiCurrentSessionId,
              !sessionId.isEmpty,
              !aiActiveProject.isEmpty,
              !aiActiveWorkspace.isEmpty else { return }
        requestAISessionStatus(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId,
            force: force
        )
    }

    /// 停止当前会话流式输出
    func stopAIStreaming() {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty,
              let sessionId = aiCurrentSessionId else { return }
        aiChatStore.setAbortPendingSessionId(sessionId)
        wsClient.requestAIChatAbort(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId
        )
        aiChatStore.stopStreamingLocallyAndPrunePlaceholder()
        requestCurrentAISessionStatus(force: true)

        // 兜底：若 done/error 丢失，2s 后解除 pending，避免输入区永久不可用。
        let store = aiChatStore
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if store.isAbortPending(for: sessionId) {
                store.clearAbortPendingIfMatches(sessionId)
            }
        }
    }

    func replyAIQuestion(requestId: String, sessionId: String, answers: [[String]]) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        wsClient.requestAIQuestionReply(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId,
            requestId: requestId,
            answers: answers
        )
    }

    /// iOS 侧问题卡片本地收敛：直接由 AIChatStore 执行，避免重复状态写入。
    func completeAIQuestionRequestLocally(requestId: String, answers: [[String]]? = nil) {
        aiChatStore.completeQuestionRequestLocally(requestId: requestId, answers: answers)
    }

    func rejectAIQuestion(requestId: String, sessionId: String) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        wsClient.requestAIQuestionReject(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId,
            requestId: requestId
        )
    }

    func hasCodexPlanImplementationQuestionCard(requestId: String) -> Bool {
        AIPlanImplementationQuestion.hasCard(
            messages: aiChatStore.messages,
            pendingQuestions: aiChatStore.pendingToolQuestions,
            requestID: requestId
        )
    }

    func insertCodexPlanImplementationQuestionCard(
        requestID: String,
        sessionID: String,
        planPartID: String
    ) {
        let request = AIPlanImplementationQuestion.buildRequest(
            requestID: requestID,
            sessionID: sessionID,
            planPartID: planPartID
        )
        aiChatStore.upsertQuestionRequest(request)
        aiChatStore.appendMessage(AIPlanImplementationQuestion.buildQuestionMessage(request: request, planPartID: planPartID))
    }

    func startImplementingCodexPlan() {
        let defaultAgent = resolveDefaultAgentName()
        if let agentInfo = aiAgents.first(where: { $0.name == defaultAgent }) {
            aiSelectedAgent = agentInfo.name
            applyAgentDefaultModel(agentInfo)
        } else {
            aiSelectedAgent = defaultAgent
        }
        _ = sendAIMessage(text: AIPlanImplementationQuestion.messageText, imageAttachments: [])
    }

    /// 当前上下文的文件索引（用于 @ 自动补全）
    func aiCurrentFileItems() -> [String] {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return [] }
        let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
        return aiFileIndexCache[key]?.items ?? []
    }

    /// 按需拉取文件索引；首次输入 @ 时调用
    func fetchAIFileIndexIfNeeded(force: Bool = false) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
        if !force, let cache = aiFileIndexCache[key], !cache.items.isEmpty, !cache.isExpired {
            return
        }
        var cache = aiFileIndexCache[key] ?? FileIndexCache.empty()
        cache.isLoading = true
        cache.error = nil
        aiFileIndexCache[key] = cache
        wsClient.requestFileIndex(project: aiActiveProject, workspace: aiActiveWorkspace)
    }

    /// 按关键词远端查询文件索引（用于引用弹窗搜索）
    func searchAIFileReferences(query: String) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
        var cache = aiFileIndexCache[key] ?? FileIndexCache.empty()
        cache.isLoading = true
        cache.error = nil
        aiFileIndexCache[key] = cache

        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        wsClient.requestFileIndex(
            project: aiActiveProject,
            workspace: aiActiveWorkspace,
            query: normalized.isEmpty ? nil : normalized
        )
    }

    private func reloadCurrentAISessionIfNeeded() {
        guard let sessionId = aiCurrentSessionId,
              !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        let context = AISessionHistoryCoordinator.Context(
            project: aiActiveProject,
            workspace: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId
        )
        AISessionHistoryCoordinator.subscribeAndLoadRecent(
            context: context,
            wsClient: wsClient,
            store: aiChatStore
        )
        wsClient.requestAISessionConfigOptions(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId
        )
        requestAISessionStatus(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId,
            force: true
        )
    }

    private func reloadAISessionDataAfterReconnect() {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }

        // 重连后重新进入舞台（断连时已 forceReset 到 idle）
        enterAIChatStage(project: aiActiveProject, workspace: aiActiveWorkspace)

        _ = requestAISessionList(for: sessionListFilter, force: true)

        // 若有选中会话，通过共享协调器重新订阅并补拉以恢复流式状态
        for tool in AIChatTool.allCases {
            guard let sessionId = (tool == aiChatTool ? aiCurrentSessionId : nil),
                  !sessionId.isEmpty else { continue }

            // 通知舞台进入 resuming 状态，等待 ack 后 ready
            resumeAIChatStage(sessionId: sessionId)

            let context = AISessionHistoryCoordinator.Context(
                project: aiActiveProject,
                workspace: aiActiveWorkspace,
                aiTool: tool,
                sessionId: sessionId
            )
            AISessionHistoryCoordinator.subscribeAndLoadRecent(
                context: context,
                wsClient: wsClient,
                store: aiChatStore,
                cacheMode: .forceRefresh
            )
            wsClient.requestAISessionConfigOptions(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: tool,
                sessionId: sessionId,
                cacheMode: .forceRefresh
            )
            requestAISessionStatus(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: tool,
                sessionId: sessionId,
                force: true
            )
        }
    }

    func aiContextKey(project: String, workspace: String) -> String {
        "\(project):\(workspace):\(aiChatTool.rawValue)"
    }

    private func preferredAISelectorContextForSettings() -> (project: String, workspace: String)? {
        let activeProject = aiActiveProject.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeWorkspace = aiActiveWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !activeProject.isEmpty, !activeWorkspace.isEmpty {
            return (activeProject, activeWorkspace)
        }

        for project in sortedProjectsForSidebar {
            let projectName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectName.isEmpty else { continue }
            if let workspaces = workspacesByProject[projectName], let first = workspaces.first {
                let workspaceName = first.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !workspaceName.isEmpty {
                    return (projectName, workspaceName)
                }
            }
        }

        return nil
    }

    @discardableResult
    func requestAISelectorResourcesForSettings() -> Bool {
        guard isConnected else { return false }
        guard let context = preferredAISelectorContextForSettings() else { return false }

        for tool in AIChatTool.allCases {
            settingsSelectorContextByTool[tool] = (
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
                sessionId: nil
            )
        }
        return true
    }

    private func shouldAcceptSettingsSelectorEvent(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        kind: AISelectorResourceKind
    ) -> Bool {
        guard let pending = settingsSelectorContextByTool[aiTool] else { return false }
        guard pending.project == projectName, pending.workspace == workspaceName else { return false }
        switch kind {
        case .providerList:
            return pending.providerPending
        case .agentList:
            return pending.agentPending
        }
    }

    private func consumeSettingsSelectorEventIfNeeded(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        kind: AISelectorResourceKind
    ) {
        guard var pending = settingsSelectorContextByTool[aiTool] else { return }
        guard pending.project == projectName, pending.workspace == workspaceName else { return }
        switch kind {
        case .providerList:
            pending.providerPending = false
        case .agentList:
            pending.agentPending = false
        }
        settingsSelectorContextByTool[aiTool] = pending
    }

    func settingsProviders(aiTool: AIChatTool) -> [AIProviderInfo] {
        guard let context = settingsSelectorContextByTool[aiTool] else { return [] }
        let key = globalWorkspaceKey(
            project: context.project,
            workspace: normalizeEvolutionWorkspaceName(context.workspace)
        )
        return evolutionProvidersByWorkspace[key]?[aiTool] ?? []
    }

    func settingsAgents(aiTool: AIChatTool) -> [AIAgentInfo] {
        guard let context = settingsSelectorContextByTool[aiTool] else { return [] }
        let key = globalWorkspaceKey(
            project: context.project,
            workspace: normalizeEvolutionWorkspaceName(context.workspace)
        )
        return evolutionAgentsByWorkspace[key]?[aiTool] ?? []
    }

    private func shouldAcceptAISessionConfigOptionsEvent(project: String, workspace: String) -> Bool {
        if aiActiveProject == project, aiActiveWorkspace == workspace {
            return true
        }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        if evolutionSelectorLoadStateByWorkspace[key] != nil {
            return true
        }
        if evolutionPendingProfileReloadWorkspaces.contains(key) {
            return true
        }
        if !evolutionStageProfilesByWorkspace[key, default: []].isEmpty {
            return true
        }
        return settingsSelectorContextByTool.values.contains { pending in
            pending.project == project && pending.workspace == workspace
        }
    }

    private func saveCurrentAISnapshotIfNeeded() {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
        aiChatStore.saveSnapshot(forKey: key, sessions: aiSessions)
    }

    private func restoreAISnapshot(project: String, workspace: String) {
        let key = aiContextKey(project: project, workspace: workspace)
        if let snapshot = aiChatStore.snapshot(forKey: key) {
            aiCurrentSessionId = snapshot.currentSessionId
            aiChatStore.applySnapshot(snapshot)
            aiSessions = snapshot.sessions
            return
        }
        aiCurrentSessionId = nil
        aiChatStore.clearAll()
        aiSessions = []
    }

    private func parseSlashCommand(from text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "/" || first == "／" else { return nil }
        let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if let separator = body.firstIndex(where: { $0.isWhitespace }) {
            let name = String(body[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let arguments = String(body[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, arguments)
        }
        return (body, "")
    }

    private func sendPendingAIRequest(
        _ kind: PendingAIRequestKind,
        sessionId: String,
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool
    ) {
        AISessionHistoryCoordinator.ensureSubscribed(
            context: .init(
                project: projectName,
                workspace: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId
            ),
            wsClient: wsClient,
            store: aiChatStore
        )
        switch kind {
        case let .message(text, imageParts, model, agent, fileRefs):
            let configOverrides = aiConfigOverrides(for: aiTool)
            wsClient.requestAIChatSend(
                projectName: projectName,
                workspaceName: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId,
                message: text,
                fileRefs: fileRefs,
                imageParts: imageParts,
                model: model,
                agent: agent,
                configOverrides: configOverrides
            )
        case let .command(command, arguments, imageParts, model, agent, fileRefs):
            let configOverrides = aiConfigOverrides(for: aiTool)
            wsClient.requestAIChatCommand(
                projectName: projectName,
                workspaceName: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId,
                command: command,
                arguments: arguments,
                fileRefs: fileRefs,
                imageParts: imageParts,
                model: model,
                agent: agent,
                configOverrides: configOverrides
            )
        }
    }

    func aiSessionConfigOptions(for tool: AIChatTool) -> [AIProtocolSessionConfigOptionInfo] {
        aiSessionConfigOptionsByTool[tool] ?? []
    }

    func modelVariantOptions(for tool: AIChatTool, model: AIModelSelection? = nil) -> [String] {
        if let model = model ?? (tool == aiChatTool ? aiSelectedModel : nil),
           let resolved = resolveModelVariantOptions(for: tool, model: model),
           !resolved.isEmpty {
            return resolved
        }
        if let option = aiSessionConfigOptionsByTool[tool]?.first(where: {
            normalizedConfigCategory($0.category, optionID: $0.optionID) == "model_variant"
        }) {
            let values = configOptionValues(option)
            if !values.isEmpty { return values }
        }
        if tool == .codex {
            return ["low", "medium", "high"]
        }
        return []
    }

    /// 返回当前工具的 model_variant 配置项 option_id；静态变体工具使用固定键名。
    func modelVariantOptionID(for tool: AIChatTool) -> String? {
        if let optionID = optionIDForCategory("model_variant", in: aiSessionConfigOptionsByTool[tool] ?? []) {
            return optionID
        }
        if tool == .codex || tool == .opencode {
            return "model_variant"
        }
        return nil
    }

    func modelVariantOptions() -> [String] {
        modelVariantOptions(for: aiChatTool)
    }

    func aiConfigOverrides(for tool: AIChatTool? = nil) -> [String: Any]? {
        let targetTool = tool ?? aiChatTool
        let options = aiSessionConfigOptionsByTool[targetTool] ?? []
        var overrides = aiSelectedConfigOptionsByTool[targetTool] ?? [:]

        if let modeOptionID = optionIDForCategory("mode", in: options),
           targetTool == aiChatTool,
           let selectedAgent = aiSelectedAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedAgent.isEmpty {
            overrides[modeOptionID] = selectedAgent
        }
        if let modelOptionID = optionIDForCategory("model", in: options),
           targetTool == aiChatTool,
           let selectedModel = aiSelectedModel {
            overrides[modelOptionID] = modelConfigValue(from: selectedModel)
        }
        if let variantOptionID = modelVariantOptionID(for: targetTool),
           let modelVariant = (aiSelectedModelVariantByTool[targetTool] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelVariant.isEmpty,
           modelVariantOptions(for: targetTool).contains(modelVariant) {
            overrides[variantOptionID] = modelVariant
        }
        return overrides.isEmpty ? nil : overrides
    }

    private func setAISessionConfigOptions(_ options: [AIProtocolSessionConfigOptionInfo], for tool: AIChatTool) {
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
        if tool == aiChatTool {
            if let modeOptionID = optionIDForCategory("mode", in: options),
               let selectedAgent = aiSelectedAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
               !selectedAgent.isEmpty {
                selected[modeOptionID] = selectedAgent
            }
            if let modelOptionID = optionIDForCategory("model", in: options),
               let selectedModel = aiSelectedModel {
                selected[modelOptionID] = modelConfigValue(from: selectedModel)
            }
            if let variantOptionID = modelVariantOptionID(for: tool),
               let modelVariant = aiSelectedModelVariant?.trimmingCharacters(in: .whitespacesAndNewlines),
               !modelVariant.isEmpty,
               modelVariantOptions(for: tool).contains(modelVariant) {
                selected[variantOptionID] = modelVariant
            }
        }
        selected = selected.filter { validOptionIDs.contains($0.key) }
        aiSelectedConfigOptionsByTool[tool] = selected

        refreshModelVariantFromConfig(for: tool)
        if tool == aiChatTool {
            aiSessionConfigOptions = options
        }
    }

    private func applyConfigOptionsHint(_ configOptions: [String: Any], for tool: AIChatTool) {
        guard !configOptions.isEmpty else { return }
        var selected = aiSelectedConfigOptionsByTool[tool] ?? [:]
        for (optionID, value) in configOptions {
            selected[optionID] = value
        }
        aiSelectedConfigOptionsByTool[tool] = selected

        guard tool == aiChatTool else { return }
        let optionsByID = Dictionary(uniqueKeysWithValues: (aiSessionConfigOptionsByTool[tool] ?? []).map { ($0.optionID, $0) })
        for (optionID, value) in configOptions {
            let category = normalizedConfigCategory(optionsByID[optionID]?.category, optionID: optionID)
            if category == "mode",
               let rawMode = configValueAsString(value),
               let resolvedAgent = resolveAIAgentName(rawMode) {
                aiSelectedAgent = resolvedAgent
                continue
            }
            if category == "model" {
                let providerHint = configValueAsProviderHint(value)
                if let rawModel = configValueAsModelID(value),
                   let resolvedModel = resolveAIModelSelection(modelID: rawModel, providerHint: providerHint) {
                    aiSelectedModel = resolvedModel
                }
                continue
            }
            if category == "model_variant" {
                setAISelectedModelVariant(configValueAsString(value), for: tool, syncConfigOption: false)
            }
        }
        refreshModelVariantFromConfig(for: tool)
    }

    private func setAISelectedModelVariant(
        _ value: String?,
        for tool: AIChatTool,
        syncConfigOption: Bool = true
    ) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set(modelVariantOptions(for: tool))
        let finalValue: String?
        if let normalized, !normalized.isEmpty,
           allowed.isEmpty || allowed.contains(normalized) {
            finalValue = normalized
        } else {
            finalValue = nil
        }
        aiSelectedModelVariantByTool[tool] = finalValue
        if tool == aiChatTool {
            aiSelectedModelVariant = finalValue
        }
        guard syncConfigOption,
              let optionID = modelVariantOptionID(for: tool) else {
            return
        }
        if let finalValue {
            updateConfigOptionValue(optionID: optionID, value: finalValue, for: tool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: tool)
        }
    }

    private func refreshModelVariantFromConfig(for tool: AIChatTool) {
        let options = aiSessionConfigOptionsByTool[tool] ?? []
        guard let option = options.first(where: {
            normalizedConfigCategory($0.category, optionID: $0.optionID) == "model_variant"
        }) else {
            setAISelectedModelVariant(nil, for: tool, syncConfigOption: false)
            return
        }
        let selected = aiSelectedConfigOptionsByTool[tool] ?? [:]
        let value = selected[option.optionID] ?? option.currentValue
        setAISelectedModelVariant(configValueAsString(value), for: tool, syncConfigOption: false)
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

    private func optionIDForCategory(_ category: String, in options: [AIProtocolSessionConfigOptionInfo]) -> String? {
        options.first(where: {
            normalizedConfigCategory($0.category, optionID: $0.optionID) == category
        })?.optionID
    }

    private func normalizedConfigCategory(_ category: String?, optionID: String) -> String {
        let trimmed = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !trimmed.isEmpty {
            return trimmed
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
        guard let optionID = optionIDForCategory("mode", in: aiSessionConfigOptionsByTool[aiChatTool] ?? []) else { return }
        let normalized = aiSelectedAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            updateConfigOptionValue(optionID: optionID, value: normalized, for: aiChatTool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: aiChatTool)
        }
    }

    private func syncModelConfigOptionForCurrentTool() {
        guard let optionID = optionIDForCategory("model", in: aiSessionConfigOptionsByTool[aiChatTool] ?? []) else { return }
        if let model = aiSelectedModel {
            updateConfigOptionValue(optionID: optionID, value: modelConfigValue(from: model), for: aiChatTool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: aiChatTool)
        }
    }

    private func syncModelVariantConfigOptionForCurrentTool() {
        guard let optionID = modelVariantOptionID(for: aiChatTool) else { return }
        let normalized = aiSelectedModelVariant?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            updateConfigOptionValue(optionID: optionID, value: normalized, for: aiChatTool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: aiChatTool)
        }
    }

    private func configOptionValues(_ option: AIProtocolSessionConfigOptionInfo) -> [String] {
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

    private func resolveAIAgentName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = aiAgents.first(where: { $0.name == trimmed }) {
            return exact.name
        }
        if let caseInsensitive = aiAgents.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return caseInsensitive.name
        }
        return nil
    }

    private func resolveAIModelSelection(modelID rawModelID: String, providerHint: String?) -> AIModelSelection? {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return nil }
        guard !aiProviders.isEmpty else { return nil }

        if providerHint == nil,
           let slash = modelID.firstIndex(of: "/") {
            let providerCandidate = String(modelID[..<slash]).trimmingCharacters(in: .whitespacesAndNewlines)
            let modelCandidate = String(modelID[modelID.index(after: slash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !providerCandidate.isEmpty,
               !modelCandidate.isEmpty {
                return resolveAIModelSelection(modelID: modelCandidate, providerHint: providerCandidate)
            }
        }

        let matchedProviders: [AIProviderInfo]
        if let providerHint = providerHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerHint.isEmpty {
            matchedProviders = aiProviders.filter {
                $0.id.caseInsensitiveCompare(providerHint) == .orderedSame ||
                    $0.name.caseInsensitiveCompare(providerHint) == .orderedSame
            }
        } else {
            matchedProviders = aiProviders
        }

        var matches: [AIModelSelection] = []
        for provider in matchedProviders {
            for model in provider.models where
                model.id.caseInsensitiveCompare(modelID) == .orderedSame ||
                model.name.caseInsensitiveCompare(modelID) == .orderedSame {
                matches.append(AIModelSelection(providerID: provider.id, modelID: model.id))
            }
        }
        if matches.count == 1 {
            return matches[0]
        }
        return nil
    }

    private func resolveModelVariantOptions(for tool: AIChatTool, model: AIModelSelection) -> [String]? {
        let providers = tool == aiChatTool ? aiProviders : settingsProviders(aiTool: tool)
        guard let provider = providers.first(where: { $0.id == model.providerID }),
              let resolvedModel = provider.models.first(where: { $0.id == model.modelID }) else {
            return nil
        }
        var seen: Set<String> = []
        let values = resolvedModel.variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        return values.isEmpty ? nil : values
    }

    // MARK: - v1.42 路由决策与预算状态

    private func aiSessionRouteKey(
        projectName: String, workspaceName: String,
        aiTool: AIChatTool, sessionId: String
    ) -> String {
        "\(projectName)::\(workspaceName)::\(aiTool.rawValue)::\(sessionId)"
    }

    private func aiWorkspaceBudgetKey(projectName: String, workspaceName: String) -> String {
        "\(projectName)::\(workspaceName)"
    }

    func upsertAISessionRouteDecision(
        projectName: String, workspaceName: String,
        aiTool: AIChatTool, sessionId: String,
        routeDecision: AIRouteDecisionInfo?
    ) {
        guard let routeDecision else { return }
        let key = aiSessionRouteKey(
            projectName: projectName, workspaceName: workspaceName,
            aiTool: aiTool, sessionId: sessionId
        )
        aiSessionRouteDecisionByKey[key] = routeDecision
    }

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

    func upsertAIWorkspaceBudgetStatus(
        projectName: String, workspaceName: String,
        budgetStatus: AIBudgetStatus?
    ) {
        guard let budgetStatus else { return }
        let key = aiWorkspaceBudgetKey(projectName: projectName, workspaceName: workspaceName)
        aiWorkspaceBudgetStatusByKey[key] = budgetStatus
    }

    func currentBudgetStatus(projectName: String, workspaceName: String) -> AIBudgetStatus? {
        let key = aiWorkspaceBudgetKey(projectName: projectName, workspaceName: workspaceName)
        return aiWorkspaceBudgetStatusByKey[key]
    }

    private func applyAISessionSelectionHint(
        _ hint: AISessionSelectionHint?,
        sessionId: String,
        for tool: AIChatTool
    ) {
        guard let hint, !hint.isEmpty else {
            aiPendingSessionSelectionHintsByTool[tool]?[sessionId] = nil
            return
        }
        var unresolvedAgent = hint.agent
        var unresolvedProvider = hint.modelProviderID
        var unresolvedModel = hint.modelID
        var unresolvedConfigOptions: [String: Any] = [:]

        if let configOptions = hint.configOptions, !configOptions.isEmpty {
            applyConfigOptionsHint(configOptions, for: tool)
            let optionsByID = Dictionary(uniqueKeysWithValues: (aiSessionConfigOptionsByTool[tool] ?? []).map { ($0.optionID, $0) })
            for (optionID, value) in configOptions {
                let category = normalizedConfigCategory(optionsByID[optionID]?.category, optionID: optionID)
                if category == "mode" {
                    if let rawMode = configValueAsString(value),
                       let resolved = resolveAIAgentName(rawMode) {
                        if tool == aiChatTool {
                            aiSelectedAgent = resolved
                        }
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
                       let resolvedModel = resolveAIModelSelection(modelID: rawModel, providerHint: providerHint) {
                        if tool == aiChatTool {
                            aiSelectedModel = resolvedModel
                        }
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
                if category == "model_variant" {
                    if let rawVariant = configValueAsString(value),
                       modelVariantOptions(for: tool).contains(rawVariant) {
                        setAISelectedModelVariant(rawVariant, for: tool, syncConfigOption: false)
                    } else if configValueAsString(value) != nil {
                        unresolvedConfigOptions[optionID] = value
                    }
                }
            }
        }

        if let rawAgent = hint.agent,
           let resolvedAgent = resolveAIAgentName(rawAgent) {
            if tool == aiChatTool {
                aiSelectedAgent = resolvedAgent
            }
            unresolvedAgent = nil
        }
        if let rawModel = hint.modelID,
           let resolvedModel = resolveAIModelSelection(modelID: rawModel, providerHint: hint.modelProviderID) {
            if tool == aiChatTool {
                aiSelectedModel = resolvedModel
            }
            unresolvedProvider = nil
            unresolvedModel = nil
        }

        let unresolved = AISessionSelectionHint(
            agent: unresolvedAgent,
            modelProviderID: unresolvedProvider,
            modelID: unresolvedModel,
            configOptions: unresolvedConfigOptions.isEmpty ? nil : unresolvedConfigOptions
        )
        aiPendingSessionSelectionHintsByTool[tool]?[sessionId] = unresolved.isEmpty ? nil : unresolved
    }

    private func retryPendingAISessionSelectionHint(for tool: AIChatTool) {
        guard var pending = aiPendingSessionSelectionHintsByTool[tool], !pending.isEmpty else { return }
        guard let sessionId = aiCurrentSessionId else {
            aiPendingSessionSelectionHintsByTool[tool] = [:]
            return
        }
        guard let hint = pending[sessionId] else { return }
        applyAISessionSelectionHint(hint, sessionId: sessionId, for: tool)
        pending = aiPendingSessionSelectionHintsByTool[tool] ?? [:]
        aiPendingSessionSelectionHintsByTool[tool] = pending
    }

    private func applyAgentDefaultModel(_ agent: AIAgentInfo?) {
        guard let agent,
              let providerID = agent.defaultProviderID,
              let modelID = agent.defaultModelID,
              !providerID.isEmpty, !modelID.isEmpty else { return }
        aiSelectedModel = AIModelSelection(providerID: providerID, modelID: modelID)
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
           let commands = bySession[sessionId] {
            return commands
        }
        return aiSlashCommandsByTool[tool] ?? []
    }

    func refreshCurrentAISlashCommands(for tool: AIChatTool? = nil) {
        let targetTool = tool ?? aiChatTool
        guard aiChatTool == targetTool else { return }
        aiSlashCommands = slashCommandsForContext(
            tool: targetTool,
            sessionId: aiCurrentSessionId
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
        let currentSessionId = normalizeSlashCommandsSessionID(aiCurrentSessionId)
        if let eventSessionID = normalizeSlashCommandsSessionID(sessionId) {
            guard eventSessionID == currentSessionId else { return }
            aiSlashCommands = commands
            return
        }
        aiSlashCommands = slashCommandsForContext(tool: tool, sessionId: currentSessionId)
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
        aiSessionListStore.handleResponse(
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

    func setAISessions(_ sessions: [AISessionInfo], for tool: AIChatTool) {
        let sortedSessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
        let visibleSessions = sortedSessions.filter(\.isVisibleInDefaultSessionList)
        aiSessionsByTool[tool] = visibleSessions
        replaceToolSessionIndex(sortedSessions, for: tool)
        if aiChatTool == tool {
            aiSessions = visibleSessions
        }
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

    private func configureAIStorePerformance(_ store: AIChatStore) {
        store.performanceTracer = performanceTracer
        store.performanceContextProvider = { [weak self] in
            guard let self, !self.aiActiveProject.isEmpty, !self.aiActiveWorkspace.isEmpty else { return nil }
            return (self.aiActiveProject, self.aiActiveWorkspace)
        }
    }

    func upsertAISession(_ session: AISessionInfo, for tool: AIChatTool) {
        var sessions = aiSessionsByTool[tool] ?? []
        sessions.removeAll { $0.sessionKey == session.sessionKey }
        sessions.insert(session, at: 0)
        setAISessions(sessions, for: tool)
        aiSessionListStore.upsertVisibleSession(session)
    }

    /// 获取指定工具的会话列表
    func aiSessionsForTool(_ tool: AIChatTool) -> [AISessionInfo] {
        aiSessionsByTool[tool] ?? []
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

    private func aiSessionStatusKey(projectName: String, workspaceName: String, sessionId: String) -> String {
        "\(projectName)::\(workspaceName)::\(sessionId)"
    }

    private func aiSessionStatusRequestKey(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> String {
        "\(projectName)::\(workspaceName)::\(aiTool.rawValue)::\(sessionId)"
    }

    func requestAISessionStatus(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        force: Bool = false
    ) {
        let key = aiSessionStatusRequestKey(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId
        )
        guard aiSessionStatusRequestLimiter.shouldRequest(
            key: key,
            minInterval: aiSessionStatusMinInterval,
            force: force
        ) else {
            return
        }
        wsClient.requestAISessionStatus(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            cacheMode: force ? .forceRefresh : .default
        )
    }

    func aiSessionStatus(for session: AISessionInfo) -> AISessionStatusSnapshot? {
        aiSessionStatusesByTool[session.aiTool]?[aiSessionStatusKey(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            sessionId: session.id
        )]
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
        let normalizedError = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        dict[key] = AISessionStatusSnapshot(
            status: normalizedStatus.isEmpty ? status : normalizedStatus,
            errorMessage: normalizedError?.isEmpty == true ? nil : normalizedError,
            contextRemainingPercent: contextRemainingPercent
        )
        aiSessionStatusesByTool[aiTool] = dict
    }

    // MARK: - 终端 AI 状态（WI-002 iOS 端同步链路）

    /// 查询指定工作区的终端 AI 状态（六态）。
    /// iOS 端以工作区粒度（非 tab 粒度）存储，与 macOS 共享同一语义枚举。
    func terminalAIStatus(projectName: String, workspaceName: String) -> TerminalAIStatus {
        let key = "\(projectName):\(workspaceName)"
        return terminalAIStatusByWorkspaceKey[key] ?? .idle
    }

    /// 将 AI 会话状态更新到对应工作区的终端 AI 状态存储。
    /// 使用共享语义层 TerminalSessionSemantics 映射，保证 macOS 与 iOS 语义一致。
    private func syncAIStatusToWorkspace(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        status: String,
        errorMessage: String?,
        toolName: String?
    ) {
        let key = "\(projectName):\(workspaceName)"
        let mapped = TerminalSessionSemantics.terminalAIStatus(
            from: status,
            errorMessage: errorMessage,
            toolName: toolName,
            aiToolDisplayName: aiTool.displayName
        )
        terminalAIStatusByWorkspaceKey[key] = mapped
    }

    /// AIChatDone 兜底状态推导，与 macOS 保持相同逻辑。
    private func fallbackSessionStatusForChatDone(stopReason: String?) -> String {
        let reason = (stopReason ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if reason.isEmpty { return "success" }
        if reason.contains("cancel") || reason.contains("abort") || reason.contains("interrupt") {
            return "cancelled"
        }
        if reason.contains("awaiting_input") ||
            reason.contains("requires_input") ||
            reason.contains("need_input") {
            return "awaiting_input"
        }
        if reason.contains("error") || reason.contains("fail") { return "failure" }
        return "success"
    }

    // MARK: - 终端视图绑定

    /// 绑定 SwiftTerm 输出目标
    func attachTerminalSink(_ sink: MobileTerminalOutputSink) {
        terminalSink = sink
        // 先确保视图处于“当前 term_id 的干净状态”，再 flush 缓冲/scrollback。
        if currentTermId.isEmpty || lastRenderedTermId != currentTermId {
            sink.resetTerminal()
            lastRenderedTermId = currentTermId
        }
        flushPendingOutput()
    }

    /// 解绑 SwiftTerm 输出目标
    func detachTerminalSink(_ sink: MobileTerminalOutputSink? = nil) {
        if let sink, let current = terminalSink, current !== sink {
            return
        }
        terminalSink = nil
        isTerminalViewReady = false
        pendingOutputChunks.removeAll()
        lastRenderedTermId = ""
    }

    /// SwiftTerm 视图尺寸变化（首次拿到有效尺寸也会走这里）
    func terminalViewDidResize(cols: Int, rows: Int) {
        // 与 Core PTY clamp 保持一致：忽略初始化阶段的无效小尺寸，减少无意义往返与日志噪声。
        guard cols >= 20, rows >= 5 else { return }

        let becameReady = !isTerminalViewReady
        isTerminalViewReady = true
        terminalCols = cols
        terminalRows = rows

        if !currentTermId.isEmpty {
            wsClient.requestTermResize(termId: currentTermId, cols: cols, rows: rows)
        }

        if becameReady {
            fireTermCreate()
            flushPendingOutput()
        }
    }


    // MARK: - 终端

    /// 记录待创建的终端信息，实际创建延迟到终端视图 ready 后
    func createTerminalForWorkspace(project: String, workspace: String) {
        pendingTermProject = project
        pendingTermWorkspace = workspace
        pendingAttachTermId = ""
        pendingCustomCommand = ""
        pendingCustomCommandIcon = ""
        pendingCustomCommandName = ""
        if isTerminalViewReady {
            fireTermCreate()
        }
    }

    /// 创建终端并在就绪后自动执行命令
    func createTerminalWithCommand(
        project: String,
        workspace: String,
        command: String,
        icon: String? = nil,
        name: String? = nil
    ) {
        pendingCustomCommand = command
        pendingCustomCommandIcon = icon ?? ""
        pendingCustomCommandName = name ?? ""
        pendingTermProject = project
        pendingTermWorkspace = workspace
        pendingAttachTermId = ""
        if isTerminalViewReady {
            fireTermCreate()
        }
    }

    /// 关闭（终止）指定终端
    func closeTerminal(termId: String) {
        wsClient.requestTermClose(termId: termId)
    }

    /// 附着已有终端（重连场景）
    func attachTerminal(project: String, workspace: String, termId: String) {
        pendingTermProject = project
        pendingTermWorkspace = workspace
        pendingAttachTermId = termId
        pendingCustomCommand = ""
        pendingCustomCommandIcon = ""
        pendingCustomCommandName = ""
        if isTerminalViewReady {
            fireTermCreate()
        }
    }

    private func fireTermCreate() {
        guard isTerminalViewReady else { return }
        guard !pendingTermProject.isEmpty else { return }

        let project = pendingTermProject
        let workspace = pendingTermWorkspace
        let attachId = pendingAttachTermId
        pendingTermProject = ""
        pendingTermWorkspace = ""
        pendingAttachTermId = ""

        if !attachId.isEmpty {
            // 附着已有终端
            pendingCustomCommand = ""
            pendingCustomCommandIcon = ""
            pendingCustomCommandName = ""
            terminalSessionStore.recordAttachRequest(termId: attachId)
            wsClient.requestTermAttach(termId: attachId)
        } else {
            // 创建新终端，携带展示信息供 Core 持久化
            let name: String? = pendingCustomCommandName.isEmpty ? nil : pendingCustomCommandName
            let icon: String? = pendingCustomCommandIcon.isEmpty ? nil : pendingCustomCommandIcon
            wsClient.requestTermCreate(
                project: project,
                workspace: workspace,
                cols: terminalCols,
                rows: terminalRows,
                name: name,
                icon: icon
            )
        }
    }

    func switchToTerminal(termId: String) {
        let switchStartedAt = Date()
        let newId = termId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newId.isEmpty else { return }
        guard newId != currentTermId else { return }
        let oldId = currentTermId
        if Self.perfTerminalAutoDetachEnabled, !oldId.isEmpty {
            terminalSessionStore.recordDetachRequest(termId: oldId)
            wsClient.requestTermDetach(termId: oldId)
        }

        // 防止 SwiftUI 复用同一个 TerminalView 时，把新终端输出追加到旧缓冲。
        pendingOutputChunks.removeAll()
        terminalSessionStore.resetUnackedBytes(for: newId)
        currentTermId = newId
        lastRenderedTermId = ""
        if let sink = terminalSink {
            sink.resetTerminal()
            lastRenderedTermId = newId
        }
        let switchCostMs = Int(Date().timeIntervalSince(switchStartedAt) * 1000)
        TFLog.app.info("perf.mobile.terminal.switch_ms=\(switchCostMs, privacy: .public)")
    }

    /// 发送特殊键序列到终端
    func sendSpecialKey(_ sequence: String) {
        guard !currentTermId.isEmpty else { return }
        wsClient.sendTerminalInput(sequence, termId: currentTermId)
    }

    /// 发送键盘输入到终端（字符串）
    func sendTerminalInput(_ data: String) {
        guard !currentTermId.isEmpty else { return }
        let transformed = consumeCtrlIfNeeded(for: data)
        wsClient.sendTerminalInput(transformed, termId: currentTermId)
    }

    /// 粘贴按钮：文本直接发送，图片上传到服务端转 JPG 写入 macOS 剪贴板
    func handlePaste() {
        let pb = UIPasteboard.general
        // 1. 文本优先
        if let text = pb.string, !text.isEmpty {
            sendSpecialKey(text)
            return
        }
        // 2. 图片：上传到服务端转 JPG 并写入 macOS 剪贴板
        if let image = pb.image, let pngData = image.pngData() {
            wsClient.sendClipboardImageUpload(imageData: [UInt8](pngData))
            return
        }
        // 3. 其他类型跳过
    }

    /// 复制纯文本到系统剪贴板。
    func copyTextToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// 复制侧边栏实体路径（项目根目录或工作空间根目录）。
    func copySidebarPath(_ path: String) {
        copyTextToClipboard(path)
    }

    /// 获取指定工作区根目录路径。
    func workspaceRootPath(project: String, workspace: String) -> String? {
        workspacesForProject(project)
            .first(where: { $0.name == workspace })?
            .root
    }

    /// 将资源管理器相对路径规范化为用户可见文本。
    func explorerRelativeDisplayPath(_ path: String) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "." : normalized
    }

    /// 将资源管理器路径解析为工作区内绝对路径。
    func explorerAbsolutePath(project: String, workspace: String, path: String) -> String? {
        guard let root = workspaceRootPath(project: project, workspace: workspace) else {
            return nil
        }
        let relativePath = explorerRelativeDisplayPath(path)
        if relativePath == "." {
            return root
        }
        return (root as NSString).appendingPathComponent(relativePath)
    }

    /// 复制资源管理器条目的绝对路径。
    func copyExplorerPath(project: String, workspace: String, path: String) {
        guard let absolutePath = explorerAbsolutePath(project: project, workspace: workspace, path: path) else {
            return
        }
        copyTextToClipboard(absolutePath)
    }

    /// 复制资源管理器条目的相对路径。
    func copyExplorerRelativePath(_ path: String) {
        copyTextToClipboard(explorerRelativeDisplayPath(path))
    }

    /// 发送键盘输入到终端（原始字节）
    func sendTerminalInputBytes(_ data: [UInt8]) {
        guard !currentTermId.isEmpty else { return }
        let transformed = consumeCtrlIfNeeded(for: data)
        wsClient.sendTerminalInput(transformed, termId: currentTermId)
    }

    /// 设置 Ctrl 锁定状态（由输入工具栏回调）
    func setCtrlArmed(_ armed: Bool) {
        ctrlArmedForNextInput = armed
        NotificationCenter.default.post(
            name: .mobileTerminalCtrlStateDidChange,
            object: nil,
            userInfo: ["armed": armed]
        )
    }

    /// 离开终端视图时清理
    func detachTerminal() {
        // 离开页面时仅取消输出订阅，避免后台持续转发导致卡顿/抖动/不必要的资源占用。
        // 注意：不要触发 term_close（那会直接 kill 远端 PTY）。
        if !currentTermId.isEmpty {
            terminalSessionStore.recordDetachRequest(termId: currentTermId)
            wsClient.requestTermDetach(termId: currentTermId)
        }
        currentTermId = ""
        pendingTermProject = ""
        pendingTermWorkspace = ""
        pendingAttachTermId = ""
        pendingCustomCommand = ""
        pendingCustomCommandIcon = ""
        pendingCustomCommandName = ""
        isTerminalViewReady = false
        terminalSessionStore.handleDisconnect()
        pendingOutputChunks.removeAll()
        terminalSink = nil
        lastRenderedTermId = ""
        setCtrlArmed(false)
        // WI-002：断连时清除工作区终端 AI 状态，防止重连后展示过期状态
        terminalAIStatusByWorkspaceKey.removeAll()
    }

    // MARK: - WS 回调

    private func setupWSCallbacks() {
        // 保留非 handler 协议的回调闭包
        wsClient.onConnectionStateChanged = { [weak self] connected in
            guard let self else { return }
            if connected {
                self.connectionPhase = .connected
                self.connectionMessage = "连接成功"
                self.errorMessage = ""
                self.refreshProjectTree()
                self.wsClient.requestSystemSnapshot(cacheMode: .forceRefresh)
                // 重连成功后重新附着终端输出订阅（后台期间订阅可能已丢失）
                self.reattachTerminalIfNeeded()
                // 重连后恢复 AI 会话数据（流式输出可能中断，需重新拉取）
                self.reloadAISessionDataAfterReconnect()
                // 恢复键盘焦点
                self.terminalSink?.focusTerminal()
            } else {
                // 断连时强制重置 AI 聊天舞台，防止旧工作区的 active/resuming 投影残留
                self.forceResetAIChatStage()
                // 清理断连前的 AI 上下文投影残留
                self.cleanupOldAIContextProjection()

                self.connectionMessage = "连接断开"
                if let phase = ConnectionPhase.evaluateDisconnect(
                    isIntentional: self.wsClient.isIntentionalDisconnect,
                    isCoreAvailable: true
                ) {
                    // 主动断开：直接设置确定阶段
                    self.connectionPhase = phase
                } else {
                    // 意外断连：通过共享语义层驱动重连
                    self.reconnectWithBackoff()
                }
            }
        }

        wsClient.onClipboardImageSet = { [weak self] ok, message in
            guard let self else { return }
            if ok {
                self.sendSpecialKey("\u{16}")
            } else {
                self.errorMessage = message ?? "剪贴板图片写入失败"
            }
        }

        wsClient.onTasksSnapshot = { [weak self] entries in
            guard let self else { return }
            self.restoreTasksFromSnapshot(entries)
        }

        wsClient.onClientSettingsResult = { [weak self] settings in
            guard let self else { return }
            self.customCommands = settings.customCommands
            self.workspaceShortcuts = settings.workspaceShortcuts
            self.mergeAIAgent = settings.mergeAIAgent
            self.clientFixedPort = settings.fixedPort
            self.clientRemoteAccessEnabled = settings.remoteAccessEnabled
            self.applyEvolutionDefaultProfilesFromCore(settings.evolutionDefaultProfiles)
            self.workspaceTodosByKey = settings.workspaceTodos
            self.keybindings = settings.keybindings.isEmpty ? KeybindingConfig.defaultKeybindings() : settings.keybindings
            self.evolutionProfilesFromClientSettings = settings.evolutionAgentProfiles
            self.applyEvolutionProfilesFromClientSettings(settings.evolutionAgentProfiles)
        }

        // 按领域 handler 绑定，替代大量 onXxx 闭包接线（与 macOS AppState+CoreWS+WSClientBinder 对称）
        let gitHandler = MobileAppStateGitMessageHandlerAdapter(appState: self)
        let projectHandler = MobileAppStateProjectMessageHandlerAdapter(appState: self)
        let fileHandler = MobileAppStateFileMessageHandlerAdapter(appState: self)
        let terminalHandler = MobileAppStateTerminalMessageHandlerAdapter(appState: self)
        let aiHandler = MobileAppStateAIMessageHandlerAdapter(appState: self)
        let evolutionHandler = MobileAppStateEvolutionMessageHandlerAdapter(appState: self)
        let evidenceHandler = MobileAppStateEvidenceMessageHandlerAdapter(appState: self)
        let errorHandler = MobileAppStateErrorMessageHandlerAdapter(appState: self)

        _gitHandlerAdapter = gitHandler
        _projectHandlerAdapter = projectHandler
        _fileHandlerAdapter = fileHandler
        _terminalHandlerAdapter = terminalHandler
        _aiHandlerAdapter = aiHandler
        _evolutionHandlerAdapter = evolutionHandler
        _evidenceHandlerAdapter = evidenceHandler
        _errorHandlerAdapter = errorHandler

        wsClient.gitMessageHandler = gitHandler
        wsClient.projectMessageHandler = projectHandler
        wsClient.fileMessageHandler = fileHandler
        wsClient.terminalMessageHandler = terminalHandler
        wsClient.aiMessageHandler = aiHandler
        wsClient.evolutionMessageHandler = evolutionHandler
        wsClient.evidenceMessageHandler = evidenceHandler
        wsClient.errorMessageHandler = errorHandler

        // 工作区缓存可观测性快照：更新 Core 权威指标（语义与 macOS 对齐）
        wsClient.onSystemSnapshot = { [weak self] metrics in
            self?.workspaceCacheMetrics = metrics
        }

        // 工作区 Evolution 摘要：由 system_snapshot 驱动种子/更新工作区运行态摘要
        wsClient.onEvolutionWorkspaceSummaries = { [weak self] summaries in
            DispatchQueue.main.async {
                self?.handleSystemEvolutionWorkspaceSummaries(summaries)
            }
        }

        // v1.42: 统一可观测性快照 — 与 macOS 使用同一套共享模型
        wsClient.onObservabilitySnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.observabilitySnapshot = snapshot
            }
        }

        // HTTP 读取失败回调：多工作区安全，与 macOS 语义对齐
        wsClient.onHTTPReadFailure = { [weak self] failure in
            DispatchQueue.main.async { [weak self] in
                self?.handleHTTPReadFailure(failure)
            }
        }

        // v1.41: 系统健康快照 - 与 macOS 使用同一套共享健康模型（语义对齐）
        wsClient.onHealthSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.systemHealthSnapshot = snapshot
            }
        }

        // v1.41: 修复执行结果 - 与 macOS 使用相同的状态迁移语义
        wsClient.onHealthRepairResult = { [weak self] audit in
            DispatchQueue.main.async {
                guard let self else { return }
                if let incidentId = audit.incidentId {
                    let project = audit.context.project
                    let workspace = audit.context.workspace
                    let key = "\(project ?? ""):\(workspace ?? ""):\(incidentId)"
                    switch audit.outcome {
                    case .success, .alreadyHealthy:
                        self.incidentRepairStates[key] = .repaired(requestId: audit.requestId)
                    case .failed:
                        self.incidentRepairStates[key] = .repairFailed(
                            requestId: audit.requestId,
                            summary: audit.resultSummary
                        )
                    case .partialSuccess:
                        self.incidentRepairStates[key] = .repaired(requestId: audit.requestId)
                    }
                }
            }
        }

        // 工作区恢复状态摘要：从 system_snapshot workspace_items 提取，按 (project, workspace) 隔离
        wsClient.onWorkspaceRecoverySummaries = { [weak self] summaries in
            DispatchQueue.main.async {
                guard let self else { return }
                for summary in summaries {
                    let key = "\(summary.project):\(summary.workspace)"
                    self.workspaceRecoverySummaries[key] = summary
                }
            }
        }
    }

    private func resolveDefaultAgentName() -> String {
        AIAgentSelectionPolicy.defaultAgentName(from: aiAgents)
    }

    // MARK: - 排序/任务内部工具

    /// 从服务端任务快照恢复本地任务状态（重连场景）
    private func restoreTasksFromSnapshot(_ entries: [TaskSnapshotEntry]) {
        // 收集当前本地已有的 remoteTaskId，避免重复创建
        let existingRemoteIds: Set<String> = Set(
            taskStore.tasksByKey.values.flatMap { $0 }.compactMap { $0.remoteTaskId }
        )

        for entry in entries {
            // 跳过已存在的任务
            if existingRemoteIds.contains(entry.taskId) { continue }

            let taskType: WorkspaceTaskType
            switch entry.taskType {
            case "ai_commit": taskType = .aiCommit
            case "ai_merge": taskType = .aiMerge
            default: taskType = .projectCommand
            }

            let status: WorkspaceTaskStatus
            switch entry.status {
            case "running": status = .running
            case "completed": status = .completed
            case "failed": status = .failed
            case "cancelled": status = .cancelled
            default: status = .running
            }

            let startedDate = Date(timeIntervalSince1970: TimeInterval(entry.startedAt) / 1000.0)
            let completedDate = entry.completedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            let key = globalWorkspaceKey(project: entry.project, workspace: entry.workspace)

            let item = WorkspaceTaskItem(
                id: UUID().uuidString,
                project: entry.project,
                workspace: entry.workspace,
                workspaceGlobalKey: key,
                type: taskType,
                title: entry.title,
                iconName: taskType == .projectCommand ? "terminal" : "sparkles",
                status: status,
                message: entry.message ?? "",
                createdAt: startedDate,
                startedAt: startedDate,
                completedAt: completedDate,
                commandId: entry.commandId,
                remoteTaskId: entry.taskId,
                lastOutputLine: nil,
                isCancellable: status.isActive
            )

            taskStore.upsert(item)

            // 维护 remoteTaskId 映射（running 状态的项目命令需要接收后续输出）
            if taskType == .projectCommand && status == .running {
                projectCommandTaskIdByRemoteTaskId[entry.taskId] = item.id
            }
        }
    }

    func explorerCacheKey(project: String, workspace: String, path: String) -> String {
        WorkspaceKeySemantics.fileCacheKey(project: project, workspace: workspace, path: path)
    }

    private func explorerCachePrefix(project: String, workspace: String) -> String {
        WorkspaceKeySemantics.fileCachePrefix(project: project, workspace: workspace)
    }

    func globalWorkspaceKey(project: String, workspace: String) -> String {
        WorkspaceKeySemantics.globalKey(project: project, workspace: workspace)
    }

    // MARK: - 资源管理：按工作区边界淘汰缓存

    /// 清除指定工作区的全部缓存数据（文件列表、Git 状态、文件索引等）。
    /// 在工作区被删除或重连后调用，确保旧数据不残留。
    func evictWorkspaceCache(project: String, workspace: String) {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        let prefix = explorerCachePrefix(project: project, workspace: workspace)

        workspaceGitDetailState.removeValue(forKey: key)
        workspaceTerminalOpenTime.removeValue(forKey: key)

        // 文件浏览缓存
        explorerFileListCache.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { explorerFileListCache.removeValue(forKey: $0) }
        explorerDirectoryExpandState.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { explorerDirectoryExpandState.removeValue(forKey: $0) }

        // AI 文件索引缓存（用 aiContextKey 格式，与 globalKey 相同）
        aiFileIndexCache.removeValue(forKey: key)
    }

    /// 释放某个已下线项目的所有工作区缓存，防止残留数据污染内存。
    func evictProjectCache(projectName: String) {
        // 获取该项目下所有已知工作区
        let wsNames = (workspacesByProject[projectName] ?? []).map(\.name)
        let allWsNames = wsNames + ["default"]
        for wsName in allWsNames {
            evictWorkspaceCache(project: projectName, workspace: wsName)
        }
        workspacesByProject.removeValue(forKey: projectName)
    }

    private func applyEvolutionProfilesFromClientSettings(
        _ profileMap: [String: [EvolutionStageProfileInfoV2]]
    ) {
        guard !profileMap.isEmpty else { return }
        for (storageKey, profiles) in profileMap {
            guard !profiles.isEmpty else { continue }
            guard let parsed = parseEvolutionProfileStorageKey(storageKey) else { continue }
            let workspace = normalizeEvolutionWorkspaceName(parsed.workspace)
            let key = globalWorkspaceKey(project: parsed.project, workspace: workspace)
            let current = evolutionStageProfilesByWorkspace[key] ?? []
            let normalized = Self.normalizedEvolutionProfiles(profiles)
            if current.isEmpty || shouldPreferEvolutionProfiles(candidate: normalized, over: current) {
                evolutionStageProfilesByWorkspace[key] = normalized
            }
        }
    }

    private func resolveEvolutionProfilesFromClientSettings(
        project: String,
        workspace: String
    ) -> [EvolutionStageProfileInfoV2]? {
        guard !evolutionProfilesFromClientSettings.isEmpty else { return nil }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let candidateKeys = evolutionProfileStorageKeyCandidates(
            project: project,
            workspace: normalizedWorkspace
        )
        for key in candidateKeys {
            if let profiles = evolutionProfilesFromClientSettings[key], !profiles.isEmpty {
                return Self.normalizedEvolutionProfiles(profiles)
            }
        }
        for (storageKey, profiles) in evolutionProfilesFromClientSettings {
            guard !profiles.isEmpty else { continue }
            guard let parsed = parseEvolutionProfileStorageKey(storageKey) else { continue }
            let parsedWorkspace = normalizeEvolutionWorkspaceName(parsed.workspace)
            if parsed.project == project && parsedWorkspace == normalizedWorkspace {
                return Self.normalizedEvolutionProfiles(profiles)
            }
        }
        return nil
    }

    private func evolutionProfileStorageKeyCandidates(project: String, workspace: String) -> [String] {
        let projectTrimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceTrimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        var keys: [String] = [
            "\(project)/\(workspace)",
            "\(projectTrimmed)/\(workspaceTrimmed)"
        ]
        if workspaceTrimmed.caseInsensitiveCompare("default") == .orderedSame {
            keys.append("\(project)/(default)")
            keys.append("\(projectTrimmed)/(default)")
        }
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    private func parseEvolutionProfileStorageKey(_ key: String) -> (project: String, workspace: String)? {
        let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private func shouldPreferEvolutionProfiles(
        candidate: [EvolutionStageProfileInfoV2],
        over existing: [EvolutionStageProfileInfoV2]
    ) -> Bool {
        if existing.isEmpty { return true }
        return isDefaultEvolutionProfiles(existing) && !isDefaultEvolutionProfiles(candidate)
    }

    private func isDefaultEvolutionProfiles(_ profiles: [EvolutionStageProfileInfoV2]) -> Bool {
        guard profiles.count == Self.defaultEvolutionProfiles().count else { return false }
        for profile in profiles {
            if profile.aiTool != .codex { return false }
            if let mode = profile.mode, !mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            if profile.model != nil { return false }
            if !profile.configOptions.isEmpty { return false }
        }
        return true
    }

    private func projectEarliestTerminalTime(_ project: ProjectInfo) -> Date? {
        var earliest: Date?
        for workspace in workspacesForProject(project.name) {
            let key = globalWorkspaceKey(project: project.name, workspace: workspace.name)
            if let time = workspaceTerminalOpenTime[key] {
                if earliest == nil || time < earliest! {
                    earliest = time
                }
            }
        }
        return earliest
    }

    private func projectMinShortcutKey(_ project: ProjectInfo) -> Int {
        var minKey = Int.max
        for workspace in workspacesForProject(project.name) {
            let wsKey = workspace.name == "default"
                ? "\(project.name)/(default)"
                : "\(project.name)/\(workspace.name)"
            if let shortcut = getWorkspaceShortcutKey(workspaceKey: wsKey),
               let num = Int(shortcut) {
                let sortValue = num == 0 ? 10 : num
                minKey = min(minKey, sortValue)
            }
        }
        return minKey
    }

    /// iOS 端项目不持有 UUID（使用 ProjectInfo），通过项目名哈希生成确定性 UUID。
    /// 保证同一项目名始终生成同一 UUID，用于构建 WorkspaceIdentity。
    private func deterministicProjectUUID(for projectName: String) -> UUID {
        let data = Data(projectName.utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { buffer in
            for (i, byte) in buffer.enumerated() {
                bytes[i % 16] ^= byte
            }
        }
        // 设置 UUID version 5 标志位（name-based SHA-1 风格）
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    @discardableResult
    func createTask(
        project: String,
        workspace: String,
        type: WorkspaceTaskType,
        title: String,
        icon: String,
        message: String
    ) -> WorkspaceTaskItem {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        let item = WorkspaceTaskItem(
            id: UUID().uuidString,
            project: project,
            workspace: workspace,
            workspaceGlobalKey: key,
            type: type,
            title: title,
            iconName: icon,
            status: .running,
            message: message,
            createdAt: Date(),
            startedAt: Date(),
            completedAt: nil,
            commandId: nil,
            remoteTaskId: nil,
            lastOutputLine: nil,
            isCancellable: true
        )
        taskStore.upsert(item)
        return item
    }

    func mutateTask(_ taskId: String, mutate: (inout WorkspaceTaskItem) -> Void) {
        taskStore.mutate(id: taskId, mutate)
    }

    func findLatestActiveTaskId(project: String, type: WorkspaceTaskType) -> String? {
        taskStore.tasksByKey.values
            .flatMap { $0 }
            .filter { $0.project == project && $0.type == type && $0.status.isActive }
            .sorted { $0.createdAt > $1.createdAt }
            .first?
            .id
    }

    func projectCommandRoutingKey(project: String, workspace: String, commandId: String) -> String {
        "\(project)|\(workspace)|\(commandId)"
    }

    /// 从项目配置中查找命令名称
    func resolveCommandName(project: String, commandId: String) -> String {
        projects.first(where: { $0.name == project })?
            .commands.first(where: { $0.id == commandId })?
            .name ?? commandId
    }

    /// 从项目配置中查找命令图标
    func resolveCommandIcon(project: String, commandId: String) -> String {
        projects.first(where: { $0.name == project })?
            .commands.first(where: { $0.id == commandId })?
            .icon ?? "terminal"
    }

    // MARK: - 输出缓冲

    func emitTerminalOutput(_ bytes: [UInt8], termId: String, shouldRender: Bool) {
        guard !bytes.isEmpty else { return }

        // 通过共享终端存储追踪 ACK 计数，流控 ACK：超过阈值时通知 Core 释放背压
        terminalSessionStore.addUnackedBytes(bytes.count, for: termId)
        let unacked = terminalSessionStore.unackedBytes(for: termId)
        if unacked >= termOutputAckThreshold {
            wsClient.sendTermOutputAck(termId: termId, bytes: unacked)
            terminalSessionStore.clearUnackedBytes(for: termId)
        }

        guard shouldRender else { return }
        if let sink = terminalSink {
            sink.writeOutput(bytes)
            return
        }

        // 终端视图尚未就绪：缓冲到本地，等 ready 后 flush
        pendingOutputChunks.append(bytes)
        if pendingOutputChunks.count > pendingOutputChunkLimit {
            pendingOutputChunks.removeFirst(pendingOutputChunks.count - pendingOutputChunkLimit)
        }
    }

    private func flushPendingOutput() {
        guard let sink = terminalSink else { return }
        guard !pendingOutputChunks.isEmpty else { return }

        let chunks = pendingOutputChunks
        pendingOutputChunks.removeAll()
        for chunk in chunks {
            sink.writeOutput(chunk)
        }
    }

    // MARK: - HTTP 配对

    private func exchangePairCode(
        host: String,
        port: Int,
        pairCode: String,
        deviceName: String,
        secure: Bool = false
    ) async throws -> PairExchangeHTTPResponse {
        let scheme = secure ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(port)/pair/exchange") else {
            throw NSError(domain: "TidyFlowiOS", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "配对服务地址无效"
            ])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(
            PairExchangeHTTPBody(pairCode: pairCode, deviceName: deviceName)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "TidyFlowiOS", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "服务端响应异常"
            ])
        }

        if (200..<300).contains(httpResponse.statusCode) {
            return try JSONDecoder().decode(PairExchangeHTTPResponse.self, from: data)
        }

        if let serverError = try? JSONDecoder().decode(PairErrorHTTPResponse.self, from: data) {
            throw NSError(domain: "TidyFlowiOS", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(serverError.error): \(serverError.message)"
            ])
        }

        throw NSError(domain: "TidyFlowiOS", code: httpResponse.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "配对失败 (HTTP \(httpResponse.statusCode))"
        ])
    }

    private func consumeCtrlIfNeeded(for data: String) -> String {
        guard ctrlArmedForNextInput else { return data }
        disarmCtrlIfNeeded()

        if let mapped = mapCtrlSequence(from: data) {
            return mapped
        }
        return data
    }

    private func consumeCtrlIfNeeded(for data: [UInt8]) -> [UInt8] {
        guard ctrlArmedForNextInput else { return data }
        disarmCtrlIfNeeded()

        guard let text = String(bytes: data, encoding: .utf8) else {
            return data
        }
        guard let mapped = mapCtrlSequence(from: text) else {
            return data
        }
        return Array(mapped.utf8)
    }

    private func disarmCtrlIfNeeded() {
        ctrlArmedForNextInput = false
        NotificationCenter.default.post(
            name: .mobileTerminalCtrlStateDidChange,
            object: nil,
            userInfo: ["armed": false]
        )
    }

    private func mapCtrlSequence(from data: String) -> String? {
        guard data.unicodeScalars.count == 1, let scalar = data.unicodeScalars.first else {
            return nil
        }

        let value = scalar.value

        // Ctrl + A-Z / a-z
        if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
            guard let ctrlScalar = UnicodeScalar(value & 0x1F) else { return nil }
            return String(ctrlScalar)
        }

        // 常见 Ctrl + 符号/数字映射
        switch value {
        case 0x20, 0x32, 0x40: // Space, 2, @
            return "\u{00}"
        case 0x33, 0x5B: // 3, [
            return "\u{1b}"
        case 0x34, 0x5C: // 4, \\
            return "\u{1c}"
        case 0x35, 0x5D: // 5, ]
            return "\u{1d}"
        case 0x36, 0x5E: // 6, ^
            return "\u{1e}"
        case 0x37, 0x2F, 0x3F, 0x5F: // 7, /, ?, _
            return "\u{1f}"
        default:
            return nil
        }
    }
}

// MARK: - iOS 模板操作 API

extension MobileAppState {
    /// 加载模板列表
    func loadTemplates() {
        wsClient.requestListTemplates()
    }

    /// 保存模板
    func saveTemplate(_ template: TemplateInfo) {
        wsClient.requestSaveTemplate(template)
    }

    /// 删除模板
    func deleteTemplate(templateId: String) {
        wsClient.requestDeleteTemplate(templateId: templateId)
    }

    /// 导入模板
    func importTemplate(_ template: TemplateInfo) {
        wsClient.requestImportTemplate(template)
    }

    /// 创建工作空间（支持模板）
    func createWorkspace(projectName: String, fromBranch: String? = nil, templateId: String? = nil) {
        wsClient.requestCreateWorkspace(project: projectName, fromBranch: fromBranch, templateId: templateId)
    }
}

// MARK: - WI-004 iOS AI 消息处理器方法
//
// 以 project/workspace/aiTool/sessionId 四元组为边界统一处理 AI 消息，
// 与 macOS AppState+CoreWS+AIEvolutionHandlers.swift 保持对称语义。
// MobileAppStateAIMessageHandlerAdapter 通过弱引用持有 MobileAppState，
// 由 wsClient.aiMessageHandler 统一分发，不再依赖独立的 wsClient.on* 闭包。

extension MobileAppState {
    func handleAITaskCancelled(_ result: AITaskCancelled) {
        let key = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        let taskType: WorkspaceTaskType = result.operationType == "ai_merge" ? .aiMerge : .aiCommit
        if let task = taskStore.allTasks(for: key).first(where: { $0.type == taskType && $0.status.isActive }) {
            mutateTask(task.id) { t in
                t.status = .cancelled
                t.message = "已取消"
                t.completedAt = Date()
            }
        }
    }

    func handleAISessionStarted(_ ev: AISessionStartedV2) {
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }

        aiCurrentSessionId = ev.sessionId
        aiChatStore.setCurrentSessionId(ev.sessionId)
        aiChatStore.addSubscription(ev.sessionId)
        wsClient.requestAISessionSubscribe(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool.rawValue,
            sessionId: ev.sessionId
        )
        applyAISessionSelectionHint(
            ev.selectionHint,
            sessionId: ev.sessionId,
            for: ev.aiTool
        )
        wsClient.requestAISessionConfigOptions(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        )
        let updatedAt = ev.updatedAt == 0 ? Int64(Date().timeIntervalSince1970 * 1000) : ev.updatedAt
        let session = AISessionInfo(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            id: ev.sessionId,
            title: ev.title,
            updatedAt: updatedAt,
            origin: ev.origin
        )
        upsertAISession(session, for: ev.aiTool)

        if let pending = aiPendingSendRequest {
            guard pending.projectName == ev.projectName,
                  pending.workspaceName == ev.workspaceName,
                  pending.aiTool == ev.aiTool else {
                aiPendingSendRequest = nil
                return
            }
            aiPendingSendRequest = nil
            sendPendingAIRequest(
                pending.kind,
                sessionId: ev.sessionId,
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool
            )
        }
    }

    func handleAISessionList(_ ev: AISessionListV2) {
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName else { return }
        let sessions = ev.sessions.map {
            AISessionInfo(
                projectName: $0.projectName,
                workspaceName: $0.workspaceName,
                aiTool: $0.aiTool,
                id: $0.id,
                title: $0.title,
                updatedAt: $0.updatedAt,
                origin: $0.origin
            )
        }
        let sorted = sessions.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.aiTool != $1.aiTool { return $0.aiTool.rawValue < $1.aiTool.rawValue }
            return $0.id < $1.id
        }
        let filter: AISessionListFilter = ev.filterAIChatTool.map { .tool($0) } ?? .all
        let pageState = aiSessionListStore.handleResponse(
            project: ev.projectName,
            workspace: ev.workspaceName,
            filter: filter,
            sessions: sorted,
            hasMore: ev.hasMore,
            nextCursor: ev.nextCursor,
            performanceTracer: performanceTracer
        )
        mergeKnownAISessions(pageState.sessions)
    }

    func handleAISessionMessages(_ ev: AISessionMessagesV2) {
        _ = consumeEvolutionReplayMessagesIfNeeded(ev)
        if consumeSubAgentViewerMessagesIfNeeded(ev) { return }
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }
        guard aiCurrentSessionId == ev.sessionId else { return }
        guard aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }

        let mapped = ev.toChatMessages()
        if ev.beforeMessageId != nil {
            aiChatStore.prependMessages(mapped)
            aiChatStore.updateHistoryPagination(
                hasMore: ev.hasMore,
                nextBeforeMessageId: ev.nextBeforeMessageId
            )
            return
        }

        aiChatStore.replaceMessages(mapped)
        // 共享消息流归一化入口
        let normalized = AISessionSemantics.normalizeMessageStream(
            sessionId: ev.sessionId,
            messages: ev.messages,
            primarySelectionHint: ev.selectionHint
        )
        aiChatStore.replaceQuestionRequests(normalized.pendingQuestionRequests)
        aiChatStore.updateHistoryPagination(
            hasMore: ev.hasMore,
            nextBeforeMessageId: ev.nextBeforeMessageId
        )
        applyAISessionSelectionHint(
            normalized.effectiveSelectionHint,
            sessionId: ev.sessionId,
            for: ev.aiTool
        )
        wsClient.requestAISessionConfigOptions(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        )
    }

    func handleAISessionMessagesUpdate(_ ev: AISessionMessagesUpdateV2) {
        _ = consumeSubAgentViewerMessagesUpdateIfNeeded(ev)
        // WI-003：四元组上下文校验 + 舞台生命周期防护
        guard aiChatStageAcceptsEvent(project: ev.projectName, workspace: ev.workspaceName, aiTool: ev.aiTool) else { return }
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }
        guard aiCurrentSessionId == ev.sessionId else { return }
        guard aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }
        if aiChatStore.isAbortPending(for: ev.sessionId) { return }

        if let messages = ev.messages {
            guard aiChatStore.shouldApplySessionCacheRevision(
                fromRevision: ev.fromRevision,
                toRevision: ev.toRevision,
                sessionId: ev.sessionId
            ) else { return }
            // 共享消息流归一化入口，与 ai_session_messages 走同一链路
            let normalized = AISessionSemantics.normalizeMessageStream(
                sessionId: ev.sessionId,
                messages: messages,
                primarySelectionHint: ev.selectionHint
            )
            aiChatStore.replaceMessagesFromSessionCache(messages, isStreaming: ev.isStreaming)
            aiChatStore.replaceQuestionRequests(normalized.pendingQuestionRequests)
            applyAISessionSelectionHint(
                normalized.effectiveSelectionHint,
                sessionId: ev.sessionId,
                for: ev.aiTool
            )
            return
        }

        if let ops = ev.ops {
            guard aiChatStore.shouldApplySessionCacheRevision(
                fromRevision: ev.fromRevision,
                toRevision: ev.toRevision,
                sessionId: ev.sessionId
            ) else { return }
            aiChatStore.applySessionCacheOps(ops, isStreaming: ev.isStreaming)
            if let hint = ev.selectionHint {
                applyAISessionSelectionHint(hint, sessionId: ev.sessionId, for: ev.aiTool)
            }
            return
        }

        if !ev.isStreaming {
            guard aiChatStore.shouldApplySessionCacheRevision(
                fromRevision: ev.fromRevision,
                toRevision: ev.toRevision,
                sessionId: ev.sessionId
            ) else { return }
            aiChatStore.applySessionCacheOps([], isStreaming: false)
        }
        if let hint = ev.selectionHint {
            applyAISessionSelectionHint(hint, sessionId: ev.sessionId, for: ev.aiTool)
        }
    }

    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) {
        upsertAISessionStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            contextRemainingPercent: ev.status.contextRemainingPercent
        )
        // WI-002：iOS 端终端 AI 状态同步（工作区粒度）
        syncAIStatusToWorkspace(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            toolName: ev.status.toolName
        )
        if aiActiveProject == ev.projectName,
           aiActiveWorkspace == ev.workspaceName,
           aiChatTool == ev.aiTool,
           aiCurrentSessionId == ev.sessionId,
           !AISessionStatusSnapshot(
               status: ev.status.status,
               errorMessage: ev.status.errorMessage,
               contextRemainingPercent: ev.status.contextRemainingPercent
           ).isActive {
            aiChatStore.handleChatDone(sessionId: ev.sessionId)
        }
    }

    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2) {
        upsertAISessionStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            contextRemainingPercent: ev.status.contextRemainingPercent
        )
        // WI-002：iOS 端终端 AI 状态同步（工作区粒度）
        syncAIStatusToWorkspace(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            toolName: ev.status.toolName
        )
        if aiActiveProject == ev.projectName,
           aiActiveWorkspace == ev.workspaceName,
           aiChatTool == ev.aiTool,
           aiCurrentSessionId == ev.sessionId,
           !AISessionStatusSnapshot(
               status: ev.status.status,
               errorMessage: ev.status.errorMessage,
               contextRemainingPercent: ev.status.contextRemainingPercent
           ).isActive {
            aiChatStore.handleChatDone(sessionId: ev.sessionId)
        }
    }

    func handleAIChatDone(_ ev: AIChatDoneV2) {
        consumeSubAgentViewerDoneIfNeeded(ev)
        // WI-002：done 兜底收敛落到工作区终端 AI 状态，不受当前选中工作区限制
        let fallbackStatus = fallbackSessionStatusForChatDone(stopReason: ev.stopReason)
        syncAIStatusToWorkspace(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            status: fallbackStatus,
            errorMessage: nil,
            toolName: nil
        )
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }
        aiChatStore.clearAbortPendingIfMatches(ev.sessionId)
        // WI-003：舞台生命周期 + 订阅双层防护
        guard aiChatStore.subscribedSessionIds.contains(ev.sessionId),
              aiChatStageLifecycle.acceptsSessionEvent(sessionId: ev.sessionId) else { return }
        aiChatStore.handleChatDone(sessionId: ev.sessionId)
        applyAISessionSelectionHint(
            ev.selectionHint,
            sessionId: ev.sessionId,
            for: ev.aiTool
        )
        // v1.42：存储路由决策与预算状态（按 project/workspace/aiTool/session 隔离）
        upsertAISessionRouteDecision(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            routeDecision: ev.routeDecision
        )
        upsertAIWorkspaceBudgetStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            budgetStatus: ev.budgetStatus
        )
    }

    func handleAIChatError(_ ev: AIChatErrorV2) {
        consumeSubAgentViewerErrorIfNeeded(ev)
        // WI-002：error 兜底收敛落到工作区终端 AI 状态，不受当前选中工作区限制
        syncAIStatusToWorkspace(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            status: "failure",
            errorMessage: ev.error,
            toolName: nil
        )
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }
        aiChatStore.clearAbortPendingIfMatches(ev.sessionId)
        // WI-003：舞台生命周期 + 订阅双层防护
        guard aiChatStore.subscribedSessionIds.contains(ev.sessionId),
              aiChatStageLifecycle.acceptsSessionEvent(sessionId: ev.sessionId) else { return }
        aiChatStore.handleChatError(sessionId: ev.sessionId, error: ev.error)
        // v1.42：存储路由决策（即使出错也记录，便于排查）
        upsertAISessionRouteDecision(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            routeDecision: ev.routeDecision
        )
    }

    func handleAIProviderList(_ ev: AIProviderListResult) {
        let providers = ev.providers.map { p in
            AIProviderInfo(
                id: p.id,
                name: p.name,
                models: p.models.map { m in
                    AIModelInfo(
                        id: m.id,
                        name: m.name,
                        providerID: m.providerID.isEmpty ? p.id : m.providerID,
                        supportsImageInput: m.supportsImageInput,
                        variants: m.variants
                    )
                }
            )
        }
        setEvolutionProviders(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            providers: providers
        )
        markEvolutionProviderListLoaded(
            project: ev.projectName,
            workspace: normalizeEvolutionWorkspaceName(ev.workspaceName),
            aiTool: ev.aiTool
        )
        if shouldAcceptSettingsSelectorEvent(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            kind: .providerList
        ) {
            consumeSettingsSelectorEventIfNeeded(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                kind: .providerList
            )
        }
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }
        aiProviders = providers
        if let selectedModel = aiSelectedModel {
            let allModels = providers.flatMap { $0.models }
            let stillValid = allModels.contains(where: {
                $0.id == selectedModel.modelID && $0.providerID == selectedModel.providerID
            })
            if !stillValid { aiSelectedModel = nil }
        }
        isAILoadingModels = false
        wsClient.requestAISessionConfigOptions(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: aiCurrentSessionId
        )
        retryPendingAISessionSelectionHint(for: ev.aiTool)
    }

    func handleAIAgentList(_ ev: AIAgentListResult) {
        let agents = ev.agents.map { a in
            AIAgentInfo(
                name: a.name,
                description: a.description,
                mode: a.mode,
                color: a.color,
                defaultProviderID: a.defaultProviderID,
                defaultModelID: a.defaultModelID
            )
        }
        setEvolutionAgents(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            agents: agents
        )
        markEvolutionAgentListLoaded(
            project: ev.projectName,
            workspace: normalizeEvolutionWorkspaceName(ev.workspaceName),
            aiTool: ev.aiTool
        )
        if shouldAcceptSettingsSelectorEvent(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            kind: .agentList
        ) {
            consumeSettingsSelectorEventIfNeeded(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                kind: .agentList
            )
        }
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }
        aiAgents = agents
        isAILoadingAgents = false
        if aiSelectedAgent == nil {
            let first = aiAgents.first(where: { $0.mode == "primary" || $0.mode == "all" }) ?? aiAgents.first
            aiSelectedAgent = first?.name
            applyAgentDefaultModel(first)
        }
        wsClient.requestAISessionConfigOptions(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: aiCurrentSessionId
        )
        retryPendingAISessionSelectionHint(for: ev.aiTool)
    }

    func handleAISlashCommands(_ ev: AISlashCommandsResult) {
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName else { return }
        let commands = ev.commands.map {
            AISlashCommandInfo(
                name: $0.name,
                description: $0.description,
                action: $0.action,
                inputHint: $0.inputHint
            )
        }
        setAISlashCommands(commands, for: ev.aiTool, sessionId: ev.sessionID)
    }

    func handleAISlashCommandsUpdate(_ ev: AISlashCommandsUpdateResult) {
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName else { return }
        let commands = ev.commands.map {
            AISlashCommandInfo(
                name: $0.name,
                description: $0.description,
                action: $0.action,
                inputHint: $0.inputHint
            )
        }
        setAISlashCommands(commands, for: ev.aiTool, sessionId: ev.sessionID)
    }

    func handleAISessionConfigOptions(_ ev: AISessionConfigOptionsResult) {
        guard shouldAcceptAISessionConfigOptionsEvent(
            project: ev.projectName,
            workspace: ev.workspaceName
        ) else { return }
        setAISessionConfigOptions(ev.options, for: ev.aiTool)
        if aiActiveProject == ev.projectName, aiActiveWorkspace == ev.workspaceName {
            retryPendingAISessionSelectionHint(for: ev.aiTool)
        }
    }

    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2) {
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }
        guard aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }
        aiChatStore.upsertQuestionRequest(ev.request)
    }

    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) {
        guard aiActiveProject == ev.projectName,
              aiActiveWorkspace == ev.workspaceName,
              aiChatTool == ev.aiTool else { return }
        guard aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }
        completeAIQuestionRequestLocally(requestId: ev.requestId)
    }

    func handleAISessionRenameResult(_ ev: AISessionRenameResult) {
        guard let tool = AIChatTool(rawValue: ev.aiTool) else { return }
        guard let old = (aiSessionsByTool[tool] ?? []).first(where: { $0.id == ev.sessionId })
            ?? cachedAISession(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: tool,
                sessionId: ev.sessionId
            ) else { return }
        let updated = AISessionInfo(
            projectName: old.projectName,
            workspaceName: old.workspaceName,
            aiTool: old.aiTool,
            id: old.id,
            title: ev.title,
            updatedAt: ev.updatedAt > 0 ? ev.updatedAt : old.updatedAt,
            origin: old.origin
        )
        if var sessions = aiSessionsByTool[tool],
           let idx = sessions.firstIndex(where: { $0.id == ev.sessionId }) {
            sessions[idx] = updated
            setAISessions(sessions, for: tool)
        }
        aiSessionIndexByKey[updated.sessionKey] = updated
        aiSessionListStore.renameSession(updated, newTitle: updated.title)
    }

    func handleAIContextSnapshotUpdated(_ json: [String: Any]) {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiToolRaw = json["ai_tool"] as? String,
              let aiTool = AIChatTool(rawValue: aiToolRaw),
              let sessionId = json["session_id"] as? String,
              let snapshotJson = json["snapshot"] as? [String: Any],
              let snapshot = AISessionContextSnapshot.from(json: snapshotJson) else { return }
        let key = AISessionSemantics.contextSnapshotKey(
            project: projectName,
            workspace: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId
        )
        aiSessionContextSnapshots[key] = snapshot
    }

    // MARK: - AI 订阅确认处理（WI-002：与 macOS 对称）

    /// 处理 `ai_session_subscribe_ack`：
    /// - 仅在舞台处于 entering/resuming 且上下文匹配时驱动 `ready` 或 `resumeCompleted`。
    /// - 迟到 ack、关闭后 ack 和 forceReset 后 ack 都会被忽略，不会把 idle 舞台错误拉回 active。
    func handleAISessionSubscribeAck(_ ev: AISessionSubscribeAck) {
        // Evolution 回放订阅确认
        if let replayRequest = evolutionReplayRequest,
           replayRequest.sessionId == ev.sessionId {
            if !ev.projectName.isEmpty, !ev.workspaceName.isEmpty {
                guard ev.projectName == replayRequest.project,
                      normalizeEvolutionWorkspaceName(ev.workspaceName) == normalizeEvolutionWorkspaceName(replayRequest.workspace) else {
                    NSLog(
                        "[MobileAppState] AI replay subscribe ack workspace mismatch: ack=(%@/%@) request=(%@/%@) session_id=%@",
                        ev.projectName, ev.workspaceName, replayRequest.project, replayRequest.workspace, ev.sessionId
                    )
                    return
                }
            }
        }

        // 舞台生命周期防护：仅在 entering/resuming 阶段接受 ack
        let stage = aiChatStageLifecycle.state
        let stagePhase = stage.phase

        guard stagePhase == .entering || stagePhase == .resuming || stagePhase == .active else {
            NSLog(
                "[MobileAppState] AI subscribe ack ignored: stage=%@, session_id=%@",
                stagePhase.rawValue, ev.sessionId
            )
            return
        }

        // 多工作区上下文四元组防护
        if !ev.projectName.isEmpty, !ev.workspaceName.isEmpty {
            guard ev.projectName == aiActiveProject,
                  ev.workspaceName == aiActiveWorkspace else {
                NSLog(
                    "[MobileAppState] AI subscribe ack workspace mismatch: ack=(%@/%@) active=(%@/%@) session_id=%@",
                    ev.projectName, ev.workspaceName, aiActiveProject, aiActiveWorkspace, ev.sessionId
                )
                return
            }
        }

        // 确认订阅
        aiChatStore.addSubscription(ev.sessionId)
        NSLog(
            "[MobileAppState] AI subscribe ack: tool=%@, session_id=%@, stage=%@",
            aiChatTool.rawValue, ev.sessionId, stagePhase.rawValue
        )

        // ack 确认后拉消息（确保 Core 已进入推送模式）
        if aiCurrentSessionId == ev.sessionId {
            wsClient.requestAISessionMessages(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: aiChatTool,
                sessionId: ev.sessionId,
                limit: 50
            )
        }

        // 根据当前舞台阶段驱动迁移
        if stagePhase == .resuming {
            // 重连恢复完成
            markAIChatStageResumeCompleted()
        } else if stagePhase == .entering {
            // 初次进入就绪
            markAIChatStageReady()
        }
    }

    // MARK: - AI 上下文投影清理（WI-003：多工作区隔离）

    /// 清理旧工作区/工具的 AI 上下文投影残留。
    /// 在工作区切换、工具切换和断连重置后调用，防止 active/resuming 投影残留到新上下文。
    func cleanupOldAIContextProjection() {
        // 清空旧上下文的缓存快照
        aiSessionContextSnapshots.removeAll()
        // 清理 store 订阅状态
        aiChatStore.clearAll()
    }

    /// 处理 HTTP 读取失败（多工作区安全版本）。
    ///
    /// 与 macOS `handleHTTPReadFailure` 语义对齐：
    /// - 仅当失败归属当前激活的 (project, workspace, aiTool) 时才更新 UI 状态。
    /// - 跨工作区的 HTTP 失败不影响当前激活工作区。
    @MainActor
    func handleHTTPReadFailure(_ failure: WSClient.HTTPReadFailure) {
        guard let context = failure.context else { return }

        switch context {
        case let .aiProviderList(project, workspace, aiTool):
            guard aiChatTool == aiTool,
                  aiActiveProject == project,
                  aiActiveWorkspace == workspace else { return }
            if isAILoadingModels {
                isAILoadingModels = false
            }

        case let .aiAgentList(project, workspace, aiTool):
            guard aiChatTool == aiTool,
                  aiActiveProject == project,
                  aiActiveWorkspace == workspace else { return }
            if isAILoadingAgents {
                isAILoadingAgents = false
            }
        case let .fileRead(project, workspace, path):
            if let pending = pendingExplorerPreviewRequest,
               pending.project == project,
               pending.workspace == workspace,
               pending.path == path {
                pendingExplorerPreviewRequest = nil
                explorerPreviewLoading = false
                explorerPreviewError = failure.message
                explorerPreviewContent = ""
            }

            if pendingPlanDocumentReadPath == path,
               aiActiveProject == project,
               aiActiveWorkspace == workspace {
                pendingPlanDocumentReadPath = nil
                evolutionPlanDocumentLoading = false
                evolutionPlanDocumentError = failure.message
            }
        }
    }
}

// MARK: - MobileAppStateAIMessageHandlerAdapter

/// iOS 端 AI 消息处理适配器，与 macOS AppStateAIMessageHandlerAdapter 对称。
/// 持有对 MobileAppState 的弱引用，由 wsClient.aiMessageHandler 统一分发事件。
/// 所有 AI 消息经此单一入口路由，确保 macOS/iOS 共享相同的消息边界与协议语义。
final class MobileAppStateAIMessageHandlerAdapter: AIMessageHandler {
    weak var appState: MobileAppState?

    init(appState: MobileAppState) {
        self.appState = appState
    }

    /// WSClient 在解码队列回调协议方法；这里统一切回主线程，避免 UI 状态跨线程写入。
    private func dispatchToMain(_ action: @escaping @MainActor (MobileAppState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            MainActor.assumeIsolated {
                action(appState)
            }
        }
    }

    func handleAITaskCancelled(_ result: AITaskCancelled) {
        dispatchToMain { $0.handleAITaskCancelled(result) }
    }

    func handleAISessionStarted(_ ev: AISessionStartedV2) {
        dispatchToMain { $0.handleAISessionStarted(ev) }
    }

    func handleAISessionList(_ ev: AISessionListV2) {
        dispatchToMain { $0.handleAISessionList(ev) }
    }

    func handleAISessionMessages(_ ev: AISessionMessagesV2) {
        dispatchToMain { $0.handleAISessionMessages(ev) }
    }

    func handleAISessionMessagesUpdate(_ ev: AISessionMessagesUpdateV2) {
        dispatchToMain { $0.handleAISessionMessagesUpdate(ev) }
    }

    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) {
        dispatchToMain { $0.handleAISessionStatusResult(ev) }
    }

    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2) {
        dispatchToMain { $0.handleAISessionStatusUpdate(ev) }
    }

    func handleAIChatDone(_ ev: AIChatDoneV2) {
        dispatchToMain { $0.handleAIChatDone(ev) }
    }

    func handleAIChatError(_ ev: AIChatErrorV2) {
        dispatchToMain { $0.handleAIChatError(ev) }
    }

    func handleAIProviderList(_ ev: AIProviderListResult) {
        dispatchToMain { $0.handleAIProviderList(ev) }
    }

    func handleAIAgentList(_ ev: AIAgentListResult) {
        dispatchToMain { $0.handleAIAgentList(ev) }
    }

    func handleAISlashCommands(_ ev: AISlashCommandsResult) {
        dispatchToMain { $0.handleAISlashCommands(ev) }
    }

    func handleAISlashCommandsUpdate(_ ev: AISlashCommandsUpdateResult) {
        dispatchToMain { $0.handleAISlashCommandsUpdate(ev) }
    }

    func handleAISessionConfigOptions(_ ev: AISessionConfigOptionsResult) {
        dispatchToMain { $0.handleAISessionConfigOptions(ev) }
    }

    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2) {
        dispatchToMain { $0.handleAIQuestionAsked(ev) }
    }

    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) {
        dispatchToMain { $0.handleAIQuestionCleared(ev) }
    }

    func handleAISessionRenameResult(_ ev: AISessionRenameResult) {
        dispatchToMain { $0.handleAISessionRenameResult(ev) }
    }

    func handleAISessionSubscribeAck(_ ev: AISessionSubscribeAck) {
        dispatchToMain { $0.handleAISessionSubscribeAck(ev) }
    }

    func handleAIContextSnapshotUpdated(_ json: [String: Any]) {
        dispatchToMain { $0.handleAIContextSnapshotUpdated(json) }
    }
}
