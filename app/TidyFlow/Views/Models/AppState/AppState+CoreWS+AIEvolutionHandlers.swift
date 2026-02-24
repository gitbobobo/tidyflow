import Foundation

extension AppState {
    private func aiSelectionHintLogDict(_ hint: AISessionSelectionHint?) -> [String: Any]? {
        guard let hint, !hint.isEmpty else { return nil }
        var dict: [String: Any] = [:]
        if let agent = hint.agent { dict["agent"] = agent }
        if let provider = hint.modelProviderID { dict["model_provider_id"] = provider }
        if let model = hint.modelID { dict["model_id"] = model }
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
        let merged = AISessionSelectionHint(
            agent: primary?.agent ?? fallback?.agent,
            modelProviderID: primary?.modelProviderID ?? fallback?.modelProviderID,
            modelID: primary?.modelID ?? fallback?.modelID
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
        TFLog.app.debug(
            "AI stream message_updated: session_id=\(ev.sessionId, privacy: .public), message_id=\(ev.messageId, privacy: .public), role=\(ev.role, privacy: .public)"
        )
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
        TFLog.app.debug(
            "AI stream part_updated: session_id=\(ev.sessionId, privacy: .public), message_id=\(ev.messageId, privacy: .public), part_id=\(ev.part.id, privacy: .public), part_type=\(ev.part.partType, privacy: .public)"
        )
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
        TFLog.app.debug(
            "AI stream part_delta: session_id=\(ev.sessionId, privacy: .public), message_id=\(ev.messageId, privacy: .public), part_id=\(ev.partId, privacy: .public), part_type=\(ev.partType, privacy: .public), field=\(ev.field, privacy: .public), delta_len=\(ev.delta.count)"
        )
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
        TFLog.app.debug("AI stream done: session_id=\(ev.sessionId, privacy: .public)")
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
        retryPendingAISessionSelectionHint(for: ev.aiTool)
    }

    func handleAISlashCommands(_ ev: AISlashCommandsResult) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let commands = ev.commands.map { cmd in
            AISlashCommandInfo(name: cmd.name, description: cmd.description, action: cmd.action)
        }
        setAISlashCommands(commands, for: ev.aiTool)
    }

    func handleEvolutionPulse() {
        wsClient.requestEvoSnapshot()
    }

    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) {
        evolutionScheduler = snapshot.scheduler
        evolutionWorkspaceItems = snapshot.workspaceItems.sorted {
            ($0.project, $0.workspace) < ($1.project, $1.workspace)
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

    func handleEvolutionStageChatOpened(_ ev: EvolutionStageChatOpenedV2) {
        guard let aiTool = ev.aiTool else {
            evolutionReplayLoading = false
            evolutionReplayError = "不支持的 AI 工具：\(ev.aiToolRaw)"
            return
        }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(ev.workspace)
        evolutionReplayRequest = nil
        evolutionReplayTitle = "\(normalizedWorkspace) · \(ev.stage) · \(ev.cycleID)"
        evolutionReplayError = nil
        evolutionReplayLoading = false

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

    func handleEvolutionError(_ message: String) {
        evolutionReplayLoading = false
        evolutionReplayError = message
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
        if let ws = selectedWorkspaceKey {
            var cache = fileIndexCache[ws] ?? FileIndexCache.empty()
            if cache.isLoading {
                cache.isLoading = false
                cache.error = errorMsg
                fileIndexCache[ws] = cache
            }
        }
    }
}
