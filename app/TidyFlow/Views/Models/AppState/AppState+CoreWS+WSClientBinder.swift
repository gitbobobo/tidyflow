import Foundation
import TidyFlowShared

extension AppState {
    // MARK: - WebSocket Setup

    func setupWSClient(port: Int) {
        // 切换到当前 Core 会话 token，确保仅本次进程可连接
        let authToken = coreProcessManager.wsAuthToken
        wsClient.updateAuthToken(authToken)
        let targetIdentity = "\(authToken ?? "")@\(port)"
        wsClient.onServerEnvelopeMeta = { [weak self] meta in
            self?.wsLastEnvelopeSeq = meta.seq
            self?.wsLastEnvelopeSummary = "\(meta.domain)/\(meta.action) [\(meta.kind)]"
        }
        wsClient.onHTTPReadFailure = { [weak self] failure in
            Task { @MainActor [weak self] in
                self?.handleHTTPReadFailure(failure)
            }
        }

        wsClient.onConnectionStateChanged = { [weak self] connected in
            guard let self else { return }
            if connected {
                self.connectionPhase = .connected
                self.markStartupReadyIfNeeded()
                self.reconnectAttempt = 0  // 重置自动重连计数
                let connectionIdentity = self.wsClient.connectionIdentity ?? targetIdentity
                guard self.initializedWSConnectionIdentity != connectionIdentity else {
                    return
                }
                self.initializedWSConnectionIdentity = connectionIdentity
                self.wsClient.requestListProjects(cacheMode: .forceRefresh)
                self.wsClient.requestGetClientSettings(cacheMode: .forceRefresh)
                self.reloadAISessionDataAfterReconnect()
                self.wsClient.requestSystemSnapshot(cacheMode: .forceRefresh)
                // 重连后尝试附着已有终端会话
                self.requestTerminalReattach()
            } else {
                // 断连时强制重置 AI 聊天舞台，防止旧工作区的 active/resuming 投影残留
                self.forceResetAIChatStage()
                // 断连时重置所有文件相位，避免残留的 watching/indexing 状态
                self.fileCache.resetAllPhasesOnDisconnect()
                // 断连时清除协调层状态缓存，防止旧工作区协调状态残留到重连后的新会话
                self.coordinatorStateCache.apply(.clear)

                if let phase = ConnectionPhase.evaluateDisconnect(
                    isIntentional: self.wsClient.isIntentionalDisconnect,
                    isCoreAvailable: self.coreProcessManager.isRunning
                ) {
                    // 主动断开或 Core 不可用：直接设置确定阶段
                    self.connectionPhase = phase
                } else {
                    // 意外断连且 Core 仍在运行：通过共享语义层触发自动重连
                    TFLog.core.warning("WebSocket 意外断连，触发自动重连")
                    self.markAllTerminalSessionsStale()
                    self.startAutoReconnect()
                }
            }
        }

        // 新路径：按领域 handler 绑定，替代大量 onXxx 闭包接线
        let gitHandler = AppStateGitMessageHandlerAdapter(appState: self)
        let projectHandler = AppStateProjectMessageHandlerAdapter(appState: self)
        let fileHandler = AppStateFileMessageHandlerAdapter(appState: self)
        let settingsHandler = AppStateSettingsMessageHandlerAdapter(appState: self)
        let terminalHandler = AppStateTerminalMessageHandlerAdapter(appState: self)
        let aiHandler = AppStateAIMessageHandlerAdapter(appState: self)
        let evidenceHandler = AppStateEvidenceMessageHandlerAdapter(appState: self)
        let evolutionHandler = AppStateEvolutionMessageHandlerAdapter(appState: self)
        let errorHandler = AppStateErrorMessageHandlerAdapter(appState: self)
        wsGitMessageHandler = gitHandler
        wsProjectMessageHandler = projectHandler
        wsFileMessageHandler = fileHandler
        wsSettingsMessageHandler = settingsHandler
        wsTerminalMessageHandler = terminalHandler
        wsAIMessageHandler = aiHandler
        wsEvidenceMessageHandler = evidenceHandler
        wsEvolutionMessageHandler = evolutionHandler
        wsErrorMessageHandler = errorHandler
        wsClient.gitMessageHandler = gitHandler
        wsClient.projectMessageHandler = projectHandler
        wsClient.fileMessageHandler = fileHandler
        wsClient.settingsMessageHandler = settingsHandler
        wsClient.terminalMessageHandler = terminalHandler
        wsClient.aiMessageHandler = aiHandler
        wsClient.evidenceMessageHandler = evidenceHandler
        wsClient.evolutionMessageHandler = evolutionHandler
        wsClient.errorMessageHandler = errorHandler

        // 工作区缓存可观测性快照：更新 FileCacheState 和 GitCacheState 的 Core 权威指标
        wsClient.onSystemSnapshot = { [weak self] metrics in
            guard let self else { return }
            self.fileCache.updateCacheMetrics(metrics)
            self.gitCache.updateCacheMetrics(metrics)
        }

        // 工作区 Evolution 摘要：由 system_snapshot 驱动种子/更新工作区运行态摘要
        wsClient.onEvolutionWorkspaceSummaries = { [weak self] summaries in
            self?.handleSystemEvolutionWorkspaceSummaries(summaries)
        }

        // v1.42: 统一可观测性快照 — 更新共享观测状态，双端统一消费
        wsClient.onObservabilitySnapshot = { [weak self] snapshot in
            self?.observabilitySnapshot = snapshot
        }

        // WI-001: 全链路性能可观测快照
        wsClient.onPerformanceObservability = { [weak self] snapshot in
            self?.performanceObservability = snapshot
        }

        // v1.41: 系统健康快照（Core 权威真源）- 更新共享健康状态，双端统一消费
        wsClient.onHealthSnapshot = { [weak self] snapshot in
            self?.systemHealthSnapshot = snapshot
        }

        // v1.41: 修复执行结果 - 更新 incident 修复状态
        wsClient.onHealthRepairResult = { [weak self] audit in
            guard let self else { return }
            if let incidentId = audit.incidentId {
                let project = audit.context.project
                let workspace = audit.context.workspace
                let key = "\(project ?? ""):\(workspace ?? ""):\(incidentId)"
                switch audit.outcome {
                case .success, .alreadyHealthy:
                    self.incidentRepairStates[key] = .repaired(requestId: audit.requestId)
                case .failed:
                    self.incidentRepairStates[key] = .repairFailed(
                        requestId: audit.requestId,
                        summary: audit.resultSummary
                    )
                case .partialSuccess:
                    self.incidentRepairStates[key] = .repaired(requestId: audit.requestId)
                }
            }
        }

        // 工作区恢复状态摘要：从 system_snapshot workspace_items 提取，按 (project, workspace) 隔离
        wsClient.onWorkspaceRecoverySummaries = { [weak self] summaries in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for summary in summaries {
                    let key = "\(summary.project):\(summary.workspace)"
                    self.workspaceRecoverySummaries[key] = summary
                }
            }
        }

        // v1.46: coordinator_snapshot 增量更新 + system_snapshot 种子恢复
        // 两路均复用同一 callback，WSClient 在 system_snapshot 解析时也会为每个 workspace_item 触发此回调
        wsClient.onCoordinatorSnapshot = { [weak self] payload in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let id = payload.workspaceId
                let existing = self.coordinatorStateCache.state(for: id)
                let updated = payload.toWorkspaceCoordinatorState(existing: existing)
                self.coordinatorStateCache.apply(.updateWorkspace(updated))
            }
        }

        if configuredWSConnectionTarget == targetIdentity,
           wsClient.currentURL == AppConfig.makeWsURL(port: port, token: authToken),
           (wsClient.isConnected || wsClient.isConnecting) {
            return
        }
        configuredWSConnectionTarget = targetIdentity
        initializedWSConnectionIdentity = nil
        // Connect to the dynamic port
        wsClient.connect(port: port)
    }
}
