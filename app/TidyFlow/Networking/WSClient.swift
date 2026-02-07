import Foundation
import MessagePacker
import os

/// Minimal WebSocket client for Core communication
/// 使用 MessagePack 二进制协议与 Rust Core 通信（协议版本 v2）
class WSClient: NSObject, ObservableObject {
    // MARK: - MessagePack 编解码器
    private let msgpackEncoder = MessagePackEncoder()
    private let msgpackDecoder = MessagePackDecoder()
    @Published private(set) var isConnected: Bool = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// Current WebSocket URL (can be updated at runtime)
    private var currentURL: URL?

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

    // MARK: - Send Messages

    /// 发送二进制 MessagePack 数据
    func sendBinary(_ data: Data) {
        guard isConnected else {
            TFLog.ws.warning("Cannot send - not connected")
            onError?("Not connected")
            return
        }

        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error = error {
                TFLog.ws.error("Send failed: \(error.localizedDescription, privacy: .public)")
                self?.onError?("Send failed: \(error.localizedDescription)")
            }
        }
    }

    /// 发送消息，使用 MessagePack 编码
    func send(_ dict: [String: Any]) {
        do {
            let codable = AnyCodable.from(dict)
            let data = try msgpackEncoder.encode(codable)
            sendBinary(data)
        } catch {
            TFLog.ws.error("MessagePack encode failed: \(error.localizedDescription, privacy: .public)")
            onError?("Failed to encode message: \(error.localizedDescription)")
        }
    }

    func requestFileIndex(project: String, workspace: String) {
        send([
            "type": "file_index",
            "project": project,
            "workspace": workspace
        ])
    }

    /// 请求文件列表（目录浏览）
    func requestFileList(project: String, workspace: String, path: String = ".") {
        send([
            "type": "file_list",
            "project": project,
            "workspace": workspace,
            "path": path
        ])
    }

    // Phase C2-2a: Request git diff
    func requestGitDiff(project: String, workspace: String, path: String, mode: String) {
        send([
            "type": "git_diff",
            "project": project,
            "workspace": workspace,
            "path": path,
            "mode": mode
        ])
    }

    // Phase C3-1: Request git status
    func requestGitStatus(project: String, workspace: String) {
        send([
            "type": "git_status",
            "project": project,
            "workspace": workspace
        ])
    }

    // Git Log: Request commit history
    func requestGitLog(project: String, workspace: String, limit: Int = 50) {
        send([
            "type": "git_log",
            "project": project,
            "workspace": workspace,
            "limit": limit
        ])
    }

    // Git Show: Request single commit details
    func requestGitShow(project: String, workspace: String, sha: String) {
        send([
            "type": "git_show",
            "project": project,
            "workspace": workspace,
            "sha": sha
        ])
    }

    // Phase C3-2a: Request git stage
    func requestGitStage(project: String, workspace: String, path: String?, scope: String) {
        var msg: [String: Any] = [
            "type": "git_stage",
            "project": project,
            "workspace": workspace,
            "scope": scope
        ]
        if let path = path {
            msg["path"] = path
        }
        send(msg)
    }

    // Phase C3-2a: Request git unstage
    func requestGitUnstage(project: String, workspace: String, path: String?, scope: String) {
        var msg: [String: Any] = [
            "type": "git_unstage",
            "project": project,
            "workspace": workspace,
            "scope": scope
        ]
        if let path = path {
            msg["path"] = path
        }
        send(msg)
    }

    // Phase C3-2b: Request git discard
    func requestGitDiscard(project: String, workspace: String, path: String?, scope: String, includeUntracked: Bool = false) {
        var msg: [String: Any] = [
            "type": "git_discard",
            "project": project,
            "workspace": workspace,
            "scope": scope
        ]
        if let path = path {
            msg["path"] = path
        }
        if includeUntracked {
            msg["include_untracked"] = true
        }
        send(msg)
    }

    // Phase C3-3a: Request git branches
    func requestGitBranches(project: String, workspace: String) {
        send([
            "type": "git_branches",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase C3-3a: Request git switch branch
    func requestGitSwitchBranch(project: String, workspace: String, branch: String) {
        send([
            "type": "git_switch_branch",
            "project": project,
            "workspace": workspace,
            "branch": branch
        ])
    }

    // Phase C3-3b: Request git create branch
    func requestGitCreateBranch(project: String, workspace: String, branch: String) {
        send([
            "type": "git_create_branch",
            "project": project,
            "workspace": workspace,
            "branch": branch
        ])
    }

    // Phase C3-4a: Request git commit
    func requestGitCommit(project: String, workspace: String, message: String) {
        send([
            "type": "git_commit",
            "project": project,
            "workspace": workspace,
            "message": message
        ])
    }

    // Phase UX-3a: Request git fetch
    func requestGitFetch(project: String, workspace: String) {
        send([
            "type": "git_fetch",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git rebase
    func requestGitRebase(project: String, workspace: String, ontoBranch: String) {
        send([
            "type": "git_rebase",
            "project": project,
            "workspace": workspace,
            "onto_branch": ontoBranch
        ])
    }

    // Phase UX-3a: Request git rebase continue
    func requestGitRebaseContinue(project: String, workspace: String) {
        send([
            "type": "git_rebase_continue",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git rebase abort
    func requestGitRebaseAbort(project: String, workspace: String) {
        send([
            "type": "git_rebase_abort",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git operation status
    func requestGitOpStatus(project: String, workspace: String) {
        send([
            "type": "git_op_status",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3b: Request git merge to default
    func requestGitMergeToDefault(project: String, workspace: String, defaultBranch: String) {
        send([
            "type": "git_merge_to_default",
            "project": project,
            "workspace": workspace,
            "default_branch": defaultBranch
        ])
    }

    // Phase UX-3b: Request git merge continue
    func requestGitMergeContinue(project: String) {
        send([
            "type": "git_merge_continue",
            "project": project
        ])
    }

    // Phase UX-3b: Request git merge abort
    func requestGitMergeAbort(project: String) {
        send([
            "type": "git_merge_abort",
            "project": project
        ])
    }

    // Phase UX-3b: Request git integration status
    func requestGitIntegrationStatus(project: String) {
        send([
            "type": "git_integration_status",
            "project": project
        ])
    }

    // Phase UX-4: Request git rebase onto default
    func requestGitRebaseOntoDefault(project: String, workspace: String, defaultBranch: String) {
        send([
            "type": "git_rebase_onto_default",
            "project": project,
            "workspace": workspace,
            "default_branch": defaultBranch
        ])
    }

    // Phase UX-4: Request git rebase onto default continue
    func requestGitRebaseOntoDefaultContinue(project: String) {
        send([
            "type": "git_rebase_onto_default_continue",
            "project": project
        ])
    }

    // Phase UX-4: Request git rebase onto default abort
    func requestGitRebaseOntoDefaultAbort(project: String) {
        send([
            "type": "git_rebase_onto_default_abort",
            "project": project
        ])
    }

    // Phase UX-5: Request git reset integration worktree
    func requestGitResetIntegrationWorktree(project: String) {
        send([
            "type": "git_reset_integration_worktree",
            "project": project
        ])
    }

    // Phase UX-6: Request git check branch up to date
    func requestGitCheckBranchUpToDate(project: String, workspace: String) {
        send([
            "type": "git_check_branch_up_to_date",
            "project": project,
            "workspace": workspace
        ])
    }

    // UX-2: Request import project
    func requestImportProject(name: String, path: String) {
        send([
            "type": "import_project",
            "name": name,
            "path": path
        ])
    }

    // UX-2: Request list projects
    func requestListProjects() {
        send([
            "type": "list_projects"
        ])
    }

    // Request list workspaces
    func requestListWorkspaces(project: String) {
        send([
            "type": "list_workspaces",
            "project": project
        ])
    }

    // UX-2: Request create workspace（名称由 Core 用 petname 生成）
    func requestCreateWorkspace(project: String, fromBranch: String? = nil) {
        var msg: [String: Any] = [
            "type": "create_workspace",
            "project": project
        ]
        if let branch = fromBranch {
            msg["from_branch"] = branch
        }
        send(msg)
    }

    // Remove project
    func requestRemoveProject(name: String) {
        send([
            "type": "remove_project",
            "name": name
        ])
    }

    // Remove workspace
    func requestRemoveWorkspace(project: String, workspace: String) {
        send([
            "type": "remove_workspace",
            "project": project,
            "workspace": workspace
        ])
    }

    // MARK: - 客户端设置

    /// 请求获取客户端设置
    func requestGetClientSettings() {
        send([
            "type": "get_client_settings"
        ])
    }

    /// 保存客户端设置
    func requestSaveClientSettings(settings: ClientSettings) {
        let commandsData = settings.customCommands.map { cmd -> [String: Any] in
            return [
                "id": cmd.id,
                "name": cmd.name,
                "icon": cmd.icon,
                "command": cmd.command
            ]
        }
        var payload: [String: Any] = [
            "type": "save_client_settings",
            "custom_commands": commandsData,
            "workspace_shortcuts": settings.workspaceShortcuts
        ]
        if let agent = settings.selectedAIAgent {
            payload["selected_ai_agent"] = agent
        }
        send(payload)
    }

    // MARK: - v1.22: 文件监控

    /// 订阅工作空间文件监控
    func requestWatchSubscribe(project: String, workspace: String) {
        send([
            "type": "watch_subscribe",
            "project": project,
            "workspace": workspace
        ])
    }

    /// 取消文件监控订阅
    func requestWatchUnsubscribe() {
        send([
            "type": "watch_unsubscribe"
        ])
    }

    // MARK: - v1.23: 文件重命名/删除

    /// 请求重命名文件或目录
    func requestFileRename(project: String, workspace: String, oldPath: String, newName: String) {
        send([
            "type": "file_rename",
            "project": project,
            "workspace": workspace,
            "old_path": oldPath,
            "new_name": newName
        ])
    }

    /// 请求删除文件或目录（移到回收站）
    func requestFileDelete(project: String, workspace: String, path: String) {
        send([
            "type": "file_delete",
            "project": project,
            "workspace": workspace,
            "path": path
        ])
    }

    // MARK: - v1.24: 文件复制

    /// 请求复制文件或目录（使用绝对路径）
    func requestFileCopy(destProject: String, destWorkspace: String, sourceAbsolutePath: String, destDir: String) {
        send([
            "type": "file_copy",
            "dest_project": destProject,
            "dest_workspace": destWorkspace,
            "source_absolute_path": sourceAbsolutePath,
            "dest_dir": destDir
        ])
    }

    // MARK: - v1.25: 文件移动

    /// 请求移动文件或目录到新目录
    func requestFileMove(project: String, workspace: String, oldPath: String, newDir: String) {
        send([
            "type": "file_move",
            "project": project,
            "workspace": workspace,
            "old_path": oldPath,
            "new_dir": newDir
        ])
    }

    // MARK: - 文件写入（新建文件）

    /// 请求写入文件（用于新建空文件）
    func requestFileWrite(project: String, workspace: String, path: String, content: Data) {
        send([
            "type": "file_write",
            "project": project,
            "workspace": workspace,
            "path": path,
            "content": [UInt8](content)
        ])
    }

    // MARK: - Receive Messages

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage() // Continue listening
            case .failure(let error):
                // Connection closed or error
                if self?.isConnected == true {
                    self?.onError?("Receive error: \(error.localizedDescription)")
                    self?.updateConnectionState(false)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            parseAndDispatchBinary(data)
        case .string:
            TFLog.ws.error("Received unexpected text message, v2 protocol requires binary")
        @unknown default:
            break
        }
    }

    /// 解析并分发二进制 MessagePack 消息
    private func parseAndDispatchBinary(_ data: Data) {
        do {
            let decoded = try msgpackDecoder.decode(AnyCodable.self, from: data)
            guard let json = decoded.toDictionary else {
                TFLog.ws.error("MessagePack decoded value is not a dictionary")
                return
            }
            dispatchMessage(json)
        } catch {
            TFLog.ws.error("MessagePack decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 分发解析后的消息到对应的处理器
    private func dispatchMessage(_ json: [String: Any]) {
        guard let type = json["type"] as? String else {
            TFLog.ws.error("Message missing 'type' field")
            return
        }

        switch type {
        case "hello":
            // Connection established, ignore or log
            break

        case "file_index_result":
            if let result = FileIndexResult.from(json: json) {
                onFileIndexResult?(result)
            }

        case "file_list_result":
            if let result = FileListResult.from(json: json) {
                onFileListResult?(result)
            }

        case "git_diff_result":
            if let result = GitDiffResult.from(json: json) {
                onGitDiffResult?(result)
            }

        case "git_status_result":
            if let result = GitStatusResult.from(json: json) {
                onGitStatusResult?(result)
            }

        case "git_log_result":
            if let result = GitLogResult.from(json: json) {
                onGitLogResult?(result)
            }

        case "git_show_result":
            if let result = GitShowResult.from(json: json) {
                onGitShowResult?(result)
            }

        case "git_op_result":
            if let result = GitOpResult.from(json: json) {
                onGitOpResult?(result)
            }

        case "git_branches_result":
            if let result = GitBranchesResult.from(json: json) {
                onGitBranchesResult?(result)
            }

        case "git_commit_result":
            if let result = GitCommitResult.from(json: json) {
                onGitCommitResult?(result)
            }

        case "git_rebase_result":
            if let result = GitRebaseResult.from(json: json) {
                onGitRebaseResult?(result)
            }

        case "git_op_status_result":
            if let result = GitOpStatusResult.from(json: json) {
                onGitOpStatusResult?(result)
            }

        case "git_merge_to_default_result":
            if let result = GitMergeToDefaultResult.from(json: json) {
                onGitMergeToDefaultResult?(result)
            }

        case "git_integration_status_result":
            if let result = GitIntegrationStatusResult.from(json: json) {
                onGitIntegrationStatusResult?(result)
            }

        case "git_rebase_onto_default_result":
            if let result = GitRebaseOntoDefaultResult.from(json: json) {
                onGitRebaseOntoDefaultResult?(result)
            }

        case "git_reset_integration_worktree_result":
            if let result = GitResetIntegrationWorktreeResult.from(json: json) {
                onGitResetIntegrationWorktreeResult?(result)
            }

        case "project_imported":
            if let result = ProjectImportedResult.from(json: json) {
                onProjectImported?(result)
            } else {
                TFLog.ws.error("Failed to parse ProjectImportedResult")
                onError?("Failed to parse project import response")
            }

        case "workspace_created":
            if let result = WorkspaceCreatedResult.from(json: json) {
                onWorkspaceCreated?(result)
            }

        case "projects":
            if let result = ProjectsListResult.from(json: json) {
                onProjectsList?(result)
            }

        case "workspaces":
            if let result = WorkspacesListResult.from(json: json) {
                onWorkspacesList?(result)
            }

        case "project_removed":
            if let result = ProjectRemovedResult.from(json: json) {
                onProjectRemoved?(result)
            }

        case "workspace_removed":
            if let result = WorkspaceRemovedResult.from(json: json) {
                onWorkspaceRemoved?(result)
            }

        case "client_settings_result":
            // 解析自定义命令列表
            var commands: [CustomCommand] = []
            if let commandsJson = json["custom_commands"] as? [[String: Any]] {
                commands = commandsJson.compactMap { cmdJson -> CustomCommand? in
                    guard let id = cmdJson["id"] as? String,
                          let name = cmdJson["name"] as? String,
                          let icon = cmdJson["icon"] as? String,
                          let command = cmdJson["command"] as? String else {
                        return nil
                    }
                    return CustomCommand(id: id, name: name, icon: icon, command: command)
                }
            }
            // 解析工作空间快捷键映射
            let workspaceShortcuts = json["workspace_shortcuts"] as? [String: String] ?? [:]
            // 解析选择的 AI Agent
            let selectedAIAgent = json["selected_ai_agent"] as? String
            let settings = ClientSettings(customCommands: commands, workspaceShortcuts: workspaceShortcuts, selectedAIAgent: selectedAIAgent)
            onClientSettingsResult?(settings)

        case "client_settings_saved":
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onClientSettingsSaved?(ok, message)

        // v1.22: 文件监控消息
        case "watch_subscribed":
            if let result = WatchSubscribedResult.from(json: json) {
                onWatchSubscribed?(result)
            }

        case "watch_unsubscribed":
            onWatchUnsubscribed?()

        case "file_changed":
            if let notification = FileChangedNotification.from(json: json) {
                onFileChanged?(notification)
            }

        case "git_status_changed":
            if let notification = GitStatusChangedNotification.from(json: json) {
                onGitStatusChanged?(notification)
            }

        case "file_rename_result":
            if let result = FileRenameResult.from(json: json) {
                onFileRenameResult?(result)
            }

        case "file_delete_result":
            if let result = FileDeleteResult.from(json: json) {
                onFileDeleteResult?(result)
            }

        case "file_copy_result":
            if let result = FileCopyResult.from(json: json) {
                onFileCopyResult?(result)
            }

        case "file_move_result":
            if let result = FileMoveResult.from(json: json) {
                onFileMoveResult?(result)
            }

        case "file_write_result":
            if let result = FileWriteResult.from(json: json) {
                onFileWriteResult?(result)
            }

        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            onError?(errorMsg)

        default:
            // Unknown message type, ignore
            break
        }
    }

    private func updateConnectionState(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = connected
            self?.onConnectionStateChanged?(connected)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WSClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        TFLog.ws.info("WebSocket connected to: \(self.currentURL?.absoluteString ?? "unknown", privacy: .public)")
        updateConnectionState(true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        TFLog.ws.info("WebSocket disconnected. Code: \(closeCode.rawValue, privacy: .public)")
        updateConnectionState(false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            TFLog.ws.error("URLSession error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
