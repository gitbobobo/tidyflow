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
        let serializedDetail = detailText ?? "{}"
        TFLog.app.debug(
            "ai selection pipeline \(event, privacy: .public) detail=\(serializedDetail, privacy: .public)"
        )
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
            updatedAt: updatedAt,
            origin: ev.origin
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
                    aiTool: $0.aiTool,
                    id: $0.id,
                    title: $0.title,
                    updatedAt: $0.updatedAt,
                    origin: $0.origin
                )
            }
            let sorted = sessions.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                if $0.aiTool != $1.aiTool {
                    return $0.aiTool.rawValue < $1.aiTool.rawValue
                }
                return $0.id < $1.id
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let filter: AISessionListFilter = ev.filterAIChatTool.map { .tool($0) } ?? .all
                let pageState = self.aiSessionListStore.handleResponse(
                    project: ev.projectName,
                    workspace: ev.workspaceName,
                    filter: filter,
                    sessions: sorted,
                    hasMore: ev.hasMore,
                    nextCursor: ev.nextCursor,
                    performanceTracer: self.performanceTracer
                )
                self.mergeKnownAISessions(pageState.sessions)
            }
        }
    }

    func handleAISessionMessages(_ ev: AISessionMessagesV2) {
        // WI-002：无论平台，优先将回放消息路由到 evolutionReplayStore，阻断旧会话内容回灌
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
            // 共享消息流归一化入口：同时重建 pending questions + 合并 selection hint，
            // 确保 ai_session_messages 与 ai_session_messages_update 走同一链路。
            let normalized = AISessionSemantics.normalizeMessageStream(
                sessionId: ev.sessionId,
                messages: ev.messages,
                primarySelectionHint: ev.selectionHint
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                store.replaceMessages(mapped)
                store.replaceQuestionRequests(normalized.pendingQuestionRequests)
                store.updateHistoryPagination(
                    hasMore: ev.hasMore,
                    nextBeforeMessageId: ev.nextBeforeMessageId
                )
                self.sendAISelectionPipelineLog(
                    event: "session_messages_received",
                    tool: ev.aiTool,
                    sessionId: ev.sessionId,
                    primaryHint: ev.selectionHint,
                    inferredHint: nil,
                    effectiveHint: normalized.effectiveSelectionHint,
                    messagesCount: ev.messages.count
                )
                self.applyAISessionSelectionHint(
                    normalized.effectiveSelectionHint,
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
                    "AI session_messages applied: ai_tool=\(ev.aiTool.rawValue, privacy: .public), session_id=\(ev.sessionId, privacy: .public), mapped_messages_count=\(mapped.count), restored_question_count=\(normalized.pendingQuestionRequests.count)"
                )
            }
        }
    }

    func handleAISessionMessagesUpdate(_ ev: AISessionMessagesUpdateV2) {
        // WI-002：无论平台，优先路由回放流式更新，阻断旧会话事件写入已清空视图
        _ = consumeEvolutionReplayMessagesUpdateIfNeeded(ev)
        _ = consumeSubAgentViewerMessagesUpdateIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        if store.isAbortPending(for: ev.sessionId) { return }

        if let messages = ev.messages {
            // 捕获当前会话 ID，后台返回时校验作用域
            let capturedSessionId = store.currentSessionId
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // 共享消息流归一化入口：与 ai_session_messages 走同一链路，避免分叉。
                let normalized = AISessionSemantics.normalizeMessageStream(
                    sessionId: ev.sessionId,
                    messages: messages,
                    primarySelectionHint: ev.selectionHint
                )
                let preparedSnapshot = AIChatPreparedSnapshotBuilder.build(
                    protocolMessages: messages,
                    pendingQuestionRequests: normalized.pendingQuestionRequests,
                    effectiveSelectionHint: normalized.effectiveSelectionHint,
                    isStreaming: ev.isStreaming,
                    fromRevision: ev.fromRevision,
                    toRevision: ev.toRevision
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // 作用域校验：若 store 的当前会话已切换，丢弃旧 snapshot
                    guard store.currentSessionId == capturedSessionId else {
                        TFLog.app.debug(
                            "AI session_messages_update(snapshot) rejected by scope change: session_id=\(ev.sessionId, privacy: .public), captured=\(capturedSessionId ?? "nil", privacy: .public), current=\(store.currentSessionId ?? "nil", privacy: .public)"
                        )
                        return
                    }
                    guard store.shouldApplySessionCacheRevision(
                        fromRevision: preparedSnapshot.fromRevision,
                        toRevision: preparedSnapshot.toRevision,
                        sessionId: ev.sessionId
                    ) else {
                        TFLog.app.debug(
                            "AI session_messages_update(snapshot) ignored by stale revision: session_id=\(ev.sessionId, privacy: .public), from=\(ev.fromRevision), to=\(ev.toRevision), ai_tool=\(ev.aiTool.rawValue, privacy: .public)"
                        )
                        return
                    }
                    store.applyPreparedSnapshot(preparedSnapshot)
                    self.sendAISelectionPipelineLog(
                        event: "session_messages_update_snapshot_received",
                        tool: ev.aiTool,
                        sessionId: ev.sessionId,
                        primaryHint: ev.selectionHint,
                        inferredHint: nil,
                        effectiveHint: preparedSnapshot.effectiveSelectionHint,
                        messagesCount: messages.count
                    )
                    self.applyAISessionSelectionHint(
                        preparedSnapshot.effectiveSelectionHint,
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
                fromRevision: ev.fromRevision,
                toRevision: ev.toRevision,
                sessionId: ev.sessionId
            ) else {
                TFLog.app.debug(
                    "AI session_messages_update(ops) ignored by stale revision: session_id=\(ev.sessionId, privacy: .public), from=\(ev.fromRevision), to=\(ev.toRevision), ai_tool=\(ev.aiTool.rawValue, privacy: .public)"
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
                fromRevision: ev.fromRevision,
                toRevision: ev.toRevision,
                sessionId: ev.sessionId
            ) else {
                TFLog.app.debug(
                    "AI session_messages_update(terminal) ignored by stale revision: session_id=\(ev.sessionId, privacy: .public), from=\(ev.fromRevision), to=\(ev.toRevision), ai_tool=\(ev.aiTool.rawValue, privacy: .public)"
                )
                return
            }
            // 终态提交：先冲刷待处理事件，再统一收敛状态
            store.commitTerminalState(sessionId: ev.sessionId)
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
        // WI-002：result 事件同样需要落到终端标签状态，避免初始快照不触发 update 时标签长期空白
        syncAIStatusToTerminalTabs(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            status: ev.status.status,
            errorMessage: ev.status.errorMessage,
            toolName: ev.status.toolName
        )
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
    /// 状态映射规则由共享语义层 TerminalSessionSemantics 提供，双端保持一致。
    private func syncAIStatusToTerminalTabs(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        status: String,
        errorMessage: String?,
        toolName: String?
    ) {
        let globalKey = globalWorkspaceKey(projectName: projectName, workspaceName: workspaceName)

        // WI-002：若 CoordinatorStateCache 已有该工作区的 Core 权威状态，
        // 本地事件驱动的同步降级为兜底，不得覆盖 Coordinator 状态。
        // 仅在首帧/重连期间（缓存尚无数据时）允许本地同步作为占位。
        guard !coordinatorStateCache.hasState(forGlobalKey: globalKey) else { return }

        let tabs = workspaceTabs[globalKey] ?? []
        guard !tabs.isEmpty else { return }

        // 通过共享语义层映射 AI 状态，不再维护本地 switch/case
        let terminalStatus = TerminalSessionSemantics.terminalAIStatus(
            from: status,
            errorMessage: errorMessage,
            toolName: toolName,
            aiToolDisplayName: aiTool.displayName
        )

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
        // WI-002：无论平台，优先将 done 事件路由到 evolutionReplayStore
        consumeEvolutionReplayDoneIfNeeded(ev)
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
        // WI-002：done 兜底收敛同样要落到终端标签，不受当前选中工作区限制
        syncAIStatusToTerminalTabs(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            status: fallbackStatus,
            errorMessage: nil,
            toolName: nil
        )

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
        store.commitTerminalState(sessionId: ev.sessionId)
        setBadgeRunning(false, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
        // v1.42：存储路由决策与预算状态（按 project/workspace/aiTool/session 隔离）
        upsertAISessionRouteDecision(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            routeDecision: ev.routeDecision
        )
        upsertAIWorkspaceBudgetStatus(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            budgetStatus: ev.budgetStatus
        )
    }

    func handleAIChatError(_ ev: AIChatErrorV2) {
        // WI-002：无论平台，优先将 error 事件路由到 evolutionReplayStore
        consumeEvolutionReplayErrorIfNeeded(ev)
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
        // WI-002：error 兜底收敛同样要落到终端标签，不受当前选中工作区限制
        syncAIStatusToTerminalTabs(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            status: "failure",
            errorMessage: ev.error,
            toolName: nil
        )

        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        store.clearAbortPendingIfMatches(ev.sessionId)
        guard store.subscribedSessionIds.contains(ev.sessionId) else { return }
        TFLog.app.error(
            "AI stream error: session_id=\(ev.sessionId, privacy: .public), error=\(ev.error, privacy: .public)"
        )
        store.commitTerminalState(sessionId: ev.sessionId)
        store.appendTerminalErrorMessage(ev.error)
        setBadgeRunning(false, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
        // v1.42：存储路由决策（即使出错也记录最后的路由，便于问题排查）
        upsertAISessionRouteDecision(
            projectName: ev.projectName,
            workspaceName: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId,
            routeDecision: ev.routeDecision
        )
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
                        supportsImageInput: m.supportsImageInput,
                        variants: m.variants
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
        if let workspace = selectedWorkspaceKey, !workspace.isEmpty {
            requestEvolutionSnapshot(project: selectedProjectName, workspace: workspace)
        } else {
            requestEvolutionSnapshot()
        }
    }

    func handleEvolutionWorkspaceStatusEvent(_ ev: EvolutionWorkspaceStatusEventV2) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.assertEvolutionStateAccessOnMainThread()
            let workspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            let key = self.globalWorkspaceKey(projectName: ev.project, workspaceName: workspace)
            guard let existing = self.evolutionWorkspaceItemIndexByKey[key] else {
                self.scheduleEvolutionSnapshotFallback(
                    project: ev.project,
                    workspace: workspace,
                    reason: "missing_workspace_status_event"
                )
                return
            }

            let shouldFallback: Bool
            switch ev.kind {
            case .started:
                shouldFallback = existing.cycleID != ev.cycleID
            case .resumed:
                shouldFallback = existing.cycleID != ev.cycleID
            case .stageChanged:
                shouldFallback = existing.cycleID != ev.cycleID || (ev.currentStage?.isEmpty ?? true)
            case .stopped:
                shouldFallback = false
            }
            if shouldFallback {
                self.scheduleEvolutionSnapshotFallback(
                    project: ev.project,
                    workspace: workspace,
                    reason: "workspace_status_event_requires_snapshot"
                )
                return
            }

            let shouldReconcileTerminalSnapshot = ev.kind == .stopped
            let updated = EvolutionWorkspaceItemV2(
                project: existing.project,
                workspace: existing.workspace,
                cycleID: ev.cycleID,
                title: existing.title,
                status: ev.status ?? existing.status,
                currentStage: ev.currentStage ?? existing.currentStage,
                globalLoopRound: existing.globalLoopRound,
                loopRoundLimit: existing.loopRoundLimit,
                verifyIteration: ev.verifyIteration ?? existing.verifyIteration,
                verifyIterationLimit: existing.verifyIterationLimit,
                agents: existing.agents,
                executions: existing.executions,
                terminalReasonCode: existing.terminalReasonCode,
                terminalErrorMessage: existing.terminalErrorMessage,
                rateLimitErrorMessage: existing.rateLimitErrorMessage,
                startedAt: existing.startedAt,
                durationMs: existing.durationMs,
                errorCode: existing.errorCode,
                retryable: existing.retryable,
                coordinationState: existing.coordinationState,
                coordinationReason: existing.coordinationReason,
                coordinationScope: existing.coordinationScope,
                coordinationPeerNodeID: existing.coordinationPeerNodeID,
                coordinationPeerNodeName: existing.coordinationPeerNodeName,
                coordinationPeerProject: existing.coordinationPeerProject,
                coordinationPeerWorkspace: existing.coordinationPeerWorkspace,
                coordinationQueueIndex: existing.coordinationQueueIndex
            )
            if self.upsertEvolutionWorkspaceItem(updated) {
                self.scheduleWorkspaceSidebarStatusRefresh(
                    projectNames: [ev.project],
                    debounce: 0.2
                )
            }
            if shouldReconcileTerminalSnapshot {
                // stopped 事件只带轻量状态，终态耗时/执行时间线仍以快照为准。
                self.scheduleEvolutionSnapshotFallback(
                    project: ev.project,
                    workspace: workspace,
                    reason: "workspace_stopped_terminal_reconcile"
                )
            }
        }
    }

    /// 直接处理 evo_cycle_updated 事件，在不触发全量快照刷新的情况下更新单个工作空间状态。
    /// 若对应工作空间尚不存在则回退到 pulse（触发全量刷新）。
    func handleEvolutionCycleUpdated(_ ev: EvoCycleUpdatedV2) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.assertEvolutionStateAccessOnMainThread()
            let workspace = self.normalizeEvolutionWorkspaceName(ev.workspace)
            let key = self.globalWorkspaceKey(projectName: ev.project, workspaceName: workspace)
            guard let existing = self.evolutionWorkspaceItemIndexByKey[key] else {
                self.scheduleEvolutionSnapshotFallback(
                    project: ev.project,
                    workspace: workspace,
                    reason: "missing_cycle_update_item"
                )
                return
            }
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
                terminalReasonCode: ev.terminalReasonCode,
                terminalErrorMessage: ev.terminalErrorMessage,
                rateLimitErrorMessage: ev.rateLimitErrorMessage,
                startedAt: ev.startedAt ?? existing.startedAt,
                durationMs: ev.durationMs ?? existing.durationMs,
                errorCode: ev.errorCode ?? existing.errorCode,
                retryable: ev.retryable,
                recovery: ev.recovery ?? existing.recovery,
                coordinationState: ev.coordinationState ?? existing.coordinationState,
                coordinationReason: ev.coordinationReason ?? existing.coordinationReason,
                coordinationScope: ev.coordinationScope ?? existing.coordinationScope,
                coordinationPeerNodeID: ev.coordinationPeerNodeID ?? existing.coordinationPeerNodeID,
                coordinationPeerNodeName: ev.coordinationPeerNodeName ?? existing.coordinationPeerNodeName,
                coordinationPeerProject: ev.coordinationPeerProject ?? existing.coordinationPeerProject,
                coordinationPeerWorkspace: ev.coordinationPeerWorkspace ?? existing.coordinationPeerWorkspace,
                coordinationQueueIndex: ev.coordinationQueueIndex ?? existing.coordinationQueueIndex
            )
            guard existing.projectionSignature != updated.projectionSignature else { return }
            let itemApplyMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            TFLog.perf.info("perf evolution_item_apply_ms=\(itemApplyMs, privacy: .public) key=\(key, privacy: .public)")
            let didUpdate = self.upsertEvolutionWorkspaceItem(updated)
            if didUpdate {
                self.cancelEvolutionSnapshotFallback(project: ev.project, workspace: workspace)
                self.evolutionTargetedSnapshotMergeKeys.remove(key)
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
        let startedAt = CFAbsoluteTimeGetCurrent()
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
                self.assertEvolutionStateAccessOnMainThread()
                if self.evolutionScheduler != snapshot.scheduler {
                    self.evolutionScheduler = snapshot.scheduler
                }
                if items.isEmpty && !self.evolutionTargetedSnapshotMergeKeys.isEmpty {
                    return
                }
                let mergeKeys = items.map(\.workspaceKey)
                let shouldMerge = !mergeKeys.isEmpty &&
                    mergeKeys.allSatisfy { self.evolutionTargetedSnapshotMergeKeys.contains($0) }
                if shouldMerge {
                    self.mergeEvolutionWorkspaceItems(items)
                    for key in mergeKeys {
                        self.evolutionTargetedSnapshotMergeKeys.remove(key)
                    }
                } else {
                    self.replaceEvolutionWorkspaceItems(items)
                    self.evolutionTargetedSnapshotMergeKeys.subtract(mergeKeys)
                }
                let itemApplyMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                TFLog.perf.info("perf evolution_item_apply_ms=\(itemApplyMs, privacy: .public) count=\(items.count, privacy: .public)")
                if !items.isEmpty {
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

    /// 使用 system_snapshot 的 Evolution 摘要更新工作区列表，避免重连后重复拉取 evo_snapshot。
    func handleSystemEvolutionWorkspaceSummaries(
        _ summaries: [SystemSnapshotEvolutionWorkspaceSummary]
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.assertEvolutionStateAccessOnMainThread()
            let existingByKey = self.evolutionWorkspaceItemIndexByKey
            let items = summaries
                .map { summary in
                    let workspace = self.normalizeEvolutionWorkspaceName(summary.workspace)
                    let key = self.globalWorkspaceKey(projectName: summary.project, workspaceName: workspace)
                    let normalizedSummary = SystemSnapshotEvolutionWorkspaceSummary(
                        project: summary.project,
                        workspace: workspace,
                        status: summary.status,
                        cycleID: summary.cycleID,
                        title: summary.title,
                        failureReason: summary.failureReason
                    )
                    return normalizedSummary.toWorkspaceItem(preserving: existingByKey[key])
                }
                .sorted { ($0.project, $0.workspace) < ($1.project, $1.workspace) }

            self.replaceEvolutionWorkspaceItems(items)
            for item in items {
                let key = item.workspaceKey
                if let pendingAction = self.evolutionPendingActionByWorkspace[key],
                   EvolutionControlCapability.shouldClearPendingAction(
                    pendingAction,
                    currentStatus: item.status
                ) {
                    self.evolutionPendingActionByWorkspace.removeValue(forKey: key)
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
        assertEvolutionStateAccessOnMainThread()
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

    func handleEvolutionError(_ message: String, project: String? = nil, workspace: String? = nil) {
        assertEvolutionStateAccessOnMainThread()
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

    func handleAISessionSubscribeAck(_ ev: AISessionSubscribeAck) {
        if let replayRequest = pendingEvolutionReplayHistoryLoadRequest,
           replayRequest.sessionId == ev.sessionId {
            defer { pendingEvolutionReplayHistoryLoadRequest = nil }
            if evolutionReplayStore.messages.isEmpty {
                TFLog.app.info(
                    "AI replay subscribe ack: reload history, tool=\(replayRequest.aiTool.rawValue, privacy: .public), session_id=\(replayRequest.sessionId, privacy: .public)"
                )
                wsClient.requestAISessionMessages(
                    projectName: replayRequest.projectName,
                    workspaceName: replayRequest.workspaceName,
                    aiTool: replayRequest.aiTool,
                    sessionId: replayRequest.sessionId,
                    limit: replayRequest.limit
                )
            }
        }

        // 遍历所有工具，消费有待处理的订阅上下文
        for tool in AIChatTool.allCases {
            guard let ctx = pendingSubscribeContextByTool[tool] else { continue }
            guard ctx.session.id == ev.sessionId else { continue }
            // 多工作区边界防护：ack 中的工作区字段非空时，必须与待确认上下文一致。
            if !ev.projectName.isEmpty, !ev.workspaceName.isEmpty {
                guard ev.projectName == ctx.session.projectName,
                      ev.workspaceName == ctx.session.workspaceName else {
                    TFLog.app.warning(
                        "AI subscribe ack workspace mismatch: ack=(\(ev.projectName, privacy: .public)/\(ev.workspaceName, privacy: .public)) ctx=(\(ctx.session.projectName, privacy: .public)/\(ctx.session.workspaceName, privacy: .public)) session_id=\(ev.sessionId, privacy: .public)"
                    )
                    continue
                }
            }
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

    @MainActor
    func handleClientErrorMessage(_ errorMsg: String) {
        aiSessionListStore.handleClientError()
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

        if pendingEvolutionPlanDocumentReadPath != nil {
            pendingEvolutionPlanDocumentReadPath = nil
            evolutionPlanDocumentLoading = false
            evolutionPlanDocumentError = errorMsg
        }

        // 历史分页请求失败时，避免“加载更早消息”按钮长期停留在 loading。
        for tool in AIChatTool.allCases {
            aiStore(for: tool).setHistoryLoading(false)
            aiStore(for: tool).setRecentHistoryLoading(false)
        }
    }

    @MainActor
    func handleHTTPReadFailure(_ failure: WSClient.HTTPReadFailure) {
        guard let context = failure.context else { return }

        switch context {
        case let .aiProviderList(project, workspace, aiTool):
            guard shouldAcceptAISelectorEvent(
                projectName: project,
                workspaceName: workspace,
                aiTool: aiTool,
                kind: .providerList
            ) else { return }
            if aiChatTool == aiTool,
               selectedProjectName == project,
               selectedWorkspaceKey == workspace,
               isAILoadingModels {
                isAILoadingModels = false
            }
            consumeAISelectorBootstrapContextIfNeeded(
                projectName: project,
                workspaceName: workspace,
                aiTool: aiTool,
                kind: .providerList
            )
        case let .aiAgentList(project, workspace, aiTool):
            guard shouldAcceptAISelectorEvent(
                projectName: project,
                workspaceName: workspace,
                aiTool: aiTool,
                kind: .agentList
            ) else { return }
            if aiChatTool == aiTool,
               selectedProjectName == project,
               selectedWorkspaceKey == workspace,
               isAILoadingAgents {
                isAILoadingAgents = false
            }
            consumeAISelectorBootstrapContextIfNeeded(
                projectName: project,
                workspaceName: workspace,
                aiTool: aiTool,
                kind: .agentList
            )
        case let .fileRead(project, workspace, path):
            if pendingEvolutionPlanDocumentReadPath == path,
               selectedProjectName == project,
               selectedWorkspaceKey == workspace {
                pendingEvolutionPlanDocumentReadPath = nil
                evolutionPlanDocumentLoading = false
                evolutionPlanDocumentError = failure.message
            }

            let key = EditorRequestKey(project: project, workspace: workspace, path: path)
            guard pendingFileReadRequests.contains(key) else { return }
            pendingFileReadRequests.remove(key)

            let globalKey = globalWorkspaceKey(projectName: project, workspaceName: workspace)
            var workspaceDocs = editorDocumentsByWorkspace[globalKey] ?? [:]
            workspaceDocs[path] = EditorDocumentState(
                path: path,
                content: "",
                originalContentHash: 0,
                isDirty: false,
                lastLoadedAt: Date(),
                status: .error(failure.message),
                conflictState: .none
            )
            editorDocumentsByWorkspace[globalKey] = workspaceDocs
        }
    }

    /// 处理来自 Core 的结构化错误（通过 errorCode 决定状态迁移，避免字符串匹配漂移）
    ///
    /// 多工作区安全：错误仅影响归属的 project/workspace，不污染当前上下文。
    @MainActor
    func handleCoreError(_ error: CoreError) {
        // 过滤：跨工作区的错误不影响当前选中工作区的状态
        let belongsToCurrentContext = error.belongsTo(
            project: selectedProjectName.isEmpty ? nil : selectedProjectName,
            workspace: selectedWorkspaceKey
        )

        // 对可恢复错误只记录日志，不改变状态
        if error.code.isRecoverable {
            TFLog.app.info(
                "Recoverable Core error (code=\(error.code.rawValue, privacy: .public)): \(error.message, privacy: .public)"
            )
            if belongsToCurrentContext {
                handleClientErrorMessage(error.message)
            }
            return
        }

        // 多工作区定位：只有归属当前工作区的错误才触发 UI 更新
        guard belongsToCurrentContext else {
            TFLog.app.warning(
                "Ignoring Core error for other workspace: code=\(error.code.rawValue, privacy: .public) project=\(error.project ?? "nil", privacy: .public) workspace=\(error.workspace ?? "nil", privacy: .public)"
            )
            return
        }

        switch error.code {
        case .authenticationFailed, .authenticationRevoked:
            connectionPhase = .authenticationFailed(reason: error.message)
            handleClientErrorMessage(error.message)
        case .evolutionError, .artifactContractViolation, .managedBacklogSyncFailed:
            handleEvolutionError(error.message, project: error.project, workspace: error.workspace)
        case .aiSessionError:
            // AI 会话错误已由 AIChatErrorV2 路径处理，这里只补充日志
            TFLog.app.error(
                "AI session error from Core: session=\(error.sessionId ?? "nil", privacy: .public), msg=\(error.message, privacy: .public)"
            )
        default:
            handleClientErrorMessage(error.message)
        }
    }

    func handleAIContextSnapshotUpdated(_ json: [String: Any]) {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiToolRaw = json["ai_tool"] as? String,
              let aiTool = AIChatTool(rawValue: aiToolRaw),
              let sessionId = json["session_id"] as? String,
              let snapshotJson = json["snapshot"] as? [String: Any],
              let snapshot = AISessionContextSnapshot.from(json: snapshotJson) else { return }
        let key = AISessionSemantics.contextSnapshotKey(
            project: projectName,
            workspace: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId
        )
        DispatchQueue.main.async {
            self.aiSessionContextSnapshots[key] = snapshot
        }
    }

    // MARK: - v1.45: 智能演化分析摘要处理

    /// 处理 system_snapshot 中的 `analysis_summaries`，使用全量替换策略
    ///
    /// 每次 system_snapshot 到达时，用本次快照的摘要集合完整替换缓存，
    /// 避免历史循环的陈旧摘要残留到下一次快照中。
    func handleSystemEvolutionAnalysisSummaries(_ summaries: [EvolutionAnalysisSummary]) {
        let updated = Dictionary(uniqueKeysWithValues: summaries.map { summary in
            let key = "\(summary.project):\(summary.workspace):\(summary.cycleId)"
            return (key, summary)
        })
        DispatchQueue.main.async {
            self.analysisSummaries = updated
        }
    }
}
