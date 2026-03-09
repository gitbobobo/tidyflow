import Foundation
import MessagePacker
import os
import TidyFlowShared

// 已拆分：
// - WSClient+Send.swift     所有 send/request 方法
// - WSClient+Receive.swift  接收、解析、分发消息 + URLSessionWebSocketDelegate

/// Minimal WebSocket client for Core communication
/// 使用 MessagePack 二进制协议与 Rust Core 通信（协议版本 v7，包络结构沿用 v6）
class WSClient: NSObject, ObservableObject {
    enum HTTPReadRequestContext: Equatable {
        case aiProviderList(project: String, workspace: String, aiTool: AIChatTool)
        case aiAgentList(project: String, workspace: String, aiTool: AIChatTool)
    }

    struct HTTPReadFailure: Equatable {
        let context: HTTPReadRequestContext?
        let message: String
    }

    struct CoalescedEnvelope {
        let domain: String
        let action: String
        let json: [String: Any]
    }
    // MARK: - MessagePack 编解码器（跨 extension 文件访问）
    let msgpackEncoder = MessagePackEncoder()
    let msgpackDecoder = MessagePackDecoder()
    @Published private(set) var isConnected: Bool = false
    /// 标记当前断连是否为主动行为（disconnect/reconnect），用于区分意外断连
    var isIntentionalDisconnect: Bool = false
    /// 当前是否处于连接建立中（尚未 didOpen）
    var isConnecting: Bool = false
    /// 进入后台时标记为 stale，回到前台时据此判断是否需要重连
    private(set) var isStale: Bool = false

    var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// Current WebSocket URL (can be updated at runtime)
    var currentURL: URL?
    /// WebSocket 鉴权 token（由 Core 进程启动时注入）
    private(set) var wsAuthToken: String?
    /// 重连防抖任务，避免短时间重复 reconnect 打断新连接
    private var pendingReconnectWorkItem: DispatchWorkItem?
    /// 最近一次已处理的服务端 seq（v7 包络），用于丢弃乱序/重复消息
    var lastServerSeq: UInt64 = 0
    /// 当前连接身份；每次建立新 socket 都会刷新，用于屏蔽旧连接的延迟回调。
    var connectionIdentity: String?
    /// 当前 socket task 对应的连接身份；跨文件扩展也需要访问它来拦截旧回调。
    var webSocketTaskIdentity: String?
    private var nextConnectionSerial: UInt64 = 0

    // 领域 handler（新路径）：优先于闭包回调分发，逐步替代 onXxx 回调。
    weak var gitMessageHandler: GitMessageHandler?
    weak var projectMessageHandler: ProjectMessageHandler?
    weak var fileMessageHandler: FileMessageHandler?
    weak var settingsMessageHandler: SettingsMessageHandler?
    weak var terminalMessageHandler: TerminalMessageHandler?
    weak var aiMessageHandler: AIMessageHandler?
    weak var evidenceMessageHandler: EvidenceMessageHandler?
    weak var evolutionMessageHandler: EvolutionMessageHandler?
    weak var errorMessageHandler: ErrorMessageHandler?

    /// Get current URL string for debug display
    var currentURLString: String? {
        currentURL?.absoluteString
    }

