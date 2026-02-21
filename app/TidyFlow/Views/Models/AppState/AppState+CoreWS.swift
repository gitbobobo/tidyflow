import Foundation
import AppKit
import Darwin

private struct PairStartHTTPResponse: Decodable {
    let pairCode: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case pairCode = "pair_code"
        case expiresAt = "expires_at"
    }
}

private struct PairErrorHTTPResponse: Decodable {
    let error: String
    let message: String
}

private final class AppStateGitMessageHandlerAdapter: GitMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleGitDiffResult(_ result: GitDiffResult) { appState?.gitCache.handleGitDiffResult(result) }
    func handleGitStatusResult(_ result: GitStatusResult) { appState?.gitCache.handleGitStatusResult(result) }
    func handleGitLogResult(_ result: GitLogResult) { appState?.gitCache.handleGitLogResult(result) }
    func handleGitShowResult(_ result: GitShowResult) { appState?.gitCache.handleGitShowResult(result) }
    func handleGitOpResult(_ result: GitOpResult) { appState?.gitCache.handleGitOpResult(result) }
    func handleGitBranchesResult(_ result: GitBranchesResult) { appState?.gitCache.handleGitBranchesResult(result) }
    func handleGitCommitResult(_ result: GitCommitResult) { appState?.gitCache.handleGitCommitResult(result) }
    func handleGitRebaseResult(_ result: GitRebaseResult) { appState?.gitCache.handleGitRebaseResult(result) }
    func handleGitOpStatusResult(_ result: GitOpStatusResult) { appState?.gitCache.handleGitOpStatusResult(result) }
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) { appState?.gitCache.handleGitMergeToDefaultResult(result) }
    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult) { appState?.gitCache.handleGitIntegrationStatusResult(result) }
    func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult) { appState?.gitCache.handleGitRebaseOntoDefaultResult(result) }
    func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult) { appState?.gitCache.handleGitResetIntegrationWorktreeResult(result) }
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) {
        appState?.gitCache.fetchGitStatus(workspaceKey: notification.workspace)
        appState?.gitCache.fetchGitBranches(workspaceKey: notification.workspace)
    }
    func handleGitAICommitResult(_ result: GitAICommitResult) { appState?.handleGitAICommitResult(result) }
    func handleGitAIMergeResult(_ result: GitAIMergeResult) { appState?.handleGitAIMergeResult(result) }
}

private final class AppStateProjectMessageHandlerAdapter: ProjectMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleProjectsList(_ result: ProjectsListResult) { appState?.handleProjectsList(result) }
    func handleWorkspacesList(_ result: WorkspacesListResult) { appState?.handleWorkspacesList(result) }
    func handleProjectImported(_ result: ProjectImportedResult) { appState?.handleProjectImported(result) }
    func handleWorkspaceCreated(_ result: WorkspaceCreatedResult) { appState?.handleWorkspaceCreated(result) }
    func handleProjectRemoved(_ result: ProjectRemovedResult) {
        if !result.ok {
            TFLog.app.error("移除项目失败: \(result.message ?? "未知错误", privacy: .public)")
        }
    }
    func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult) { appState?.handleWorkspaceRemoved(result) }
    func handleProjectCommandsSaved(_ project: String, _ ok: Bool, _ message: String?) {
        if !ok {
            TFLog.app.warning("项目命令保存失败: \(message ?? "未知错误", privacy: .public)")
        }
    }
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String) {
        appState?.handleProjectCommandStarted(project: project, workspace: workspace, commandId: commandId, taskId: taskId)
    }
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?) {
        appState?.handleProjectCommandCompleted(
            project: project,
            workspace: workspace,
            commandId: commandId,
            taskId: taskId,
            ok: ok,
            message: message
        )
    }
    func handleProjectCommandOutput(_ taskId: String, _ line: String) {
        appState?.handleProjectCommandOutput(taskId: taskId, line: line)
    }
}

private final class AppStateFileMessageHandlerAdapter: FileMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleFileIndexResult(_ result: FileIndexResult) { appState?.handleFileIndexResult(result) }
    func handleFileListResult(_ result: FileListResult) { appState?.handleFileListResult(result) }
    func handleFileRenameResult(_ result: FileRenameResult) { appState?.handleFileRenameResult(result) }
    func handleFileDeleteResult(_ result: FileDeleteResult) { appState?.handleFileDeleteResult(result) }
    func handleFileCopyResult(_ result: FileCopyResult) { appState?.handleFileCopyResult(result) }
    func handleFileMoveResult(_ result: FileMoveResult) { appState?.handleFileMoveResult(result) }
    func handleFileWriteResult(_ result: FileWriteResult) { appState?.handleFileWriteResult(result) }
    func handleFileChanged(_ notification: FileChangedNotification) {
        appState?.invalidateFileCache(project: notification.project, workspace: notification.workspace)
        appState?.notifyEditorFileChanged(notification: notification)
    }
}

private final class AppStateSettingsMessageHandlerAdapter: SettingsMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleClientSettingsResult(_ settings: ClientSettings) {
        guard let appState else { return }
        appState.clientSettings = settings
        appState.clientSettingsLoaded = true
        appState.applyEvolutionProfilesFromClientSettings(settings.evolutionAgentProfiles)
        LocalizationManager.shared.appLanguage = settings.appLanguage
    }

    func handleClientSettingsSaved(_ ok: Bool, _ message: String?) {
        if !ok {
            TFLog.app.error("保存设置失败: \(message ?? "未知错误", privacy: .public)")
        }
    }
}

