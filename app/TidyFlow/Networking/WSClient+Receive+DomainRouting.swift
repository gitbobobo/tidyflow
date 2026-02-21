import Foundation

// MARK: - WSClient 分领域路由

extension WSClient {
    func routeByDomain(domain: String, action: String, json: [String: Any]) -> Bool {
        switch domain {
        case "system":
            return handleSystemDomain(action, json: json)
        case "terminal":
            return handleTerminalDomain(action, json: json)
        case "git":
            return handleGitDomain(action, json: json)
        case "project":
            return handleProjectDomain(action, json: json)
        case "file":
            return handleFileDomain(action, json: json)
        case "settings":
            return handleSettingsDomain(action, json: json)
        case "lsp":
            return handleLspDomain(action, json: json)
        case "ai":
            return handleAiDomain(action, json: json)
        case "evolution":
            return handleEvolutionDomain(action, json: json)
        default:
            return false
        }
    }

    func routeFallbackByAction(_ action: String, json: [String: Any]) -> Bool {
        if handleSystemDomain(action, json: json) { return true }
        if handleTerminalDomain(action, json: json) { return true }
        if handleGitDomain(action, json: json) { return true }
        if handleProjectDomain(action, json: json) { return true }
        if handleFileDomain(action, json: json) { return true }
        if handleSettingsDomain(action, json: json) { return true }
        if handleLspDomain(action, json: json) { return true }
        if handleAiDomain(action, json: json) { return true }
        if handleEvolutionDomain(action, json: json) { return true }

        switch action {
        case "clipboard_image_set":
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onClipboardImageSet?(ok, message)
            return true
        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            onError?(errorMsg)
            return true
        default:
            return false
        }
    }