    // Message handlers
    var onFileIndexResult: ((FileIndexResult) -> Void)?
    var onFileListResult: ((FileListResult) -> Void)?
    var onGitDiffResult: ((GitDiffResult) -> Void)?
    var onGitStatusResult: ((GitStatusResult) -> Void)?
    var onGitLogResult: ((GitLogResult) -> Void)?
    var onGitShowResult: ((GitShowResult) -> Void)?
    var onGitOpResult: ((GitOpResult) -> Void)?
    var onGitBranchesResult: ((GitBranchesResult) -> Void)?
    var onGitCommitResult: ((GitCommitResult) -> Void)?
    var onGitAIMergeResult: ((GitAIMergeResult) -> Void)?
    var onGitRebaseResult: ((GitRebaseResult) -> Void)?
    var onGitOpStatusResult: ((GitOpStatusResult) -> Void)?
    var onGitMergeToDefaultResult: ((GitMergeToDefaultResult) -> Void)?
    var onGitIntegrationStatusResult: ((GitIntegrationStatusResult) -> Void)?
    // UX-4: Rebase onto default handler
    var onGitRebaseOntoDefaultResult: ((GitRebaseOntoDefaultResult) -> Void)?
    // UX-5: Reset integration worktree handler
    var onGitResetIntegrationWorktreeResult: ((GitResetIntegrationWorktreeResult) -> Void)?
    // UX-2: Project import handlers
    var onProjectImported: ((ProjectImportedResult) -> Void)?
    var onWorkspaceCreated: ((WorkspaceCreatedResult) -> Void)?
    var onProjectsList: ((ProjectsListResult) -> Void)?
    var onWorkspacesList: ((WorkspacesListResult) -> Void)?
    // 终端会话
    var onTermCreated: ((TermCreatedResult) -> Void)?
    var onTermAttached: ((TermAttachedResult) -> Void)?
    var onTermList: ((TermListResult) -> Void)?
    var onTermClosed: ((String) -> Void)?
    var onTerminalOutput: ((String?, [UInt8]) -> Void)?
    var onTerminalExit: ((String?, Int) -> Void)?
    var onProjectRemoved: ((ProjectRemovedResult) -> Void)?
    var onWorkspaceRemoved: ((WorkspaceRemovedResult) -> Void)?
    // 客户端设置
    var onClientSettingsResult: ((ClientSettings) -> Void)?
    var onClientSettingsSaved: ((Bool, String?) -> Void)?
    // v1.22: 文件监控回调
    var onWatchSubscribed: ((WatchSubscribedResult) -> Void)?
    var onWatchUnsubscribed: (() -> Void)?
    var onFileChanged: ((FileChangedNotification) -> Void)?
    var onGitStatusChanged: ((GitStatusChangedNotification) -> Void)?
    // v1.23: 文件重命名/删除回调
    var onFileRenameResult: ((FileRenameResult) -> Void)?
    var onFileDeleteResult: ((FileDeleteResult) -> Void)?
    // v1.24: 文件复制回调
    var onFileCopyResult: ((FileCopyResult) -> Void)?
    // v1.25: 文件移动回调
    var onFileMoveResult: ((FileMoveResult) -> Void)?
    // 文件写入回调（新建文件）
    var onFileWriteResult: ((FileWriteResult) -> Void)?
    // 文件读取回调（预览/查看）
    var onFileReadResult: ((FileReadResult) -> Void)?
    // v1.29: 项目命令回调
    var onProjectCommandsSaved: ((String, Bool, String?) -> Void)?
    var onProjectCommandStarted: ((String, String, String, String) -> Void)?
    var onProjectCommandCompleted: ((String, String, String, String, Bool, String?) -> Void)?
    var onProjectCommandCancelled: ((String, String, String, String) -> Void)?
    // v1.30: 项目命令实时输出回调 (taskId, line)
    var onProjectCommandOutput: ((String, String) -> Void)?
    var onRemoteTermChanged: (() -> Void)?
    // v1.37: AI 任务取消确认
    var onAITaskCancelled: ((AITaskCancelled) -> Void)?
    // v1.39: 剪贴板图片写入结果
    var onClipboardImageSet: ((Bool, String?) -> Void)?
    // v1.40: 任务历史快照（iOS 重连恢复）
    var onTasksSnapshot: (([TaskSnapshotEntry]) -> Void)?
    // v1.40: 工作流模板回调
    var onTemplatesList: ((TemplatesListResult) -> Void)?
    var onTemplateSaved: ((TemplateSavedResult) -> Void)?
    var onTemplateDeleted: ((TemplateDeletedResult) -> Void)?
    var onTemplateImported: ((TemplateImportedResult) -> Void)?
    var onTemplateExported: ((TemplateExportedResult) -> Void)?
    // AI Chat（结构化 message/part 流）
    var onAISessionStarted: ((AISessionStartedV2) -> Void)?
    var onAISessionList: ((AISessionListV2) -> Void)?
    var onAISessionMessages: ((AISessionMessagesV2) -> Void)?
    var onAISessionMessagesUpdate: ((AISessionMessagesUpdateV2) -> Void)?
    var onAISessionStatusResult: ((AISessionStatusResultV2) -> Void)?
    var onAISessionStatusUpdate: ((AISessionStatusUpdateV2) -> Void)?
    var onAIChatDone: ((AIChatDoneV2) -> Void)?
    var onAIChatPending: ((AIChatPendingV2) -> Void)?
    var onAIChatError: ((AIChatErrorV2) -> Void)?
    var onAIQuestionAsked: ((AIQuestionAskedV2) -> Void)?
    var onAIQuestionCleared: ((AIQuestionClearedV2) -> Void)?
    var onAIProviderList: ((AIProviderListResult) -> Void)?
    var onAIAgentList: ((AIAgentListResult) -> Void)?
    var onAISlashCommands: ((AISlashCommandsResult) -> Void)?
    var onAISlashCommandsUpdate: ((AISlashCommandsUpdateResult) -> Void)?
    var onAISessionConfigOptions: ((AISessionConfigOptionsResult) -> Void)?
    var onAISessionSubscribeAck: ((AISessionSubscribeAck) -> Void)?
    var onAISessionRenameResult: ((AISessionRenameResult) -> Void)?
    var onAISessionSearchResult: ((AISessionSearchResult) -> Void)?
    var onAICodeReviewResult: ((AICodeReviewResult) -> Void)?
    var onAICodeCompletionChunk: ((AICodeCompletionChunk) -> Void)?
    var onAICodeCompletionDone: ((AICodeCompletionDone) -> Void)?
    // Evolution
    var onEvoPulse: (() -> Void)?
    var onEvoWorkspaceStatusEvent: ((EvolutionWorkspaceStatusEventV2) -> Void)?
    var onEvoSnapshot: ((EvolutionSnapshotV2) -> Void)?
    var onEvoCycleUpdated: ((EvoCycleUpdatedV2) -> Void)?
    var onEvoAgentProfile: ((EvolutionAgentProfileV2) -> Void)?
    var onEvoBlockingRequired: ((EvolutionBlockingRequiredV2) -> Void)?
    var onEvoBlockersUpdated: ((EvolutionBlockersUpdatedV2) -> Void)?
    var onEvoCycleHistory: ((String, String, [EvolutionCycleHistoryItemV2]) -> Void)?
    var onEvoAutoCommitResult: ((EvoAutoCommitResult) -> Void)?
    var onEvidenceSnapshot: ((EvidenceSnapshotV2) -> Void)?
    var onEvidenceRebuildPrompt: ((EvidenceRebuildPromptV2) -> Void)?
    var onEvidenceItemChunk: ((EvidenceItemChunkV2) -> Void)?
    /// 工作区缓存可观测性快照（由 /api/v1/system/snapshot HTTP 响应驱动，按 (project, workspace) 隔离）
    var onSystemSnapshot: ((SystemSnapshotCacheMetrics) -> Void)?
    var onEvoError: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// 结构化 Core 错误回调（含错误码与上下文）
    var onCoreError: ((CoreError) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?
    /// v7 包络元信息流（用于上层统一路由/观测）
    var onServerEnvelopeMeta: ((ServerEnvelopeMeta) -> Void)?
    /// v1.41: Core 推送系统健康快照
    var onHealthSnapshot: ((SystemHealthSnapshot) -> Void)?
    /// v1.41: Core 推送修复执行结果
    var onHealthRepairResult: ((RepairAuditEntry) -> Void)?

    func emitClientError(_ message: String) {
        if let handler = errorMessageHandler {
            handler.handleClientError(message)
        } else {
            onError?(message)
        }
    }

    /// 发送结构化 Core 错误（含错误码与上下文，供多工作区定位使用）
    func emitCoreError(_ error: CoreError) {
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
    var onHTTPRequestScheduled: ((_ domain: String, _ path: String, _ queryItems: [URLQueryItem]) -> Void)?
    /// HTTP 读请求失败钩子（用于上层清理 loading / pending 状态）
    var onHTTPReadFailure: ((HTTPReadFailure) -> Void)?
    /// AI 最近页消息请求防重（仅 before=nil 场景）
    var aiRecentSessionMessagesInFlightAt: [String: Date] = [:]
    var aiRecentSessionMessagesLastSuccessAt: [String: Date] = [:]
    var aiRecentSessionMessagesDedupDropTotal: Int = 0

    /// 后台串行队列，用于 MessagePack 解码（避免阻塞主线程）
    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.tidyflow.ws.decode"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: decodeQueue)
    }

    /// Initialize with a specific URL
    init(url: URL) {
        super.init()
        self.currentURL = url
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: decodeQueue)
    }