private final class AppStateTerminalMessageHandlerAdapter: TerminalMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleTermList(_ result: TermListResult) {
        appState?.updateRemoteTerminals(from: result.items)
    }

    func handleRemoteTermChanged() {
        appState?.refreshRemoteTerminals()
    }
}

private final class AppStateLspMessageHandlerAdapter: LspMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleLspDiagnostics(_ result: LspDiagnosticsResult) {
        appState?.handleLspDiagnostics(result)
    }

    func handleLspStatus(_ result: LspStatusResult) {
        appState?.handleLspStatus(result)
    }
}

private final class AppStateAIMessageHandlerAdapter: AIMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleAISessionStarted(_ ev: AISessionStartedV2) { appState?.handleAISessionStarted(ev) }
    func handleAISessionList(_ ev: AISessionListV2) { appState?.handleAISessionList(ev) }
    func handleAISessionMessages(_ ev: AISessionMessagesV2) { appState?.handleAISessionMessages(ev) }
    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) { appState?.handleAISessionStatusResult(ev) }
    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2) { appState?.handleAISessionStatusUpdate(ev) }
    func handleAIChatMessageUpdated(_ ev: AIChatMessageUpdatedV2) { appState?.handleAIChatMessageUpdated(ev) }
    func handleAIChatPartUpdated(_ ev: AIChatPartUpdatedV2) { appState?.handleAIChatPartUpdated(ev) }
    func handleAIChatPartDelta(_ ev: AIChatPartDeltaV2) { appState?.handleAIChatPartDelta(ev) }
    func handleAIChatDone(_ ev: AIChatDoneV2) { appState?.handleAIChatDone(ev) }
    func handleAIChatError(_ ev: AIChatErrorV2) { appState?.handleAIChatError(ev) }
    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2) { appState?.handleAIQuestionAsked(ev) }
    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) { appState?.handleAIQuestionCleared(ev) }
    func handleAIProviderList(_ ev: AIProviderListResult) { appState?.handleAIProviderList(ev) }
    func handleAIAgentList(_ ev: AIAgentListResult) { appState?.handleAIAgentList(ev) }
    func handleAISlashCommands(_ ev: AISlashCommandsResult) { appState?.handleAISlashCommands(ev) }
}

private final class AppStateEvolutionMessageHandlerAdapter: EvolutionMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleEvolutionPulse() { appState?.handleEvolutionPulse() }
    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) { appState?.handleEvolutionSnapshot(snapshot) }
    func handleEvolutionStageChatOpened(_ ev: EvolutionStageChatOpenedV2) { appState?.handleEvolutionStageChatOpened(ev) }
    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2) { appState?.handleEvolutionAgentProfile(ev) }
    func handleEvolutionError(_ message: String) { appState?.handleEvolutionError(message) }
}

private final class AppStateErrorMessageHandlerAdapter: ErrorMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleClientError(_ message: String) {
        appState?.handleClientErrorMessage(message)
    }
}

extension AppState {
    /// 当前会话是否允许生成并使用移动端连接信息（Core 运行即可）
    var remoteAccessReady: Bool {
        coreProcessManager.status.isRunning
    }

    /// 当前可用于移动端连接的局域网 IPv4 地址列表（优先 en* 接口）
    var mobileLanIPv4Addresses: [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var preferred: [String] = []
        var others: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = cursor {
            let iface = current.pointee
            let flags = Int32(iface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp,
               isRunning,
               !isLoopback,
               let sa = iface.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET),
               let cName = iface.ifa_name {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    sa,
                    socklen_t(sa.pointee.sa_len),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(cString: hostBuffer)
                    let name = String(cString: cName)
                    if name.hasPrefix("en") {
                        preferred.append(ip)
                    } else {
                        others.append(ip)
                    }
                }
            }

            cursor = iface.ifa_next
        }

