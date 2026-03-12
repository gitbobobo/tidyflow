import Foundation
import Darwin
import TidyFlowShared

struct RemoteAPIKeyRecord: Identifiable, Equatable {
    let id: String
    let name: String
    let apiKey: String
    let createdAt: String
    let lastUsedAt: String?

    var maskedKey: String {
        guard apiKey.count > 10 else { return apiKey }
        let prefix = apiKey.prefix(8)
        let suffix = apiKey.suffix(4)
        return "\(prefix)••••\(suffix)"
    }
}

private struct RemoteAPIKeyHTTPPayload: Decodable {
    let keyID: String
    let name: String
    let apiKey: String
    let createdAt: String
    let lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case name
        case apiKey = "api_key"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

private struct RemoteAPIKeyListHTTPResponse: Decodable {
    let items: [RemoteAPIKeyHTTPPayload]
}

private struct CreateRemoteAPIKeyHTTPBody: Encodable {
    let name: String
}

private struct RemoteAPIKeyErrorHTTPResponse: Decodable {
    let error: String
    let message: String
}

extension AppState {
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

    /// 设置 Core 进程生命周期回调。
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
            self?.wsClient.disconnect()
            self?.connectionPhase = .intentionallyDisconnected
        }

        coreProcessManager.onCoreRestartLimitReached = { [weak self] message in
            TFLog.core.error("Core restart limit reached: \(message, privacy: .public)")
            self?.connectionPhase = .intentionallyDisconnected
            self?.markStartupFailedIfNeeded(message: message)
        }
    }

    /// 在 Core 未运行时启动 Core。
    func startCoreIfNeeded() {
        guard !coreProcessManager.isRunning else {
            return
        }
        coreProcessManager.start()
    }

    /// 手动重启 Core，并重置自动重启计数。
    func restartCore() {
        wsClient.disconnect()
        coreProcessManager.restart(resetCounter: true)
    }

    /// 应用退出时停止 Core。
    func stopCore() {
        deferredAISessionReloadWorkItem?.cancel()
        deferredAISessionReloadWorkItem = nil
        coreProcessManager.stop()
    }

    /// 当前会话是否允许管理移动端连接信息（Core 运行即可）
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

        var seen = Set<String>()
        return (preferred + others).filter { seen.insert($0).inserted }
    }

    var mobileLanAddressDisplayText: String {
        let addresses = mobileLanIPv4Addresses
        if addresses.isEmpty {
            return "settings.mobile.unavailable".localized
        }
        return addresses.joined(separator: ", ")
    }

    var mobileAccessPortDisplayText: String {
        if let wsPort = wsClient.currentURL?.port {
            return "\(wsPort)"
        }
        guard let port = coreProcessManager.runningPort else {
            return "settings.mobile.unavailable".localized
        }
        return "\(port)"
    }

    func refreshRemoteAPIKeys() {
        guard coreProcessManager.status.isRunning else {
            remoteAPIKeysError = "settings.mobile.error.coreNotReady".localized
            return
        }
        guard let url = makeLocalAuthKeysURL() else {
            remoteAPIKeysError = "settings.mobile.error.invalidPairURL".localized
            return
        }

        remoteAPIKeysLoading = true
        remoteAPIKeysError = nil
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        Task { [weak self] in
            await self?.performRemoteAPIKeyRequest(request) { data in
                let response = try JSONDecoder().decode(RemoteAPIKeyListHTTPResponse.self, from: data)
                return response.items.map(Self.remoteAPIKeyRecord(from:))
            }
        }
    }

    func createRemoteAPIKey(name: String) {
        guard let url = makeLocalAuthKeysURL() else {
            remoteAPIKeysError = "settings.mobile.error.invalidPairURL".localized
            return
        }

        remoteAPIKeysLoading = true
        remoteAPIKeysError = nil
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(CreateRemoteAPIKeyHTTPBody(name: name))

        Task { [weak self] in
            await self?.performRemoteAPIKeyRequest(request) { data in
                let created = try JSONDecoder().decode(RemoteAPIKeyHTTPPayload.self, from: data)
                var current = self?.remoteAPIKeys ?? []
                current.insert(Self.remoteAPIKeyRecord(from: created), at: 0)
                return current
            }
        }
    }

    func deleteRemoteAPIKey(id: String) {
        guard let url = makeLocalAuthKeysURL(pathComponent: id) else {
            remoteAPIKeysError = "settings.mobile.error.invalidPairURL".localized
            return
        }

        remoteAPIKeysLoading = true
        remoteAPIKeysError = nil
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        Task { [weak self] in
            await self?.performRemoteAPIKeyRequest(request) { _ in
                (self?.remoteAPIKeys ?? []).filter { $0.id != id }
            }
        }
    }

    private static func remoteAPIKeyRecord(from payload: RemoteAPIKeyHTTPPayload) -> RemoteAPIKeyRecord {
        RemoteAPIKeyRecord(
            id: payload.keyID,
            name: payload.name,
            apiKey: payload.apiKey,
            createdAt: payload.createdAt,
            lastUsedAt: payload.lastUsedAt
        )
    }

    private func makeLocalAuthKeysURL(pathComponent: String? = nil) -> URL? {
        let readyPort = wsClient.currentURL?.port ?? coreProcessManager.runningPort
        guard let port = readyPort else { return nil }
        let suffix = pathComponent.map { "/\($0)" } ?? ""
        return URL(string: "http://127.0.0.1:\(port)/auth/keys\(suffix)")
    }

    private func performRemoteAPIKeyRequest(
        _ request: URLRequest,
        onSuccess: @escaping (Data) throws -> [RemoteAPIKeyRecord]
    ) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    self.remoteAPIKeysLoading = false
                    self.remoteAPIKeysError = "settings.mobile.error.invalidResponse".localized
                }
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let serverError = try? JSONDecoder().decode(RemoteAPIKeyErrorHTTPResponse.self, from: data)
                await MainActor.run {
                    self.remoteAPIKeysLoading = false
                    self.remoteAPIKeysError = serverError.map { "\($0.error): \($0.message)" }
                        ?? String(
                            format: "settings.mobile.error.httpStatus".localized,
                            httpResponse.statusCode
                        )
                }
                return
            }
            let nextKeys = try onSuccess(data)
            await MainActor.run {
                self.remoteAPIKeys = nextKeys
                self.remoteAPIKeysLoading = false
                self.remoteAPIKeysError = nil
            }
        } catch {
            await MainActor.run {
                self.remoteAPIKeysLoading = false
                self.remoteAPIKeysError = String(
                    format: "settings.mobile.error.general".localized,
                    error.localizedDescription
                )
            }
        }
    }
}
