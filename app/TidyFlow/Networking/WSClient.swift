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
    var onError: ((String) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    /// Initialize with a specific URL
    init(url: URL) {
        super.init()
        self.currentURL = url
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
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
}
