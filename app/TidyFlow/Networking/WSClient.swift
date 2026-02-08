import Foundation
import MessagePacker
import os

// 已拆分：
// - WSClient+Send.swift     所有 send/request 方法
// - WSClient+Receive.swift  接收、解析、分发消息 + URLSessionWebSocketDelegate

/// Minimal WebSocket client for Core communication
/// 使用 MessagePack 二进制协议与 Rust Core 通信（协议版本 v2）
class WSClient: NSObject, ObservableObject {
    // MARK: - MessagePack 编解码器（跨 extension 文件访问）
    let msgpackEncoder = MessagePackEncoder()
    let msgpackDecoder = MessagePackDecoder()
    @Published private(set) var isConnected: Bool = false
    /// 标记当前断连是否为主动行为（disconnect/reconnect），用于区分意外断连
    private(set) var isIntentionalDisconnect: Bool = false

    var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// Current WebSocket URL (can be updated at runtime)
    var currentURL: URL?

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
    // v1.29: 项目命令回调
    var onProjectCommandsSaved: ((String, Bool, String?) -> Void)?
    var onProjectCommandStarted: ((String, String, String, String) -> Void)?
    var onProjectCommandCompleted: ((String, String, String, String, Bool, String?) -> Void)?
    var onError: ((String) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    // MARK: - 高频消息合并队列
    /// 合并窗口时长（秒），窗口内同 key 的消息只保留最后一条
    private let coalesceInterval: TimeInterval = 0.05 // 50ms
    /// 合并队列：key 为 "消息类型:项目:工作空间"，value 为待处理的原始字典
    private var coalesceQueue: [String: [String: Any]] = [:]
    /// 合并窗口定时器
    private var coalesceTimer: DispatchWorkItem?

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
        let url = AppConfig.makeWsURL(port: port)
        updateBaseURL(url, reconnect: reconnect)
    }

    // MARK: - Connection

    func connect() {
        guard webSocketTask == nil else { return }

        guard let url = currentURL else {
            onError?("No WebSocket URL configured")
            return
        }

        isIntentionalDisconnect = false
        TFLog.ws.info("Connecting to: \(url.absoluteString, privacy: .public)")
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
    }

    /// Connect to a specific port (convenience method)
    func connect(port: Int) {
        currentURL = AppConfig.makeWsURL(port: port)
        connect()
    }

    func disconnect() {
        isIntentionalDisconnect = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        updateConnectionState(false)
    }

    func reconnect() {
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.connect()
        }
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

    // MARK: - 内部辅助

    func updateConnectionState(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = connected
            self?.onConnectionStateChanged?(connected)
        }
    }

    // MARK: - 高频消息合并

    /// 需要合并的高频消息类型集合
    private static let coalescibleTypes: Set<String> = [
        "file_changed",
        "git_status_changed",
        "file_index_result",
        "file_list_result"
    ]

    /// 判断消息是否需要合并处理
    func isCoalescible(_ type: String) -> Bool {
        WSClient.coalescibleTypes.contains(type)
    }

    /// 生成合并队列的 key：类型 + 项目 + 工作空间，确保同一上下文的消息被合并
    func coalesceKey(for json: [String: Any]) -> String {
        let type = json["type"] as? String ?? ""
        let project = json["project"] as? String ?? ""
        let workspace = json["workspace"] as? String ?? ""
        return "\(type):\(project):\(workspace)"
    }

    /// 将高频消息放入合并队列，在窗口到期后统一处理
    func enqueueForCoalesce(_ json: [String: Any]) {
        let key = coalesceKey(for: json)
        coalesceQueue[key] = json

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

        for (_, json) in pending {
            dispatchCoalescedMessage(json)
        }
    }
}
