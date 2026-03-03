import Foundation

extension AppState {
    static func rebuildPendingQuestionRequests(
        sessionId: String,
        messages: [AIProtocolMessageInfo]
    ) -> [AIQuestionRequestInfo] {
        var requests: [AIQuestionRequestInfo] = []
        var seenRequestIDs: Set<String> = []

        for message in messages {
            for part in message.parts {
                guard part.partType == "tool" else { continue }
                let toolName = (part.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard toolName == "question" else { continue }
                guard let stateDict = part.toolState else { continue }

                let status = ((stateDict["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // 仅重建未结束的 question，避免把已完成历史误判为待处理。
                if status == "completed" || status == "error" || status == "failed" || status == "done" {
                    continue
                }

                let input = stateDict["input"] as? [String: Any]
                let questionsValue = input?["questions"] ?? stateDict["questions"]
                let questions = parseQuestionInfos(from: questionsValue)
                guard !questions.isEmpty else { continue }

                let metadata = part.toolPartMetadata ?? [:]
                let requestId =
                    stringValue(metadata["request_id"]) ??
                    stringValue(metadata["requestId"]) ??
                    stringValue(stateDict["request_id"]) ??
                    stringValue(stateDict["requestId"]) ??
                    stringValue((stateDict["metadata"] as? [String: Any])?["request_id"]) ??
                    stringValue((stateDict["metadata"] as? [String: Any])?["requestId"]) ??
                    part.toolCallId
                guard let requestId, !requestId.isEmpty else { continue }
                guard !seenRequestIDs.contains(requestId) else { continue }
                seenRequestIDs.insert(requestId)

                let toolMessageId =
                    stringValue(metadata["tool_message_id"]) ??
                    stringValue(metadata["toolMessageId"]) ??
                    part.id

                requests.append(
                    AIQuestionRequestInfo(
                        id: requestId,
                        sessionId: sessionId,
                        questions: questions,
                        toolMessageId: toolMessageId,
                        toolCallId: part.toolCallId
                    )
                )
            }
        }

        return requests
    }

    static func parseQuestionInfos(from value: Any?) -> [AIQuestionInfo] {
        if let array = value as? [[String: Any]] {
            return array.compactMap { AIQuestionInfo.from(json: $0) }
        }
        if let array = value as? [Any] {
            return array.compactMap { item in
                guard let dict = item as? [String: Any] else { return nil }
                return AIQuestionInfo.from(json: dict)
            }
        }
        if let dict = value as? [String: Any], let nested = dict["questions"] {
            return parseQuestionInfos(from: nested)
        }
        return []
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    /// 会话状态兜底收敛：避免 done/error 事件丢失时，输入区长期停留在“停止中”。
    func reconcileAIStreamStateFromSessionStatus(
        aiTool: AIChatTool,
        sessionId: String,
        status: String
    ) {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedStatus == "busy" || normalizedStatus == "running" || normalizedStatus == "retry" {
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

    private static let maxReconnectAttempts = 5
    private static let reconnectDelays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0]
    private static let aiSessionListLimit = 50
    private static let aiDeferredSessionReloadDelay: TimeInterval = 0.35

    func reloadAISessionDataAfterReconnect() {
        deferredAISessionReloadWorkItem?.cancel()
        deferredAISessionReloadWorkItem = nil
        guard let workspace = selectedWorkspaceKey, !workspace.isEmpty else {
            TFLog.app.debug("AI reconnect reload skipped: workspace not selected")
            return
        }

        // 当前工具优先，减少首轮大包对连接稳定性的冲击。
        let currentTool = aiChatTool
        wsClient.requestAISessionList(
            projectName: selectedProjectName,
            workspaceName: workspace,
            aiTool: currentTool,
            limit: Self.aiSessionListLimit
        )
        let delayedTools = AIChatTool.allCases.filter { $0 != currentTool }
        if !delayedTools.isEmpty {
            let expectedProject = selectedProjectName
            let expectedWorkspace = workspace
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.selectedProjectName == expectedProject,
                      self.selectedWorkspaceKey == expectedWorkspace else { return }
                for tool in delayedTools {
                    self.wsClient.requestAISessionList(
                        projectName: expectedProject,
                        workspaceName: expectedWorkspace,
                        aiTool: tool,
                        limit: Self.aiSessionListLimit
                    )
                }
            }
            deferredAISessionReloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.aiDeferredSessionReloadDelay,
                execute: workItem
            )
        }

        // 若某工具已有选中会话，则补拉详情，避免断线窗口内响应丢失导致空白。
        for tool in AIChatTool.allCases {
            let store = aiStore(for: tool)
            guard let sessionId = store.currentSessionId, !sessionId.isEmpty else { continue }
            TFLog.app.info(
                "AI reconnect reload: request session messages, tool=\(tool.rawValue, privacy: .public), session_id=\(sessionId, privacy: .public)"
            )
            wsClient.requestAISessionSubscribe(
                project: selectedProjectName,
                workspace: workspace,
                aiTool: tool.rawValue,
                sessionId: sessionId
            )
            wsClient.requestAISessionMessages(
                projectName: selectedProjectName,
                workspaceName: workspace,
                aiTool: tool,
                sessionId: sessionId,
                limit: 50
            )
        }
    }

    func handleSystemWake() {
        TFLog.core.info("系统唤醒，延迟探活 WebSocket")
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
        // 防止重复触发（唤醒探活 + 意外断连回调可能同时触发）
        guard reconnectAttempt == 0 else {
            TFLog.core.info("自动重连已在进行中，跳过")
            return
        }
        attemptReconnect()
    }

    func attemptReconnect() {
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            TFLog.core.error("自动重连失败，已达最大重试次数 \(Self.maxReconnectAttempts)")
            return
        }

        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        TFLog.core.info("自动重连第 \(self.reconnectAttempt) 次，延迟 \(delay)s")

        // 重连 Swift WSClient (WS①)
        wsClient.reconnect()

        // 等待连接结果后判断是否需要继续重试
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 2.0) { [weak self] in
            guard let self else { return }
            if self.connectionState == .connected {
                TFLog.core.info("自动重连成功")
                self.reconnectAttempt = 0
            } else {
                self.attemptReconnect()
            }
        }
    }
}
