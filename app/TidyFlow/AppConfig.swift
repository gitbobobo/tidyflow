import Foundation

/// Centralized configuration for TidyFlow app
/// Single source of truth for host and URL settings
enum AppConfig {
    /// Host for Core server (localhost only)
    static let coreHost: String = "127.0.0.1"
    /// Core 监听地址（始终允许局域网访问）
    static let coreBindAddress: String = "0.0.0.0"

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

    /// 固定端口：从 tidyflow.json 读取，0 表示动态分配
    static var configuredFixedPort: Int {
        readClientSettingsFromDisk().fixedPort
    }

    /// 从磁盘直接读取 client_settings（Core 启动前使用）
    static func readClientSettingsFromDisk() -> (fixedPort: Int, appLanguage: String) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let path = home.appendingPathComponent(".tidyflow/tidyflow.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cs = root["client_settings"] as? [String: Any] else {
            return (fixedPort: 0, appLanguage: "system")
        }
        let fixedPort = cs["fixed_port"] as? Int ?? 0
        let appLanguage = cs["app_language"] as? String ?? "system"
        return (fixedPort: fixedPort, appLanguage: appLanguage)
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
