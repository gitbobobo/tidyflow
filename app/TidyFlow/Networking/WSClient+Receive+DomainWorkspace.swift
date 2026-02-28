import Foundation

// MARK: - WSClient 领域处理（Workspace）

extension WSClient {
    func handleProjectDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "project_imported":
            if let result = ProjectImportedResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleProjectImported(result)
                } else {
                    onProjectImported?(result)
                }
            } else {
                TFLog.ws.error("Failed to parse ProjectImportedResult")
                emitClientError("Failed to parse project import response")
            }
            return true
        case "workspace_created":
            if let result = WorkspaceCreatedResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleWorkspaceCreated(result)
                } else {
                    onWorkspaceCreated?(result)
                }
            }
            return true
        case "projects":
            if let result = ProjectsListResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleProjectsList(result)
                } else {
                    onProjectsList?(result)
                }
            }
            return true
        case "workspaces":
            if let result = WorkspacesListResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleWorkspacesList(result)
                } else {
                    onWorkspacesList?(result)
                }
            }
            return true
        case "project_removed":
            if let result = ProjectRemovedResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleProjectRemoved(result)
                } else {
                    onProjectRemoved?(result)
                }
            }
            return true
        case "workspace_removed":
            if let result = WorkspaceRemovedResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleWorkspaceRemoved(result)
                } else {
                    onWorkspaceRemoved?(result)
                }
            }
            return true
        case "project_commands_saved":
            let project = json["project"] as? String ?? ""
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            if let handler = projectMessageHandler {
                handler.handleProjectCommandsSaved(project, ok, message)
            } else {
                onProjectCommandsSaved?(project, ok, message)
            }
            return true
        case "project_command_started":
            let project = json["project"] as? String ?? ""
            let workspace = json["workspace"] as? String ?? ""
            let commandId = json["command_id"] as? String ?? ""
            let taskId = json["task_id"] as? String ?? ""
            if let handler = projectMessageHandler {
                handler.handleProjectCommandStarted(project, workspace, commandId, taskId)
            } else {
                onProjectCommandStarted?(project, workspace, commandId, taskId)
            }
            return true
        case "project_command_completed":
            let project = json["project"] as? String ?? ""
            let workspace = json["workspace"] as? String ?? ""
            let commandId = json["command_id"] as? String ?? ""
            let taskId = json["task_id"] as? String ?? ""
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            if let handler = projectMessageHandler {
                handler.handleProjectCommandCompleted(project, workspace, commandId, taskId, ok, message)
            } else {
                onProjectCommandCompleted?(project, workspace, commandId, taskId, ok, message)
            }
            return true
        case "project_command_output":
            let taskId = json["task_id"] as? String ?? ""
            let line = json["line"] as? String ?? ""
            if let handler = projectMessageHandler {
                handler.handleProjectCommandOutput(taskId, line)
            } else {
                onProjectCommandOutput?(taskId, line)
            }
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
            let evolutionImplementAgentProfiles =
                parseEvolutionImplementAgentProfilesFromClientSettings(
                    json["evolution_implement_agent_profiles"]
                )
            let settings = ClientSettings(
                customCommands: commands,
                workspaceShortcuts: workspaceShortcuts,
                commitAIAgent: commitAIAgent,
                mergeAIAgent: mergeAIAgent,
                fixedPort: fixedPort,
                remoteAccessEnabled: remoteAccessEnabled,
                appLanguage: appLanguage,
                evolutionAgentProfiles: evolutionAgentProfiles,
                evolutionImplementAgentProfiles: evolutionImplementAgentProfiles
            )
            if let handler = settingsMessageHandler {
                handler.handleClientSettingsResult(settings)
            } else {
                onClientSettingsResult?(settings)
            }
            return true
        case "client_settings_saved":
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            if let handler = settingsMessageHandler {
                handler.handleClientSettingsSaved(ok, message)
            } else {
                onClientSettingsSaved?(ok, message)
            }
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
            if let handler = evolutionMessageHandler {
                handler.handleEvolutionPulse()
            } else {
                onEvoPulse?()
            }
            return true
        case "evo_snapshot":
            if let ev = EvolutionSnapshotV2.from(json: json) {
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionSnapshot(ev)
                } else {
                    onEvoSnapshot?(ev)
                }
            }
            return true
        case "evo_stage_chat_opened":
            if let ev = EvolutionStageChatOpenedV2.from(json: json) {
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionStageChatOpened(ev)
                } else {
                    onEvoStageChatOpened?(ev)
                }
            }
            return true
        case "evo_agent_profile":
            if let ev = EvolutionAgentProfileV2.from(json: json) {
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionAgentProfile(ev)
                } else {
                    onEvoAgentProfile?(ev)
                }
            } else {
                let project = json["project"] as? String ?? ""
                let workspace = json["workspace"] as? String ?? ""
                let stageProfilesType = String(describing: Swift.type(of: json["stage_profiles"] as Any))
                TFLog.ws.warning(
                    "Failed to parse evo_agent_profile: project=\(project, privacy: .public), workspace=\(workspace, privacy: .public), stage_profiles_type=\(stageProfilesType, privacy: .public)"
                )
            }
            return true
        case "evo_blocking_required":
            if let ev = EvolutionBlockingRequiredV2.from(json: json) {
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionBlockingRequired(ev)
                } else {
                    onEvoBlockingRequired?(ev)
                }
            }
            return true
        case "evo_blockers_updated":
            if let ev = EvolutionBlockersUpdatedV2.from(json: json) {
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionBlockersUpdated(ev)
                } else {
                    onEvoBlockersUpdated?(ev)
                }
            }
            return true
        case "evo_error":
            let message = json["message"] as? String ?? "evolution error"
            if let handler = evolutionMessageHandler {
                handler.handleEvolutionError(message)
            } else {
                onEvoError?(message)
            }
            return true
        default:
            return false
        }
    }

    func handleEvidenceDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "evidence_snapshot":
            if let ev = EvidenceSnapshotV2.from(json: json) {
                if let handler = evidenceMessageHandler {
                    handler.handleEvidenceSnapshot(ev)
                } else {
                    onEvidenceSnapshot?(ev)
                }
            }
            return true
        case "evidence_rebuild_prompt":
            if let ev = EvidenceRebuildPromptV2.from(json: json) {
                if let handler = evidenceMessageHandler {
                    handler.handleEvidenceRebuildPrompt(ev)
                } else {
                    onEvidenceRebuildPrompt?(ev)
                }
            }
            return true
        case "evidence_item_chunk":
            if let ev = EvidenceItemChunkV2.from(json: json) {
                if let handler = evidenceMessageHandler {
                    handler.handleEvidenceItemChunk(ev)
                } else {
                    onEvidenceItemChunk?(ev)
                }
            }
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

    private func parseEvolutionImplementAgentProfilesFromClientSettings(
        _ raw: Any?
    ) -> EvolutionImplementAgentProfilesV2 {
        guard let rawMap = raw as? [String: Any] else { return .default }
        return EvolutionImplementAgentProfilesV2.from(json: rawMap)
    }
}
