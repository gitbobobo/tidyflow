import Foundation

/// Minimal WebSocket client for Core communication
class WSClient: NSObject, ObservableObject {
    @Published private(set) var isConnected: Bool = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Message handlers
    var onFileIndexResult: ((FileIndexResult) -> Void)?
    var onGitDiffResult: ((GitDiffResult) -> Void)?
    var onGitStatusResult: ((GitStatusResult) -> Void)?
    var onGitOpResult: ((GitOpResult) -> Void)?
    var onGitBranchesResult: ((GitBranchesResult) -> Void)?
    var onGitCommitResult: ((GitCommitResult) -> Void)?
    var onError: ((String) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    // MARK: - Connection

    func connect() {
        guard webSocketTask == nil else { return }

        let urlString = AppConfig.coreWsURL
        guard let url = URL(string: urlString) else {
            onError?("Invalid WebSocket URL")
            return
        }

        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
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
            onError?("Not connected")
            return
        }

        webSocketTask?.send(.string(message)) { [weak self] error in
            if let error = error {
                self?.onError?("Send failed: \(error.localizedDescription)")
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
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
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

        case "git_diff_result":
            if let result = GitDiffResult.from(json: json) {
                onGitDiffResult?(result)
            }

        case "git_status_result":
            if let result = GitStatusResult.from(json: json) {
                onGitStatusResult?(result)
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
        updateConnectionState(true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        updateConnectionState(false)
    }
}
