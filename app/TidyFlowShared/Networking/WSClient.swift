import Foundation
import MessagePacker
import OSLog

// 已拆分：
// - WSClient+Send.swift     所有 send/request 方法
// - WSClient+Receive.swift  接收、解析、分发消息 + URLSessionWebSocketDelegate

/// Minimal WebSocket client for Core communication
/// 使用 MessagePack 二进制协议与 Rust Core 通信（协议版本 v10，包络结构沿用 v6）
public class WSClient: NSObject, ObservableObject {
    public enum HTTPReadRequestContext: Equatable {
        case aiProviderList(project: String, workspace: String, aiTool: AIChatTool)
        case aiAgentList(project: String, workspace: String, aiTool: AIChatTool)
        case fileRead(project: String, workspace: String, path: String)
    }

        public struct HTTPReadFailure: Equatable {
        public let context: HTTPReadRequestContext?
        public let message: String
        
        public init(context: HTTPReadRequestContext?, message: String) {
            self.context = context
            self.message = message
        }
    }

    public struct CoalescedEnvelope {
        public let domain: String
        public let action: String
        public let json: [String: Any]
        
        public init(domain: String, action: String, json: [String: Any]) {
            self.domain = domain
            self.action = action
            self.json = json
        }
    }
    // MARK: - MessagePack 编解码器（跨 extension 文件访问）
    // MessagePacker 的 Encoder/Decoder 内部持有可变 storage/codingPath，
    // 在多条 reducer 队列并发解码时复用实例会发生数据竞争，重则直接崩溃。
    // 这里统一改为按次创建，避免热路径共享可变状态。
    public func makeMessagePackEncoder() -> MessagePackEncoder { MessagePackEncoder() }
    public func makeMessagePackDecoder() -> MessagePackDecoder { MessagePackDecoder() }
    @Published public private(set) var isConnected: Bool = false
    /// 标记当前断连是否为主动行为（disconnect/reconnect），用于区分意外断连
    public var isIntentionalDisconnect: Bool = false
    /// 当前是否处于连接建立中（尚未 didOpen）
    public var isConnecting: Bool = false
    /// 进入后台时标记为 stale，回到前台时据此判断是否需要重连
    public private(set) var isStale: Bool = false

    public var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// Current WebSocket URL (can be updated at runtime)
    public var currentURL: URL?
    /// WebSocket 鉴权 token（由 Core 进程启动时注入）
    public private(set) var wsAuthToken: String?
    /// 远程 API key 连接的客户端实例标识；本地 macOS Core 连接保持为空
    public private(set) var authClientID: String?
    /// 远程 API key 连接的设备名；仅用于服务端展示与订阅观察
    public private(set) var authDeviceName: String?
    /// 重连防抖任务，避免短时间重复 reconnect 打断新连接
    private var pendingReconnectWorkItem: DispatchWorkItem?
    /// 最近一次已处理的服务端 seq（v9 包络），用于丢弃乱序/重复消息
    public var lastServerSeq: UInt64 = 0
    /// 当前连接身份；每次建立新 socket 都会刷新，用于屏蔽旧连接的延迟回调。
    public var connectionIdentity: String?
    /// 当前 socket task 对应的连接身份；跨文件扩展也需要访问它来拦截旧回调。
    public var webSocketTaskIdentity: String?
    private var nextConnectionSerial: UInt64 = 0

    // 领域 handler（新路径）：优先于闭包回调分发，逐步替代 onXxx 回调。
    public weak var gitMessageHandler: GitMessageHandler?
    public weak var projectMessageHandler: ProjectMessageHandler?
    public weak var fileMessageHandler: FileMessageHandler?
    public weak var settingsMessageHandler: SettingsMessageHandler?
    public weak var nodeMessageHandler: NodeMessageHandler?
    public weak var terminalMessageHandler: TerminalMessageHandler?
    public weak var aiMessageHandler: AIMessageHandler?
    public weak var evolutionMessageHandler: EvolutionMessageHandler?
    public weak var errorMessageHandler: ErrorMessageHandler?

