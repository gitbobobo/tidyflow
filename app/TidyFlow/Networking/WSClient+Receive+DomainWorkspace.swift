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
            let project = json["project"] as? String ?? ""
            let workspace = json["workspace"] as? String ?? ""
            let commandId = json["command_id"] as? String ?? ""
            let taskId = json["task_id"] as? String ?? ""
            if let handler = projectMessageHandler {
                handler.handleProjectCommandCancelled(project, workspace, commandId, taskId)
            } else {
                onProjectCommandCancelled?(project, workspace, commandId, taskId)
            }
            return true
        case "tasks_snapshot":
            if let items = json["tasks"] as? [[String: Any]] {
                let entries = items.compactMap { TaskSnapshotEntry.from(json: $0) }
                onTasksSnapshot?(entries)
            }
            return true
        // v1.40: 工作流模板管理
        case "templates":
            if let result = TemplatesListResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleTemplatesList(result)
                } else {
                    onTemplatesList?(result)
                }
            }
            return true
        case "template_saved":
            if let result = TemplateSavedResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleTemplateSaved(result)
                } else {
                    onTemplateSaved?(result)
                }
            }
            return true
        case "template_deleted":
            if let result = TemplateDeletedResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleTemplateDeleted(result)
                } else {
                    onTemplateDeleted?(result)
                }
            }
            return true
        case "template_imported":
            if let result = TemplateImportedResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleTemplateImported(result)
                } else {
                    onTemplateImported?(result)
                }
            }
            return true
        case "template_exported":
            if let result = TemplateExportedResult.from(json: json) {
                if let handler = projectMessageHandler {
                    handler.handleTemplateExported(result)
                } else {
                    onTemplateExported?(result)
                }
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
            let mergeAIAgent = json["merge_ai_agent"] as? String
            let fixedPort = json["fixed_port"] as? Int ?? 0
            let remoteAccessEnabled = json["remote_access_enabled"] as? Bool ?? false
            let nodeName = json["node_name"] as? String
            let nodeDiscoveryEnabled = json["node_discovery_enabled"] as? Bool ?? false
            let evolutionDefaultProfiles = parseEvolutionStageProfiles(json["evolution_default_profiles"])
            let evolutionAgentProfiles = parseEvolutionProfilesFromClientSettings(json["evolution_agent_profiles"])
            let workspaceTodos = parseWorkspaceTodosFromClientSettings(json["workspace_todos"])
            var keybindings: [KeybindingConfig] = []
            if let kbJson = json["keybindings"] as? [[String: Any]] {
                keybindings = kbJson.compactMap { kbDict -> KeybindingConfig? in
                    guard let commandId = kbDict["commandId"] as? String,
                          let keyCombination = kbDict["keyCombination"] as? String,
                          let context = kbDict["context"] as? String else {
                        return nil
                    }
                    return KeybindingConfig(commandId: commandId, keyCombination: keyCombination, context: context)
                }
            }
            let settings = ClientSettings(
                customCommands: commands,
                workspaceShortcuts: workspaceShortcuts,
                mergeAIAgent: mergeAIAgent,
                fixedPort: fixedPort,
                remoteAccessEnabled: remoteAccessEnabled,
                nodeName: nodeName,
                nodeDiscoveryEnabled: nodeDiscoveryEnabled,
                evolutionDefaultProfiles: evolutionDefaultProfiles,
                evolutionAgentProfiles: evolutionAgentProfiles,
                workspaceTodos: workspaceTodos,
                keybindings: keybindings
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
            "evo_stage_changed":
            if let event = EvolutionWorkspaceStatusEventV2.from(action: action, json: json) {
                invalidateHTTPQueries(.evolutionWorkspace(project: event.project, workspace: event.workspace))
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionWorkspaceStatusEvent(event)
                } else if let onEvoWorkspaceStatusEvent {
                    onEvoWorkspaceStatusEvent(event)
                } else {
                    onEvoPulse?()
                }
            } else if let handler = evolutionMessageHandler {
                handler.handleEvolutionPulse()
            } else {
                onEvoPulse?()
            }
            return true
        case "evo_cycle_updated":
            // 优先尝试直接解析并更新工作空间状态，避免触发全量快照重新拉取
            if let ev = EvoCycleUpdatedV2.from(json: json) {
                invalidateHTTPQueries(.evolutionWorkspace(project: ev.project, workspace: ev.workspace))
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionCycleUpdated(ev)
                } else {
                    onEvoCycleUpdated?(ev)
                    onEvoPulse?()
                }
            } else {
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionPulse()
                } else {
                    onEvoPulse?()
                }
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
                invalidateHTTPQueries(.evolutionWorkspace(project: ev.project, workspace: ev.workspace))
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionBlockingRequired(ev)
                } else {
                    onEvoBlockingRequired?(ev)
                }
            }
            return true
        case "evo_blockers_updated":
            if let ev = EvolutionBlockersUpdatedV2.from(json: json) {
                invalidateHTTPQueries(.evolutionWorkspace(project: ev.project, workspace: ev.workspace))
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionBlockersUpdated(ev)
                } else {
                    onEvoBlockersUpdated?(ev)
                }
            }
            return true
        case "evo_cycle_history":
            if let project = json["project"] as? String,
               let workspace = json["workspace"] as? String {
                let cycles = (json["cycles"] as? [[String: Any]] ?? [])
                    .compactMap { EvolutionCycleHistoryItemV2.from(json: $0) }
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionCycleHistory(project: project, workspace: workspace, cycles: cycles)
                } else {
                    onEvoCycleHistory?(project, workspace, cycles)
                }
            }
            return true
        case "evo_auto_commit_result":
            if let result = EvoAutoCommitResult.from(json: json) {
                if let handler = evolutionMessageHandler {
                    handler.handleEvolutionAutoCommitResult(result)
                } else {
                    onEvoAutoCommitResult?(result)
                }
            }
            return true
        case "evo_error":
            let error = CoreError.fromEvoError(json: json)
            if let handler = evolutionMessageHandler {
                handler.handleEvolutionError(error)
            } else {
                onEvoError?(error.message)
            }
            return true
        default:
            return false
        }
    }

    func handleNodeDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "node_self", "node_self_updated":
            let payload = (json["identity"] as? [String: Any]).flatMap(NodeSelfInfoV2.from)
                ?? NodeSelfInfoV2.from(json: json)
            guard let payload else { return false }
            if let handler = nodeMessageHandler {
                handler.handleNodeSelfUpdated(payload)
            } else {
                onNodeSelfUpdated?(payload)
            }
            return true
        case "node_discovery", "node_discovery_updated":
            let rawItems = (json["items"] as? [[String: Any]]) ?? []
            let items = rawItems.compactMap(NodeDiscoveryItemV2.from)
            if let handler = nodeMessageHandler {
                handler.handleNodeDiscoveryUpdated(items)
            } else {
                onNodeDiscoveryUpdated?(items)
            }
            return true
        case "node_network", "node_network_updated":
            let payload = NodeNetworkSnapshotV2.from(json: json)
            guard let payload else { return false }
            if let handler = nodeMessageHandler {
                handler.handleNodeNetworkUpdated(payload)
            } else {
                onNodeNetworkUpdated?(payload)
            }
            return true
        case "node_pairing_result":
            let result = NodePairingResultV2.from(json: json)
            if let handler = nodeMessageHandler {
                handler.handleNodePairingResult(result)
            } else {
                onNodePairingResult?(result)
            }
            return true
        case "node_peer_status":
            guard let peerNodeID = json["peer_node_id"] as? String,
                  let status = json["status"] as? String else { return false }
            let lastSeenAtUnix = (json["last_seen_at_unix"] as? NSNumber)?.uint64Value
            if let handler = nodeMessageHandler {
                handler.handleNodePeerStatus(peerNodeID: peerNodeID, status: status, lastSeenAtUnix: lastSeenAtUnix)
            } else {
                onNodePeerStatus?(peerNodeID, status, lastSeenAtUnix)
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
                invalidateHTTPQueries(.evidenceWorkspace(project: ev.project, workspace: ev.workspace))
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

    private func parseWorkspaceTodosFromClientSettings(_ raw: Any?) -> [String: [WorkspaceTodoItem]] {
        guard let rawMap = raw as? [String: Any] else { return [:] }
        var result: [String: [WorkspaceTodoItem]] = [:]
        result.reserveCapacity(rawMap.count)

        for (workspaceKey, value) in rawMap {
            let items = parseWorkspaceTodoItems(value)
            if !items.isEmpty {
                result[workspaceKey] = WorkspaceTodoStore.normalize(items)
            }
        }
        return result
    }

    private func parseWorkspaceTodoItems(_ raw: Any?) -> [WorkspaceTodoItem] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { item -> WorkspaceTodoItem? in
            guard let dict = item as? [String: Any] else { return nil }
            guard let id = dict["id"] as? String,
                  let title = dict["title"] as? String,
                  let statusRaw = dict["status"] as? String,
                  let status = WorkspaceTodoStatus(rawValue: statusRaw) else {
                return nil
            }
            let note = dict["note"] as? String
            let order = (dict["order"] as? NSNumber)?.int64Value
                ?? Int64(dict["order"] as? Int ?? 0)
            let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.int64Value
                ?? Int64(dict["created_at_ms"] as? Int ?? 0)
            let updatedAtMs = (dict["updated_at_ms"] as? NSNumber)?.int64Value
                ?? Int64(dict["updated_at_ms"] as? Int ?? 0)
            return WorkspaceTodoItem(
                id: id,
                title: title,
                note: note,
                status: status,
                order: order,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs
            )
        }
    }
}
