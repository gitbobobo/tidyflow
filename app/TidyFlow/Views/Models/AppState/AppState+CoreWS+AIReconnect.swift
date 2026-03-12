import Foundation

extension AppState {
    /// 向后兼容包装：委托到共享语义层。
    static func rebuildPendingQuestionRequests(
        sessionId: String,
        messages: [AIProtocolMessageInfo]
    ) -> [AIQuestionRequestInfo] {
        AISessionSemantics.rebuildPendingQuestionRequests(sessionId: sessionId, messages: messages)
    }

    static func parseQuestionInfos(from value: Any?) -> [AIQuestionInfo] {
        AISessionSemantics.parseQuestionInfos(from: value)
    }

    static func stringValue(_ value: Any?) -> String? {
        AISessionSemantics.stringValue(value)
    }

    /// 会话状态兜底收敛：避免 done/error 事件丢失时，输入区长期停留在“停止中”。
    func reconcileAIStreamStateFromSessionStatus(
        aiTool: AIChatTool,
        sessionId: String,
        status: String
    ) {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedStatus == "busy" ||
            normalizedStatus == "running" ||
            normalizedStatus == "retry" ||
            normalizedStatus == "awaiting_input" {
            return
        }

        let store = aiStore(for: aiTool)
        guard store.subscribedSessionIds.contains(sessionId) else { return }

        let hasLocalStreamingState =
            store.isStreaming ||
            store.awaitingUserEcho ||
            store.isAbortPending(for: sessionId)
        guard hasLocalStreamingState else { return }

        TFLog.app.warning(
            "AI stream reconciled by session status: ai_tool=\(aiTool.rawValue, privacy: .public), session_id=\(sessionId, privacy: .public), status=\(normalizedStatus, privacy: .public)"
        )
        store.handleChatDone(sessionId: sessionId)
        setBadgeRunning(false, for: aiTool)
    }

    // MARK: - 系统唤醒探活 + 自动重连

    // 退避策略常量由共享 ReconnectPolicy 提供，确保 macOS/iOS 使用同一份参数。
    private static let aiSessionListLimit = 50
    func reloadAISessionDataAfterReconnect() {
        deferredAISessionReloadWorkItem?.cancel()
        deferredAISessionReloadWorkItem = nil
        guard let workspace = selectedWorkspaceKey, !workspace.isEmpty else {
            TFLog.app.debug("AI reconnect reload skipped: workspace not selected")
            return
        }

        // 捕获重连时刻的工作区快照，防止异步路径中工作区切换导致 session 状态回放到错误工作区
        let workspaceSnapshot = workspace
        let projectSnapshot = selectedProjectName

        // 通知舞台状态机进入恢复阶段
        if let sessionId = aiStore(for: aiChatTool).currentSessionId, !sessionId.isEmpty {
            aiChatStageLifecycle.apply(.resume(sessionId: sessionId))
        }

        _ = requestAISessionList(for: sessionPanelFilter, limit: Self.aiSessionListLimit, force: true)

        // 若某工具已有选中会话，则补拉详情，避免断线窗口内响应丢失导致空白。
        // 工作区边界校验：仅在当前工作区未发生切换时继续回放，避免 session 状态串台。
        for tool in AIChatTool.allCases {
            let store = aiStore(for: tool)
            guard let sessionId = store.currentSessionId, !sessionId.isEmpty else { continue }

            // 工作区快照一致性检查：防止重连期间工作区切换导致旧 session 回放到新工作区
            guard selectedWorkspaceKey == workspaceSnapshot, selectedProjectName == projectSnapshot else {
                TFLog.app.warning(
                    "AI reconnect reload aborted: workspace changed during reload, tool=\(tool.rawValue, privacy: .public)"
                )
                aiChatStageLifecycle.apply(.forceReset)
                return
            }

            TFLog.app.info(
                "AI reconnect reload: request session messages, tool=\(tool.rawValue, privacy: .public), session_id=\(sessionId, privacy: .public)"
            )
            let context = AISessionHistoryCoordinator.Context(
                project: projectSnapshot,
                workspace: workspaceSnapshot,
                aiTool: tool,
                sessionId: sessionId
            )
            AISessionHistoryCoordinator.subscribeAndLoadRecent(
                context: context,
                wsClient: wsClient,
                store: store,
                cacheMode: .forceRefresh
            )
        }

        // 恢复完成后迁移到 active
        aiChatStageLifecycle.apply(.resumeCompleted)
    }

    func handleSceneDidBecomeActive() {
        TFLog.core.info("应用切回活跃态，延迟探活 WebSocket")
        // 延迟 1s 等待系统网络栈恢复
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.probeAndReconnectIfNeeded()
        }
    }

    func probeAndReconnectIfNeeded() {
        wsClient.sendPing(timeout: 2.0) { [weak self] alive in
            DispatchQueue.main.async {
                if alive {
                    TFLog.core.info("WebSocket 探活成功，无需重连")
                } else {
                    TFLog.core.warning("WebSocket 探活失败，触发自动重连")
                    self?.markAllTerminalSessionsStale()
                    self?.startAutoReconnect()
                }
            }
        }
    }

    func startAutoReconnect() {
        // 使用共享语义层统一判断：排除已在重连、主动断开、配对失败、重连耗尽
        guard connectionPhase.allowsAutoReconnect else {
            TFLog.core.info("当前连接阶段不允许自动重连，跳过: phase=\(String(describing: self.connectionPhase), privacy: .public)")
            return
        }
        reconnectAttempt = 0
        attemptReconnect()
    }

    func attemptReconnect() {
        let nextPhase = ConnectionPhase.nextReconnectPhase(currentAttempt: reconnectAttempt)
        if case .reconnectFailed = nextPhase {
            TFLog.core.error("自动重连失败，已达最大重试次数 \(ReconnectPolicy.maxAttempts)")
            connectionPhase = .reconnectFailed
            return
        }

        let delay = ReconnectPolicy.delay(for: reconnectAttempt + 1)
        reconnectAttempt += 1
        connectionPhase = nextPhase
        TFLog.core.info("自动重连第 \(self.reconnectAttempt) 次，延迟 \(delay)s")

        // 重连 Swift WSClient (WS①)
        wsClient.reconnect()

        // 等待连接结果后判断是否需要继续重试
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 2.0) { [weak self] in
            guard let self else { return }
            if self.connectionPhase.isConnected {
                TFLog.core.info("自动重连成功")
                self.reconnectAttempt = 0
            } else {
                self.attemptReconnect()
            }
        }
    }
}
