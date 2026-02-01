import Foundation

/// Centralized configuration for TidyFlow app
/// Single source of truth for port and URL settings
enum AppConfig {
    /// Fixed port for Core WebSocket server (MVP: no dynamic port)
    static let corePort: Int = 47999

    /// Host for Core server (localhost only)
    static let coreHost: String = "127.0.0.1"

    /// WebSocket URL for Core connection
    static var coreWsURL: String {
        "ws://\(coreHost):\(corePort)/ws"
    }

    /// Core binary name in bundle
    static let coreBinaryName: String = "tidyflow-core"

    /// Subdirectory in bundle for Core binary (Contents/Resources/Core/)
    static let coreBundleSubdir: String = "Core"
}
