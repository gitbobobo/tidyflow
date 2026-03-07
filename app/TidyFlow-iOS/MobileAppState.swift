import Foundation
import SwiftUI
import UIKit

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
    private var clientFixedPort: Int = 0
    private var clientRemoteAccessEnabled: Bool = false
    // AI Chat 状态（iOS 端完整对齐 macOS）
    @Published var aiActiveProject: String = ""
    @Published var aiActiveWorkspace: String = ""
    @Published var aiChatTool: AIChatTool = .opencode
    @Published var aiCurrentSessionId: String?
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
    /// 正在加载会话列表的 AI 工具集合
    @Published var aiSessionListLoadingTools: Set<AIChatTool> = []
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
    @Published var aiSelectedThoughtLevel: String? {
        didSet {
            aiSelectedThoughtLevelByTool[aiChatTool] = aiSelectedThoughtLevel
            syncThoughtLevelConfigOptionForCurrentTool()
        }
    }
    @Published var aiSlashCommands: [AISlashCommandInfo] = []
    @Published var isAILoadingModels: Bool = false
    @Published var isAILoadingAgents: Bool = false
    @Published var aiFileIndexCache: [String: FileIndexCache] = [:]
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
    private var pendingPlanDocumentReadPath: String?
    @Published var evidenceSnapshotsByWorkspace: [String: EvidenceSnapshotV2] = [:]
    @Published var evidenceLoadingByWorkspace: [String: Bool] = [:]
    @Published var evidenceErrorByWorkspace: [String: String] = [:]
    @Published var aiChatOneShotHintByWorkspace: [String: String] = [:]
    @Published var subAgentViewerTitle: String = ""
    @Published var subAgentViewerLoading: Bool = false
    @Published var subAgentViewerError: String?
    /// ClientSettings 下发的 Evolution 代理配置（key: "project/workspace"）
    private var evolutionProfilesFromClientSettings: [String: [EvolutionStageProfileInfoV2]] = [:]
    @Published private var evolutionProvidersByWorkspace: [String: [AIChatTool: [AIProviderInfo]]] = [:]
    @Published private var evolutionAgentsByWorkspace: [String: [AIChatTool: [AIAgentInfo]]] = [:]
    /// Evolution：按工作空间追踪 provider/agent 列表是否齐全，用于串联 profile 加载时序。
    private var evolutionSelectorLoadStateByWorkspace: [String: [AIChatTool: (providerLoaded: Bool, agentLoaded: Bool)]] = [:]
    /// Evolution：等待在列表齐全后拉取 profile 的工作空间 key 集合。
    private var evolutionPendingProfileReloadWorkspaces: Set<String> = []
    /// Evolution：profile 请求兜底定时器。
    private var evolutionProfileReloadFallbackTimers: [String: DispatchWorkItem] = [:]
    private var evolutionPendingActionByWorkspace: [String: String] = [:]
    private var evidencePromptCompletionByWorkspace: [String: (_ prompt: EvidenceRebuildPromptV2?, _ errorMessage: String?) -> Void] = [:]
    private var evidenceReadRequestByWorkspace: [String: MobileEvidenceReadRequestState] = [:]

    let aiChatStore = AIChatStore()
    let subAgentViewerStore = AIChatStore()

    // AI Chat：按工具分桶存储会话
    private var aiSessionsByTool: [AIChatTool: [AISessionInfo]] = [:]
    private var aiSlashCommandsByTool: [AIChatTool: [AISlashCommandInfo]] = [:]
    private var aiSlashCommandsBySessionByTool: [AIChatTool: [String: [AISlashCommandInfo]]] = [:]
    private var aiSessionConfigOptionsByTool: [AIChatTool: [AIProtocolSessionConfigOptionInfo]] = [:]
    private var aiSelectedConfigOptionsByTool: [AIChatTool: [String: Any]] = [:]
    private var aiSelectedThoughtLevelByTool: [AIChatTool: String?] = [:]
    private var aiPendingSessionSelectionHintsByTool: [AIChatTool: [String: AISessionSelectionHint]] = [:]
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
    /// 待创建终端的项目/工作空间（等终端视图 ready 后再真正创建）
    private var pendingTermProject: String = ""
    private var pendingTermWorkspace: String = ""
    /// 待附着的终端 ID（重连场景）
    private var pendingAttachTermId: String = ""
    /// 待执行的自定义命令（终端创建后自动发送）
    private var pendingCustomCommand: String = ""
    /// 待执行命令图标（用于终端列表展示）
    private var pendingCustomCommandIcon: String = ""
    /// 待执行命令名称（用于终端列表展示）
    private var pendingCustomCommandName: String = ""
    /// Ctrl 一次性修饰状态（用于虚拟键盘输入）
    private var ctrlArmedForNextInput: Bool = false
    /// 终端视图是否已经拿到有效 cols/rows
    private var isTerminalViewReady: Bool = false
    /// ACK 阈值（50KB），与 macOS 原生终端端保持一致
    private let termOutputAckThreshold = 50 * 1024

    /// 共享终端会话存储：按 project/workspace/termId 隔离，统一管理展示信息、
    /// 置顶状态、attach/detach 请求时间和输出 ACK 计数，与 macOS 共享语义。
    let terminalSessionStore = TerminalSessionStore()

    /// 原生终端输出目标（SwiftTerm）
    private weak var terminalSink: MobileTerminalOutputSink?
    /// 终端未 ready 或尚未绑定 sink 时暂存输出，避免首屏丢数据
    private var pendingOutputChunks: [[UInt8]] = []
    private let pendingOutputChunkLimit = 128
    /// 记录最近一次已重置并开始渲染的 term_id，用于避免 SwiftUI 复用视图导致内容串台
    private var lastRenderedTermId: String = ""
    /// AI 提交结果不带 project/workspace，按触发顺序匹配
    private var aiCommitPendingTaskIds: [String] = []
    /// AI 合并按 project 匹配
    private var aiMergePendingTaskIdByProject: [String: String] = [:]
    /// AI 会话状态请求限流（key: project/workspace/tool/session）。
    private var aiSessionStatusRequestLimiter = AISessionStatusRequestLimiter()
    private let aiSessionStatusMinInterval: TimeInterval = 1.2
    /// AI Chat：等待会话创建完成后的待发送请求（含上下文防串台）
    private var aiPendingSendRequest: (
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        kind: PendingAIRequestKind
    )?
    /// 项目命令 started/completed 路由（project|workspace|commandId -> taskId 队列）
    private var projectCommandPendingTaskIdsByKey: [String: [String]] = [:]
    /// 项目命令 remote task_id -> 本地 taskId
    private var projectCommandTaskIdByRemoteTaskId: [String: String] = [:]
    /// Evolution 阶段聊天回放请求
    private var evolutionReplayRequest: (
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
    private var selectedProjectName: String = ""
    /// 资源管理器预览请求（用于过滤过期回调）
    private var pendingExplorerPreviewRequest: (project: String, workspace: String, path: String)?

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

    private let wsClient = WSClient()
    /// 重连任务（指数退避）
    private var reconnectTask: Task<Void, Never>?
    init() {
        setupWSCallbacks()
        for tool in AIChatTool.allCases {
            aiSessionsByTool[tool] = []
            aiSlashCommandsByTool[tool] = []
            aiSlashCommandsBySessionByTool[tool] = [:]
            aiSessionConfigOptionsByTool[tool] = []
            aiSelectedConfigOptionsByTool[tool] = [:]
            aiSelectedThoughtLevelByTool[tool] = nil
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
        wsClient.requestTermList()
        wsClient.requestGitStatus(project: project, workspace: workspace)
        wsClient.requestGitBranches(project: project, workspace: workspace)
        fetchExplorerFileList(project: project, workspace: workspace, path: ".")
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

        fetchExplorerFileList(project: project, workspace: workspace, path: ".")
        for path in expandedPaths where path != "." {
            fetchExplorerFileList(project: project, workspace: workspace, path: path)
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

    func fetchExplorerFileList(project: String, workspace: String, path: String = ".") {
        guard isConnected else {
            let key = explorerCacheKey(project: project, workspace: workspace, path: path)
            var cache = explorerFileListCache[key] ?? FileListCache.empty()
            cache.isLoading = false
            cache.error = "连接已断开"
            explorerFileListCache[key] = cache
            return
        }

        let key = explorerCacheKey(project: project, workspace: workspace, path: path)
        var cache = explorerFileListCache[key] ?? FileListCache.empty()
        cache.isLoading = true
        cache.error = nil
        explorerFileListCache[key] = cache
        wsClient.requestFileList(project: project, workspace: workspace, path: path)
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

    func workspacesForProject(_ project: String) -> [WorkspaceInfo] {
        workspacesByProject[project] ?? []
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

    /// iOS 侧与 macOS 相同的项目排序策略
    var sortedProjectsForSidebar: [ProjectInfo] {
        projects.sorted { lhs, rhs in
            let lhsHasShortcut = projectMinShortcutKey(lhs) < Int.max
            let rhsHasShortcut = projectMinShortcutKey(rhs) < Int.max
            if lhsHasShortcut != rhsHasShortcut {
                return lhsHasShortcut
            }

            if lhsHasShortcut && rhsHasShortcut {
                let lhsTime = projectEarliestTerminalTime(lhs)
                let rhsTime = projectEarliestTerminalTime(rhs)
                if let l = lhsTime, let r = rhsTime, l != r {
                    return l < r
                }
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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

    /// 清除指定工作空间的已完成任务
    func clearCompletedTasks(project: String, workspace: String) {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        taskStore.clearCompleted(for: key)
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

    func consumeAIChatOneShotHint(project: String, workspace: String) -> String? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        let hint = aiChatOneShotHintByWorkspace[key]
        aiChatOneShotHintByWorkspace.removeValue(forKey: key)
        return hint
    }

    func openEvolutionStageChat(project: String, workspace: String, cycleId: String, stage: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        // WI-002：在打开新回放前先取消旧回放会话的订阅，阻断旧会话内容回灌
        if let request = evolutionReplayRequest {
            wsClient.requestAISessionUnsubscribe(
                project: request.project,
                workspace: request.workspace,
                aiTool: request.aiTool.rawValue,
                sessionId: request.sessionId
            )
        }
        evolutionReplayTitle = "\(normalizedWorkspace) · \(stage) · \(cycleId)"
        evolutionReplayRequest = nil
        evolutionReplayMessages = []
        evolutionReplayError = nil
        evolutionReplayLoading = true
        wsClient.requestEvoOpenStageChat(
            project: project,
            workspace: normalizedWorkspace,
            cycleID: cycleId,
            stage: stage
        )
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

    private func finishEvolutionProfileReloadTracking(project: String, workspace: String) {
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
            ev.cacheRevision,
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

        let contextChanged = aiActiveProject != trimmedProject || aiActiveWorkspace != trimmedWorkspace
        if contextChanged {
            saveCurrentAISnapshotIfNeeded()
            aiPendingSendRequest = nil
            aiAbortPendingSessionId = nil
            aiSessionListLoadingTools.removeAll()
        }

        aiActiveProject = trimmedProject
        aiActiveWorkspace = trimmedWorkspace

        if contextChanged {
            restoreAISnapshot(project: trimmedProject, workspace: trimmedWorkspace)
        } else if aiChatMessages.isEmpty {
            // 同一上下文视图重建时，优先从快照恢复，避免页面闪空
            restoreAISnapshot(project: trimmedProject, workspace: trimmedWorkspace)
        }

        aiProviders = []
        aiSelectedModel = nil
        aiAgents = []
        aiSelectedAgent = nil
        aiSessionConfigOptions = aiSessionConfigOptionsByTool[aiChatTool] ?? []
        aiSelectedThoughtLevel = aiSelectedThoughtLevelByTool[aiChatTool] ?? nil
        refreshCurrentAISlashCommands(for: aiChatTool)
        requestAIContextResources()
        reloadCurrentAISessionIfNeeded()
    }

    /// 离开 AI 聊天页面：仅保存快照，不主动清空上下文，便于返回时秒级恢复
    func closeAIChat() {
        saveCurrentAISnapshotIfNeeded()
        aiPendingSendRequest = nil
        aiAbortPendingSessionId = nil
    }

    /// 新建空会话（本地清空态）
    func createNewAISession() {
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

    /// 切换 AI 工具（仅空白会话允许）
    func switchAIChatTool(_ newTool: AIChatTool) {
        guard newTool != aiChatTool else { return }
        guard canSwitchAIChatTool else { return }

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
            aiSelectedThoughtLevel = aiSelectedThoughtLevelByTool[newTool] ?? nil
            refreshCurrentAISlashCommands(for: newTool)
            requestAIContextResources()
            reloadCurrentAISessionIfNeeded()
        }
    }

    /// 拉取会话列表 + provider/agent/斜杠命令
    func requestAIContextResources() {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        // 会话列表按工具分别拉取，再在客户端做跨工具融合排序
        for tool in AIChatTool.allCases {
            requestAISessionList(for: tool)
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

    /// 拉取指定 AI 工具的会话列表
    func requestAISessionList(for tool: AIChatTool) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else {
            aiSessionListLoadingTools.remove(tool)
            return
        }
        aiSessionListLoadingTools.insert(tool)
        wsClient.requestAISessionList(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: tool
        )
    }

    /// 加载指定会话消息
    func loadAISession(_ session: AISessionInfo) {
        guard session.projectName == aiActiveProject,
              session.workspaceName == aiActiveWorkspace else { return }

        let targetTool = session.aiTool
        let previousTool = aiChatTool
        let previousSessionId = aiCurrentSessionId

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
            aiSelectedThoughtLevel = aiSelectedThoughtLevelByTool[targetTool] ?? nil
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
            sessions.removeAll { $0.id == session.id }
            setAISessions(sessions, for: targetTool)
        }
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
                                toolName: nil,
                                toolState: nil
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
        // 兜底：避免"工具与 session_id 不匹配"时把请求发到错误后端（如 opencode + codex 线程 ID）。
        let currentToolSessions = aiSessionsByTool[aiChatTool] ?? []
        let existsInCurrentTool = currentToolSessions.contains { $0.id == sessionId }
        guard existsInCurrentTool else {
            aiCurrentSessionId = nil
            aiChatStore.setCurrentSessionId(nil)
            aiChatStore.setAbortPendingSessionId(nil)
            aiChatStore.clearMessages()
            return
        }
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

        // 重连后补拉各工具会话列表
        for tool in AIChatTool.allCases {
            wsClient.requestAISessionList(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: tool
            )
        }

        // 若有选中会话，通过共享协调器重新订阅并补拉以恢复流式状态
        for tool in AIChatTool.allCases {
            let sessions = aiSessionsByTool[tool] ?? []
            guard let sessionId = (tool == aiChatTool ? aiCurrentSessionId : nil),
                  !sessionId.isEmpty,
                  sessions.contains(where: { $0.id == sessionId }) else { continue }
            let context = AISessionHistoryCoordinator.Context(
                project: aiActiveProject,
                workspace: aiActiveWorkspace,
                aiTool: tool,
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
                aiTool: tool,
                sessionId: sessionId
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

    private func aiContextKey(project: String, workspace: String) -> String {
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

    func thoughtLevelOptions(for tool: AIChatTool) -> [String] {
        if let option = aiSessionConfigOptionsByTool[tool]?.first(where: {
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
        if let optionID = optionIDForCategory("thought_level", in: aiSessionConfigOptionsByTool[tool] ?? []) {
            return optionID
        }
        if tool == .codex {
            return "thought_level"
        }
        return nil
    }

    func thoughtLevelOptions() -> [String] {
        thoughtLevelOptions(for: aiChatTool)
    }

    func aiConfigOverrides(for tool: AIChatTool? = nil) -> [String: Any]? {
        let targetTool = tool ?? aiChatTool
        let options = aiSessionConfigOptionsByTool[targetTool] ?? []
        guard !options.isEmpty else { return nil }
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
        if let thoughtOptionID = optionIDForCategory("thought_level", in: options),
           let thought = (aiSelectedThoughtLevelByTool[targetTool] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thought.isEmpty {
            overrides[thoughtOptionID] = thought
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
            if let thoughtOptionID = optionIDForCategory("thought_level", in: options),
               let thought = aiSelectedThoughtLevel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thought.isEmpty {
                selected[thoughtOptionID] = thought
            }
        }
        selected = selected.filter { validOptionIDs.contains($0.key) }
        aiSelectedConfigOptionsByTool[tool] = selected

        refreshThoughtLevelFromConfig(for: tool)
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
            if category == "thought_level" {
                setAISelectedThoughtLevel(configValueAsString(value), for: tool, syncConfigOption: false)
            }
        }
        refreshThoughtLevelFromConfig(for: tool)
    }

    private func setAISelectedThoughtLevel(
        _ value: String?,
        for tool: AIChatTool,
        syncConfigOption: Bool = true
    ) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalValue = (normalized?.isEmpty == true) ? nil : normalized
        aiSelectedThoughtLevelByTool[tool] = finalValue
        if tool == aiChatTool {
            aiSelectedThoughtLevel = finalValue
        }
        guard syncConfigOption,
              let optionID = optionIDForCategory("thought_level", in: aiSessionConfigOptionsByTool[tool] ?? []) else {
            return
        }
        if let finalValue {
            updateConfigOptionValue(optionID: optionID, value: finalValue, for: tool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: tool)
        }
    }

    private func refreshThoughtLevelFromConfig(for tool: AIChatTool) {
        let options = aiSessionConfigOptionsByTool[tool] ?? []
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

    private func syncThoughtLevelConfigOptionForCurrentTool() {
        guard let optionID = optionIDForCategory("thought_level", in: aiSessionConfigOptionsByTool[aiChatTool] ?? []) else { return }
        let normalized = aiSelectedThoughtLevel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            updateConfigOptionValue(optionID: optionID, value: normalized, for: aiChatTool)
        } else {
            updateConfigOptionValue(optionID: optionID, value: nil, for: aiChatTool)
        }
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
                if category == "thought_level" {
                    setAISelectedThoughtLevel(configValueAsString(value), for: tool, syncConfigOption: false)
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

    func setAISessions(_ sessions: [AISessionInfo], for tool: AIChatTool) {
        let sortedSessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
        aiSessionsByTool[tool] = sortedSessions
        aiSessionListLoadingTools.remove(tool)
        if aiChatTool == tool {
            aiSessions = sortedSessions
        }
    }

    /// 获取指定工具的会话列表
    func aiSessionsForTool(_ tool: AIChatTool) -> [AISessionInfo] {
        aiSessionsByTool[tool] ?? []
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

    private func requestAISessionStatus(
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
            sessionId: sessionId
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

    private func switchToTerminal(termId: String) {
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
    }

    // MARK: - WS 回调

    private func setupWSCallbacks() {
        wsClient.onConnectionStateChanged = { [weak self] connected in
            guard let self else { return }
            if connected {
                self.connectionPhase = .connected
                self.connectionMessage = "连接成功"
                self.errorMessage = ""
                self.refreshProjectTree()
                self.wsClient.requestEvoSnapshot()
                // 重连成功后重新附着终端输出订阅（后台期间订阅可能已丢失）
                self.reattachTerminalIfNeeded()
                // 重连后恢复 AI 会话数据（流式输出可能中断，需重新拉取）
                self.reloadAISessionDataAfterReconnect()
                // 恢复键盘焦点
                self.terminalSink?.focusTerminal()
            } else {
                self.connectionMessage = "连接断开"
                if !self.wsClient.isIntentionalDisconnect {
                    // 意外断连：通过共享语义层驱动重连
                    self.reconnectWithBackoff()
                } else {
                    self.connectionPhase = .intentionallyDisconnected
                }
            }
        }

        wsClient.onProjectsList = { [weak self] result in
            guard let self else { return }
            self.projects = result.items
            let names = Set(result.items.map(\.name))
            self.workspacesByProject = self.workspacesByProject.filter { names.contains($0.key) }
            for project in result.items {
                self.wsClient.requestListWorkspaces(project: project.name)
            }
        }

        wsClient.onWorkspacesList = { [weak self] result in
            guard let self else { return }
            self.workspacesByProject[result.project] = result.items
            if self.selectedProjectName == result.project || self.workspaces.isEmpty {
                self.workspaces = result.items
            }
        }

        wsClient.onFileListResult = { [weak self] result in
            guard let self else { return }
            let key = self.explorerCacheKey(project: result.project, workspace: result.workspace, path: result.path)
            self.explorerFileListCache[key] = FileListCache(
                items: result.items,
                isLoading: false,
                error: nil,
                updatedAt: Date()
            )
        }

        wsClient.onFileWriteResult = { [weak self] result in
            guard let self else { return }
            if result.success {
                self.refreshExplorer(project: result.project, workspace: result.workspace)
            } else {
                self.errorMessage = "新建文件失败：\(result.path)"
            }
        }

        wsClient.onFileRenameResult = { [weak self] result in
            guard let self else { return }
            if result.success {
                self.refreshExplorer(project: result.project, workspace: result.workspace)
            } else {
                self.errorMessage = result.message ?? "重命名失败"
            }
        }

        wsClient.onFileDeleteResult = { [weak self] result in
            guard let self else { return }
            if result.success {
                self.refreshExplorer(project: result.project, workspace: result.workspace)
            } else {
                self.errorMessage = result.message ?? "删除失败"
            }
        }

        wsClient.onFileReadResult = { [weak self] result in
            guard let self else { return }

            // 计划文档预览分流
            if let pendingPath = self.pendingPlanDocumentReadPath, pendingPath == result.path {
                self.pendingPlanDocumentReadPath = nil
                self.evolutionPlanDocumentLoading = false
                let bytes = Data(result.content)
                if let text = String(data: bytes, encoding: .utf8) {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.evolutionPlanDocumentError = "evolution.page.planDocument.empty".localized
                        self.evolutionPlanDocumentContent = nil
                    } else {
                        self.evolutionPlanDocumentContent = text
                    }
                } else {
                    self.evolutionPlanDocumentError = "evolution.page.planDocument.empty".localized
                    self.evolutionPlanDocumentContent = nil
                }
                return
            }

            guard let pending = self.pendingExplorerPreviewRequest else { return }
            guard pending.project == result.project,
                  pending.workspace == result.workspace,
                  pending.path == result.path else { return }
            self.pendingExplorerPreviewRequest = nil
            self.explorerPreviewLoading = false

            let bytes = Data(result.content)
            if result.size > 256 * 1024 {
                self.explorerPreviewError = "文件过大，暂不支持预览"
                self.explorerPreviewContent = ""
                return
            }

            if let text = String(data: bytes, encoding: .utf8) {
                self.explorerPreviewError = nil
                self.explorerPreviewContent = text
            } else {
                self.explorerPreviewError = "二进制文件暂不支持预览"
                self.explorerPreviewContent = ""
            }
        }

        wsClient.onGitStatusResult = { [weak self] result in
            guard let self else { return }
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            // 统一写入 workspaceGitDetailState，additions/deletions 汇总通过 semanticSnapshot 按需计算
            var detail = self.workspaceGitDetailState[key] ?? MobileWorkspaceGitDetailState.empty()
            detail.currentBranch = result.currentBranch
            detail.defaultBranch = result.defaultBranch
            detail.isGitRepo = result.isGitRepo
            detail.aheadBy = result.aheadBy
            detail.behindBy = result.behindBy
            let staged = result.items.filter { $0.staged == true }
            let unstaged = result.items.filter { $0.staged != true }
            detail.stagedItems = staged
            detail.unstagedItems = unstaged
            self.workspaceGitDetailState[key] = detail
        }

        wsClient.onGitBranchesResult = { [weak self] result in
            guard let self else { return }
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            var detail = self.workspaceGitDetailState[key] ?? MobileWorkspaceGitDetailState.empty()
            detail.currentBranch = result.current
            detail.branches = result.branches
            self.workspaceGitDetailState[key] = detail
        }

        wsClient.onGitCommitResult = { [weak self] result in
            guard let self else { return }
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            var detail = self.workspaceGitDetailState[key] ?? MobileWorkspaceGitDetailState.empty()
            detail.isCommitting = false
            detail.commitResult = result.ok ? "提交成功" : (result.message ?? "提交失败")
            // 提交成功后刷新 Git 状态
            if result.ok {
                detail.stagedItems = []
                self.wsClient.requestGitStatus(project: result.project, workspace: result.workspace)
            }
            self.workspaceGitDetailState[key] = detail
        }

        wsClient.onTermList = { [weak self] result in
            guard let self else { return }
            self.activeTerminals = result.items
            // 通过共享终端存储协调 term_list 恢复（清理过期条目 + 服务端展示信息兜底恢复 + open time 更新）
            self.terminalSessionStore.reconcileTermList(
                items: result.items,
                makeKey: self.globalWorkspaceKey(project:workspace:)
            )
            self.workspaceTerminalOpenTime = self.terminalSessionStore.workspaceOpenTime
        }

        wsClient.onTermCreated = { [weak self] result in
            guard let self else { return }
            self.switchToTerminal(termId: result.termId)
            // 通过共享终端存储处理 term_created（展示信息 + open time）
            self.terminalSessionStore.handleTermCreated(
                result: result,
                pendingCommandIcon: self.pendingCustomCommandIcon.isEmpty ? nil : self.pendingCustomCommandIcon,
                pendingCommandName: self.pendingCustomCommandName.isEmpty ? nil : self.pendingCustomCommandName,
                pendingCommand: self.pendingCustomCommand.isEmpty ? nil : self.pendingCustomCommand,
                makeKey: self.globalWorkspaceKey(project:workspace:)
            )
            self.workspaceTerminalOpenTime = self.terminalSessionStore.workspaceOpenTime

            // 确保 PTY 尺寸与终端视图一致（兜底 resize）
            self.wsClient.requestTermResize(
                termId: result.termId,
                cols: self.terminalCols,
                rows: self.terminalRows
            )
            self.terminalSink?.focusTerminal()
            // 刷新终端列表
            self.wsClient.requestTermList()
            // 自定义命令：延迟发送，等 shell 初始化完成
            let cmd = self.pendingCustomCommand
            if !cmd.isEmpty {
                let termId = result.termId
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.wsClient.sendTerminalInput(cmd + "\n", termId: termId)
                }
            }
            self.pendingCustomCommand = ""
            self.pendingCustomCommandIcon = ""
            self.pendingCustomCommandName = ""
        }

        wsClient.onTermAttached = { [weak self] result in
            guard let self else { return }
            // 通过共享终端存储处理 attach 完成（含 RTT 追踪 + 展示信息恢复）
            if let rtt = self.terminalSessionStore.handleTermAttached(result: result) {
                let costMs = Int(rtt * 1000)
                TFLog.app.info("perf.mobile.terminal.attach.rtt_ms=\(costMs, privacy: .public) term=\(result.termId, privacy: .public)")
            }
            self.switchToTerminal(termId: result.termId)
            // 写入 scrollback 到 SwiftTerm
            if !result.scrollback.isEmpty {
                self.emitTerminalOutput(result.scrollback, termId: result.termId, shouldRender: true)
                // scrollback 回放后立即发送 ACK，避免大量 scrollback 数据触发背压
                if !result.termId.isEmpty {
                    self.wsClient.sendTermOutputAck(termId: result.termId, bytes: result.scrollback.count)
                    self.terminalSessionStore.resetUnackedBytes(for: result.termId)
                }
            }
            self.wsClient.requestTermResize(
                termId: result.termId,
                cols: self.terminalCols,
                rows: self.terminalRows
            )
            self.terminalSink?.focusTerminal()
        }

        wsClient.onTerminalOutput = { [weak self] termId, bytes in
            guard let self else { return }
            if let termId, self.currentTermId.isEmpty {
                self.switchToTerminal(termId: termId)
            }
            guard let termId else { return }
            self.emitTerminalOutput(bytes, termId: termId, shouldRender: termId == self.currentTermId)
        }

        wsClient.onTerminalExit = { [weak self] _, _ in
            // 终端退出，可选择通知用户
            _ = self
        }

        wsClient.onTermClosed = { [weak self] termId in
            guard let self else { return }
            // 通过共享终端存储清理所有与该 termId 相关的追踪状态
            self.terminalSessionStore.handleTermClosed(termId: termId)
            if self.currentTermId == termId {
                self.currentTermId = ""
            }
            // 刷新终端列表
            self.wsClient.requestTermList()
        }

        wsClient.onEvoAutoCommitResult = { [weak self] result in
            guard let self else { return }
            // 按 project:workspace 匹配本地任务
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            let localTaskId = self.aiCommitPendingTaskIds.first.flatMap { taskId -> String? in
                // 验证 taskId 归属的 workspace key 匹配
                if self.taskStore.allTasks(for: key).contains(where: { $0.id == taskId && $0.status.isActive }) {
                    return taskId
                }
                return nil
            } ?? self.aiCommitPendingTaskIds.first // 兜底：按顺序匹配

            if let taskId = localTaskId {
                self.aiCommitPendingTaskIds.removeAll { $0 == taskId }
                self.mutateTask(taskId) { task in
                    task.status = result.success ? .completed : .failed
                    task.message = result.message
                    task.completedAt = Date()
                }
            } else {
                // 远程任务：非本地发起，创建条目并直接标记完成
                let task = self.createTask(
                    project: result.project,
                    workspace: result.workspace,
                    type: .aiCommit,
                    title: "一键提交",
                    icon: "sparkles",
                    message: result.message
                )
                self.mutateTask(task.id) { t in
                    t.status = result.success ? .completed : .failed
                    t.completedAt = Date()
                }
            }
        }

        wsClient.onGitAIMergeResult = { [weak self] result in
            guard let self else { return }
            let resolvedTaskId =
                self.aiMergePendingTaskIdByProject.removeValue(forKey: result.project)
                ?? self.findLatestActiveTaskId(project: result.project, type: .aiMerge)
            if let taskId = resolvedTaskId {
                self.mutateTask(taskId) { task in
                    task.status = result.success ? .completed : .failed
                    task.message = result.message
                    task.completedAt = Date()
                }
            } else {
                // 远程任务：非本地发起，创建条目并直接标记完成
                let task = self.createTask(
                    project: result.project,
                    workspace: result.workspace,
                    type: .aiMerge,
                    title: "智能合并",
                    icon: "cpu",
                    message: result.message
                )
                self.mutateTask(task.id) { t in
                    t.status = result.success ? .completed : .failed
                    t.completedAt = Date()
                }
            }
        }

        wsClient.onGitMergeToDefaultResult = { [weak self] result in
            guard let self else { return }
            let resolvedTaskId =
                self.aiMergePendingTaskIdByProject.removeValue(forKey: result.project)
                ?? self.findLatestActiveTaskId(project: result.project, type: .aiMerge)
            guard let taskId = resolvedTaskId else { return }
            self.mutateTask(taskId) { task in
                let success = result.ok && result.state == .completed
                task.status = success ? .completed : .failed
                task.message = result.message ?? (success ? "完成" : "失败")
                task.completedAt = Date()
            }
        }

        wsClient.onProjectCommandStarted = { [weak self] project, workspace, commandId, taskId in
            guard let self else { return }
            let routeKey = self.projectCommandRoutingKey(project: project, workspace: workspace, commandId: commandId)
            let localTaskId: String?
            if let mapped = self.projectCommandTaskIdByRemoteTaskId[taskId] {
                localTaskId = mapped
            } else if var queue = self.projectCommandPendingTaskIdsByKey[routeKey], !queue.isEmpty {
                let first = queue.removeFirst()
                self.projectCommandPendingTaskIdsByKey[routeKey] = queue.isEmpty ? nil : queue
                self.projectCommandTaskIdByRemoteTaskId[taskId] = first
                localTaskId = first
            } else {
                localTaskId = nil
            }
            if let resolvedId = localTaskId {
                self.mutateTask(resolvedId) { task in
                    task.status = .running
                    task.startedAt = task.startedAt ?? Date()
                    task.message = "运行中..."
                    task.remoteTaskId = taskId
                }
            } else {
                // 远程任务：非本地发起，创建远程任务条目
                let commandName = self.resolveCommandName(project: project, commandId: commandId)
                let commandIcon = self.resolveCommandIcon(project: project, commandId: commandId)
                let task = self.createTask(
                    project: project,
                    workspace: workspace,
                    type: .projectCommand,
                    title: commandName,
                    icon: commandIcon,
                    message: "运行中..."
                )
                self.mutateTask(task.id) { t in
                    t.commandId = commandId
                    t.remoteTaskId = taskId
                }
                self.projectCommandTaskIdByRemoteTaskId[taskId] = task.id
            }
        }

        wsClient.onProjectCommandOutput = { [weak self] taskId, line in
            guard let self else { return }
            guard let localTaskId = self.projectCommandTaskIdByRemoteTaskId[taskId] else { return }
            self.mutateTask(localTaskId) { task in
                task.lastOutputLine = line
            }
        }

        wsClient.onProjectCommandCompleted = { [weak self] project, workspace, commandId, taskId, ok, message in
            guard let self else { return }
            let routeKey = self.projectCommandRoutingKey(project: project, workspace: workspace, commandId: commandId)
            let localTaskId = self.projectCommandTaskIdByRemoteTaskId.removeValue(forKey: taskId)
                ?? self.projectCommandPendingTaskIdsByKey[routeKey]?.first
            if let localTaskId,
               var queue = self.projectCommandPendingTaskIdsByKey[routeKey],
               queue.first == localTaskId {
                queue.removeFirst()
                self.projectCommandPendingTaskIdsByKey[routeKey] = queue.isEmpty ? nil : queue
            }
            guard let resolvedId = localTaskId else { return }
            self.mutateTask(resolvedId) { task in
                task.status = ok ? .completed : .failed
                task.message = message ?? (ok ? "完成" : "失败")
                task.completedAt = Date()
            }
        }

        wsClient.onError = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            self.aiSessionListLoadingTools.removeAll()
            if !self.evolutionPendingActionByWorkspace.isEmpty {
                let pendingCount = self.evolutionPendingActionByWorkspace.count
                self.evolutionPendingActionByWorkspace.removeAll()
                NSLog(
                    "[MobileAppState] Evolution pending actions cleared after client error: count=%d, error=%@",
                    pendingCount,
                    message
                )
            }
            if self.pendingExplorerPreviewRequest != nil {
                self.pendingExplorerPreviewRequest = nil
                self.explorerPreviewLoading = false
                self.explorerPreviewError = message
                self.explorerPreviewContent = ""
            }
            if self.pendingPlanDocumentReadPath != nil {
                self.pendingPlanDocumentReadPath = nil
                self.evolutionPlanDocumentLoading = false
                self.evolutionPlanDocumentError = message
            }
            if !self.aiActiveProject.isEmpty, !self.aiActiveWorkspace.isEmpty {
                let key = self.aiContextKey(project: self.aiActiveProject, workspace: self.aiActiveWorkspace)
                if var cache = self.aiFileIndexCache[key], cache.isLoading {
                    cache.isLoading = false
                    cache.error = message
                    self.aiFileIndexCache[key] = cache
                }
            }
        }

        wsClient.onClipboardImageSet = { [weak self] ok, message in
            guard let self else { return }
            if ok {
                // 图片已写入 macOS 剪贴板，发送 Ctrl+V 让 TUI 应用读取
                self.sendSpecialKey("\u{16}")
            } else {
                self.errorMessage = message ?? "剪贴板图片写入失败"
            }
        }

        wsClient.onAITaskCancelled = { [weak self] result in
            guard let self else { return }
            // 按 project + workspace + operation_type 查找活跃任务并标记取消
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            let taskType: WorkspaceTaskType = result.operationType == "ai_merge" ? .aiMerge : .aiCommit
            if let task = self.taskStore.allTasks(for: key).first(where: { $0.type == taskType && $0.status.isActive }) {
                self.mutateTask(task.id) { t in
                    t.status = .cancelled
                    t.message = "已取消"
                    t.completedAt = Date()
                }
            }
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

        wsClient.onTasksSnapshot = { [weak self] entries in
            guard let self else { return }
            self.restoreTasksFromSnapshot(entries)
        }

        // Evolution
        wsClient.onEvoPulse = { [weak self] in
            self?.wsClient.requestEvoSnapshot()
        }

        wsClient.onEvoSnapshot = { [weak self] snapshot in
            guard let self else { return }
            if self.evolutionScheduler != snapshot.scheduler {
                self.evolutionScheduler = snapshot.scheduler
            }
            let items = snapshot.workspaceItems.sorted {
                ($0.project, $0.workspace) < ($1.project, $1.workspace)
            }
            if self.evolutionWorkspaceItems != items {
                self.evolutionWorkspaceItems = items
            }
            for item in items where item.status != "interrupted" {
                let key = self.globalWorkspaceKey(project: item.project, workspace: self.normalizeEvolutionWorkspaceName(item.workspace))
                self.evolutionPendingActionByWorkspace.removeValue(forKey: key)
            }
        }

        wsClient.onEvoAgentProfile = { [weak self] ev in
            guard let self else { return }
            let workspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            let key = self.globalWorkspaceKey(project: ev.project, workspace: workspace)
            if ev.stageProfiles.isEmpty {
                NSLog(
                    "[MobileAppState] Evolution profile ignored: empty stage_profiles, project=%@, workspace=%@",
                    ev.project,
                    workspace
                )
                self.finishEvolutionProfileReloadTracking(project: ev.project, workspace: workspace)
                return
            }
            self.evolutionStageProfilesByWorkspace[key] = ev.stageProfiles
            let directionModel = ev.stageProfiles
                .first(where: { $0.stage == "direction" })?
                .model
                .map { "\($0.providerID)/\($0.modelID)" } ?? "default"
            NSLog(
                "[MobileAppState] Evolution profile applied: project=%@, workspace=%@, stages=%d, direction_model=%@",
                ev.project,
                workspace,
                ev.stageProfiles.count,
                directionModel
            )
            self.finishEvolutionProfileReloadTracking(project: ev.project, workspace: workspace)
        }

        wsClient.onEvoStageChatOpened = { [weak self] ev in
            guard let self else { return }
            guard let aiTool = ev.aiTool else {
                self.evolutionReplayLoading = false
                self.evolutionReplayError = "不支持的 AI 工具：\(ev.aiToolRaw)"
                return
            }
            let normalizedWorkspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            self.evolutionReplayRequest = (
                project: ev.project,
                workspace: normalizedWorkspace,
                aiTool: aiTool,
                sessionId: ev.sessionID,
                cycleId: ev.cycleID,
                stage: ev.stage
            )
            self.evolutionReplayTitle = "\(normalizedWorkspace) · \(ev.stage) · \(ev.cycleID)"
            self.evolutionReplayMessages = []
            self.evolutionReplayError = nil
            self.evolutionReplayLoading = false

            self.openAIChat(project: ev.project, workspace: normalizedWorkspace)

            let updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
            let session = AISessionInfo(
                projectName: ev.project,
                workspaceName: normalizedWorkspace,
                aiTool: aiTool,
                id: ev.sessionID,
                title: "\(ev.stage) · \(ev.cycleID)",
                updatedAt: updatedAt
            )

            var sessions = self.aiSessionsByTool[aiTool] ?? []
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            self.setAISessions(sessions.sorted { $0.updatedAt > $1.updatedAt }, for: aiTool)

            // 通过共享协调器订阅并加载历史，确保与 macOS 端语义一致
            let evoContext = AISessionHistoryCoordinator.Context(
                project: ev.project,
                workspace: normalizedWorkspace,
                aiTool: aiTool,
                sessionId: ev.sessionID
            )
            AISessionHistoryCoordinator.subscribeAndLoadRecent(
                context: evoContext,
                wsClient: self.wsClient,
                store: self.aiChatStore
            )
            self.requestAISessionStatus(
                projectName: ev.project,
                workspaceName: normalizedWorkspace,
                aiTool: aiTool,
                sessionId: ev.sessionID,
                force: true
            )
        }

        wsClient.onEvoError = { [weak self] message in
            guard let self else { return }
            self.evolutionReplayLoading = false
            self.evolutionReplayError = message
            self.evolutionPendingActionByWorkspace.removeAll()
            for key in self.evidenceLoadingByWorkspace.keys {
                self.evidenceLoadingByWorkspace[key] = false
                self.evidenceErrorByWorkspace[key] = message
            }
            let promptCallbacks = self.evidencePromptCompletionByWorkspace
            self.evidencePromptCompletionByWorkspace.removeAll()
            for (_, completion) in promptCallbacks {
                completion(nil, message)
            }
            let readRequests = self.evidenceReadRequestByWorkspace
            self.evidenceReadRequestByWorkspace.removeAll()
            for (_, request) in readRequests {
                if request.autoContinue {
                    request.fullCompletion(nil, message)
                } else {
                    request.pageCompletion(nil, message)
                }
            }
        }

        wsClient.onEvoBlockingRequired = { [weak self] ev in
            guard let self else { return }
            let normalizedWorkspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            self.evolutionBlockingRequired = EvolutionBlockingRequiredV2(
                project: ev.project,
                workspace: normalizedWorkspace,
                trigger: ev.trigger,
                cycleID: ev.cycleID,
                stage: ev.stage,
                blockerFilePath: ev.blockerFilePath,
                unresolvedItems: ev.unresolvedItems
            )
            self.evolutionBlockers = ev.unresolvedItems
        }

        wsClient.onEvoBlockersUpdated = { [weak self] ev in
            guard let self else { return }
            let normalizedWorkspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            self.evolutionBlockers = ev.unresolvedItems
            if ev.unresolvedCount > 0 {
                self.evolutionBlockingRequired = EvolutionBlockingRequiredV2(
                    project: ev.project,
                    workspace: normalizedWorkspace,
                    trigger: "updated",
                    cycleID: self.evolutionBlockingRequired?.cycleID,
                    stage: self.evolutionBlockingRequired?.stage,
                    blockerFilePath: self.evolutionBlockingRequired?.blockerFilePath ?? "",
                    unresolvedItems: ev.unresolvedItems
                )
                return
            }
            self.evolutionBlockingRequired = nil
            let key = self.globalWorkspaceKey(project: ev.project, workspace: normalizedWorkspace)
            guard let pendingAction = self.evolutionPendingActionByWorkspace.removeValue(forKey: key) else {
                return
            }
            if pendingAction == "start" {
                let profiles = self.evolutionProfiles(project: ev.project, workspace: normalizedWorkspace)
                let loopRoundLimit = max(
                    1,
                    self.evolutionItem(project: ev.project, workspace: normalizedWorkspace)?.loopRoundLimit ?? 1
                )
                self.startEvolution(
                    project: ev.project,
                    workspace: normalizedWorkspace,
                    loopRoundLimit: loopRoundLimit,
                    profiles: profiles
                )
                return
            }
            if pendingAction == "resume" {
                self.resumeEvolution(project: ev.project, workspace: normalizedWorkspace)
            }
        }

        wsClient.onEvoCycleHistory = { [weak self] project, workspace, cycles in
            guard let self else { return }
            let normalizedWorkspace = self.normalizeEvolutionWorkspaceName(workspace)
            let key = self.globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
            self.evolutionCycleHistories[key] = cycles
        }

        wsClient.onEvidenceSnapshot = { [weak self] ev in
            guard let self else { return }
            let normalizedWorkspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            let key = self.globalWorkspaceKey(project: ev.project, workspace: normalizedWorkspace)
            self.evidenceSnapshotsByWorkspace[key] = ev
            self.evidenceLoadingByWorkspace[key] = false
            self.evidenceErrorByWorkspace[key] = nil
        }

        wsClient.onEvidenceRebuildPrompt = { [weak self] ev in
            guard let self else { return }
            let normalizedWorkspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            let key = self.globalWorkspaceKey(project: ev.project, workspace: normalizedWorkspace)
            if let completion = self.evidencePromptCompletionByWorkspace.removeValue(forKey: key) {
                completion(ev, nil)
            }
        }

        wsClient.onEvidenceItemChunk = { [weak self] ev in
            guard let self else { return }
            let normalizedWorkspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            let key = self.globalWorkspaceKey(project: ev.project, workspace: normalizedWorkspace)
            guard var request = self.evidenceReadRequestByWorkspace[key] else { return }
            guard request.itemID == ev.itemID else { return }

            guard ev.offset == request.expectedOffset else {
                // 同一条目的旧分块回包（通常由重入读取触发）直接丢弃，避免误判中断。
                if ev.offset < request.expectedOffset {
                    return
                }
                // 首块期待偏移为 0；若先收到更大偏移，通常是上一次读取会话的滞后分块。
                if request.expectedOffset == 0 {
                    return
                }
                self.evidenceReadRequestByWorkspace.removeValue(forKey: key)
                if request.autoContinue {
                    request.fullCompletion(nil, "证据分块偏移不连续，读取已中断")
                } else {
                    request.pageCompletion(nil, "证据分块偏移不连续，读取已中断")
                }
                return
            }

            request.totalSizeBytes = ev.totalSizeBytes
            request.mimeType = ev.mimeType
            request.expectedOffset = ev.nextOffset

            if !request.autoContinue {
                self.evidenceReadRequestByWorkspace.removeValue(forKey: key)
                request.pageCompletion(
                    .init(
                        mimeType: ev.mimeType,
                        content: ev.content,
                        offset: ev.offset,
                        nextOffset: ev.nextOffset,
                        totalSizeBytes: ev.totalSizeBytes,
                        eof: ev.eof
                    ),
                    nil
                )
                return
            }

            request.content.append(contentsOf: ev.content)

            if ev.eof {
                self.evidenceReadRequestByWorkspace.removeValue(forKey: key)
                request.fullCompletion((mimeType: request.mimeType, content: request.content), nil)
                return
            }

            self.evidenceReadRequestByWorkspace[key] = request
            self.wsClient.requestEvidenceReadItem(
                project: request.project,
                workspace: request.workspace,
                itemID: request.itemID,
                offset: request.expectedOffset,
                limit: request.limit
            )
        }

        // AI Chat: 文件索引（@ 自动补全）
        wsClient.onFileIndexResult = { [weak self] result in
            guard let self else { return }
            let key = self.aiContextKey(project: result.project, workspace: result.workspace)
            self.aiFileIndexCache[key] = FileIndexCache(
                items: result.items,
                truncated: result.truncated,
                updatedAt: Date(),
                isLoading: false,
                error: nil
            )
        }

        // AI Chat（结构化 message/part 流）
        wsClient.onAISessionStarted = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }

            self.aiCurrentSessionId = ev.sessionId
            self.aiChatStore.setCurrentSessionId(ev.sessionId)
            self.aiChatStore.addSubscription(ev.sessionId)
            self.wsClient.requestAISessionSubscribe(
                project: ev.projectName,
                workspace: ev.workspaceName,
                aiTool: ev.aiTool.rawValue,
                sessionId: ev.sessionId
            )
            self.applyAISessionSelectionHint(
                ev.selectionHint,
                sessionId: ev.sessionId,
                for: ev.aiTool
            )
            self.wsClient.requestAISessionConfigOptions(
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
                updatedAt: updatedAt
            )
            self.aiSessions.removeAll { $0.id == session.id }
            self.aiSessions.insert(session, at: 0)

            if let pending = self.aiPendingSendRequest {
                guard pending.projectName == ev.projectName,
                      pending.workspaceName == ev.workspaceName,
                      pending.aiTool == ev.aiTool else {
                    self.aiPendingSendRequest = nil
                    return
                }
                self.aiPendingSendRequest = nil
                self.sendPendingAIRequest(
                    pending.kind,
                    sessionId: ev.sessionId,
                    projectName: ev.projectName,
                    workspaceName: ev.workspaceName,
                    aiTool: ev.aiTool
                )
            }
        }

        wsClient.onAISessionList = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName else { return }
            let sessions = ev.sessions.map {
                AISessionInfo(
                    projectName: $0.projectName,
                    workspaceName: $0.workspaceName,
                    aiTool: ev.aiTool,
                    id: $0.id,
                    title: $0.title,
                    updatedAt: $0.updatedAt
                )
            }
            self.setAISessions(sessions.sorted { $0.updatedAt > $1.updatedAt }, for: ev.aiTool)
        }

        wsClient.onAISessionMessages = { [weak self] ev in
            guard let self else { return }
            // iOS 没有独立的进化回放视图，使用主聊天视图展示；
            // 不提前 return，让消息同时流入主聊天。
            _ = self.consumeEvolutionReplayMessagesIfNeeded(ev)
            if self.consumeSubAgentViewerMessagesIfNeeded(ev) {
                return
            }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            guard self.aiCurrentSessionId == ev.sessionId else { return }
            guard self.aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }

            self.aiChatStore.replaceMessages(ev.toChatMessages())
            let restoredQuestions = AISessionSemantics.rebuildPendingQuestionRequests(
                sessionId: ev.sessionId,
                messages: ev.messages
            )
            self.aiChatStore.replaceQuestionRequests(restoredQuestions)
            self.aiChatStore.updateHistoryPagination(
                hasMore: ev.hasMore,
                nextBeforeMessageId: ev.nextBeforeMessageId
            )
            let inferredHint = AISessionSemantics.inferSelectionHintFromMessages(ev.messages)
            let effectiveHint = AISessionSemantics.mergedSelectionHint(primary: ev.selectionHint, fallback: inferredHint)
            self.applyAISessionSelectionHint(
                effectiveHint,
                sessionId: ev.sessionId,
                for: ev.aiTool
            )
            self.wsClient.requestAISessionConfigOptions(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                sessionId: ev.sessionId
            )
        }

        wsClient.onAISessionMessagesUpdate = { [weak self] ev in
            guard let self else { return }
            _ = self.consumeSubAgentViewerMessagesUpdateIfNeeded(ev)
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            guard self.aiCurrentSessionId == ev.sessionId else { return }
            guard self.aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }
            if self.aiChatStore.isAbortPending(for: ev.sessionId) { return }

            if let messages = ev.messages {
                guard self.aiChatStore.shouldApplySessionCacheRevision(
                    ev.cacheRevision,
                    sessionId: ev.sessionId
                ) else { return }
                self.aiChatStore.replaceMessagesFromSessionCache(messages, isStreaming: ev.isStreaming)
                let restoredQuestions = AISessionSemantics.rebuildPendingQuestionRequests(
                    sessionId: ev.sessionId,
                    messages: messages
                )
                self.aiChatStore.replaceQuestionRequests(restoredQuestions)
                let inferredHint = AISessionSemantics.inferSelectionHintFromMessages(messages)
                let effectiveHint = AISessionSemantics.mergedSelectionHint(
                    primary: ev.selectionHint,
                    fallback: inferredHint
                )
                self.applyAISessionSelectionHint(
                    effectiveHint,
                    sessionId: ev.sessionId,
                    for: ev.aiTool
                )
                return
            }

            if let ops = ev.ops {
                guard self.aiChatStore.shouldApplySessionCacheRevision(
                    ev.cacheRevision,
                    sessionId: ev.sessionId
                ) else { return }
                self.aiChatStore.applySessionCacheOps(ops, isStreaming: ev.isStreaming)
                if let hint = ev.selectionHint {
                    self.applyAISessionSelectionHint(
                        hint,
                        sessionId: ev.sessionId,
                        for: ev.aiTool
                    )
                }
                return
            }

            if !ev.isStreaming {
                guard self.aiChatStore.shouldApplySessionCacheRevision(
                    ev.cacheRevision,
                    sessionId: ev.sessionId
                ) else { return }
                self.aiChatStore.applySessionCacheOps([], isStreaming: false)
            }
            if let hint = ev.selectionHint {
                self.applyAISessionSelectionHint(
                    hint,
                    sessionId: ev.sessionId,
                    for: ev.aiTool
                )
            }
        }

        wsClient.onAISessionStatusResult = { [weak self] ev in
            guard let self else { return }
            self.upsertAISessionStatus(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                sessionId: ev.sessionId,
                status: ev.status.status,
                errorMessage: ev.status.errorMessage,
                contextRemainingPercent: ev.status.contextRemainingPercent
            )
            if self.aiActiveProject == ev.projectName,
               self.aiActiveWorkspace == ev.workspaceName,
               self.aiChatTool == ev.aiTool,
               self.aiCurrentSessionId == ev.sessionId,
               !AISessionStatusSnapshot(status: ev.status.status, errorMessage: ev.status.errorMessage, contextRemainingPercent: ev.status.contextRemainingPercent).isActive {
                self.aiChatStore.handleChatDone(sessionId: ev.sessionId)
            }
        }

        wsClient.onAISessionStatusUpdate = { [weak self] ev in
            guard let self else { return }
            self.upsertAISessionStatus(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                sessionId: ev.sessionId,
                status: ev.status.status,
                errorMessage: ev.status.errorMessage,
                contextRemainingPercent: ev.status.contextRemainingPercent
            )
            if self.aiActiveProject == ev.projectName,
               self.aiActiveWorkspace == ev.workspaceName,
               self.aiChatTool == ev.aiTool,
               self.aiCurrentSessionId == ev.sessionId,
               !AISessionStatusSnapshot(status: ev.status.status, errorMessage: ev.status.errorMessage, contextRemainingPercent: ev.status.contextRemainingPercent).isActive {
                self.aiChatStore.handleChatDone(sessionId: ev.sessionId)
            }
        }

        wsClient.onAIChatDone = { [weak self] ev in
            guard let self else { return }
            self.consumeSubAgentViewerDoneIfNeeded(ev)
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            // WI-002：与 macOS 一致，先无条件清 abort-pending，再用订阅集合守卫，
            // 避免旧会话 done 事件在切换后仍写入当前 UI。
            self.aiChatStore.clearAbortPendingIfMatches(ev.sessionId)
            guard self.aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }
            self.aiChatStore.handleChatDone(sessionId: ev.sessionId)
            self.applyAISessionSelectionHint(
                ev.selectionHint,
                sessionId: ev.sessionId,
                for: ev.aiTool
            )
        }

        wsClient.onAIChatError = { [weak self] ev in
            guard let self else { return }
            self.consumeSubAgentViewerErrorIfNeeded(ev)
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            // WI-002：与 macOS 一致，先无条件清 abort-pending，再用订阅集合守卫。
            self.aiChatStore.clearAbortPendingIfMatches(ev.sessionId)
            guard self.aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }
            self.aiChatStore.handleChatError(sessionId: ev.sessionId, error: ev.error)
        }

        wsClient.onAIProviderList = { [weak self] ev in
            guard let self else { return }
            let providers = ev.providers.map { p in
                AIProviderInfo(
                    id: p.id,
                    name: p.name,
                    models: p.models.map { m in
                        AIModelInfo(
                            id: m.id,
                            name: m.name,
                            providerID: m.providerID.isEmpty ? p.id : m.providerID,
                            supportsImageInput: m.supportsImageInput
                        )
                    }
                )
            }
            self.setEvolutionProviders(
                project: ev.projectName,
                workspace: ev.workspaceName,
                aiTool: ev.aiTool,
                providers: providers
            )
            self.markEvolutionProviderListLoaded(
                project: ev.projectName,
                workspace: self.normalizeEvolutionWorkspaceName(ev.workspaceName),
                aiTool: ev.aiTool
            )
            if self.shouldAcceptSettingsSelectorEvent(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                kind: .providerList
            ) {
                self.consumeSettingsSelectorEventIfNeeded(
                    projectName: ev.projectName,
                    workspaceName: ev.workspaceName,
                    aiTool: ev.aiTool,
                    kind: .providerList
                )
            }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            self.aiProviders = providers
            // 验证当前选中的模型在新 provider 列表中是否仍然有效；
            // 若已失效则清除选择，避免发送时携带不存在的模型导致请求出错。
            if let selectedModel = self.aiSelectedModel {
                let allModels = providers.flatMap { $0.models }
                let stillValid = allModels.contains(where: {
                    $0.id == selectedModel.modelID && $0.providerID == selectedModel.providerID
                })
                if !stillValid {
                    self.aiSelectedModel = nil
                }
            }
            self.isAILoadingModels = false
            self.wsClient.requestAISessionConfigOptions(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                sessionId: self.aiCurrentSessionId
            )
            self.retryPendingAISessionSelectionHint(for: ev.aiTool)
        }

        wsClient.onAIAgentList = { [weak self] ev in
            guard let self else { return }
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
            self.setEvolutionAgents(
                project: ev.projectName,
                workspace: ev.workspaceName,
                aiTool: ev.aiTool,
                agents: agents
            )
            self.markEvolutionAgentListLoaded(
                project: ev.projectName,
                workspace: self.normalizeEvolutionWorkspaceName(ev.workspaceName),
                aiTool: ev.aiTool
            )
            if self.shouldAcceptSettingsSelectorEvent(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                kind: .agentList
            ) {
                self.consumeSettingsSelectorEventIfNeeded(
                    projectName: ev.projectName,
                    workspaceName: ev.workspaceName,
                    aiTool: ev.aiTool,
                    kind: .agentList
                )
            }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            self.aiAgents = agents
            self.isAILoadingAgents = false
            if self.aiSelectedAgent == nil {
                let first = self.aiAgents.first(where: { $0.mode == "primary" || $0.mode == "all" }) ?? self.aiAgents.first
                self.aiSelectedAgent = first?.name
                self.applyAgentDefaultModel(first)
            }
            self.wsClient.requestAISessionConfigOptions(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                sessionId: self.aiCurrentSessionId
            )
            self.retryPendingAISessionSelectionHint(for: ev.aiTool)
        }

        wsClient.onAISlashCommands = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName else { return }
            let commands = ev.commands.map {
                AISlashCommandInfo(
                    name: $0.name,
                    description: $0.description,
                    action: $0.action,
                    inputHint: $0.inputHint
                )
            }
            self.setAISlashCommands(commands, for: ev.aiTool, sessionId: ev.sessionID)
        }

        wsClient.onAISlashCommandsUpdate = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName else { return }
            let commands = ev.commands.map {
                AISlashCommandInfo(
                    name: $0.name,
                    description: $0.description,
                    action: $0.action,
                    inputHint: $0.inputHint
                )
            }
            self.setAISlashCommands(commands, for: ev.aiTool, sessionId: ev.sessionID)
        }

        wsClient.onAISessionConfigOptions = { [weak self] ev in
            guard let self else { return }
            guard self.shouldAcceptAISessionConfigOptionsEvent(
                project: ev.projectName,
                workspace: ev.workspaceName
            ) else { return }
            self.setAISessionConfigOptions(ev.options, for: ev.aiTool)
            if self.aiActiveProject == ev.projectName, self.aiActiveWorkspace == ev.workspaceName {
                self.retryPendingAISessionSelectionHint(for: ev.aiTool)
            }
        }

        wsClient.onAIQuestionAsked = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            // WI-002：与 macOS 一致，使用 subscribedSessionIds 守卫，阻断旧会话问题事件。
            guard self.aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }
            self.aiChatStore.upsertQuestionRequest(ev.request)
        }

        wsClient.onAIQuestionCleared = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            // WI-002：与 macOS 一致，使用 subscribedSessionIds 守卫。
            guard self.aiChatStore.subscribedSessionIds.contains(ev.sessionId) else { return }
            self.completeAIQuestionRequestLocally(requestId: ev.requestId)
        }

        wsClient.onAISessionRenameResult = { [weak self] ev in
            guard let self,
                  let tool = AIChatTool(rawValue: ev.aiTool) else { return }
            var sessions = self.aiSessionsByTool[tool] ?? []
            if let idx = sessions.firstIndex(where: { $0.id == ev.sessionId }) {
                let old = sessions[idx]
                sessions[idx] = AISessionInfo(
                    projectName: old.projectName,
                    workspaceName: old.workspaceName,
                    aiTool: old.aiTool,
                    id: old.id,
                    title: ev.title,
                    updatedAt: ev.updatedAt > 0 ? ev.updatedAt : old.updatedAt
                )
                self.setAISessions(sessions, for: tool)
            }
        }

        // v1.40: 工作流模板回调
        wsClient.onTemplatesList = { [weak self] result in
            guard let self else { return }
            self.templates = result.items
        }
        wsClient.onTemplateSaved = { [weak self] result in
            guard let self, result.ok else { return }
            if let idx = self.templates.firstIndex(where: { $0.id == result.template.id }) {
                self.templates[idx] = result.template
            } else {
                self.templates.append(result.template)
            }
        }
        wsClient.onTemplateDeleted = { [weak self] result in
            guard let self, result.ok else { return }
            self.templates.removeAll { $0.id == result.templateId }
        }
        wsClient.onTemplateImported = { [weak self] result in
            guard let self, result.ok else { return }
            if let idx = self.templates.firstIndex(where: { $0.id == result.template.id }) {
                self.templates[idx] = result.template
            } else {
                self.templates.append(result.template)
            }
        }
        wsClient.onTemplateExported = { [weak self] _ in
            // iOS 端导出通过 share sheet 实现
            _ = self
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

    private func explorerCacheKey(project: String, workspace: String, path: String) -> String {
        WorkspaceKeySemantics.fileCacheKey(project: project, workspace: workspace, path: path)
    }

    private func explorerCachePrefix(project: String, workspace: String) -> String {
        WorkspaceKeySemantics.fileCachePrefix(project: project, workspace: workspace)
    }

    func globalWorkspaceKey(project: String, workspace: String) -> String {
        WorkspaceKeySemantics.globalKey(project: project, workspace: workspace)
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

    @discardableResult
    private func createTask(
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

    private func mutateTask(_ taskId: String, mutate: (inout WorkspaceTaskItem) -> Void) {
        taskStore.mutate(id: taskId, mutate)
    }

    private func findLatestActiveTaskId(project: String, type: WorkspaceTaskType) -> String? {
        taskStore.tasksByKey.values
            .flatMap { $0 }
            .filter { $0.project == project && $0.type == type && $0.status.isActive }
            .sorted { $0.createdAt > $1.createdAt }
            .first?
            .id
    }

    private func projectCommandRoutingKey(project: String, workspace: String, commandId: String) -> String {
        "\(project)|\(workspace)|\(commandId)"
    }

    /// 从项目配置中查找命令名称
    private func resolveCommandName(project: String, commandId: String) -> String {
        projects.first(where: { $0.name == project })?
            .commands.first(where: { $0.id == commandId })?
            .name ?? commandId
    }

    /// 从项目配置中查找命令图标
    private func resolveCommandIcon(project: String, commandId: String) -> String {
        projects.first(where: { $0.name == project })?
            .commands.first(where: { $0.id == commandId })?
            .icon ?? "terminal"
    }

    // MARK: - 输出缓冲

    private func emitTerminalOutput(_ bytes: [UInt8], termId: String, shouldRender: Bool) {
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
