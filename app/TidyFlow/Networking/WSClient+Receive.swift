import Foundation

// MARK: - WSClient 接收消息扩展

extension WSClient {

    // MARK: - Receive Messages

    func receiveMessage() {
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
            let commitAIAgent = json["commit_ai_agent"] as? String
            let mergeAIAgent = json["merge_ai_agent"] as? String
            let settings = ClientSettings(customCommands: commands, workspaceShortcuts: workspaceShortcuts, commitAIAgent: commitAIAgent, mergeAIAgent: mergeAIAgent)
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
