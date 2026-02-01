import Foundation

/// Centralized configuration for TidyFlow app
/// Single source of truth for host and URL settings
enum AppConfig {
    /// Host for Core server (localhost only)
    static let coreHost: String = "127.0.0.1"

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
    static func makeWsURL(port: Int) -> URL {
        URL(string: "ws://\(coreHost):\(port)/ws")!
    }

    /// Generate WebSocket URL string for a given port
    static func makeWsURLString(port: Int) -> String {
        "ws://\(coreHost):\(port)/ws"
    }
}
