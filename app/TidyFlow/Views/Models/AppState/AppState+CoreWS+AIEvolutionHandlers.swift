import Foundation

extension AppState {
    private func aiSelectionHintLogDict(_ hint: AISessionSelectionHint?) -> [String: Any]? {
        guard let hint, !hint.isEmpty else { return nil }
        var dict: [String: Any] = [:]
        if let agent = hint.agent { dict["agent"] = agent }
        if let provider = hint.modelProviderID { dict["model_provider_id"] = provider }
        if let model = hint.modelID { dict["model_id"] = model }
        if let configOptions = hint.configOptions, !configOptions.isEmpty {
            dict["config_options"] = configOptions
        }
        return dict.isEmpty ? nil : dict
    }

    private func aiSelectionModelLogDict(_ model: AIModelSelection?) -> [String: Any]? {
        guard let model else { return nil }
        return [
            "provider_id": model.providerID,
            "model_id": model.modelID
        ]
    }

    private func sendAISelectionPipelineLog(
        event: String,
        tool: AIChatTool,
        sessionId: String,
        messageId: String? = nil,
        primaryHint: AISessionSelectionHint?,
        inferredHint: AISessionSelectionHint?,
        effectiveHint: AISessionSelectionHint?,
        messagesCount: Int? = nil
    ) {
        guard isPerfAISelectionDebugLogEnabled else { return }

        var detail: [String: Any] = [
            "event": event,
            "tool": tool.rawValue,
            "session_id": sessionId,
            "selected_tool": aiChatTool.rawValue,
            "current_agent": selectedAgent(for: tool) ?? ""
        ]
        if let messageId, !messageId.isEmpty {
            detail["message_id"] = messageId
        }
        if let messagesCount {
            detail["messages_count"] = messagesCount
        }
        if let currentModel = aiSelectionModelLogDict(selectedModel(for: tool)) {
            detail["current_model"] = currentModel
        }
        if let primaryHint = aiSelectionHintLogDict(primaryHint) {
            detail["primary_hint"] = primaryHint
        }
        if let inferredHint = aiSelectionHintLogDict(inferredHint) {
            detail["inferred_hint"] = inferredHint
        }
        if let effectiveHint = aiSelectionHintLogDict(effectiveHint) {
            detail["effective_hint"] = effectiveHint
        }
        let detailText: String? = {
            guard JSONSerialization.isValidJSONObject(detail),
                  let data = try? JSONSerialization.data(withJSONObject: detail, options: []),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        }()
        wsClient.sendLogEntry(
            level: "DEBUG",
            category: "ai_selection_sync_pipeline",
            msg: "ai selection pipeline \(event)",
            detail: detailText
        )
    }

    private func mergedAISessionSelectionHint(
        primary: AISessionSelectionHint?,
        fallback: AISessionSelectionHint?
    ) -> AISessionSelectionHint? {
        if primary == nil { return fallback }
        if fallback == nil { return primary }
        var mergedConfigOptions: [String: Any] = fallback?.configOptions ?? [:]
        if let primaryConfig = primary?.configOptions {
            for (optionID, value) in primaryConfig {
                mergedConfigOptions[optionID] = value
            }
        }
        let merged = AISessionSelectionHint(
            agent: primary?.agent ?? fallback?.agent,
            modelProviderID: primary?.modelProviderID ?? fallback?.modelProviderID,
            modelID: primary?.modelID ?? fallback?.modelID,
            configOptions: mergedConfigOptions.isEmpty ? nil : mergedConfigOptions
        )
        return merged.isEmpty ? nil : merged
    }

