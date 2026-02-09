import os

/// TidyFlow 日志分类
enum TFLog {
    static let bridge = Logger(subsystem: "cn.tidyflow", category: "bridge")
    static let ws = Logger(subsystem: "cn.tidyflow", category: "ws")
    static let core = Logger(subsystem: "cn.tidyflow", category: "core")
    static let app = Logger(subsystem: "cn.tidyflow", category: "app")
    static let port = Logger(subsystem: "cn.tidyflow", category: "port")
    static let logWriter = Logger(subsystem: "cn.tidyflow", category: "logWriter")

    /// 用于向 Rust Core 发送日志的 WSClient 引用（App 启动后由 AppState 设置）
    static weak var wsClient: WSClient?

    /// 同时写入 os.Logger 和通过 WebSocket 发送到 Rust Core
    static func log(_ logger: Logger, category: String, level: String, _ message: String, detail: String? = nil) {
        // 写入系统日志
        switch level {
        case "DEBUG":
            logger.debug("\(message, privacy: .public)")
        case "WARN":
            logger.warning("\(message, privacy: .public)")
        case "ERROR":
            logger.error("\(message, privacy: .public)")
        default:
            logger.info("\(message, privacy: .public)")
        }

        // 通过 WebSocket 发送到 Rust Core 写入文件
        wsClient?.sendLogEntry(level: level, category: category, msg: message, detail: detail)
    }
}
