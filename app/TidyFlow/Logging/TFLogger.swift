import os

/// TidyFlow 日志分类
enum TFLog {
    static let bridge = Logger(subsystem: "cn.tidyflow", category: "bridge")
    static let ws = Logger(subsystem: "cn.tidyflow", category: "ws")
    static let core = Logger(subsystem: "cn.tidyflow", category: "core")
    static let app = Logger(subsystem: "cn.tidyflow", category: "app")
    static let port = Logger(subsystem: "cn.tidyflow", category: "port")
    static let logWriter = Logger(subsystem: "cn.tidyflow", category: "logWriter")
}
