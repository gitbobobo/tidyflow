import Foundation

/// Centralized configuration for TidyFlow app
/// Single source of truth for host and URL settings
enum AppConfig {
    /// Host for Core server (localhost only)
    static let coreHost: String = "127.0.0.1"
    /// Core 监听地址（本机）
    static let coreBindLocal: String = "127.0.0.1"
    /// Core 监听地址（局域网）
    static let coreBindRemote: String = "0.0.0.0"
    /// 远程访问开关（UserDefaults 键）
    static let remoteAccessEnabledKey: String = "core.remoteAccessEnabled"
    /// 固定端口（UserDefaults 键），0 表示动态分配
    static let fixedPortKey: String = "core.fixedPort"
    /// 当前配置的固定端口，0 表示动态分配
    static var configuredFixedPort: Int {
        UserDefaults.standard.integer(forKey: fixedPortKey)
    }

    // MARK: - Logging Configuration

    /// Log directory path for display in UI
    static let logPathDisplay: String = "~/Library/Logs/TidyFlow/core.log"

    /// Core binary name in bundle
    static let coreBinaryName: String = "tidyflow-core"

    /// Subdirectory in bundle for Core binary (Contents/Resources/Core/)
    static let coreBundleSubdir: String = "Core"

    /// Maximum retry attempts for port allocation
    static let maxPortRetries: Int = 5

    /// Timeout for graceful shutdown (seconds)
    static let shutdownTimeout: TimeInterval = 1.0

    /// Auto-restart configuration
    static let autoRestartLimit: Int = 3
    static let autoRestartBackoffs: [TimeInterval] = [0.2, 0.5, 1.2]

    /// 当前 Core 绑定地址（由本地设置决定）
    static var currentCoreBindAddress: String {
        let enabled = UserDefaults.standard.bool(forKey: remoteAccessEnabledKey)
        return enabled ? coreBindRemote : coreBindLocal
    }

    /// Generate WebSocket URL for a given port
    static func makeWsURL(host: String = coreHost, port: Int, token: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/ws"
        if let token, !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url!
    }

    /// Generate WebSocket URL string for a given port
    static func makeWsURLString(host: String = coreHost, port: Int, token: String? = nil) -> String {
        makeWsURL(host: host, port: port, token: token).absoluteString
    }
}