    private func handleSystemDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "hello", "pong":
            return true
        default:
            return false
        }
    }

    private func handleTerminalDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "output":
            let termId = json["term_id"] as? String
            let bytes = WSBinary.decodeBytes(json["data"])
            onTerminalOutput?(termId, bytes)
            return true
        case "exit":
            let termId = json["term_id"] as? String
            let code = json["code"] as? Int ?? -1
            onTerminalExit?(termId, code)
            return true
        case "term_created":
            if let result = TermCreatedResult.from(json: json) {
                onTermCreated?(result)
            }
            return true
        case "term_attached":
            if let result = TermAttachedResult.from(json: json) {
                onTermAttached?(result)
            }
            return true
        case "term_list":
            if let result = TermListResult.from(json: json) {
                let remoteSubs = result.items.flatMap(\.remoteSubscribers)
                TFLog.ws.info("Received term_list: \(result.items.count) terminals, \(remoteSubs.count) remote subscribers")
                onTermList?(result)
            } else {
                TFLog.ws.warning("Failed to parse term_list response")
            }
            return true
        case "term_closed":
            if let termId = json["term_id"] as? String {
                onTermClosed?(termId)
            }
            return true
        case "remote_term_changed":
            TFLog.ws.info("Received remote_term_changed notification")
            onRemoteTermChanged?()
            return true
        default:
            return false
        }
    }

    private func handleGitDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "git_diff_result":
            if let result = GitDiffResult.from(json: json) {
                onGitDiffResult?(result)
            }
            return true
        case "git_status_result":
            if let result = GitStatusResult.from(json: json) {
                onGitStatusResult?(result)
            }
            return true
        case "git_log_result":
            if let result = GitLogResult.from(json: json) {
                onGitLogResult?(result)
            }
            return true
        case "git_show_result":
            if let result = GitShowResult.from(json: json) {
                onGitShowResult?(result)
            }
            return true
        case "git_op_result":
            if let result = GitOpResult.from(json: json) {
                onGitOpResult?(result)
            }
            return true
        case "git_branches_result":
            if let result = GitBranchesResult.from(json: json) {
                onGitBranchesResult?(result)
            }
            return true
        case "git_commit_result":
            if let result = GitCommitResult.from(json: json) {
                onGitCommitResult?(result)
            }
            return true
        case "git_ai_commit_result":
            if let result = GitAICommitResult.from(json: json) {
                onGitAICommitResult?(result)
            }
            return true
        case "git_ai_merge_result":
            if let result = GitAIMergeResult.from(json: json) {
                onGitAIMergeResult?(result)
            }
            return true
        case "git_rebase_result":
            if let result = GitRebaseResult.from(json: json) {
                onGitRebaseResult?(result)
            }
            return true
        case "git_op_status_result":
            if let result = GitOpStatusResult.from(json: json) {
                onGitOpStatusResult?(result)
            }
            return true
        case "git_merge_to_default_result":
            if let result = GitMergeToDefaultResult.from(json: json) {
                onGitMergeToDefaultResult?(result)
            }
            return true
        case "git_integration_status_result":
            if let result = GitIntegrationStatusResult.from(json: json) {
                onGitIntegrationStatusResult?(result)
            }
            return true
        case "git_rebase_onto_default_result":
            if let result = GitRebaseOntoDefaultResult.from(json: json) {
                onGitRebaseOntoDefaultResult?(result)
            }
            return true
        case "git_reset_integration_worktree_result":
            if let result = GitResetIntegrationWorktreeResult.from(json: json) {
                onGitResetIntegrationWorktreeResult?(result)
            }
            return true
        default:
            return false
        }
    }

    private func handleProjectDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "project_imported":
            if let result = ProjectImportedResult.from(json: json) {
                onProjectImported?(result)
            } else {
                TFLog.ws.error("Failed to parse ProjectImportedResult")
                onError?("Failed to parse project import response")
            }
            return true
        case "workspace_created":
            if let result = WorkspaceCreatedResult.from(json: json) {
                onWorkspaceCreated?(result)
            }
            return true
        case "projects":
            if let result = ProjectsListResult.from(json: json) {
                onProjectsList?(result)
            }
            return true
        case "workspaces":
            if let result = WorkspacesListResult.from(json: json) {
                onWorkspacesList?(result)
            }
            return true
        case "project_removed":
            if let result = ProjectRemovedResult.from(json: json) {
                onProjectRemoved?(result)
            }
            return true
        case "workspace_removed":
            if let result = WorkspaceRemovedResult.from(json: json) {
                onWorkspaceRemoved?(result)
            }
            return true
        case "project_commands_saved":
            let project = json["project"] as? String ?? ""
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onProjectCommandsSaved?(project, ok, message)
            return true
        case "project_command_started":
            let project = json["project"] as? String ?? ""
            let workspace = json["workspace"] as? String ?? ""
            let commandId = json["command_id"] as? String ?? ""
            let taskId = json["task_id"] as? String ?? ""
            onProjectCommandStarted?(project, workspace, commandId, taskId)
            return true
        case "project_command_completed":
            let project = json["project"] as? String ?? ""
            let workspace = json["workspace"] as? String ?? ""
            let commandId = json["command_id"] as? String ?? ""
            let taskId = json["task_id"] as? String ?? ""
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onProjectCommandCompleted?(project, workspace, commandId, taskId, ok, message)
            return true
        case "project_command_output":
            let taskId = json["task_id"] as? String ?? ""
            let line = json["line"] as? String ?? ""
            onProjectCommandOutput?(taskId, line)
            return true
        case "project_command_cancelled":
            // 服务端确认取消，客户端已在 stopRunningTask 中提前处理，此处仅日志
            let taskId = json["task_id"] as? String ?? ""
            NSLog("[WSClient] ProjectCommand cancelled: task_id=%@", taskId)
            return true
        case "tasks_snapshot":
            if let items = json["tasks"] as? [[String: Any]] {
                let entries = items.compactMap { TaskSnapshotEntry.from(json: $0) }
                onTasksSnapshot?(entries)
            }
            return true
        default:
            return false
        }
    }

    private func handleFileDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "watch_subscribed":
            if let result = WatchSubscribedResult.from(json: json) {
                onWatchSubscribed?(result)
            }
            return true
        case "watch_unsubscribed":
            onWatchUnsubscribed?()
            return true
        case "file_rename_result":
            if let result = FileRenameResult.from(json: json) {
                onFileRenameResult?(result)
            }
            return true
        case "file_delete_result":
            if let result = FileDeleteResult.from(json: json) {
                onFileDeleteResult?(result)
            }
            return true
        case "file_copy_result":
            if let result = FileCopyResult.from(json: json) {
                onFileCopyResult?(result)
            }
            return true
        case "file_move_result":
            if let result = FileMoveResult.from(json: json) {
                onFileMoveResult?(result)
            }
            return true
        case "file_write_result":
            if let result = FileWriteResult.from(json: json) {
                onFileWriteResult?(result)
            }
            return true
        default:
            return false
        }
    }

    private func handleSettingsDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "client_settings_result":
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
            let workspaceShortcuts = json["workspace_shortcuts"] as? [String: String] ?? [:]
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
            return true
        case "client_settings_saved":
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onClientSettingsSaved?(ok, message)
            return true
        default:
            return false
        }
    }

    private func handleLspDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "lsp_diagnostics":
            if let result = LspDiagnosticsResult.from(json: json) {
                onLspDiagnostics?(result)
            }
            return true
        case "lsp_status":
            if let result = LspStatusResult.from(json: json) {
                onLspStatus?(result)
            }
            return true
        default:
            return false
        }
    }

    private func handleAiDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "ai_task_cancelled":
            if let result = AITaskCancelled.from(json: json) {
                onAITaskCancelled?(result)
            }
            return true
        case "ai_session_started":
            if let ev = AISessionStartedV2.from(json: json) {
                onAISessionStarted?(ev)
            }
            return true
        case "ai_session_list":
            if let ev = AISessionListV2.from(json: json) {
                onAISessionList?(ev)
            }
            return true
        case "ai_session_messages":
            if let ev = AISessionMessagesV2.from(json: json) {
                onAISessionMessages?(ev)
            }
            return true
        case "ai_session_status_result":
            if let ev = AISessionStatusResultV2.from(json: json) {
                onAISessionStatusResult?(ev)
            }
            return true
        case "ai_session_status_update":
            if let ev = AISessionStatusUpdateV2.from(json: json) {
                onAISessionStatusUpdate?(ev)
            }
            return true
        case "ai_chat_message_updated":
            if let ev = AIChatMessageUpdatedV2.from(json: json) {
                onAIChatMessageUpdated?(ev)
            }
            return true
        case "ai_chat_part_updated":
            if let ev = AIChatPartUpdatedV2.from(json: json) {
                onAIChatPartUpdated?(ev)
            }
            return true
        case "ai_chat_part_delta":
            if let ev = AIChatPartDeltaV2.from(json: json) {
                onAIChatPartDelta?(ev)
            }
            return true
        case "ai_chat_done":
            if let ev = AIChatDoneV2.from(json: json) {
                onAIChatDone?(ev)
            }
            return true
        case "ai_chat_error":
            if let ev = AIChatErrorV2.from(json: json) {
                onAIChatError?(ev)
            }
            return true
        case "ai_question_asked":
            if let ev = AIQuestionAskedV2.from(json: json) {
                onAIQuestionAsked?(ev)
            }
            return true
        case "ai_question_cleared":
            if let ev = AIQuestionClearedV2.from(json: json) {
                onAIQuestionCleared?(ev)
            }
            return true
        case "ai_provider_list":
            if let ev = AIProviderListResult.from(json: json) {
                onAIProviderList?(ev)
            }
            return true
        case "ai_agent_list":
            if let ev = AIAgentListResult.from(json: json) {
                onAIAgentList?(ev)
            }
            return true
        case "ai_slash_commands":
            if let ev = AISlashCommandsResult.from(json: json) {
                onAISlashCommands?(ev)
            }
            return true
        default:
            return false
        }
    }

    private func handleEvolutionDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "evo_scheduler_updated", "evo_scheduler_status",
             "evo_workspace_started", "evo_workspace_stopped", "evo_workspace_resumed",
             "evo_stage_changed", "evo_cycle_updated", "evo_judge_result":
            onEvoPulse?()
            return true
        case "evo_snapshot":
            if let ev = EvolutionSnapshotV2.from(json: json) {
                onEvoSnapshot?(ev)
            }
            return true
        case "evo_stage_chat_opened":
            if let ev = EvolutionStageChatOpenedV2.from(json: json) {
                onEvoStageChatOpened?(ev)
            }
            return true
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
            return true
        case "evo_error":
            let message = json["message"] as? String ?? "evolution error"
            onEvoError?(message)
            return true
        default:
            return false
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
