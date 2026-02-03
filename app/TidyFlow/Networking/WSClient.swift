import Foundation

/// Minimal WebSocket client for Core communication
class WSClient: NSObject, ObservableObject {
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
        print("[WSClient] Updating URL to: \(url.absoluteString)")
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

        print("[WSClient] Connecting to: \(url.absoluteString)")
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

    func send(_ message: String) {
        guard isConnected else {
            print("[WSClient] Cannot send - not connected")
            onError?("Not connected")
            return
        }

        print("[WSClient] Sending message: \(message.prefix(200))...")
        webSocketTask?.send(.string(message)) { [weak self] error in
            if let error = error {
                print("[WSClient] Send failed: \(error.localizedDescription)")
                self?.onError?("Send failed: \(error.localizedDescription)")
            } else {
                print("[WSClient] Message sent successfully")
            }
        }
    }

    func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: data, encoding: .utf8) else {
            onError?("Failed to serialize JSON")
            return
        }
        send(jsonString)
    }

    func requestFileIndex(project: String, workspace: String) {
        sendJSON([
            "type": "file_index",
            "project": project,
            "workspace": workspace
        ])
    }

    /// 请求文件列表（目录浏览）
    func requestFileList(project: String, workspace: String, path: String = ".") {
        sendJSON([
            "type": "file_list",
            "project": project,
            "workspace": workspace,
            "path": path
        ])
    }

    // Phase C2-2a: Request git diff
    func requestGitDiff(project: String, workspace: String, path: String, mode: String) {
        sendJSON([
            "type": "git_diff",
            "project": project,
            "workspace": workspace,
            "path": path,
            "mode": mode
        ])
    }

    // Phase C3-1: Request git status
    func requestGitStatus(project: String, workspace: String) {
        sendJSON([
            "type": "git_status",
            "project": project,
            "workspace": workspace
        ])
    }

    // Git Log: Request commit history
    func requestGitLog(project: String, workspace: String, limit: Int = 50) {
        sendJSON([
            "type": "git_log",
            "project": project,
            "workspace": workspace,
            "limit": limit
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
        sendJSON(msg)
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
        sendJSON(msg)
    }

    // Phase C3-2b: Request git discard
    func requestGitDiscard(project: String, workspace: String, path: String?, scope: String) {
        var msg: [String: Any] = [
            "type": "git_discard",
            "project": project,
            "workspace": workspace,
            "scope": scope
        ]
        if let path = path {
            msg["path"] = path
        }
        sendJSON(msg)
    }

    // Phase C3-3a: Request git branches
    func requestGitBranches(project: String, workspace: String) {
        sendJSON([
            "type": "git_branches",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase C3-3a: Request git switch branch
    func requestGitSwitchBranch(project: String, workspace: String, branch: String) {
        sendJSON([
            "type": "git_switch_branch",
            "project": project,
            "workspace": workspace,
            "branch": branch
        ])
    }

    // Phase C3-3b: Request git create branch
    func requestGitCreateBranch(project: String, workspace: String, branch: String) {
        sendJSON([
            "type": "git_create_branch",
            "project": project,
            "workspace": workspace,
            "branch": branch
        ])
    }

    // Phase C3-4a: Request git commit
    func requestGitCommit(project: String, workspace: String, message: String) {
        sendJSON([
            "type": "git_commit",
            "project": project,
            "workspace": workspace,
            "message": message
        ])
    }

    // Phase UX-3a: Request git fetch
    func requestGitFetch(project: String, workspace: String) {
        sendJSON([
            "type": "git_fetch",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git rebase
    func requestGitRebase(project: String, workspace: String, ontoBranch: String) {
        sendJSON([
            "type": "git_rebase",
            "project": project,
            "workspace": workspace,
            "onto_branch": ontoBranch
        ])
    }

    // Phase UX-3a: Request git rebase continue
    func requestGitRebaseContinue(project: String, workspace: String) {
        sendJSON([
            "type": "git_rebase_continue",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git rebase abort
    func requestGitRebaseAbort(project: String, workspace: String) {
        sendJSON([
            "type": "git_rebase_abort",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git operation status
    func requestGitOpStatus(project: String, workspace: String) {
        sendJSON([
            "type": "git_op_status",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3b: Request git merge to default
    func requestGitMergeToDefault(project: String, workspace: String, defaultBranch: String) {
        sendJSON([
            "type": "git_merge_to_default",
            "project": project,
            "workspace": workspace,
            "default_branch": defaultBranch
        ])
    }

    // Phase UX-3b: Request git merge continue
    func requestGitMergeContinue(project: String) {
        sendJSON([
            "type": "git_merge_continue",
            "project": project
        ])
    }

    // Phase UX-3b: Request git merge abort
    func requestGitMergeAbort(project: String) {
        sendJSON([
            "type": "git_merge_abort",
            "project": project
        ])
    }

    // Phase UX-3b: Request git integration status
    func requestGitIntegrationStatus(project: String) {
        sendJSON([
            "type": "git_integration_status",
            "project": project
        ])
    }

    // Phase UX-4: Request git rebase onto default
    func requestGitRebaseOntoDefault(project: String, workspace: String, defaultBranch: String) {
        sendJSON([
            "type": "git_rebase_onto_default",
            "project": project,
            "workspace": workspace,
            "default_branch": defaultBranch
        ])
    }

    // Phase UX-4: Request git rebase onto default continue
    func requestGitRebaseOntoDefaultContinue(project: String) {
        sendJSON([
            "type": "git_rebase_onto_default_continue",
            "project": project
        ])
    }

    // Phase UX-4: Request git rebase onto default abort
    func requestGitRebaseOntoDefaultAbort(project: String) {
        sendJSON([
            "type": "git_rebase_onto_default_abort",
            "project": project
        ])
    }

    // Phase UX-5: Request git reset integration worktree
    func requestGitResetIntegrationWorktree(project: String) {
        sendJSON([
            "type": "git_reset_integration_worktree",
            "project": project
        ])
    }

    // Phase UX-6: Request git check branch up to date
    func requestGitCheckBranchUpToDate(project: String, workspace: String) {
        sendJSON([
            "type": "git_check_branch_up_to_date",
            "project": project,
            "workspace": workspace
        ])
    }

    // UX-2: Request import project
    func requestImportProject(name: String, path: String, createDefaultWorkspace: Bool = true) {
        sendJSON([
            "type": "import_project",
            "name": name,
            "path": path,
            "create_default_workspace": createDefaultWorkspace
        ])
    }

    // UX-2: Request list projects
    func requestListProjects() {
        sendJSON([
            "type": "list_projects"
        ])
    }

    // Request list workspaces
    func requestListWorkspaces(project: String) {
        sendJSON([
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
        sendJSON(msg)
    }

    // Remove project
    func requestRemoveProject(name: String) {
        sendJSON([
            "type": "remove_project",
            "name": name
        ])
    }

    // Remove workspace
    func requestRemoveWorkspace(project: String, workspace: String) {
        sendJSON([
            "type": "remove_workspace",
            "project": project,
            "workspace": workspace
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
        case .string(let text):
            parseAndDispatch(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseAndDispatch(text)
            }
        @unknown default:
            break
        }
    }

    private func parseAndDispatch(_ text: String) {
        print("[WSClient] Received raw message: \(text.prefix(300))...")
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("[WSClient] Failed to parse message as JSON")
            return
        }

        print("[WSClient] Parsed message type: \(type)")

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
            print("[WSClient] Received project_imported: \(json)")
            if let result = ProjectImportedResult.from(json: json) {
                print("[WSClient] Parsed ProjectImportedResult: \(result.name)")
                onProjectImported?(result)
            } else {
                print("[WSClient] Failed to parse ProjectImportedResult from: \(json)")
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
        print("[WSClient] WebSocket connection opened to: \(currentURL?.absoluteString ?? "unknown")")
        updateConnectionState(true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        print("[WSClient] WebSocket connection closed. Code: \(closeCode.rawValue), Reason: \(reasonStr)")
        updateConnectionState(false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("[WSClient] URLSession task completed with error: \(error.localizedDescription)")
        }
    }
}