    func handleAISessionStarted(_ ev: AISessionStartedV2) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }

        let store = aiStore(for: ev.aiTool)
        store.setCurrentSessionId(ev.sessionId)
        sendAISelectionPipelineLog(
            event: "session_started_received",
            tool: ev.aiTool,
            sessionId: ev.sessionId,
            primaryHint: ev.selectionHint,
            inferredHint: nil,
            effectiveHint: ev.selectionHint
        )
        applyAISessionSelectionHint(
            ev.selectionHint,
            sessionId: ev.sessionId,
            for: ev.aiTool,
            trigger: "session_started"
        )
        let updatedAt = ev.updatedAt == 0 ? Int64(Date().timeIntervalSince1970 * 1000) : ev.updatedAt
        let session = AISessionInfo(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            id: ev.sessionId,
            title: ev.title,
            updatedAt: updatedAt
        )
        upsertAISession(session, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
        wsClient.requestAISessionConfigOptions(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        )
    }

    func handleAISessionList(_ ev: AISessionListV2) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let sessions = ev.sessions.map {
            AISessionInfo(
                projectName: $0.projectName,
                workspaceName: $0.workspaceName,
                aiTool: ev.aiTool,
                id: $0.id,
                title: $0.title,
                updatedAt: $0.updatedAt
            )
        }
        setAISessions(sessions.sorted { $0.updatedAt > $1.updatedAt }, for: ev.aiTool)
    }

    func handleAISessionMessages(_ ev: AISessionMessagesV2) {
        if consumeEvolutionReplayMessagesIfNeeded(ev) {
            return
        }
        if consumeSubAgentViewerMessagesIfNeeded(ev) {
            return
        }
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else {
            TFLog.app.debug(
                "AI session_messages ignored: workspace mismatch, event_project=\(ev.projectName, privacy: .public), event_workspace=\(ev.workspaceName, privacy: .public), selected_project=\(self.selectedProjectName, privacy: .public), selected_workspace=\((self.selectedWorkspaceKey ?? ""), privacy: .public)"
            )
            return
        }
        let store = aiStore(for: ev.aiTool)
        let currentSessionId = store.currentSessionId ?? ""
        guard store.subscribedSessionIds.contains(ev.sessionId) else {
            TFLog.app.warning(
                "AI session_messages ignored: session mismatch, ai_tool=\(ev.aiTool.rawValue, privacy: .public), event_session_id=\(ev.sessionId, privacy: .public), current_session_id=\(currentSessionId, privacy: .public), messages_count=\(ev.messages.count)"
            )
            return
        }
        TFLog.app.info(
            "AI session_messages accepted: ai_tool=\(ev.aiTool.rawValue, privacy: .public), session_id=\(ev.sessionId, privacy: .public), messages_count=\(ev.messages.count)"
        )
        let mapped = ev.toChatMessages()
        let restoredQuestions = Self.rebuildPendingQuestionRequests(
            sessionId: ev.sessionId,
            messages: ev.messages
        )
        store.replaceMessages(mapped)
        store.replaceQuestionRequests(restoredQuestions)
        let inferredHint = inferAISessionSelectionHintFromMessages(ev.messages)
        let effectiveHint = mergedAISessionSelectionHint(primary: ev.selectionHint, fallback: inferredHint)
        sendAISelectionPipelineLog(
            event: "session_messages_received",
            tool: ev.aiTool,
            sessionId: ev.sessionId,
            primaryHint: ev.selectionHint,
            inferredHint: inferredHint,
            effectiveHint: effectiveHint,
            messagesCount: ev.messages.count
        )
        applyAISessionSelectionHint(
            effectiveHint,
            sessionId: ev.sessionId,
            for: ev.aiTool,
            trigger: "session_messages"
        )
        wsClient.requestAISessionConfigOptions(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        )
        TFLog.app.info(
            "AI session_messages applied: ai_tool=\(ev.aiTool.rawValue, privacy: .public), session_id=\(ev.sessionId, privacy: .public), mapped_messages_count=\(mapped.count), restored_question_count=\(restoredQuestions.count)"
        )
    }

    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) {
        upsertAISessionStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            contextRemainingPercent: ev.status.contextRemainingPercent
        )
        if selectedProjectName == ev.projectName,
           selectedWorkspaceKey == ev.workspaceName {
            reconcileAIStreamStateFromSessionStatus(
                aiTool: ev.aiTool,
                sessionId: ev.sessionId,
                status: ev.status.status
            )
        }
    }

    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2) {
        upsertAISessionStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            contextRemainingPercent: ev.status.contextRemainingPercent
        )
        if selectedProjectName == ev.projectName,
           selectedWorkspaceKey == ev.workspaceName {
            reconcileAIStreamStateFromSessionStatus(
                aiTool: ev.aiTool,
                sessionId: ev.sessionId,
                status: ev.status.status
            )
        }
    }

    func handleAIChatMessageUpdated(_ ev: AIChatMessageUpdatedV2) {
        consumeEvolutionReplayMessageUpdatedIfNeeded(ev)
        consumeSubAgentViewerMessageUpdatedIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        if store.isAbortPending(for: ev.sessionId) { return }
        if isPerfAISelectionDebugLogEnabled {
            TFLog.app.debug(
                "AI stream message_updated: session_id=\(ev.sessionId, privacy: .public), message_id=\(ev.messageId, privacy: .public), role=\(ev.role, privacy: .public)"
            )
        }
        store.enqueueMessageUpdated(messageId: ev.messageId, role: ev.role)
        sendAISelectionPipelineLog(
            event: "message_updated_received",
            tool: ev.aiTool,
            sessionId: ev.sessionId,
            messageId: ev.messageId,
            primaryHint: ev.selectionHint,
            inferredHint: nil,
            effectiveHint: ev.selectionHint
        )
        applyAISessionSelectionHint(
            ev.selectionHint,
            sessionId: ev.sessionId,
            for: ev.aiTool,
            trigger: "message_updated"
        )
        setBadgeRunning(true, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIChatPartUpdated(_ ev: AIChatPartUpdatedV2) {
        consumeEvolutionReplayPartUpdatedIfNeeded(ev)
        consumeSubAgentViewerPartUpdatedIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        if store.isAbortPending(for: ev.sessionId) { return }
        if isPerfAISelectionDebugLogEnabled {
            TFLog.app.debug(
                "AI stream part_updated: session_id=\(ev.sessionId, privacy: .public), message_id=\(ev.messageId, privacy: .public), part_id=\(ev.part.id, privacy: .public), part_type=\(ev.part.partType, privacy: .public)"
            )
        }
        store.enqueuePartUpdated(messageId: ev.messageId, part: ev.part)
        applyAISessionSelectionHintFromPart(
            ev.part,
            sessionId: ev.sessionId,
            for: ev.aiTool,
            trigger: "part_updated"
        )
        setBadgeRunning(true, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIChatPartDelta(_ ev: AIChatPartDeltaV2) {
        consumeEvolutionReplayPartDeltaIfNeeded(ev)
        consumeSubAgentViewerPartDeltaIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        if store.isAbortPending(for: ev.sessionId) { return }
        if isPerfAISelectionDebugLogEnabled {
            TFLog.app.debug(
                "AI stream part_delta: session_id=\(ev.sessionId, privacy: .public), message_id=\(ev.messageId, privacy: .public), part_id=\(ev.partId, privacy: .public), part_type=\(ev.partType, privacy: .public), field=\(ev.field, privacy: .public), delta_len=\(ev.delta.count)"
            )
        }
        store.enqueuePartDelta(
            messageId: ev.messageId,
            partId: ev.partId,
            partType: ev.partType,
            field: ev.field,
            delta: ev.delta
        )
        setBadgeRunning(true, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIChatDone(_ ev: AIChatDoneV2) {
        consumeEvolutionReplayDoneIfNeeded(ev)
        consumeSubAgentViewerDoneIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        store.clearAbortPendingIfMatches(ev.sessionId)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        if isPerfAISelectionDebugLogEnabled {
            TFLog.app.debug(
                "AI stream done: session_id=\(ev.sessionId, privacy: .public), stop_reason=\((ev.stopReason ?? "none"), privacy: .public)"
            )
        }
        sendAISelectionPipelineLog(
            event: "chat_done_received",
            tool: ev.aiTool,
            sessionId: ev.sessionId,
            primaryHint: ev.selectionHint,
            inferredHint: nil,
            effectiveHint: ev.selectionHint
        )
        applyAISessionSelectionHint(
            ev.selectionHint,
            sessionId: ev.sessionId,
            for: ev.aiTool,
            trigger: "chat_done"
        )
        store.handleChatDone(sessionId: ev.sessionId)
        if store.currentSessionId == ev.sessionId {
            wsClient.requestAISessionMessages(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                sessionId: ev.sessionId,
                limit: 200
            )
        }
        setBadgeRunning(false, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIChatError(_ ev: AIChatErrorV2) {
        consumeEvolutionReplayErrorIfNeeded(ev)
        consumeSubAgentViewerErrorIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        store.clearAbortPendingIfMatches(ev.sessionId)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        TFLog.app.error(
            "AI stream error: session_id=\(ev.sessionId, privacy: .public), error=\(ev.error, privacy: .public)"
        )
        store.handleChatError(sessionId: ev.sessionId, error: ev.error)
        setBadgeRunning(false, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        store.upsertQuestionRequest(ev.request)
        setBadgeRunning(true, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        store.completeQuestionRequestLocally(requestId: ev.requestId)
    }

    func handleAIProviderList(_ ev: AIProviderListResult) {
        guard shouldAcceptAISelectorEvent(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            kind: .providerList
        ) else { return }
        let providers = ev.providers.map { p in
            AIProviderInfo(
                id: p.id,
                name: p.name,
                models: p.models.map { m in
                    AIModelInfo(
                        id: m.id,
                        name: m.name,
                        providerID: m.providerID.isEmpty ? p.id : m.providerID,
                        supportsImageInput: m.supportsImageInput
                    )
                }
            )
        }
        setAIProviders(providers, for: ev.aiTool)
        isAILoadingModels = false
        markEvolutionProviderListLoaded(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool
        )
        consumeAISelectorBootstrapContextIfNeeded(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            kind: .providerList
        )
        wsClient.requestAISessionConfigOptions(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: aiStore(for: ev.aiTool).currentSessionId
        )
        retryPendingAISessionSelectionHint(for: ev.aiTool)
    }

    func handleAIAgentList(_ ev: AIAgentListResult) {
        guard shouldAcceptAISelectorEvent(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            kind: .agentList
        ) else { return }
        let agents = ev.agents.map { a in
            AIAgentInfo(
                name: a.name,
                description: a.description,
                mode: a.mode,
                color: a.color,
                defaultProviderID: a.defaultProviderID,
                defaultModelID: a.defaultModelID
            )
        }
        setAIAgents(agents, for: ev.aiTool)
        isAILoadingAgents = false
        markEvolutionAgentListLoaded(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool
        )
        consumeAISelectorBootstrapContextIfNeeded(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            kind: .agentList
        )
        if selectedAgent(for: ev.aiTool) == nil {
            let firstAgent = agents.first(where: { $0.mode == "primary" || $0.mode == "all" })
                ?? agents.first
            setAISelectedAgent(firstAgent?.name, for: ev.aiTool)
            applyAgentDefaultModel(firstAgent, for: ev.aiTool)
        }
        wsClient.requestAISessionConfigOptions(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: aiStore(for: ev.aiTool).currentSessionId
        )
        retryPendingAISessionSelectionHint(for: ev.aiTool)
    }

    func handleAISessionConfigOptions(_ ev: AISessionConfigOptionsResult) {
        let matchesSelectedContext = selectedProjectName == ev.projectName &&
            selectedWorkspaceKey == ev.workspaceName
        let matchesBootstrapContext: Bool = {
            guard let pending = aiSelectorBootstrapContextByTool[ev.aiTool] else { return false }
            return pending.project == ev.projectName && pending.workspace == ev.workspaceName
        }()
        guard matchesSelectedContext || matchesBootstrapContext else { return }
        setAISessionConfigOptions(ev.options, for: ev.aiTool)
        retryPendingAISessionSelectionHint(for: ev.aiTool)
    }

    func handleAISlashCommands(_ ev: AISlashCommandsResult) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let commands = ev.commands.map { cmd in
            AISlashCommandInfo(
                name: cmd.name,
                description: cmd.description,
                action: cmd.action,
                inputHint: cmd.inputHint
            )
        }
        setAISlashCommands(commands, for: ev.aiTool, sessionId: ev.sessionID)
    }

    func handleAISlashCommandsUpdate(_ ev: AISlashCommandsUpdateResult) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let commands = ev.commands.map { cmd in
            AISlashCommandInfo(
                name: cmd.name,
                description: cmd.description,
                action: cmd.action,
                inputHint: cmd.inputHint
            )
        }
        setAISlashCommands(commands, for: ev.aiTool, sessionId: ev.sessionID)
    }

    func handleEvolutionPulse() {
        wsClient.requestEvoSnapshot()
    }

    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) {
        evolutionScheduler = snapshot.scheduler
        let items = snapshot.workspaceItems.sorted {
            ($0.project, $0.workspace) < ($1.project, $1.workspace)
        }
        evolutionWorkspaceItems = items
        var itemStatusByWorkspace: [String: String] = [:]
        for item in items {
            let key = globalWorkspaceKey(
                projectName: item.project,
                workspaceName: normalizeEvolutionWorkspaceName(item.workspace)
            )
            itemStatusByWorkspace[key] = item.status
        }
        for (key, pendingAction) in evolutionPendingActionByWorkspace {
            if EvolutionControlCapability.shouldClearPendingAction(
                pendingAction,
                currentStatus: itemStatusByWorkspace[key]
            ) {
                evolutionPendingActionByWorkspace.removeValue(forKey: key)
            }
        }
    }

    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2) {
        let workspace = normalizeEvolutionWorkspaceName(ev.workspace)
        let key = globalWorkspaceKey(projectName: ev.project, workspaceName: workspace)
        if ev.stageProfiles.isEmpty {
            TFLog.app.warning(
                "Evolution profile ignored: empty stage_profiles, project=\(ev.project, privacy: .public), workspace=\(workspace, privacy: .public)"
            )
            finishEvolutionProfileReloadTracking(project: ev.project, workspace: workspace)
            return
        }
        let normalizedProfiles = Self.normalizedEvolutionProfiles(ev.stageProfiles)
        evolutionStageProfilesByWorkspace[key] = normalizedProfiles
        let directionModel = normalizedProfiles
            .first(where: { $0.stage == "direction" })?
            .model
            .map { "\($0.providerID)/\($0.modelID)" } ?? "default"
        TFLog.app.info(
            "Evolution profile applied: project=\(ev.project, privacy: .public), workspace=\(workspace, privacy: .public), stages=\(normalizedProfiles.count), direction_model=\(directionModel, privacy: .public)"
        )
        finishEvolutionProfileReloadTracking(project: ev.project, workspace: workspace)
    }

    func handleEvolutionBlockingRequired(_ ev: EvolutionBlockingRequiredV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(ev.workspace)
        evolutionBlockingRequired = EvolutionBlockingRequiredV2(
            project: ev.project,
            workspace: normalizedWorkspace,
            trigger: ev.trigger,
            cycleID: ev.cycleID,
            stage: ev.stage,
            blockerFilePath: ev.blockerFilePath,
            unresolvedItems: ev.unresolvedItems
        )
        evolutionBlockers = ev.unresolvedItems
    }

    func handleEvolutionBlockersUpdated(_ ev: EvolutionBlockersUpdatedV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(ev.workspace)
        evolutionBlockers = ev.unresolvedItems
        if ev.unresolvedCount > 0 {
            evolutionBlockingRequired = EvolutionBlockingRequiredV2(
                project: ev.project,
                workspace: normalizedWorkspace,
                trigger: "updated",
                cycleID: evolutionBlockingRequired?.cycleID,
                stage: evolutionBlockingRequired?.stage,
                blockerFilePath: evolutionBlockingRequired?.blockerFilePath ?? "",
                unresolvedItems: ev.unresolvedItems
            )
            return
        }
        evolutionBlockingRequired = nil
        let key = globalWorkspaceKey(projectName: ev.project, workspaceName: normalizedWorkspace)
        guard let pendingAction = evolutionPendingActionByWorkspace[key] else {
            return
        }
        if pendingAction.action == .start {
            let profiles = evolutionProfiles(project: ev.project, workspace: normalizedWorkspace)
            let loopRoundLimit = pendingAction.resolvedLoopRoundLimit(fallback: 1)
            startEvolution(
                project: ev.project,
                workspace: normalizedWorkspace,
                loopRoundLimit: loopRoundLimit,
                profiles: profiles
            )
            return
        }
        if pendingAction.action == .resume {
            resumeEvolution(project: ev.project, workspace: normalizedWorkspace)
            return
        }
        if pendingAction.action == .stop {
            stopEvolution(project: ev.project, workspace: normalizedWorkspace)
        }
    }

    func handleEvolutionStageChatOpened(_ ev: EvolutionStageChatOpenedV2) {
        guard let aiTool = ev.aiTool else {
            evolutionReplayLoading = false
            evolutionReplayError = "不支持的 AI 工具：\(ev.aiToolRaw)"
            return
        }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(ev.workspace)
        evolutionReplayRequest = (
            project: ev.project,
            workspace: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: ev.sessionID,
            cycleId: ev.cycleID,
            stage: ev.stage
        )
        evolutionReplayTitle = "\(normalizedWorkspace) · \(ev.stage) · \(ev.cycleID)"
        evolutionReplayError = nil
        evolutionReplayLoading = false
        evolutionReplayStore.clearAll()
        evolutionReplayStore.setCurrentSessionId(ev.sessionID)

        let updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let session = AISessionInfo(
            projectName: ev.project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            id: ev.sessionID,
            title: "\(ev.stage) · \(ev.cycleID)",
            updatedAt: updatedAt
        )
        upsertAISession(session, for: aiTool)

        if aiChatTool != aiTool {
            aiChatTool = aiTool
        }
        let targetStore = aiStore(for: aiTool)
        targetStore.setAbortPendingSessionId(nil)
        targetStore.setCurrentSessionId(ev.sessionID)
        targetStore.clearMessages()

        wsClient.requestAISessionStatus(
            projectName: ev.project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: ev.sessionID
        )
        wsClient.requestAISessionMessages(
            projectName: ev.project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: ev.sessionID,
            limit: 400
        )
    }

    func handleEvolutionError(_ message: String, project: String? = nil, workspace: String? = nil) {
        evolutionReplayLoading = false
        evolutionReplayError = message
        if let project, let workspace {
            clearEvolutionPendingAction(project: project, workspace: workspace)
        } else if let workspace = selectedWorkspaceKey {
            clearEvolutionPendingAction(project: selectedProjectName, workspace: workspace)
        }
        for key in evidenceLoadingByWorkspace.keys {
            evidenceLoadingByWorkspace[key] = false
            evidenceErrorByWorkspace[key] = message
        }
        let promptCallbacks = evidencePromptCompletionByWorkspace
        evidencePromptCompletionByWorkspace.removeAll()
        for (_, completion) in promptCallbacks {
            completion(nil, message)
        }
        let readRequests = evidenceReadRequestByWorkspace
        evidenceReadRequestByWorkspace.removeAll()
        for (_, request) in readRequests {
            if request.autoContinue {
                request.fullCompletion(nil, message)
            } else {
                request.pageCompletion(nil, message)
            }
        }
    }

    func handleEvolutionCycleHistory(project: String, workspace: String, cycles: [EvolutionCycleHistoryItemV2]) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evolutionCycleHistories[key] = cycles
    }

    func handleEvidenceSnapshot(_ snapshot: EvidenceSnapshotV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(snapshot.workspace)
        let key = globalWorkspaceKey(projectName: snapshot.project, workspaceName: normalizedWorkspace)
        evidenceSnapshotsByWorkspace[key] = snapshot
        evidenceLoadingByWorkspace[key] = false
        evidenceErrorByWorkspace[key] = nil
    }

    func handleEvidenceRebuildPrompt(_ prompt: EvidenceRebuildPromptV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(prompt.workspace)
        let key = globalWorkspaceKey(projectName: prompt.project, workspaceName: normalizedWorkspace)
        if let completion = evidencePromptCompletionByWorkspace.removeValue(forKey: key) {
            completion(prompt, nil)
        }
    }

    func handleEvidenceItemChunk(_ chunk: EvidenceItemChunkV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(chunk.workspace)
        let key = globalWorkspaceKey(projectName: chunk.project, workspaceName: normalizedWorkspace)
        guard var request = evidenceReadRequestByWorkspace[key] else { return }
        guard request.itemID == chunk.itemID else { return }

        guard chunk.offset == request.expectedOffset else {
            // 同一条目的旧分块回包（通常由重入读取触发）直接丢弃，避免误判中断。
            if chunk.offset < request.expectedOffset {
                return
            }
            // 首块期待偏移为 0；若先收到更大偏移，通常是上一次读取会话的滞后分块。
            if request.expectedOffset == 0 {
                return
            }
            evidenceReadRequestByWorkspace.removeValue(forKey: key)
            if request.autoContinue {
                request.fullCompletion(nil, "证据分块偏移不连续，读取已中断")
            } else {
                request.pageCompletion(nil, "证据分块偏移不连续，读取已中断")
            }
            return
        }

        request.totalSizeBytes = chunk.totalSizeBytes
        request.mimeType = chunk.mimeType
        request.expectedOffset = chunk.nextOffset

        if !request.autoContinue {
            evidenceReadRequestByWorkspace.removeValue(forKey: key)
            request.pageCompletion(
                .init(
                    mimeType: chunk.mimeType,
                    content: chunk.content,
                    offset: chunk.offset,
                    nextOffset: chunk.nextOffset,
                    totalSizeBytes: chunk.totalSizeBytes,
                    eof: chunk.eof
                ),
                nil
            )
            return
        }

        request.content.append(contentsOf: chunk.content)

        if chunk.eof {
            evidenceReadRequestByWorkspace.removeValue(forKey: key)
            request.fullCompletion((mimeType: request.mimeType, content: request.content), nil)
            return
        }

        evidenceReadRequestByWorkspace[key] = request
        wsClient.requestEvidenceReadItem(
            project: request.project,
            workspace: request.workspace,
            itemID: request.itemID,
            offset: request.expectedOffset,
            limit: request.limit
        )
    }

    func handleAISessionSubscribeAck() {
        // 遍历所有工具，消费有待处理的订阅上下文
        for tool in AIChatTool.allCases {
            guard let ctx = pendingSubscribeContextByTool[tool] else { continue }
            pendingSubscribeContextByTool[tool] = nil

            let session = ctx.session
            let store = aiStore(for: tool)

            // 手动维护订阅集合（setCurrentSessionId 已 insert，此处确保一致）
            store.addSubscription(session.id)

            TFLog.app.info(
                "AI subscribe ack: tool=\(tool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public)"
            )

            // ack 确认后再拉消息，确保 Core 已进入推送模式
            wsClient.requestAISessionMessages(
                projectName: session.projectName,
                workspaceName: session.workspaceName,
                aiTool: tool,
                sessionId: session.id,
                limit: 200
            )

            // 取消订阅旧会话
            if let oldId = ctx.oldSessionId, !oldId.isEmpty, oldId != session.id {
                wsClient.requestAISessionUnsubscribe(
                    project: session.projectName,
                    workspace: session.workspaceName,
                    aiTool: tool.rawValue,
                    sessionId: oldId
                )
                TFLog.app.info(
                    "AI unsubscribed old session: tool=\(tool.rawValue, privacy: .public), old_session_id=\(oldId, privacy: .public)"
                )
            }
        }
    }

    func handleClientErrorMessage(_ errorMsg: String) {
        // 导入项目期间收到服务端错误，结束导入并透传错误给 UI。
        if projectImportInFlight {
            projectImportInFlight = false
            projectImportError = errorMsg
        }

        if let ws = selectedWorkspaceKey {
            var cache = fileIndexCache[ws] ?? FileIndexCache.empty()
            if cache.isLoading {
                cache.isLoading = false
                cache.error = errorMsg
                fileIndexCache[ws] = cache
            }
        }

        // Handoff 请求失败时清除加载状态
        if pendingHandoffReadPath != nil {
            pendingHandoffReadPath = nil
            evolutionHandoffLoading = false
            evolutionHandoffError = errorMsg
        }
    }
}
