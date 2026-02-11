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

extension AppState {
    /// 用户配置是否已在当前 Core 会话生效
    var remoteAccessPendingApply: Bool {
        remoteAccessEnabled != coreProcessManager.isRemoteBindActive
    }

    /// 当前 Core 会话是否已开启局域网访问（0.0.0.0）
    var remoteAccessActive: Bool {
        coreProcessManager.isRemoteBindActive
    }

    /// 当前会话是否允许生成并使用移动端连接信息
    var remoteAccessReady: Bool {
        remoteAccessEnabled && remoteAccessActive
    }

    /// 移动端访问提示文案（区分“已配置未生效”）
    var mobileRemoteAccessHintText: String {
        if remoteAccessPendingApply {
            return "settings.mobile.remoteAccess.pendingHint".localized
        }
        return remoteAccessEnabled
            ? "settings.mobile.remoteAccess.onHint".localized
            : "settings.mobile.remoteAccess.offHint".localized
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

    /// 更新局域网访问开关（仅写入配置，下次启动应用生效）
    func setRemoteAccessEnabled(_ enabled: Bool) {
        guard remoteAccessEnabled != enabled else { return }
        remoteAccessEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppConfig.remoteAccessEnabledKey)

        // 切换网络暴露状态后，旧配对码不可继续展示
        mobilePairCode = nil
        mobilePairCodeExpiresAt = nil
        mobilePairCodeError = nil
    }

