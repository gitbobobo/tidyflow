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
        // 会话列表 map + sort 移至后台
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
            let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
            DispatchQueue.main.async { [weak self] in
                self?.setAISessions(sorted, for: ev.aiTool)
            }
        }
    }

    func handleAISessionMessages(_ ev: AISessionMessagesV2) {
        #if os(iOS)
        if consumeEvolutionReplayMessagesIfNeeded(ev) {
            return
        }
        #endif
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
        // 将重型数据转换移至后台线程，避免阻塞主线程造成卡顿
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mapped = ev.toChatMessages()
            if ev.beforeMessageId != nil {
                DispatchQueue.main.async {
                    store.prependMessages(mapped)
                    store.updateHistoryPagination(
                        hasMore: ev.hasMore,
                        nextBeforeMessageId: ev.nextBeforeMessageId
                    )
                    TFLog.app.info(
                        "AI session_messages prepended: ai_tool=\(ev.aiTool.rawValue, privacy: .public), session_id=\(ev.sessionId, privacy: .public), before_message_id=\((ev.beforeMessageId ?? ""), privacy: .public), prepended_count=\(mapped.count), has_more=\(ev.hasMore), next_before=\((ev.nextBeforeMessageId ?? ""), privacy: .public)"
                    )
                }
                return
            }
            let restoredQuestions = Self.rebuildPendingQuestionRequests(
                sessionId: ev.sessionId,
                messages: ev.messages
            )
            let inferredHint = self?.inferAISessionSelectionHintFromMessages(ev.messages)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                store.replaceMessages(mapped)
                store.replaceQuestionRequests(restoredQuestions)
                store.updateHistoryPagination(
                    hasMore: ev.hasMore,
                    nextBeforeMessageId: ev.nextBeforeMessageId
                )
                let effectiveHint = self.mergedAISessionSelectionHint(primary: ev.selectionHint, fallback: inferredHint)
                self.sendAISelectionPipelineLog(
                    event: "session_messages_received",
                    tool: ev.aiTool,
                    sessionId: ev.sessionId,
                    primaryHint: ev.selectionHint,
                    inferredHint: inferredHint,
                    effectiveHint: effectiveHint,
                    messagesCount: ev.messages.count
                )
                self.applyAISessionSelectionHint(
                    effectiveHint,
                    sessionId: ev.sessionId,
                    for: ev.aiTool,
                    trigger: "session_messages"
                )
                self.wsClient.requestAISessionConfigOptions(
                    projectName: ev.projectName,
                    workspaceName: ev.workspaceName,
                    aiTool: ev.aiTool,
                    sessionId: ev.sessionId
                )
                TFLog.app.info(
                    "AI session_messages applied: ai_tool=\(ev.aiTool.rawValue, privacy: .public), session_id=\(ev.sessionId, privacy: .public), mapped_messages_count=\(mapped.count), restored_question_count=\(restoredQuestions.count)"
                )
            }
        }
    }

    func handleAISessionMessagesUpdate(_ ev: AISessionMessagesUpdateV2) {
        #if os(iOS)
        _ = consumeEvolutionReplayMessagesUpdateIfNeeded(ev)
        #endif
        _ = consumeSubAgentViewerMessagesUpdateIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        if store.isAbortPending(for: ev.sessionId) { return }

        if let messages = ev.messages {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let inferredHint = self?.inferAISessionSelectionHintFromMessages(messages)
                let restoredQuestions = Self.rebuildPendingQuestionRequests(
                    sessionId: ev.sessionId,
                    messages: messages
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard store.shouldApplySessionCacheRevision(
                        ev.cacheRevision,
                        sessionId: ev.sessionId
                    ) else {
                        TFLog.app.debug(
                            "AI session_messages_update(snapshot) ignored by stale revision: session_id=\(ev.sessionId, privacy: .public), revision=\(ev.cacheRevision), ai_tool=\(ev.aiTool.rawValue, privacy: .public)"
                        )
                        return
                    }
                    store.replaceMessagesFromSessionCache(messages, isStreaming: ev.isStreaming)
                    store.replaceQuestionRequests(restoredQuestions)
                    let effectiveHint = self.mergedAISessionSelectionHint(
                        primary: ev.selectionHint,
                        fallback: inferredHint
                    )
                    self.sendAISelectionPipelineLog(
                        event: "session_messages_update_snapshot_received",
                        tool: ev.aiTool,
                        sessionId: ev.sessionId,
                        primaryHint: ev.selectionHint,
                        inferredHint: inferredHint,
                        effectiveHint: effectiveHint,
                        messagesCount: messages.count
                    )
                    self.applyAISessionSelectionHint(
                        effectiveHint,
                        sessionId: ev.sessionId,
                        for: ev.aiTool,
                        trigger: "session_messages_update_snapshot"
                    )
                    self.setBadgeRunning(ev.isStreaming, for: ev.aiTool)
                    self.markUnreadBadge(for: ev.aiTool)
                }
            }
            return
        }

        if let ops = ev.ops {
            guard store.shouldApplySessionCacheRevision(
                ev.cacheRevision,
                sessionId: ev.sessionId
            ) else {
                TFLog.app.debug(
                    "AI session_messages_update(ops) ignored by stale revision: session_id=\(ev.sessionId, privacy: .public), revision=\(ev.cacheRevision), ai_tool=\(ev.aiTool.rawValue, privacy: .public)"
                )
                return
            }
            store.applySessionCacheOps(ops, isStreaming: ev.isStreaming)
            if let hint = ev.selectionHint {
                sendAISelectionPipelineLog(
                    event: "session_messages_update_ops_received",
                    tool: ev.aiTool,
                    sessionId: ev.sessionId,
                    primaryHint: hint,
                    inferredHint: nil,
                    effectiveHint: hint
                )
                applyAISessionSelectionHint(
                    hint,
                    sessionId: ev.sessionId,
                    for: ev.aiTool,
                    trigger: "session_messages_update_ops"
                )
            }
            setBadgeRunning(ev.isStreaming, for: ev.aiTool)
            markUnreadBadge(for: ev.aiTool)
            return
        }

        if !ev.isStreaming {
            guard store.shouldApplySessionCacheRevision(
                ev.cacheRevision,
                sessionId: ev.sessionId
            ) else {
                TFLog.app.debug(
                    "AI session_messages_update(terminal) ignored by stale revision: session_id=\(ev.sessionId, privacy: .public), revision=\(ev.cacheRevision), ai_tool=\(ev.aiTool.rawValue, privacy: .public)"
                )
                return
            }
            store.applySessionCacheOps([], isStreaming: false)
        }
        if let hint = ev.selectionHint {
            applyAISessionSelectionHint(
                hint,
                sessionId: ev.sessionId,
                for: ev.aiTool,
                trigger: "session_messages_update_terminal"
            )
        }
        setBadgeRunning(ev.isStreaming, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) {
        let activeChanged = upsertAISessionStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            contextRemainingPercent: ev.status.contextRemainingPercent
        )
        if activeChanged {
            scheduleWorkspaceSidebarStatusRefresh(projectName: ev.projectName)
        }
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
        let activeChanged = upsertAISessionStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            contextRemainingPercent: ev.status.contextRemainingPercent
        )
        if activeChanged {
            scheduleWorkspaceSidebarStatusRefresh(projectName: ev.projectName)
        }
        if selectedProjectName == ev.projectName,
           selectedWorkspaceKey == ev.workspaceName {
            reconcileAIStreamStateFromSessionStatus(
                aiTool: ev.aiTool,
                sessionId: ev.sessionId,
                status: ev.status.status
            )
        }
        // 将 AI 会话状态同步到所属工作空间的所有终端 tab
        syncAIStatusToTerminalTabs(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            toolName: ev.status.toolName
        )
    }

    /// 将 AI 会话状态映射为 TerminalAIStatus 并更新该工作空间下所有终端 tab。
    /// 每个工作空间的 AI 会话与终端 tab 建立稳定映射，实现逐 tab 状态可视化。
    private func syncAIStatusToTerminalTabs(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        status: String,
        errorMessage: String?,
        toolName: String?
    ) {
        let globalKey = globalWorkspaceKey(projectName: projectName, workspaceName: workspaceName)
        let tabs = workspaceTabs[globalKey] ?? []
        guard !tabs.isEmpty else { return }

        // 将后端状态字符串映射为六态枚举；toolName 优先使用后端工具名，否则回退到 AI 工具显示名
        let displayName = toolName ?? aiTool.displayName
        let terminalStatus: TerminalAIStatus
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running":
            terminalStatus = .running(toolName: displayName)
        case "awaiting_input":
            terminalStatus = .awaitingInput
        case "success":
            terminalStatus = .success
        case "failure", "error":
            terminalStatus = .failure(message: errorMessage)
        case "cancelled":
            terminalStatus = .cancelled
        default:
            terminalStatus = .idle
        }

        for tab in tabs where tab.kind == .terminal {
            terminalStore.updateTerminalAIStatus(tabId: tab.id, status: terminalStatus)
        }
    }

    private func fallbackSessionStatusForChatDone(stopReason: String?) -> String {
        let reason = (stopReason ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if reason.isEmpty {
            return "success"
        }
        if reason.contains("cancel") || reason.contains("abort") || reason.contains("interrupt") {
            return "cancelled"
        }
        if reason.contains("awaiting_input") ||
            reason.contains("requires_input") ||
            reason.contains("need_input") {
            return "awaiting_input"
        }
        if reason.contains("error") || reason.contains("fail") {
            return "failure"
        }
        return "success"
    }

    func handleAIChatDone(_ ev: AIChatDoneV2) {
        #if os(iOS)
        consumeEvolutionReplayDoneIfNeeded(ev)
        #endif
        consumeSubAgentViewerDoneIfNeeded(ev)

        // 兜底收敛：部分后端路径可能未及时推送 ai_session_status_update，
        // 避免会话列表长期停留在 running。
        let fallbackStatus = fallbackSessionStatusForChatDone(stopReason: ev.stopReason)
        scheduleWorkspaceSidebarStatusRefresh(projectName: ev.projectName)
        upsertAISessionStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            status: fallbackStatus,
            errorMessage: nil,
            contextRemainingPercent: nil
        )
        if selectedProjectName == ev.projectName,
           selectedWorkspaceKey == ev.workspaceName {
            reconcileAIStreamStateFromSessionStatus(
                aiTool: ev.aiTool,
                sessionId: ev.sessionId,
                status: fallbackStatus
            )
        }

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
        setBadgeRunning(false, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIChatError(_ ev: AIChatErrorV2) {
        #if os(iOS)
        consumeEvolutionReplayErrorIfNeeded(ev)
        #endif
        consumeSubAgentViewerErrorIfNeeded(ev)

        // 兜底收敛：确保 error 事件会把会话状态从 running 拉回终态。
        scheduleWorkspaceSidebarStatusRefresh(projectName: ev.projectName)
        upsertAISessionStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            status: "failure",
            errorMessage: ev.error,
            contextRemainingPercent: nil
        )
        if selectedProjectName == ev.projectName,
           selectedWorkspaceKey == ev.workspaceName {
            reconcileAIStreamStateFromSessionStatus(
                aiTool: ev.aiTool,
                sessionId: ev.sessionId,
                status: "failure"
            )
        }

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

    func handleAIChatPending(_ ev: AIChatPendingV2) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        // AIChatPending 仅用于确认服务端已收到请求；客户端 pending 态已在发送时由 beginAwaitingUserEcho 设置，无需额外操作。
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
        if isAILoadingModels { isAILoadingModels = false }
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
        if isAILoadingAgents { isAILoadingAgents = false }
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

    /// 直接处理 evo_cycle_updated 事件，在不触发全量快照刷新的情况下更新单个工作空间状态。
    /// 若对应工作空间尚不存在则回退到 pulse（触发全量刷新）。
    func handleEvolutionCycleUpdated(_ ev: EvoCycleUpdatedV2) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let workspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            let key = self.globalWorkspaceKey(projectName: ev.project, workspaceName: workspace)
            guard let existingIndex = self.evolutionWorkspaceItems.firstIndex(where: { $0.workspaceKey == key }) else {
                // 找不到已有条目时触发全量刷新（首次连接或重连场景）
                self.wsClient.requestEvoSnapshot()
                return
            }
            let existing = self.evolutionWorkspaceItems[existingIndex]
            // 构建更新后的条目，保留只有快照才携带的 handoff 字段
            let updated = EvolutionWorkspaceItemV2(
                project: ev.project,
                workspace: workspace,
                cycleID: ev.cycleID,
                title: ev.title ?? existing.title,
                status: ev.status,
                currentStage: ev.currentStage,
                globalLoopRound: ev.globalLoopRound,
                loopRoundLimit: ev.loopRoundLimit,
                verifyIteration: ev.verifyIteration,
                verifyIterationLimit: ev.verifyIterationLimit,
                agents: ev.agents,
                executions: ev.executions,
                activeAgents: ev.activeAgents,
                handoff: existing.handoff,
                terminalReasonCode: ev.terminalReasonCode,
                terminalErrorMessage: ev.terminalErrorMessage,
                rateLimitErrorMessage: ev.rateLimitErrorMessage,
                selectedDirectionType: ev.selectedDirectionType ?? existing.selectedDirectionType
            )
            if self.evolutionWorkspaceItems[existingIndex] != updated {
                self.evolutionWorkspaceItems[existingIndex] = updated
                self.scheduleWorkspaceSidebarStatusRefresh(
                    projectNames: [ev.project],
                    debounce: 0.2
                )
            }
            if let pendingAction = self.evolutionPendingActionByWorkspace[key],
               EvolutionControlCapability.shouldClearPendingAction(
                pendingAction,
                currentStatus: ev.status
            ) {
                self.evolutionPendingActionByWorkspace.removeValue(forKey: key)
            }
        }
    }

    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) {
        // 排序和字典构建移至后台线程
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let items = snapshot.workspaceItems.sorted {
                ($0.project, $0.workspace) < ($1.project, $1.workspace)
            }
            var itemStatusByWorkspace: [String: String] = [:]
            for item in items {
                let key = self.globalWorkspaceKey(
                    projectName: item.project,
                    workspaceName: self.normalizeEvolutionWorkspaceName(item.workspace)
                )
                itemStatusByWorkspace[key] = item.status
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.evolutionScheduler != snapshot.scheduler {
                    self.evolutionScheduler = snapshot.scheduler
                }
                if self.evolutionWorkspaceItems != items {
                    self.evolutionWorkspaceItems = items
                    self.scheduleWorkspaceSidebarStatusRefresh(
                        projectNames: items.map(\.project),
                        debounce: 0.2
                    )
                }
                for (key, pendingAction) in self.evolutionPendingActionByWorkspace {
                    if EvolutionControlCapability.shouldClearPendingAction(
                        pendingAction,
                        currentStatus: itemStatusByWorkspace[key]
                    ) {
                        self.evolutionPendingActionByWorkspace.removeValue(forKey: key)
                    }
                }
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
        // 同步侧边栏筛选，确保会话列表高亮当前进化会话
        if sessionPanelFilterTool != aiTool {
            sessionPanelFilterTool = aiTool
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
        wsClient.requestAISessionSubscribe(
            project: ev.project,
            workspace: normalizedWorkspace,
            aiTool: aiTool.rawValue,
            sessionId: ev.sessionID
        )
        wsClient.requestAISessionMessages(
            projectName: ev.project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: ev.sessionID,
            limit: 50
        )
    }

    func handleEvolutionError(_ message: String, project: String? = nil, workspace: String? = nil) {
        evolutionReplayLoading = false
        evolutionReplayError = message
        if let project, let workspace {
            clearEvolutionPendingAction(project: project, workspace: workspace)
        } else if let workspace = selectedWorkspaceKey {
            clearEvolutionPendingAction(project: selectedProjectName, workspace: workspace)
        } else {
            evolutionPendingActionByWorkspace.removeAll()
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
        if evidenceLoadingByWorkspace[key] != false { evidenceLoadingByWorkspace[key] = false }
        if evidenceErrorByWorkspace[key] != nil { evidenceErrorByWorkspace[key] = nil }
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

        // 预分配容量，减少大证据文件的重复内存拷贝
        if request.content.isEmpty, chunk.totalSizeBytes > 0 {
            request.content.reserveCapacity(Int(chunk.totalSizeBytes))
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
                limit: 50
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
        aiSessionListLoadingTools.removeAll()
        if !evolutionPendingActionByWorkspace.isEmpty {
            let pendingCount = evolutionPendingActionByWorkspace.count
            evolutionPendingActionByWorkspace.removeAll()
            TFLog.app.warning(
                "Evolution pending actions cleared after client error: count=\(pendingCount), error=\(errorMsg, privacy: .public)"
            )
        }

        // 导入项目期间收到服务端错误，结束导入并透传错误给 UI。
        if projectImportInFlight {
            projectImportInFlight = false
            projectImportError = errorMsg
        }

        if let globalKey = currentGlobalWorkspaceKey {
            var cache = fileIndexCache[globalKey] ?? FileIndexCache.empty()
            if cache.isLoading {
                cache.isLoading = false
                cache.error = errorMsg
                fileIndexCache[globalKey] = cache
            }
        }

        // 历史分页请求失败时，避免“加载更早消息”按钮长期停留在 loading。
        for tool in AIChatTool.allCases {
            aiStore(for: tool).setHistoryLoading(false)
        }
    }
}
