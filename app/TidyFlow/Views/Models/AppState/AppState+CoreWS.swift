import Foundation
import AppKit
import Darwin
import TidyFlowShared

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
        }

        coreProcessManager.onCoreFailed = { [weak self] message in
            TFLog.core.error("Core failed: \(message, privacy: .public)")
            self?.connectionPhase = .intentionallyDisconnected
            self?.markStartupFailedIfNeeded(message: message)
        }

        coreProcessManager.onCoreRestarting = { [weak self] attempt, maxAttempts in
            TFLog.core.warning("Core restarting (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public))")
            // Disconnect WebSocket during restart
            self?.wsClient.disconnect()
            self?.connectionPhase = .intentionallyDisconnected
        }

        coreProcessManager.onCoreRestartLimitReached = { [weak self] message in
            TFLog.core.error("Core restart limit reached: \(message, privacy: .public)")
            self?.connectionPhase = .intentionallyDisconnected
            self?.markStartupFailedIfNeeded(message: message)
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
        deferredAISessionReloadWorkItem?.cancel()
        deferredAISessionReloadWorkItem = nil
        coreProcessManager.stop()
    }

}