        // 去重并保持顺序
        var seen = Set<String>()
        return (preferred + others).filter { seen.insert($0).inserted }
    }

    /// 移动端连接展示用的局域网地址文案
    var mobileLanAddressDisplayText: String {
        let addresses = mobileLanIPv4Addresses
        if addresses.isEmpty {
            return "settings.mobile.unavailable".localized
        }
        return addresses.joined(separator: ", ")
    }

    /// 移动端连接展示用的端口文案
    var mobileAccessPortDisplayText: String {
        if let wsPort = wsClient.currentURL?.port {
            return "\(wsPort)"
        }
        guard let port = coreProcessManager.runningPort else {
            return "settings.mobile.unavailable".localized
        }
        return "\(port)"
    }

    // MARK: - GitCacheState 接线

    func setupGitCache() {
        gitCache.wsClient = wsClient
        gitCache.getProjectName = { [weak self] in
            self?.selectedProjectName ?? "default"
        }
        gitCache.getConnectionState = { [weak self] in
            self?.connectionState ?? .disconnected
        }
        gitCache.getSelectedWorkspaceKey = { [weak self] in
            self?.selectedWorkspaceKey
        }
        gitCache.onCloseAllDiffTabs = { [weak self] workspaceKey in
            self?.closeAllDiffTabs(workspaceKey: workspaceKey)
        }
        gitCache.onCloseDiffTab = { [weak self] workspaceKey, path in
            self?.closeDiffTab(workspaceKey: workspaceKey, path: path)
        }
        gitCache.onRefreshActiveDiff = { [weak self] in
            self?.gitCache.refreshActiveDiff()
        }
        gitCache.getActiveDiffPath = { [weak self] in
            self?.activeDiffPath
        }
        gitCache.getActiveDiffMode = { [weak self] in
            self?.activeDiffMode ?? .working
        }
    }

    // MARK: - Core Process Management

    /// Setup callbacks for Core process events
    func setupCoreCallbacks() {
        coreProcessManager.onCoreReady = { [weak self] port in
            self?.setupWSClient(port: port)
            // Notify CenterContentView to update WebBridge with the port
            self?.onCoreReadyWithPort?(port)
            // 启动阶段：Core ready 后再展示主窗口
            self?.onCoreReadyForWindow?()
        }

        coreProcessManager.onCoreFailed = { [weak self] message in
            TFLog.core.error("Core failed: \(message, privacy: .public)")
            self?.connectionState = .disconnected
        }

        coreProcessManager.onCoreRestarting = { [weak self] attempt, maxAttempts in
            TFLog.core.warning("Core restarting (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public))")
            // Disconnect WebSocket during restart
            self?.wsClient.disconnect()
            self?.connectionState = .disconnected
        }

        coreProcessManager.onCoreRestartLimitReached = { [weak self] message in
            TFLog.core.error("Core restart limit reached: \(message, privacy: .public)")
            self?.connectionState = .disconnected
        }

        // 注册系统唤醒通知，用于探活 + 自动重连
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWake()
        }
    }

    /// Start Core process if not already running
    func startCoreIfNeeded() {
        guard !coreProcessManager.isRunning else {
            return
        }
        coreProcessManager.start()
    }

    /// Restart Core process (for Cmd+R recovery)
    /// Resets auto-restart counter for manual recovery
    func restartCore() {
        wsClient.disconnect()
        coreProcessManager.restart(resetCounter: true)
    }

    /// 生成移动端配对码（仅本机调用 /pair/start）
    func requestMobilePairCode() {
        guard coreProcessManager.status.isRunning else {
            mobilePairCodeError = "settings.mobile.error.coreNotReady".localized
            return
        }
        let readyPort = wsClient.currentURL?.port ?? coreProcessManager.runningPort
        guard let port = readyPort else {
            mobilePairCodeError = "settings.mobile.error.coreNotReady".localized
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/pair/start") else {
            mobilePairCodeError = "settings.mobile.error.invalidPairURL".localized
            return
        }

        mobilePairCodeLoading = true
        mobilePairCodeError = nil
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    let appState = self
                    await MainActor.run {
                        appState?.mobilePairCodeLoading = false
                        appState?.mobilePairCodeError = "settings.mobile.error.invalidResponse".localized
                    }
                    return
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    let decoded = try JSONDecoder().decode(PairStartHTTPResponse.self, from: data)
                    let appState = self
                    await MainActor.run {
                        appState?.mobilePairCodeLoading = false
                        appState?.mobilePairCode = decoded.pairCode
                        appState?.mobilePairCodeExpiresAt = decoded.expiresAt
                        appState?.mobilePairCodeError = nil
                    }
                    return
                }

                let serverError = try? JSONDecoder().decode(PairErrorHTTPResponse.self, from: data)
                let appState = self
                await MainActor.run {
                    appState?.mobilePairCodeLoading = false
                    if let serverError {
                        appState?.mobilePairCodeError = "\(serverError.error): \(serverError.message)"
                    } else {
                        appState?.mobilePairCodeError = String(
                            format: "settings.mobile.error.httpStatus".localized,
                            httpResponse.statusCode
                        )
                    }
                }
            } catch {
                let appState = self
                await MainActor.run {
                    appState?.mobilePairCodeLoading = false
                    appState?.mobilePairCodeError = String(
                        format: "settings.mobile.error.general".localized,
                        error.localizedDescription
                    )
                }
            }
        }
    }

    /// Stop Core process (called on app termination)
    func stopCore() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        coreProcessManager.stop()
    }

    // MARK: - WebSocket Setup

    private func setupWSClient(port: Int) {
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
                if let self, let ws = self.selectedWorkspaceKey {
                    self.markLspLoading(project: self.selectedProjectName, workspace: ws, loading: true)
                    self.wsClient.requestLspStartWorkspace(project: self.selectedProjectName, workspace: ws)
                    self.wsClient.requestLspGetDiagnostics(project: self.selectedProjectName, workspace: ws)
                }
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
        let lspHandler = AppStateLspMessageHandlerAdapter(appState: self)
        let aiHandler = AppStateAIMessageHandlerAdapter(appState: self)
        let evolutionHandler = AppStateEvolutionMessageHandlerAdapter(appState: self)
        let errorHandler = AppStateErrorMessageHandlerAdapter(appState: self)
        wsGitMessageHandler = gitHandler
        wsProjectMessageHandler = projectHandler
        wsFileMessageHandler = fileHandler
        wsSettingsMessageHandler = settingsHandler
        wsTerminalMessageHandler = terminalHandler
        wsLspMessageHandler = lspHandler
        wsAIMessageHandler = aiHandler
        wsEvolutionMessageHandler = evolutionHandler
        wsErrorMessageHandler = errorHandler
        wsClient.gitMessageHandler = gitHandler
        wsClient.projectMessageHandler = projectHandler
        wsClient.fileMessageHandler = fileHandler
        wsClient.settingsMessageHandler = settingsHandler
        wsClient.terminalMessageHandler = terminalHandler
        wsClient.lspMessageHandler = lspHandler
        wsClient.aiMessageHandler = aiHandler
        wsClient.evolutionMessageHandler = evolutionHandler
        wsClient.errorMessageHandler = errorHandler

        // Connect to the dynamic port
        wsClient.connect(port: port)
    }

    func handleAISessionStarted(_ ev: AISessionStartedV2) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }

        let store = aiStore(for: ev.aiTool)
        store.setCurrentSessionId(ev.sessionId)
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
        guard currentSessionId == ev.sessionId else {
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
        applyAISessionSelectionHint(
            ev.selectionHint,
            sessionId: ev.sessionId,
            for: ev.aiTool
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
        guard store.currentSessionId == ev.sessionId else { return }
        if store.isAbortPending(for: ev.sessionId) { return }
        TFLog.app.debug(
            "AI stream message_updated: session_id=\(ev.sessionId, privacy: .public), message_id=\(ev.messageId, privacy: .public), role=\(ev.role, privacy: .public)"
        )
        store.enqueueMessageUpdated(messageId: ev.messageId, role: ev.role)
        setBadgeRunning(true, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIChatPartUpdated(_ ev: AIChatPartUpdatedV2) {
        consumeEvolutionReplayPartUpdatedIfNeeded(ev)
        consumeSubAgentViewerPartUpdatedIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.currentSessionId == ev.sessionId else { return }
        if store.isAbortPending(for: ev.sessionId) { return }
        TFLog.app.debug(
            "AI stream part_updated: session_id=\(ev.sessionId, privacy: .public), message_id=\(ev.messageId, privacy: .public), part_id=\(ev.part.id, privacy: .public), part_type=\(ev.part.partType, privacy: .public)"
        )
        store.enqueuePartUpdated(messageId: ev.messageId, part: ev.part)
        setBadgeRunning(true, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIChatPartDelta(_ ev: AIChatPartDeltaV2) {
        consumeEvolutionReplayPartDeltaIfNeeded(ev)
        consumeSubAgentViewerPartDeltaIfNeeded(ev)
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.currentSessionId == ev.sessionId else { return }
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
        guard store.currentSessionId == ev.sessionId else { return }
        TFLog.app.debug("AI stream done: session_id=\(ev.sessionId, privacy: .public)")
        store.handleChatDone(sessionId: ev.sessionId)
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
        guard store.currentSessionId == ev.sessionId else { return }
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
        guard store.currentSessionId == ev.sessionId else { return }
        store.upsertQuestionRequest(ev.request)
        setBadgeRunning(true, for: ev.aiTool)
        markUnreadBadge(for: ev.aiTool)
    }

    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
        let store = aiStore(for: ev.aiTool)
        guard store.currentSessionId == ev.sessionId else { return }
        store.completeQuestionRequestLocally(requestId: ev.requestId)
    }

    func handleAIProviderList(_ ev: AIProviderListResult) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
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
        retryPendingAISessionSelectionHint(for: ev.aiTool)
    }

    func handleAIAgentList(_ ev: AIAgentListResult) {
        guard selectedProjectName == ev.projectName,
              selectedWorkspaceKey == ev.workspaceName else { return }
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

        let workspaceKey = globalWorkspaceKey(projectName: ev.project, workspaceName: normalizedWorkspace)
        showWorkspaceSpecialPage(workspaceKey: workspaceKey, page: .aiChat)

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

    // MARK: - Evolution

    func requestEvolutionSnapshot(project: String? = nil, workspace: String? = nil) {
        wsClient.requestEvoSnapshot(project: project, workspace: workspace)
    }

    func requestEvolutionAgentProfile(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        finishEvolutionProfileReloadTracking(project: project, workspace: normalizedWorkspace)
        wsClient.requestEvoGetAgentProfile(project: project, workspace: normalizedWorkspace)
    }

    /// 先拉齐每个 AI 工具的 provider/agent 列表，再拉取 Evolution profile，避免冷启动时读到默认配置。
    func requestEvolutionSelectorResourcesThenProfile(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        beginEvolutionSelectorLoading(project: project, workspace: normalizedWorkspace, requestProfileAfterLoaded: true)
        // 首次进入页面时先立即拉一次 profile，避免连接抖动导致页面长期停留默认值。
        wsClient.requestEvoGetAgentProfile(project: project, workspace: normalizedWorkspace)
        for tool in AIChatTool.allCases {
            wsClient.requestAIProviderList(projectName: project, workspaceName: normalizedWorkspace, aiTool: tool)
            wsClient.requestAIAgentList(projectName: project, workspaceName: normalizedWorkspace, aiTool: tool)
        }
    }

    func updateEvolutionAgentProfile(project: String, workspace: String, profiles: [EvolutionStageProfileInfoV2]) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoUpdateAgentProfile(project: project, workspace: normalizedWorkspace, stageProfiles: profiles)
    }

    func startEvolution(
        project: String,
        workspace: String,
        maxVerifyIterations: Int,
        autoLoopEnabled: Bool,
        profiles: [EvolutionStageProfileInfoV2]
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoStartWorkspace(
            project: project,
            workspace: normalizedWorkspace,
            priority: 0,
            maxVerifyIterations: maxVerifyIterations,
            autoLoopEnabled: autoLoopEnabled,
            stageProfiles: profiles
        )
    }

    func stopEvolution(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoStopWorkspace(project: project, workspace: normalizedWorkspace)
    }

    func resumeEvolution(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoResumeWorkspace(project: project, workspace: normalizedWorkspace)
    }

    func openEvolutionStageChat(project: String, workspace: String, cycleId: String, stage: String) {
        evolutionReplayTitle = "\(workspace) · \(stage) · \(cycleId)"
        evolutionReplayLoading = true
        evolutionReplayError = nil
        evolutionReplayRequest = nil
        evolutionReplayStore.clearAll()
        wsClient.requestEvoOpenStageChat(project: project, workspace: workspace, cycleID: cycleId, stage: stage)
    }

    func clearEvolutionReplay() {
        evolutionReplayRequest = nil
        evolutionReplayLoading = false
        evolutionReplayError = nil
        evolutionReplayTitle = ""
        evolutionReplayStore.clearAll()
    }

    func openSubAgentSessionViewer(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String,
        sourceToolName: String?
    ) {
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty else { return }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let source = (sourceToolName ?? "task").trimmingCharacters(in: .whitespacesAndNewlines)
        subAgentViewerTitle = source.isEmpty ? "子会话 · \(trimmedSessionId)" : "子会话(\(source)) · \(trimmedSessionId)"
        subAgentViewerLoading = true
        subAgentViewerError = nil
        subAgentViewerRequest = (
            project: project,
            workspace: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId
        )
        subAgentViewerStore.clearAll()
        subAgentViewerStore.setCurrentSessionId(trimmedSessionId)
        wsClient.requestAISessionStatus(
            projectName: project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId
        )
        wsClient.requestAISessionMessages(
            projectName: project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId,
            limit: 400
        )
    }

    func clearSubAgentSessionViewer() {
        subAgentViewerRequest = nil
        subAgentViewerLoading = false
        subAgentViewerError = nil
        subAgentViewerTitle = ""
        subAgentViewerStore.clearAll()
    }

    func evolutionItem(project: String, workspace: String) -> EvolutionWorkspaceItemV2? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        return evolutionWorkspaceItems.first {
            $0.project == project &&
                normalizeEvolutionWorkspaceName($0.workspace) == normalizedWorkspace
        }
    }

    func evolutionProfiles(project: String, workspace: String) -> [EvolutionStageProfileInfoV2] {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        if let profiles = evolutionStageProfilesByWorkspace[key], !profiles.isEmpty {
            if let fallback = evolutionProfilesFromClientSettings(project: project, workspace: normalizedWorkspace),
               shouldPreferEvolutionProfiles(candidate: fallback, over: profiles) {
                return Self.normalizedEvolutionProfiles(fallback)
            }
            return Self.normalizedEvolutionProfiles(profiles)
        }
        if let profiles = evolutionProfilesFromClientSettings(project: project, workspace: normalizedWorkspace) {
            return Self.normalizedEvolutionProfiles(profiles)
        }
        return Self.defaultEvolutionProfiles()
    }

    static func defaultEvolutionProfiles() -> [EvolutionStageProfileInfoV2] {
        ["bootstrap", "direction", "plan", "implement", "verify", "judge", "report"].map {
            EvolutionStageProfileInfoV2(stage: $0, aiTool: .codex, mode: nil, model: nil)
        }
    }

    static func normalizedEvolutionProfiles(_ profiles: [EvolutionStageProfileInfoV2]) -> [EvolutionStageProfileInfoV2] {
        if profiles.isEmpty {
            return defaultEvolutionProfiles()
        }

        var byStage: [String: EvolutionStageProfileInfoV2] = [:]
        for profile in profiles {
            let stage = profile.stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !stage.isEmpty else { continue }
            if byStage[stage] != nil { continue }
            byStage[stage] = EvolutionStageProfileInfoV2(
                stage: stage,
                aiTool: profile.aiTool,
                mode: profile.mode,
                model: profile.model
            )
        }

        return defaultEvolutionProfiles().map { item in
            byStage[item.stage] ?? item
        }
    }

    private func beginEvolutionSelectorLoading(
        project: String,
        workspace: String,
        requestProfileAfterLoaded: Bool
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        var byTool: [AIChatTool: (providerLoaded: Bool, agentLoaded: Bool)] = [:]
        for tool in AIChatTool.allCases {
            byTool[tool] = (providerLoaded: false, agentLoaded: false)
        }
        evolutionSelectorLoadStateByWorkspace[key] = byTool

        if requestProfileAfterLoaded {
            evolutionPendingProfileReloadWorkspaces.insert(key)
            scheduleEvolutionProfileReloadFallback(project: project, workspace: normalizedWorkspace)
        } else {
            finishEvolutionProfileReloadTracking(project: project, workspace: normalizedWorkspace)
        }
    }

    private func normalizeEvolutionWorkspaceName(_ workspace: String) -> String {
        let trimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("(default)") == .orderedSame ||
            trimmed.caseInsensitiveCompare("default") == .orderedSame {
            return "default"
        }
        return trimmed
    }

    fileprivate func applyEvolutionProfilesFromClientSettings(
        _ profileMap: [String: [EvolutionStageProfileInfoV2]]
    ) {
        guard !profileMap.isEmpty else { return }
        for (storageKey, profiles) in profileMap {
            guard !profiles.isEmpty else { continue }
            guard let parsed = parseEvolutionProfileStorageKey(storageKey) else { continue }
            let workspace = normalizeEvolutionWorkspaceName(parsed.workspace)
            let key = globalWorkspaceKey(projectName: parsed.project, workspaceName: workspace)
            let current = evolutionStageProfilesByWorkspace[key] ?? []
            let normalized = Self.normalizedEvolutionProfiles(profiles)
            if current.isEmpty || shouldPreferEvolutionProfiles(candidate: normalized, over: current) {
                evolutionStageProfilesByWorkspace[key] = normalized
            }
        }
    }

    private func evolutionProfilesFromClientSettings(
        project: String,
        workspace: String
    ) -> [EvolutionStageProfileInfoV2]? {
        guard !clientSettings.evolutionAgentProfiles.isEmpty else { return nil }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let candidateKeys = evolutionProfileStorageKeyCandidates(
            project: project,
            workspace: normalizedWorkspace
        )
        for key in candidateKeys {
            if let profiles = clientSettings.evolutionAgentProfiles[key], !profiles.isEmpty {
                return Self.normalizedEvolutionProfiles(profiles)
            }
        }
        for (storageKey, profiles) in clientSettings.evolutionAgentProfiles {
            guard !profiles.isEmpty else { continue }
            guard let parsed = parseEvolutionProfileStorageKey(storageKey) else { continue }
            let parsedWorkspace = normalizeEvolutionWorkspaceName(parsed.workspace)
            if parsed.project == project && parsedWorkspace == normalizedWorkspace {
                return Self.normalizedEvolutionProfiles(profiles)
            }
        }
        return nil
    }

    private func evolutionProfileStorageKeyCandidates(project: String, workspace: String) -> [String] {
        let projectTrimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceTrimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        var keys: [String] = [
            "\(project)/\(workspace)",
            "\(projectTrimmed)/\(workspaceTrimmed)"
        ]
        if workspaceTrimmed.caseInsensitiveCompare("default") == .orderedSame {
            keys.append("\(project)/(default)")
            keys.append("\(projectTrimmed)/(default)")
        }

        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    private func parseEvolutionProfileStorageKey(_ key: String) -> (project: String, workspace: String)? {
        let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private func shouldPreferEvolutionProfiles(
        candidate: [EvolutionStageProfileInfoV2],
        over existing: [EvolutionStageProfileInfoV2]
    ) -> Bool {
        if existing.isEmpty { return true }
        return isDefaultEvolutionProfiles(existing) && !isDefaultEvolutionProfiles(candidate)
    }

    private func isDefaultEvolutionProfiles(_ profiles: [EvolutionStageProfileInfoV2]) -> Bool {
        guard profiles.count == Self.defaultEvolutionProfiles().count else { return false }
        for profile in profiles {
            if profile.aiTool != .codex { return false }
            if let mode = profile.mode, !mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            if profile.model != nil { return false }
        }
        return true
    }

    private func markEvolutionProviderListLoaded(project: String, workspace: String, aiTool: AIChatTool) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        guard var byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        var state = byTool[aiTool] ?? (providerLoaded: false, agentLoaded: false)
        state.providerLoaded = true
        byTool[aiTool] = state
        evolutionSelectorLoadStateByWorkspace[key] = byTool
        maybeRequestEvolutionProfileAfterSelectorsReady(project: project, workspace: normalizedWorkspace)
    }

    private func markEvolutionAgentListLoaded(project: String, workspace: String, aiTool: AIChatTool) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        guard var byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        var state = byTool[aiTool] ?? (providerLoaded: false, agentLoaded: false)
        state.agentLoaded = true
        byTool[aiTool] = state
        evolutionSelectorLoadStateByWorkspace[key] = byTool
        maybeRequestEvolutionProfileAfterSelectorsReady(project: project, workspace: normalizedWorkspace)
    }

    private func maybeRequestEvolutionProfileAfterSelectorsReady(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        guard evolutionPendingProfileReloadWorkspaces.contains(key) else { return }
        guard let byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        let allReady = AIChatTool.allCases.allSatisfy { tool in
            let state = byTool[tool]
            return (state?.providerLoaded == true) && (state?.agentLoaded == true)
        }
        guard allReady else { return }
        requestEvolutionProfileIfPending(project: project, workspace: normalizedWorkspace)
    }

    private func scheduleEvolutionProfileReloadFallback(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evolutionProfileReloadFallbackTimers[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.requestEvolutionProfileIfPending(project: project, workspace: normalizedWorkspace)
        }
        evolutionProfileReloadFallbackTimers[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func requestEvolutionProfileIfPending(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        guard evolutionPendingProfileReloadWorkspaces.contains(key) else { return }
        finishEvolutionProfileReloadTracking(project: project, workspace: normalizedWorkspace)
        wsClient.requestEvoGetAgentProfile(project: project, workspace: normalizedWorkspace)
    }

    private func finishEvolutionProfileReloadTracking(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evolutionPendingProfileReloadWorkspaces.remove(key)
        if let work = evolutionProfileReloadFallbackTimers[key] {
            work.cancel()
            evolutionProfileReloadFallbackTimers[key] = nil
        }
    }

    private func consumeEvolutionReplayMessagesIfNeeded(_ ev: AISessionMessagesV2) -> Bool {
        guard let request = evolutionReplayRequest else { return false }
        guard request.project == ev.projectName,
              normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(ev.workspaceName),
              request.aiTool == ev.aiTool,
              request.sessionId == ev.sessionId else { return false }
        evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        evolutionReplayStore.replaceMessages(ev.toChatMessages())
        evolutionReplayLoading = false
        evolutionReplayError = nil
        return true
    }

    private func consumeEvolutionReplayMessageUpdatedIfNeeded(_ ev: AIChatMessageUpdatedV2) {
        guard matchesEvolutionReplayContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if evolutionReplayStore.currentSessionId != ev.sessionId {
            evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        }
        if evolutionReplayStore.isAbortPending(for: ev.sessionId) { return }
        evolutionReplayStore.enqueueMessageUpdated(messageId: ev.messageId, role: ev.role)
        evolutionReplayLoading = false
        evolutionReplayError = nil
    }

    private func consumeEvolutionReplayPartUpdatedIfNeeded(_ ev: AIChatPartUpdatedV2) {
        guard matchesEvolutionReplayContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if evolutionReplayStore.currentSessionId != ev.sessionId {
            evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        }
        if evolutionReplayStore.isAbortPending(for: ev.sessionId) { return }
        evolutionReplayStore.enqueuePartUpdated(messageId: ev.messageId, part: ev.part)
        evolutionReplayLoading = false
        evolutionReplayError = nil
    }

    private func consumeEvolutionReplayPartDeltaIfNeeded(_ ev: AIChatPartDeltaV2) {
        guard matchesEvolutionReplayContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if evolutionReplayStore.currentSessionId != ev.sessionId {
            evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        }
        if evolutionReplayStore.isAbortPending(for: ev.sessionId) { return }
        evolutionReplayStore.enqueuePartDelta(
            messageId: ev.messageId,
            partId: ev.partId,
            partType: ev.partType,
            field: ev.field,
            delta: ev.delta
        )
        evolutionReplayLoading = false
        evolutionReplayError = nil
    }

    private func consumeEvolutionReplayDoneIfNeeded(_ ev: AIChatDoneV2) {
        guard matchesEvolutionReplayContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if evolutionReplayStore.currentSessionId != ev.sessionId {
            evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        }
        evolutionReplayStore.handleChatDone(sessionId: ev.sessionId)
        evolutionReplayLoading = false
    }

    private func consumeEvolutionReplayErrorIfNeeded(_ ev: AIChatErrorV2) {
        guard matchesEvolutionReplayContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if evolutionReplayStore.currentSessionId != ev.sessionId {
            evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        }
        evolutionReplayStore.handleChatError(sessionId: ev.sessionId, error: ev.error)
        evolutionReplayLoading = false
    }

    private func matchesEvolutionReplayContext(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> Bool {
        guard let request = evolutionReplayRequest else { return false }
        return request.project == project &&
            normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(workspace) &&
            request.aiTool == aiTool &&
            request.sessionId == sessionId
    }

    private func consumeSubAgentViewerMessagesIfNeeded(_ ev: AISessionMessagesV2) -> Bool {
        guard let request = subAgentViewerRequest else { return false }
        guard request.project == ev.projectName,
              normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(ev.workspaceName),
              request.aiTool == ev.aiTool,
              request.sessionId == ev.sessionId else { return false }
        subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        subAgentViewerStore.replaceMessages(ev.toChatMessages())
        subAgentViewerLoading = false
        subAgentViewerError = nil
        return true
    }

    private func consumeSubAgentViewerMessageUpdatedIfNeeded(_ ev: AIChatMessageUpdatedV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        if subAgentViewerStore.isAbortPending(for: ev.sessionId) { return }
        subAgentViewerStore.enqueueMessageUpdated(messageId: ev.messageId, role: ev.role)
        subAgentViewerLoading = false
        subAgentViewerError = nil
    }

    private func consumeSubAgentViewerPartUpdatedIfNeeded(_ ev: AIChatPartUpdatedV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        if subAgentViewerStore.isAbortPending(for: ev.sessionId) { return }
        subAgentViewerStore.enqueuePartUpdated(messageId: ev.messageId, part: ev.part)
        subAgentViewerLoading = false
        subAgentViewerError = nil
    }

    private func consumeSubAgentViewerPartDeltaIfNeeded(_ ev: AIChatPartDeltaV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        if subAgentViewerStore.isAbortPending(for: ev.sessionId) { return }
        subAgentViewerStore.enqueuePartDelta(
            messageId: ev.messageId,
            partId: ev.partId,
            partType: ev.partType,
            field: ev.field,
            delta: ev.delta
        )
        subAgentViewerLoading = false
        subAgentViewerError = nil
    }

    private func consumeSubAgentViewerDoneIfNeeded(_ ev: AIChatDoneV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        subAgentViewerStore.handleChatDone(sessionId: ev.sessionId)
        subAgentViewerLoading = false
    }

    private func consumeSubAgentViewerErrorIfNeeded(_ ev: AIChatErrorV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        subAgentViewerStore.handleChatError(sessionId: ev.sessionId, error: ev.error)
        subAgentViewerLoading = false
        subAgentViewerError = ev.error
    }

    private func matchesSubAgentViewerContext(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> Bool {
        guard let request = subAgentViewerRequest else { return false }
        return request.project == project &&
            normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(workspace) &&
            request.aiTool == aiTool &&
            request.sessionId == sessionId
    }

    func handleFileIndexResult(_ result: FileIndexResult) {
        let cache = FileIndexCache(
            items: result.items,
            truncated: result.truncated,
            updatedAt: Date(),
            isLoading: false,
            error: nil
        )
        fileIndexCache[result.workspace] = cache
    }

    // MARK: - v1.31 LSP diagnostics

    func handleLspDiagnostics(_ result: LspDiagnosticsResult) {
        let key = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        workspaceLspLoading[key] = false
        let items = result.items.map { item in
            ProjectDiagnosticItem(
                severity: DiagnosticSeverity.from(token: item.severity),
                displayPath: item.path,
                editorPath: item.path.isEmpty ? nil : item.path,
                line: max(1, item.line),
                column: item.column > 0 ? item.column : nil,
                summary: item.message,
                rawLine: item.message
            )
        }.sorted {
            if $0.severity.rank != $1.severity.rank {
                return $0.severity.rank > $1.severity.rank
            }
            if $0.displayPath != $1.displayPath {
                return $0.displayPath < $1.displayPath
            }
            if $0.line != $1.line {
                return $0.line < $1.line
            }
            return ($0.column ?? 0) < ($1.column ?? 0)
        }

        let highest = items.first?.severity ?? DiagnosticSeverity.from(token: result.highestSeverity)
        let updatedAt = Self.parseISO8601(result.updatedAt) ?? Date()
        workspaceDiagnostics[key] = WorkspaceDiagnosticsSnapshot(
            items: items,
            highestSeverity: highest,
            updatedAt: updatedAt,
            sourceCommandId: nil
        )
    }

    func handleLspStatus(_ result: LspStatusResult) {
        let key = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        workspaceLspStatus[key] = WorkspaceLspStatusSnapshot(
            runningLanguages: result.runningLanguages,
            missingLanguages: result.missingLanguages,
            message: result.message,
            updatedAt: Date()
        )
    }

    func lspStatusSnapshot(for workspaceGlobalKey: String?) -> WorkspaceLspStatusSnapshot? {
        guard let key = workspaceGlobalKey else { return nil }
        return workspaceLspStatus[key]
    }

    func isLspLoading(for workspaceGlobalKey: String?) -> Bool {
        guard let key = workspaceGlobalKey else { return false }
        return workspaceLspLoading[key] ?? false
    }

    func markLspLoading(project: String, workspace: String, loading: Bool) {
        let key = globalWorkspaceKey(projectName: project, workspaceName: workspace)
        workspaceLspLoading[key] = loading
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        return fmt.date(from: text)
    }

    private static func rebuildPendingQuestionRequests(
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

    private static func parseQuestionInfos(from value: Any?) -> [AIQuestionInfo] {
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

    private static func stringValue(_ value: Any?) -> String? {
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
    private func reconcileAIStreamStateFromSessionStatus(
        aiTool: AIChatTool,
        sessionId: String,
        status: String
    ) {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedStatus == "busy" || normalizedStatus == "running" || normalizedStatus == "retry" {
            return
        }

        let store = aiStore(for: aiTool)
        guard store.currentSessionId == sessionId else { return }

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

    private func reloadAISessionDataAfterReconnect() {
        guard let workspace = selectedWorkspaceKey, !workspace.isEmpty else {
            TFLog.app.debug("AI reconnect reload skipped: workspace not selected")
            return
        }

        // 重连后补拉各工具会话列表，避免列表/详情状态滞后。
        for tool in AIChatTool.allCases {
            wsClient.requestAISessionList(
                projectName: selectedProjectName,
                workspaceName: workspace,
                aiTool: tool
            )
        }

        // 若某工具已有选中会话，则补拉详情，避免断线窗口内响应丢失导致空白。
        for tool in AIChatTool.allCases {
            let store = aiStore(for: tool)
            guard let sessionId = store.currentSessionId, !sessionId.isEmpty else { continue }
            TFLog.app.info(
                "AI reconnect reload: request session messages, tool=\(tool.rawValue, privacy: .public), session_id=\(sessionId, privacy: .public)"
            )
            wsClient.requestAISessionMessages(
                projectName: selectedProjectName,
                workspaceName: workspace,
                aiTool: tool,
                sessionId: sessionId,
                limit: 200
            )
        }
    }

    private func handleSystemWake() {
        TFLog.core.info("系统唤醒，延迟探活 WebSocket")
        // 延迟 1s 等待系统网络栈恢复
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.probeAndReconnectIfNeeded()
        }
    }

    private func probeAndReconnectIfNeeded() {
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

    private func startAutoReconnect() {
        // 防止重复触发（唤醒探活 + 意外断连回调可能同时触发）
        guard reconnectAttempt == 0 else {
            TFLog.core.info("自动重连已在进行中，跳过")
            return
        }
        attemptReconnect()
    }

    private func attemptReconnect() {
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            TFLog.core.error("自动重连失败，已达最大重试次数 \(Self.maxReconnectAttempts)")
            return
        }

        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        TFLog.core.info("自动重连第 \(self.reconnectAttempt) 次，延迟 \(delay)s")

        // 重连 Swift WSClient (WS①)
        wsClient.reconnect()
        // 重连 JS WebSocket (WS②)
        onReconnectJS?()

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