    /// Get current URL string for debug display
    public var currentURLString: String? {
        currentURL?.absoluteString
    }

    // Message handlers
    public var onFileIndexResult: ((FileIndexResult) -> Void)?
    public var onFileListResult: ((FileListResult) -> Void)?
    public var onFileContentSearchResult: ((FileContentSearchResult) -> Void)?
    public var onGitDiffResult: ((GitDiffResult) -> Void)?
    public var onGitStatusResult: ((GitStatusResult) -> Void)?
    public var onGitLogResult: ((GitLogResult) -> Void)?
    public var onGitShowResult: ((GitShowResult) -> Void)?
    public var onGitOpResult: ((GitOpResult) -> Void)?
    public var onGitBranchesResult: ((GitBranchesResult) -> Void)?
    public var onGitCommitResult: ((GitCommitResult) -> Void)?
    public var onGitAIMergeResult: ((GitAIMergeResult) -> Void)?
    public var onGitRebaseResult: ((GitRebaseResult) -> Void)?
    public var onGitOpStatusResult: ((GitOpStatusResult) -> Void)?
    public var onGitMergeToDefaultResult: ((GitMergeToDefaultResult) -> Void)?
    public var onGitIntegrationStatusResult: ((GitIntegrationStatusResult) -> Void)?
    // UX-4: Rebase onto default handler
    public var onGitRebaseOntoDefaultResult: ((GitRebaseOntoDefaultResult) -> Void)?
    // UX-5: Reset integration worktree handler
    public var onGitResetIntegrationWorktreeResult: ((GitResetIntegrationWorktreeResult) -> Void)?
    // UX-2: Project import handlers
    public var onProjectImported: ((ProjectImportedResult) -> Void)?
    public var onWorkspaceCreated: ((WorkspaceCreatedResult) -> Void)?
    public var onProjectsList: ((ProjectsListResult) -> Void)?
    public var onWorkspacesList: ((WorkspacesListResult) -> Void)?
    // 终端会话
    public var onTermCreated: ((TermCreatedResult) -> Void)?
    public var onTermAttached: ((TermAttachedResult) -> Void)?
    public var onTermList: ((TermListResult) -> Void)?
    public var onTermClosed: ((String) -> Void)?
    public var onTerminalOutput: ((String?, [UInt8]) -> Void)?
    public var onTerminalExit: ((String?, Int) -> Void)?
    public var onProjectRemoved: ((ProjectRemovedResult) -> Void)?
    public var onWorkspaceRemoved: ((WorkspaceRemovedResult) -> Void)?
    // 客户端设置
    public var onClientSettingsResult: ((ClientSettings) -> Void)?
    public var onClientSettingsSaved: ((Bool, String?) -> Void)?
    public var onNodeSelfUpdated: ((NodeSelfInfoV2) -> Void)?
    public var onNodeDiscoveryUpdated: (([NodeDiscoveryItemV2]) -> Void)?
    public var onNodeNetworkUpdated: ((NodeNetworkSnapshotV2) -> Void)?
    public var onNodePairingResult: ((NodePairingResultV2) -> Void)?
    public var onNodePeerStatus: ((String, String, UInt64?) -> Void)?
    // v1.22: 文件监控回调
    public var onWatchSubscribed: ((WatchSubscribedResult) -> Void)?
    public var onWatchUnsubscribed: (() -> Void)?
    public var onFileChanged: ((FileChangedNotification) -> Void)?
    public var onGitStatusChanged: ((GitStatusChangedNotification) -> Void)?
    // v1.23: 文件重命名/删除回调
    public var onFileRenameResult: ((FileRenameResult) -> Void)?
    public var onFileDeleteResult: ((FileDeleteResult) -> Void)?
    // v1.24: 文件复制回调
    public var onFileCopyResult: ((FileCopyResult) -> Void)?
    // v1.25: 文件移动回调
    public var onFileMoveResult: ((FileMoveResult) -> Void)?
    // 文件写入回调（新建文件）
    public var onFileWriteResult: ((FileWriteResult) -> Void)?
    // 文件读取回调（预览/查看）
    public var onFileReadResult: ((FileReadResult) -> Void)?
    // 文件格式化回调
    public var onFileFormatCapabilitiesResult: ((FileFormatCapabilitiesResult) -> Void)?
    public var onFileFormatResult: ((FileFormatResult) -> Void)?
    public var onFileFormatError: ((FileFormatErrorResult) -> Void)?
    // v1.29: 项目命令回调
    public var onProjectCommandsSaved: ((String, Bool, String?) -> Void)?
    public var onProjectCommandStarted: ((String, String, String, String) -> Void)?
    public var onProjectCommandCompleted: ((String, String, String, String, Bool, String?) -> Void)?
    public var onProjectCommandCancelled: ((String, String, String, String) -> Void)?
    // v1.30: 项目命令实时输出回调 (taskId, line)
    public var onProjectCommandOutput: ((String, String) -> Void)?
    public var onRemoteTermChanged: (() -> Void)?
    // v1.37: AI 任务取消确认
    public var onAITaskCancelled: ((AITaskCancelled) -> Void)?
    // v1.39: 剪贴板图片写入结果
    public var onClipboardImageSet: ((Bool, String?) -> Void)?
    // v1.40: 任务历史快照（iOS 重连恢复）
    public var onTasksSnapshot: (([TaskSnapshotEntry]) -> Void)?
    // v1.40: 工作流模板回调
    public var onTemplatesList: ((TemplatesListResult) -> Void)?
    public var onTemplateSaved: ((TemplateSavedResult) -> Void)?
    public var onTemplateDeleted: ((TemplateDeletedResult) -> Void)?
    public var onTemplateImported: ((TemplateImportedResult) -> Void)?
    public var onTemplateExported: ((TemplateExportedResult) -> Void)?
    // AI Chat（结构化 message/part 流）
    public var onAISessionStarted: ((AISessionStartedV2) -> Void)?
    public var onAISessionList: ((AISessionListV2) -> Void)?
    public var onAISessionMessages: ((AISessionMessagesV2) -> Void)?
    public var onAISessionMessagesUpdate: ((AISessionMessagesUpdateV2) -> Void)?
    public var onAISessionStatusResult: ((AISessionStatusResultV2) -> Void)?
    public var onAISessionStatusUpdate: ((AISessionStatusUpdateV2) -> Void)?
    public var onAIChatDone: ((AIChatDoneV2) -> Void)?
    public var onAIChatPending: ((AIChatPendingV2) -> Void)?
    public var onAIChatError: ((AIChatErrorV2) -> Void)?
    public var onAIQuestionAsked: ((AIQuestionAskedV2) -> Void)?
    public var onAIQuestionCleared: ((AIQuestionClearedV2) -> Void)?
    public var onAIProviderList: ((AIProviderListResult) -> Void)?
    public var onAIAgentList: ((AIAgentListResult) -> Void)?
    public var onAISlashCommands: ((AISlashCommandsResult) -> Void)?
    public var onAISlashCommandsUpdate: ((AISlashCommandsUpdateResult) -> Void)?
    public var onAISessionConfigOptions: ((AISessionConfigOptionsResult) -> Void)?
    public var onAISessionSubscribeAck: ((AISessionSubscribeAck) -> Void)?
    public var onAISessionRenameResult: ((AISessionRenameResult) -> Void)?
    public var onAISessionSearchResult: ((AISessionSearchResult) -> Void)?
    public var onAICodeReviewResult: ((AICodeReviewResult) -> Void)?
    public var onAICodeCompletionChunk: ((AICodeCompletionChunk) -> Void)?
    public var onAICodeCompletionDone: ((AICodeCompletionDone) -> Void)?
    public var onAIContextSnapshotUpdated: (([String: Any]) -> Void)?
    // Evolution
    public var onEvoPulse: (() -> Void)?
    public var onEvoWorkspaceStatusEvent: ((EvolutionWorkspaceStatusEventV2) -> Void)?
    public var onEvoSnapshot: ((EvolutionSnapshotV2) -> Void)?
    public var onEvoCycleUpdated: ((EvoCycleUpdatedV2) -> Void)?
    public var onEvoAgentProfile: ((EvolutionAgentProfileV2) -> Void)?
    public var onEvoBlockingRequired: ((EvolutionBlockingRequiredV2) -> Void)?
    public var onEvoBlockersUpdated: ((EvolutionBlockersUpdatedV2) -> Void)?
    public var onEvoCycleHistory: ((String, String, [EvolutionCycleHistoryItemV2]) -> Void)?
    public var onEvoAutoCommitResult: ((EvoAutoCommitResult) -> Void)?
    /// 工作区缓存可观测性快照（由 /api/v1/system/snapshot HTTP 响应驱动，按 (project, workspace) 隔离）
    public var onSystemSnapshot: ((SystemSnapshotCacheMetrics) -> Void)?
    /// 工作区级 Evolution 摘要（由 system_snapshot.workspace_items 提取，按 (project, workspace) 隔离）
    public var onEvolutionWorkspaceSummaries: (([SystemSnapshotEvolutionWorkspaceSummary]) -> Void)?
    /// v1.42: 统一可观测性快照（聚合 perf_metrics + log_context + cache_metrics）
    public var onObservabilitySnapshot: ((ObservabilitySnapshot) -> Void)?
    /// WI-001: 全链路性能可观测快照
    public var onPerformanceObservability: ((PerformanceObservabilitySnapshot) -> Void)?
    /// v1.45: 智能演化分析摘要（按 (project, workspace, cycle_id) 隔离，Core 权威真源）
    /// 与 ObservabilitySnapshot 职责分离：原始观测由 onObservabilitySnapshot 承载，决策结论由此回调承载
    public var onEvolutionAnalysisSummaries: (([EvolutionAnalysisSummary]) -> Void)?
    public var onEvoError: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    /// 结构化 Core 错误回调（含错误码与上下文）
    public var onCoreError: ((CoreError) -> Void)?
    public var onConnectionStateChanged: ((Bool) -> Void)?
    /// v9 包络元信息流（用于上层统一路由/观测）
    public var onServerEnvelopeMeta: ((ServerEnvelopeMeta) -> Void)?
    /// v1.41: Core 推送系统健康快照
    public var onHealthSnapshot: ((SystemHealthSnapshot) -> Void)?
    /// v1.41: Core 推送修复执行结果
    public var onHealthRepairResult: ((RepairAuditEntry) -> Void)?
    /// 工作区恢复状态摘要（从 system_snapshot workspace_items 提取，按 (project, workspace) 隔离）
    public var onWorkspaceRecoverySummaries: (([WorkspaceRecoverySummary]) -> Void)?
    /// v1.46: Core 推送工作区级 Coordinator AI 状态增量快照
    public var onCoordinatorSnapshot: ((CoordinatorWorkspaceSnapshotPayload) -> Void)?

