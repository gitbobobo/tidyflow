import Foundation

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
            self?.connectionState = connected ? .connected : .disconnected
            if connected {
                self?.reconnectAttempt = 0  // 重置自动重连计数
                self?.wsClient.requestListProjects()
                self?.wsClient.requestGetClientSettings()
                self?.reloadAISessionDataAfterReconnect()
                self?.wsClient.requestEvoSnapshot()
                // 重连后尝试附着已有终端会话
                self?.requestTerminalReattach()
            } else if !(self?.wsClient.isIntentionalDisconnect ?? true),
                      self?.coreProcessManager.isRunning == true {
                // 意外断连且 Core 仍在运行，触发自动重连
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

        // Connect to the dynamic port
        wsClient.connect(port: port)
    }
}
