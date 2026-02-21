import Foundation

// MARK: - WSClient 接收消息扩展

extension WSClient {

    // MARK: - Receive Messages

    func receiveMessage(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            // 旧连接回调可能在重连后延迟到达；只处理当前 task 的回调。
            guard self.webSocketTask === task else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage(for: task) // Continue listening
            case .failure(let error):
                // Connection closed or error — 切回主线程更新状态
                DispatchQueue.main.async {
                    guard self.webSocketTask === task else { return }
                    self.isConnecting = false
                    self.webSocketTask = nil
                    if self.isConnected {
                        self.onError?("Receive error: \(error.localizedDescription)")
                        self.updateConnectionState(false)
                    }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            parseAndDispatchBinary(data)
        case .string:
            TFLog.ws.error("Received unexpected text message, protocol v4 requires binary")
        @unknown default:
            break
        }
    }

    /// 解析并分发二进制 MessagePack 消息
    /// 解码在后台队列执行，分发回调切回主线程
    private func parseAndDispatchBinary(_ data: Data) {
        do {
            let decoded = try msgpackDecoder.decode(AnyCodable.self, from: data)
            guard let json = decoded.toDictionary else {
                TFLog.ws.error("MessagePack decoded value is not a dictionary")
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.dispatchMessage(json)
            }
        } catch {
            TFLog.ws.error("MessagePack decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 分发解析后的消息到对应的处理器
    private func dispatchMessage(_ envelope: [String: Any]) {
        guard let type = envelope["action"] as? String,
              let seq = parseEnvelopeSeq(envelope["seq"]),
              let _ = envelope["domain"] as? String,
              let _ = envelope["kind"] as? String,
              let payload = envelope["payload"] as? [String: Any] else {
            TFLog.ws.error("Message missing v4 envelope fields: seq/domain/action/kind/payload")
            return
        }
        if seq <= lastServerSeq {
            TFLog.ws.warning(
                "Dropping stale envelope: seq=\(seq, privacy: .public), last=\(self.lastServerSeq, privacy: .public)"
            )
            return
        }
        lastServerSeq = seq
        var json = payload
        json["type"] = type

        // 高频消息走合并队列，避免淹没 UI 线程
        if isCoalescible(type) {
            enqueueForCoalesce(json)
            return
        }

        switch type {
        case "hello":
            // Connection established, ignore or log
            break

        case "output":
            let termId = json["term_id"] as? String
            let bytes = WSBinary.decodeBytes(json["data"])
            onTerminalOutput?(termId, bytes)

        case "exit":
            let termId = json["term_id"] as? String
            let code = json["code"] as? Int ?? -1
            onTerminalExit?(termId, code)

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

        case "git_ai_commit_result":
            if let result = GitAICommitResult.from(json: json) {
                onGitAICommitResult?(result)
            }

        case "git_ai_merge_result":
            if let result = GitAIMergeResult.from(json: json) {
                onGitAIMergeResult?(result)
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

        case "term_created":
            if let result = TermCreatedResult.from(json: json) {
                onTermCreated?(result)
            }

        case "term_attached":
            if let result = TermAttachedResult.from(json: json) {
                onTermAttached?(result)
            }

        case "term_list":
            if let result = TermListResult.from(json: json) {
                let remoteSubs = result.items.flatMap(\.remoteSubscribers)
                TFLog.ws.info("Received term_list: \(result.items.count) terminals, \(remoteSubs.count) remote subscribers")
                onTermList?(result)
            } else {
                TFLog.ws.warning("Failed to parse term_list response")
            }

        case "term_closed":
            if let termId = json["term_id"] as? String {
                onTermClosed?(termId)
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
            let fixedPort = json["fixed_port"] as? Int ?? 0
            let remoteAccessEnabled = json["remote_access_enabled"] as? Bool ?? false
            let appLanguage = json["app_language"] as? String ?? "system"
            let evolutionAgentProfiles = parseEvolutionProfilesFromClientSettings(json["evolution_agent_profiles"])
            let settings = ClientSettings(
                customCommands: commands,
                workspaceShortcuts: workspaceShortcuts,
                commitAIAgent: commitAIAgent,
                mergeAIAgent: mergeAIAgent,
                fixedPort: fixedPort,
                remoteAccessEnabled: remoteAccessEnabled,
                appLanguage: appLanguage,
                evolutionAgentProfiles: evolutionAgentProfiles
            )
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

        case "project_commands_saved":
            let project = json["project"] as? String ?? ""
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onProjectCommandsSaved?(project, ok, message)

        case "project_command_started":
            let project = json["project"] as? String ?? ""
            let workspace = json["workspace"] as? String ?? ""
            let commandId = json["command_id"] as? String ?? ""
            let taskId = json["task_id"] as? String ?? ""
            onProjectCommandStarted?(project, workspace, commandId, taskId)

        case "project_command_completed":
            let project = json["project"] as? String ?? ""
            let workspace = json["workspace"] as? String ?? ""
            let commandId = json["command_id"] as? String ?? ""
            let taskId = json["task_id"] as? String ?? ""
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onProjectCommandCompleted?(project, workspace, commandId, taskId, ok, message)

        case "project_command_output":
            let taskId = json["task_id"] as? String ?? ""
            let line = json["line"] as? String ?? ""
            onProjectCommandOutput?(taskId, line)

        case "project_command_cancelled":
            // 服务端确认取消，客户端已在 stopRunningTask 中提前处理，此处仅日志
            let taskId = json["task_id"] as? String ?? ""
            NSLog("[WSClient] ProjectCommand cancelled: task_id=%@", taskId)

        case "lsp_diagnostics":
            if let result = LspDiagnosticsResult.from(json: json) {
                onLspDiagnostics?(result)
            }

        case "lsp_status":
            if let result = LspStatusResult.from(json: json) {
                onLspStatus?(result)
            }

        case "remote_term_changed":
            TFLog.ws.info("Received remote_term_changed notification")
            onRemoteTermChanged?()

        case "ai_task_cancelled":
            if let result = AITaskCancelled.from(json: json) {
                onAITaskCancelled?(result)
            }

        // AI Chat（结构化 message/part 流）
        case "ai_session_started":
            if let ev = AISessionStartedV2.from(json: json) {
                onAISessionStarted?(ev)
            }

        case "ai_session_list":
            if let ev = AISessionListV2.from(json: json) {
                onAISessionList?(ev)
            }

        case "ai_session_messages":
            if let ev = AISessionMessagesV2.from(json: json) {
                onAISessionMessages?(ev)
            }

        case "ai_session_status_result":
            if let ev = AISessionStatusResultV2.from(json: json) {
                onAISessionStatusResult?(ev)
            }

        case "ai_session_status_update":
            if let ev = AISessionStatusUpdateV2.from(json: json) {
                onAISessionStatusUpdate?(ev)
            }

        case "ai_chat_message_updated":
            if let ev = AIChatMessageUpdatedV2.from(json: json) {
                onAIChatMessageUpdated?(ev)
            }

        case "ai_chat_part_updated":
            if let ev = AIChatPartUpdatedV2.from(json: json) {
                onAIChatPartUpdated?(ev)
            }

        case "ai_chat_part_delta":
            if let ev = AIChatPartDeltaV2.from(json: json) {
                onAIChatPartDelta?(ev)
            }

        case "ai_chat_done":
            if let ev = AIChatDoneV2.from(json: json) {
                onAIChatDone?(ev)
            }

        case "ai_chat_error":
            if let ev = AIChatErrorV2.from(json: json) {
                onAIChatError?(ev)
            }

        case "ai_question_asked":
            if let ev = AIQuestionAskedV2.from(json: json) {
                onAIQuestionAsked?(ev)
            }

        case "ai_question_cleared":
            if let ev = AIQuestionClearedV2.from(json: json) {
                onAIQuestionCleared?(ev)
            }

        case "ai_provider_list":
            if let ev = AIProviderListResult.from(json: json) {
                onAIProviderList?(ev)
            }

        case "ai_agent_list":
            if let ev = AIAgentListResult.from(json: json) {
                onAIAgentList?(ev)
            }

        case "ai_slash_commands":
            if let ev = AISlashCommandsResult.from(json: json) {
                onAISlashCommands?(ev)
            }

        // Evolution
        case "evo_scheduler_updated", "evo_scheduler_status",
             "evo_workspace_started", "evo_workspace_stopped", "evo_workspace_resumed",
             "evo_stage_changed", "evo_cycle_updated", "evo_judge_result":
            onEvoPulse?()

        case "evo_snapshot":
            if let ev = EvolutionSnapshotV2.from(json: json) {
                onEvoSnapshot?(ev)
            }

        case "evo_stage_chat_opened":
            if let ev = EvolutionStageChatOpenedV2.from(json: json) {
                onEvoStageChatOpened?(ev)
            }

        case "evo_agent_profile":
            if let ev = EvolutionAgentProfileV2.from(json: json) {
                onEvoAgentProfile?(ev)
            } else {
                let project = json["project"] as? String ?? ""
                let workspace = json["workspace"] as? String ?? ""
                let stageProfilesType = String(describing: Swift.type(of: json["stage_profiles"] as Any))
                TFLog.ws.warning(
                    "Failed to parse evo_agent_profile: project=\(project, privacy: .public), workspace=\(workspace, privacy: .public), stage_profiles_type=\(stageProfilesType, privacy: .public)"
                )
            }

        case "evo_error":
            let message = json["message"] as? String ?? "evolution error"
            onEvoError?(message)

        case "clipboard_image_set":
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onClipboardImageSet?(ok, message)

        case "tasks_snapshot":
            if let items = json["tasks"] as? [[String: Any]] {
                let entries = items.compactMap { TaskSnapshotEntry.from(json: $0) }
                onTasksSnapshot?(entries)
            }

        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            onError?(errorMsg)

        default:
            // Unknown message type, ignore
            break
        }
    }

    private func parseEnvelopeSeq(_ raw: Any?) -> UInt64? {
        if let value = raw as? UInt64 { return value }
        if let value = raw as? UInt { return UInt64(value) }
        if let value = raw as? Int, value >= 0 { return UInt64(value) }
        if let value = raw as? NSNumber { return value.uint64Value }
        return nil
    }

    /// 处理合并队列刷新后的高频消息（由 flushCoalesceQueue 调用）
    func dispatchCoalescedMessage(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        switch type {
        case "file_changed":
            if let notification = FileChangedNotification.from(json: json) {
                onFileChanged?(notification)
            }

        case "git_status_changed":
            if let notification = GitStatusChangedNotification.from(json: json) {
                onGitStatusChanged?(notification)
            }

        case "file_index_result":
            if let result = FileIndexResult.from(json: json) {
                onFileIndexResult?(result)
            }

        case "file_list_result":
            if let result = FileListResult.from(json: json) {
                onFileListResult?(result)
            }

        default:
            break
        }
    }

    private func parseEvolutionProfilesFromClientSettings(_ raw: Any?) -> [String: [EvolutionStageProfileInfoV2]] {
        guard let rawMap = raw as? [String: Any] else { return [:] }
        var result: [String: [EvolutionStageProfileInfoV2]] = [:]
        result.reserveCapacity(rawMap.count)

        for (key, value) in rawMap {
            let profiles = parseEvolutionStageProfiles(value)
            if !profiles.isEmpty {
                result[key] = profiles
            }
        }
        return result
    }

    private func parseEvolutionStageProfiles(_ raw: Any?) -> [EvolutionStageProfileInfoV2] {
        if let items = raw as? [[String: Any]] {
            return items.compactMap { EvolutionStageProfileInfoV2.from(json: $0) }
        }
        guard let array = raw as? [Any] else { return [] }
        let dicts: [[String: Any]] = array.compactMap { item in
            if let dict = item as? [String: Any] {
                return dict
            }
            if let dict = item as? [AnyHashable: Any] {
                var converted: [String: Any] = [:]
                converted.reserveCapacity(dict.count)
                for (k, v) in dict {
                    guard let key = k as? String else { continue }
                    converted[key] = v
                }
                return converted
            }
            return nil
        }
        return dicts.compactMap { EvolutionStageProfileInfoV2.from(json: $0) }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WSClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard self.webSocketTask === webSocketTask else { return }
        isConnecting = false
        isIntentionalDisconnect = false
        TFLog.ws.info("WebSocket connected to: \(self.currentURL?.absoluteString ?? "unknown", privacy: .public)")
        updateConnectionState(true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard self.webSocketTask === webSocketTask else { return }
        isConnecting = false
        self.webSocketTask = nil
        TFLog.ws.info("WebSocket disconnected. Code: \(closeCode.rawValue, privacy: .public)")
        updateConnectionState(false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === webSocketTask else { return }
        isConnecting = false
        if let error = error {
            webSocketTask = nil
            TFLog.ws.error("URLSession error: \(error.localizedDescription, privacy: .public)")
            updateConnectionState(false)
        }
    }
}
