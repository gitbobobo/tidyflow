import Foundation

/// Centralized configuration for TidyFlow app
/// Single source of truth for host and URL settings
enum AppConfig {
    /// Host for Core server (localhost only)
    static let coreHost: String = "127.0.0.1"
    /// Core/Web 前后端协议版本（必须与 Core `PROTOCOL_VERSION` 一致）
    static let protocolVersion: Int = 7

    // MARK: - Port Configuration

    /// 生产环境默认端口
    static let defaultPortProduction: Int = 8439
    /// 开发环境默认端口
    static let defaultPortDevelopment: Int = 3439
    /// 当前环境默认端口
    static var defaultPort: Int {
        isDevelopmentBuild ? defaultPortDevelopment : defaultPortProduction
    }
    /// 是否为开发构建（run-app.sh 产出 TidyFlow-Debug.app）
    static var isDevelopmentBuild: Bool {
        Bundle.main.bundleURL.lastPathComponent == "TidyFlow-Debug.app"
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
    /// Core 启动后等待 bootstrap + 端口可达的最长时间（秒）
    static let coreReadyTimeout: TimeInterval = 30

    /// Generate WebSocket URL for a given port
    static func makeWsURL(host: String = coreHost, port: Int, token: String? = nil, secure: Bool = false) -> URL {
        var components = URLComponents()
        components.scheme = secure ? "wss" : "ws"
        components.host = host
        components.port = port
        components.path = "/ws"
        if let token, !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url!
    }

    /// Generate WebSocket URL string for a given port
    static func makeWsURLString(host: String = coreHost, port: Int, token: String? = nil, secure: Bool = false) -> String {
        makeWsURL(host: host, port: port, token: token, secure: secure).absoluteString
    }
}