    /// Update the base URL and optionally reconnect
    /// - Parameters:
    ///   - url: New WebSocket URL
    ///   - reconnect: Whether to disconnect and reconnect immediately
    func updateBaseURL(_ url: URL, reconnect: Bool = true) {
        currentURL = url
        if reconnect {
            self.reconnect()
        }
    }

    /// Update the base URL using port number
    func updatePort(_ port: Int, reconnect: Bool = true) {
        let url = AppConfig.makeWsURL(port: port, token: wsAuthToken)
        updateBaseURL(url, reconnect: reconnect)
    }

    /// 更新 WebSocket 鉴权 token（用于后续 connect/reconnect）
    func updateAuthToken(_ token: String?) {
        wsAuthToken = token
    }

    // MARK: - Connection

    func connect() {
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
        TFLog.ws.info("Connecting to: \(url.absoluteString, privacy: .public)")
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
    func connect(port: Int) {
        let targetURL = AppConfig.makeWsURL(port: port, token: wsAuthToken)
        if currentURL == targetURL, (isConnected || isConnecting || webSocketTask != nil) {
            return
        }
        currentURL = targetURL
        connect()
    }

    func disconnect() {
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

    func reconnect() {
        disconnect(clearPendingReconnect: false)
        pendingReconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        pendingReconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// 发送 WebSocket ping 探活，超时则回调 false
    func sendPing(timeout: TimeInterval = 2.0, completion: @escaping (Bool) -> Void) {
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
    func markStaleIfConnected() {
        if isConnected {
            isStale = true
        }
    }

    // MARK: - 内部辅助

    func updateConnectionState(_ connected: Bool) {
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
    func isCoalescible(_ type: String) -> Bool {
        WSClient.coalescibleTypes.contains(type)
    }

    /// 生成合并队列 key：类型 + 项目 + 工作空间 + 路径（若有），避免不同路径结果互相覆盖
    func coalesceKey(for envelope: CoalescedEnvelope) -> String {
        let type = envelope.action
        let json = envelope.json
        let project = json["project"] as? String ?? ""
        let workspace = json["workspace"] as? String ?? ""
        let path = json["path"] as? String ?? ""
        return "\(type):\(project):\(workspace):\(path)"
    }

    /// 将高频消息放入合并队列，在窗口到期后统一处理
    func enqueueForCoalesce(domain: String, action: String, json: [String: Any]) {
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