    public func emitClientError(_ message: String) {
        if let handler = errorMessageHandler {
            handler.handleClientError(message)
        } else {
            onError?(message)
        }
    }

    /// 发送结构化 Core 错误（含错误码与上下文，供多工作区定位使用）
    public func emitCoreError(_ error: CoreError) {
        if let handler = errorMessageHandler {
            handler.handleCoreError(error)
        } else {
            onCoreError?(error)
            onError?(error.message)
        }
    }

    // MARK: - 高频消息合并队列
    /// 合并窗口时长（秒），窗口内同 key 的消息只保留最后一条
    private let coalesceInterval: TimeInterval = 0.05 // 50ms
    /// 合并队列：key 为 "消息类型:项目:工作空间"，value 为待处理的完整包络
    private var coalesceQueue: [String: CoalescedEnvelope] = [:]
    /// 合并窗口定时器
    private var coalesceTimer: DispatchWorkItem?
    /// HTTP 读请求观测钩子（测试与性能排查使用，不参与业务逻辑）
    public var onHTTPRequestScheduled: ((_ domain: String, _ path: String, _ queryItems: [URLQueryItem]) -> Void)?
    /// HTTP 读请求失败钩子（用于上层清理 loading / pending 状态）
    public var onHTTPReadFailure: ((HTTPReadFailure) -> Void)?
    /// 统一 HTTP Query 缓存层（SWR + in-flight 去重）
    public let httpQueryClient = HTTPQueryClient()
    /// 测试注入：允许单测替换真实 HTTP 读取实现
    public var httpReadFetcherOverride:
        ((URL, String, [URLQueryItem], String?, String?, String?) async throws -> Data)?