    /// 生成移动端配对码（仅本机调用 /pair/start）
    func requestMobilePairCode() {
        guard remoteAccessEnabled else {
            mobilePairCodeError = "settings.mobile.error.enableFirst".localized
            return
        }
        guard remoteAccessReady else {
            mobilePairCodeError = "settings.mobile.error.restartRequired".localized
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
                    await MainActor.run {
                        self?.mobilePairCodeLoading = false
                        self?.mobilePairCodeError = "settings.mobile.error.invalidResponse".localized
                    }
                    return
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    let decoded = try JSONDecoder().decode(PairStartHTTPResponse.self, from: data)
                    await MainActor.run {
                        self?.mobilePairCodeLoading = false
                        self?.mobilePairCode = decoded.pairCode
                        self?.mobilePairCodeExpiresAt = decoded.expiresAt
                        self?.mobilePairCodeError = nil
                    }
                    return
                }

                let serverError = try? JSONDecoder().decode(PairErrorHTTPResponse.self, from: data)
                await MainActor.run {
                    self?.mobilePairCodeLoading = false
                    if let serverError {
                        self?.mobilePairCodeError = "\(serverError.error): \(serverError.message)"
                    } else {
                        self?.mobilePairCodeError = String(
                            format: "settings.mobile.error.httpStatus".localized,
                            httpResponse.statusCode
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self?.mobilePairCodeLoading = false
                    self?.mobilePairCodeError = String(
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

        wsClient.onConnectionStateChanged = { [weak self] connected in
            self?.connectionState = connected ? .connected : .disconnected
            if connected {
                self?.reconnectAttempt = 0  // 重置自动重连计数
                self?.wsClient.requestListProjects()
                self?.wsClient.requestGetClientSettings()
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

        wsClient.onFileIndexResult = { [weak self] result in
            self?.handleFileIndexResult(result)
        }

        // 处理文件列表结果
        wsClient.onFileListResult = { [weak self] result in
            self?.handleFileListResult(result)
        }

        // Phase C2-2a: Handle git diff results
        wsClient.onGitDiffResult = { [weak self] result in
            self?.gitCache.handleGitDiffResult(result)
        }

        // Phase C3-1: Handle git status results
        wsClient.onGitStatusResult = { [weak self] result in
            self?.gitCache.handleGitStatusResult(result)
        }

        // Handle git log results
        wsClient.onGitLogResult = { [weak self] result in
            self?.gitCache.handleGitLogResult(result)
        }

        // Handle git show results (single commit details)
        wsClient.onGitShowResult = { [weak self] result in
            self?.gitCache.handleGitShowResult(result)
        }

        // Phase C3-2a: Handle git operation results
        wsClient.onGitOpResult = { [weak self] result in
            self?.gitCache.handleGitOpResult(result)
        }

        // Phase C3-3a: Handle git branches results
        wsClient.onGitBranchesResult = { [weak self] result in
            self?.gitCache.handleGitBranchesResult(result)
        }

        // Phase C3-4a: Handle git commit results
        wsClient.onGitCommitResult = { [weak self] result in
            self?.gitCache.handleGitCommitResult(result)
        }

        // Phase UX-3a: Handle git rebase results
        wsClient.onGitRebaseResult = { [weak self] result in
            self?.gitCache.handleGitRebaseResult(result)
        }

        // Phase UX-3a: Handle git op status results
        wsClient.onGitOpStatusResult = { [weak self] result in
            self?.gitCache.handleGitOpStatusResult(result)
        }

        // Phase UX-3b: Handle git merge to default results
        wsClient.onGitMergeToDefaultResult = { [weak self] result in
            self?.gitCache.handleGitMergeToDefaultResult(result)
        }

        // Phase UX-3b: Handle git integration status results
        wsClient.onGitIntegrationStatusResult = { [weak self] result in
            self?.gitCache.handleGitIntegrationStatusResult(result)
        }

        // Phase UX-4: Handle git rebase onto default results
        wsClient.onGitRebaseOntoDefaultResult = { [weak self] result in
            self?.gitCache.handleGitRebaseOntoDefaultResult(result)
        }

        // Phase UX-5: Handle git reset integration worktree results
        wsClient.onGitResetIntegrationWorktreeResult = { [weak self] result in
            self?.gitCache.handleGitResetIntegrationWorktreeResult(result)
        }

        // UX-2: Handle project import results
        wsClient.onProjectImported = { [weak self] result in
            self?.handleProjectImported(result)
        }

        // UX-2: Handle project list results
        wsClient.onProjectsList = { [weak self] result in
            self?.handleProjectsList(result)
        }

        // Handle workspaces list results
        wsClient.onWorkspacesList = { [weak self] result in
            self?.handleWorkspacesList(result)
        }

        // UX-2: Handle workspace created results
        wsClient.onWorkspaceCreated = { [weak self] result in
            self?.handleWorkspaceCreated(result)
        }

        // Handle project removed results
        wsClient.onProjectRemoved = { result in
            if !result.ok {
                TFLog.app.error("移除项目失败: \(result.message ?? "未知错误", privacy: .public)")
            }
        }

        // Handle workspace removed results
        wsClient.onWorkspaceRemoved = { [weak self] result in
            self?.handleWorkspaceRemoved(result)
        }

        // 处理客户端设置结果
        wsClient.onClientSettingsResult = { [weak self] settings in
            self?.clientSettings = settings
            self?.clientSettingsLoaded = true
        }

        wsClient.onClientSettingsSaved = { ok, message in
            if !ok {
                TFLog.app.error("保存设置失败: \(message ?? "未知错误", privacy: .public)")
            }
        }

        // v1.22: 文件监控回调
        wsClient.onWatchSubscribed = { _ in
            // 已订阅文件监控
        }

        wsClient.onWatchUnsubscribed = {
            // 已取消文件监控订阅
        }

        wsClient.onFileChanged = { [weak self] notification in
            // 使相关缓存失效
            self?.invalidateFileCache(project: notification.project, workspace: notification.workspace)
            // 通知编辑器层文件变化
            self?.notifyEditorFileChanged(notification: notification)
        }

        wsClient.onGitStatusChanged = { [weak self] notification in
            // 自动刷新 Git 状态
            self?.gitCache.fetchGitStatus(workspaceKey: notification.workspace)
            // 同时刷新分支信息（可能有新分支创建）
            self?.gitCache.fetchGitBranches(workspaceKey: notification.workspace)
        }

        // v1.23: 文件重命名结果
        wsClient.onFileRenameResult = { [weak self] result in
            self?.handleFileRenameResult(result)
        }

        // v1.23: 文件删除结果
        wsClient.onFileDeleteResult = { [weak self] result in
            self?.handleFileDeleteResult(result)
        }

        // v1.24: 文件复制结果
        wsClient.onFileCopyResult = { [weak self] result in
            self?.handleFileCopyResult(result)
        }

        // v1.25: 文件移动结果
        wsClient.onFileMoveResult = { [weak self] result in
            self?.handleFileMoveResult(result)
        }

        // 文件写入结果（新建文件）
        wsClient.onFileWriteResult = { [weak self] result in
            self?.handleFileWriteResult(result)
        }

        // 项目命令回调
        wsClient.onProjectCommandsSaved = { [weak self] project, ok, message in
            if !ok {
                TFLog.app.warning("项目命令保存失败: \(message ?? "未知错误", privacy: .public)")
            }
        }
        wsClient.onProjectCommandStarted = { [weak self] project, workspace, commandId, taskId in
            self?.handleProjectCommandStarted(
                project: project,
                workspace: workspace,
                commandId: commandId,
                taskId: taskId
            )
        }
        wsClient.onProjectCommandOutput = { [weak self] taskId, line in
            self?.handleProjectCommandOutput(taskId: taskId, line: line)
        }
        wsClient.onProjectCommandCompleted = { [weak self] project, workspace, commandId, taskId, ok, message in
            self?.handleProjectCommandCompleted(
                project: project,
                workspace: workspace,
                commandId: commandId,
                taskId: taskId,
                ok: ok,
                message: message
            )
        }
        wsClient.onLspDiagnostics = { [weak self] result in
            self?.handleLspDiagnostics(result)
        }
        wsClient.onLspStatus = { [weak self] result in
            self?.handleLspStatus(result)
        }

        wsClient.onError = { [weak self] errorMsg in
            // Update cache with error if we were loading
            if let ws = self?.selectedWorkspaceKey {
                var cache = self?.fileIndexCache[ws] ?? FileIndexCache.empty()
                if cache.isLoading {
                    cache.isLoading = false
                    cache.error = errorMsg
                    self?.fileIndexCache[ws] = cache
                }
            }
        }

        // Connect to the dynamic port
        wsClient.connect(port: port)
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

    // MARK: - 系统唤醒探活 + 自动重连

    private static let maxReconnectAttempts = 5
    private static let reconnectDelays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0]

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
