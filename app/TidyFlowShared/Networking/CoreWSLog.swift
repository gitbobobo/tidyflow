import Foundation
import OSLog

/// 共享网络层日志分类
/// 避免 TidyFlowShared 反向依赖 app target 的 TFLog。
enum CoreWSLog {
    static let ws = Logger(subsystem: "cn.tidyflow.shared", category: "ws")
}
