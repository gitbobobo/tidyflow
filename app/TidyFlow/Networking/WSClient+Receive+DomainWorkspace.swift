import Foundation

// MARK: - WSClient 领域处理（Workspace）

extension WSClient {
    func handleProjectDomain(_ action: String, json: [String: Any]) -> Bool {
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

    func handleSettingsDomain(_ action: String, json: [String: Any]) -> Bool {
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

    func handleEvolutionDomain(_ action: String, json: [String: Any]) -> Bool {
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