    /// 后台串行队列，用于 MessagePack 解码（避免阻塞主线程）
    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.tidyflow.ws.decode"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// 终端高频事件 reducer 队列，先做批量归并，再切回主线程提交。
    public let terminalReducerQueue = DispatchQueue(label: "com.tidyflow.ws.reducer.terminal", qos: .userInitiated)
    /// AI 高频事件 reducer 队列，避免主线程承担原始流式消息解析。
    public let aiReducerQueue = DispatchQueue(label: "com.tidyflow.ws.reducer.ai", qos: .userInitiated)
    /// 文件/Git 变更 reducer 队列，统一承接最终一致性通知。
    public let workspaceReducerQueue = DispatchQueue(label: "com.tidyflow.ws.reducer.workspace", qos: .utility)

        public override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: decodeQueue)
    }

    /// Initialize with a specific URL
    public init(url: URL) {
        super.init()
        self.currentURL = url
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: decodeQueue)
    }

    /// Update the base URL and optionally reconnect
    /// - Parameters:
    ///   - url: New WebSocket URL
    ///   - reconnect: Whether to disconnect and reconnect immediately
    public func updateBaseURL(_ url: URL, reconnect: Bool = true) {
        currentURL = url
        if reconnect {
            self.reconnect()
        }
    }

    /// Update the base URL using port number
    public func updatePort(_ port: Int, reconnect: Bool = true) {
        let url = CoreWSURLBuilder.makeURL(
            port: port,
            token: wsAuthToken,
            clientID: authClientID,
            deviceName: authDeviceName
        )
        updateBaseURL(url, reconnect: reconnect)
    }

    /// 更新 WebSocket 鉴权 token（用于后续 connect/reconnect）
    public func updateAuthToken(_ token: String?) {
        wsAuthToken = token
    }

    /// 更新远程连接附加身份元数据；本地 Core 连接保持为空即可。
    public func updateAuthClientMetadata(clientID: String?, deviceName: String?) {
        authClientID = clientID
        authDeviceName = deviceName
    }

    // MARK: - Connection

    public func connect() {
        guard webSocketTask == nil, !isConnecting else { return }

        guard let url = currentURL else {
            emitClientError("No WebSocket URL configured")
            return
        }

        isStale = false
        isConnecting = true
        lastServerSeq = 0
        let identity = makeConnectionIdentity(for: url)
        webSocketTaskIdentity = identity
        CoreWSLog.ws.info("Connecting to: \(url.absoluteString, privacy: .public)")
        guard let task = urlSession?.webSocketTask(with: url) else {
            isConnecting = false
            webSocketTaskIdentity = nil
            emitClientError("Failed to create WebSocket task")
            return
        }
        webSocketTask = task
        task.resume()
        receiveMessage(for: task, identity: identity)
    }

    /// Connect to a specific port (convenience method)
    public func connect(port: Int) {
        let targetURL = CoreWSURLBuilder.makeURL(port: port, token: wsAuthToken)
        if currentURL == targetURL, (isConnected || isConnecting || webSocketTask != nil) {
            return
        }
        currentURL = targetURL
        connect()
    }

    public func disconnect() {
        disconnect(clearPendingReconnect: true)
    }

    private func disconnect(clearPendingReconnect: Bool) {
        isIntentionalDisconnect = true
        isStale = false
        isConnecting = false
        if clearPendingReconnect {
            pendingReconnectWorkItem?.cancel()
            pendingReconnectWorkItem = nil
        }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        webSocketTaskIdentity = nil
        connectionIdentity = nil
        lastServerSeq = 0
        updateConnectionState(false)
    }

    public func reconnect() {
        disconnect(clearPendingReconnect: false)
        pendingReconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        pendingReconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// 发送 WebSocket ping 探活，超时则回调 false
    public func sendPing(timeout: TimeInterval = 2.0, completion: @escaping (Bool) -> Void) {
        guard let task = webSocketTask, isConnected else {
            completion(false)
            return
        }

        var completed = false
        let lock = NSLock()

        // 超时计时器
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            lock.lock()
            defer { lock.unlock() }
            if !completed {
                completed = true
                completion(false)
            }
        }

        // URLSessionWebSocketTask 内置 ping/pong
        task.sendPing { error in
            lock.lock()
            defer { lock.unlock() }
            if !completed {
                completed = true
                completion(error == nil)
            }
        }
    }

    /// 进入后台时标记连接为 stale；回到前台后据此直接走重连而非 ping 探活
    public func markStaleIfConnected() {
        if isConnected {
            isStale = true
        }
    }

    // MARK: - 内部辅助

    public func updateConnectionState(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.isConnected != connected else { return }
            self.isConnected = connected
            self.onConnectionStateChanged?(connected)
        }
    }

    // MARK: - 高频消息合并

    /// 需要合并的高频消息类型集合
    private static let coalescibleTypes: Set<String> = [
        "file_changed",
        "git_status_changed"
    ]

    private func makeConnectionIdentity(for url: URL) -> String {
        nextConnectionSerial &+= 1
        return "\(url.absoluteString)#\(nextConnectionSerial)"
    }

    /// 判断消息是否需要合并处理
    public func isCoalescible(_ type: String) -> Bool {
        WSClient.coalescibleTypes.contains(type)
    }

    /// 生成合并队列 key：类型 + 项目 + 工作空间 + 路径（若有），避免不同路径结果互相覆盖
    public func coalesceKey(for envelope: CoalescedEnvelope) -> String {
        let type = envelope.action
        let json = envelope.json
        let project = json["project"] as? String ?? ""
        let workspace = json["workspace"] as? String ?? ""
        let path = json["path"] as? String ?? ""
        return "\(type):\(project):\(workspace):\(path)"
    }

    /// 将高频消息放入合并队列，在窗口到期后统一处理
    public func enqueueForCoalesce(domain: String, action: String, json: [String: Any]) {
        let envelope = CoalescedEnvelope(domain: domain, action: action, json: json)
        let key = coalesceKey(for: envelope)
        coalesceQueue[key] = envelope

        // 如果已有定时器在等待，不重复创建
        if coalesceTimer != nil { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushCoalesceQueue()
        }
        coalesceTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval, execute: workItem)
    }

    /// 刷新合并队列，对每个 key 只处理最后一条消息
    private func flushCoalesceQueue() {
        coalesceTimer = nil
        let pending = coalesceQueue
        coalesceQueue.removeAll()

        for (_, envelope) in pending {
            dispatchCoalescedMessage(envelope)
        }
    }
}
