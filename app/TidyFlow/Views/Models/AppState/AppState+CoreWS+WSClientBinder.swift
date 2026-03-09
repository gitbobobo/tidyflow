import Foundation
import TidyFlowShared

extension AppState {
    // MARK: - WebSocket Setup

    func setupWSClient(port: Int) {
        // 设置日志转发引用
        TFLog.wsClient = wsClient
        // 切换到当前 Core 会话 token，确保仅本次进程可连接
        wsClient.updateAuthToken(coreProcessManager.wsAuthToken)
        wsClient.onServerEnvelopeMeta = { [weak self] meta in
            self?.wsLastEnvelopeSeq = meta.seq
            self?.wsLastEnvelopeSummary = "\(meta.domain)/\(meta.action) [\(meta.kind)]"
        }

        wsClient.onConnectionStateChanged = { [weak self] connected in
            if connected {
                self?.connectionPhase = .connected
                self?.markStartupReadyIfNeeded()
                self?.reconnectAttempt = 0  // 重置自动重连计数
                self?.wsClient.requestListProjects()
                self?.wsClient.requestGetClientSettings()
                self?.reloadAISessionDataAfterReconnect()
                self?.wsClient.requestEvoSnapshot()
                self?.wsClient.requestSystemSnapshot()
                // 重连后尝试附着已有终端会话
                self?.requestTerminalReattach()
            } else if let phase = ConnectionPhase.evaluateDisconnect(
                isIntentional: self?.wsClient.isIntentionalDisconnect ?? true,
                isCoreAvailable: self?.coreProcessManager.isRunning ?? false
            ) {
                // 主动断开或 Core 不可用：直接设置确定阶段
                self?.connectionPhase = phase
            } else {
                // 意外断连且 Core 仍在运行：通过共享语义层触发自动重连
                TFLog.core.warning("WebSocket 意外断连，触发自动重连")
                self?.markAllTerminalSessionsStale()
                self?.startAutoReconnect()
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
            DispatchQueue.main.async {
                self?.fileCache.updateCacheMetrics(metrics)
                self?.gitCache.updateCacheMetrics(metrics)
            }
        }

        // v1.41: 系统健康快照（Core 权威真源）- 更新共享健康状态，双端统一消费
        wsClient.onHealthSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.systemHealthSnapshot = snapshot
            }
        }

        // v1.41: 修复执行结果 - 更新 incident 修复状态
        wsClient.onHealthRepairResult = { [weak self] audit in
            DispatchQueue.main.async {
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
        }

        // Connect to the dynamic port
        wsClient.connect(port: port)
    }
}
