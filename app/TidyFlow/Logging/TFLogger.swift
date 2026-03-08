import os
import Foundation

/// TidyFlow 日志分类
enum TFLog {
    static let bridge = Logger(subsystem: "cn.tidyflow", category: "bridge")
    static let ws = Logger(subsystem: "cn.tidyflow", category: "ws")
    static let core = Logger(subsystem: "cn.tidyflow", category: "core")
    static let app = Logger(subsystem: "cn.tidyflow", category: "app")
    static let port = Logger(subsystem: "cn.tidyflow", category: "port")
    static let logWriter = Logger(subsystem: "cn.tidyflow", category: "logWriter")
    static let perf = Logger(subsystem: "cn.tidyflow", category: "perf")

    /// 用于向 Rust Core 发送日志的 WSClient 引用（App 启动后由 AppState 设置）
    static weak var wsClient: WSClient?

    /// 同时写入 os.Logger 和通过 WebSocket 发送到 Rust Core
    ///
    /// - Parameters:
    ///   - errorCode: 当 level == "ERROR" 时可携带共享错误码，与 Core 端的 AppError::code() 对应
    ///   - project: 错误归属项目（多项目场景）
    ///   - workspace: 错误归属工作区
    ///   - sessionId: AI 会话 ID（AI 相关错误）
    ///   - cycleId: Evolution Cycle ID（Evolution 相关错误）
    static func log(
        _ logger: Logger,
        category: String,
        level: String,
        _ message: String,
        detail: String? = nil,
        errorCode: CoreErrorCode? = nil,
        project: String? = nil,
        workspace: String? = nil,
        sessionId: String? = nil,
        cycleId: String? = nil
    ) {
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

        // 通过 WebSocket 发送到 Rust Core 写入文件（含结构化错误码与上下文）
        wsClient?.sendLogEntry(
            level: level,
            category: category,
            msg: message,
            detail: detail,
            errorCode: errorCode,
            project: project,
            workspace: workspace,
            sessionId: sessionId,
            cycleId: cycleId
        )
    }
}

// MARK: - 性能事件定义

/// 统一的性能观测事件点，macOS 与 iOS 共享同一枚举定义。
/// 每个事件携带 project/workspace 以及操作相关定位字段，适配多项目并行场景。
enum TFPerformanceEvent: String, CaseIterable {
    case workspaceSwitch = "workspace_switch"
    case fileTreeRequest = "file_tree_request"
    case fileTreeExpand = "file_tree_expand"
    case aiSessionListRequest = "ai_session_list_request"
    case aiSessionListPage = "ai_session_list_page"

    var category: String { "perf" }
}

/// 性能追踪上下文，携带多项目场景下的定位字段。
struct TFPerformanceContext: Equatable {
    let event: TFPerformanceEvent
    let project: String
    let workspace: String
    /// 额外定位字段（如 path、filter、cursor 等）
    let metadata: [String: String]

    init(event: TFPerformanceEvent, project: String, workspace: String, metadata: [String: String] = [:]) {
        self.event = event
        self.project = project
        self.workspace = workspace
        self.metadata = metadata
    }
}

/// 性能追踪结果快照，用于共享状态层暴露观测数据。
struct TFPerformanceSnapshot: Equatable, Identifiable {
    let id: String
    let context: TFPerformanceContext
    let startTime: Date
    let endTime: Date?
    let durationMs: Double?

    var isCompleted: Bool { endTime != nil }
}

/// 共享性能追踪器，macOS 与 iOS 共用。
/// 通过 `enabled` 开关控制是否收集，避免生产环境无谓开销。
final class TFPerformanceTracer: ObservableObject {
    /// 全局开关，默认关闭。可通过设置或开发者菜单打开。
    @Published var enabled: Bool = false

    /// 最近的性能快照列表（上限 100 条，FIFO 淘汰）
    @Published private(set) var snapshots: [TFPerformanceSnapshot] = []

    private var pending: [String: (context: TFPerformanceContext, startTime: Date)] = [:]
    private let maxSnapshots = 100

    /// 开始追踪一个性能事件，返回追踪 ID。
    @discardableResult
    func begin(_ context: TFPerformanceContext) -> String {
        guard enabled else { return "" }
        let traceId = "\(context.event.rawValue):\(context.project):\(context.workspace):\(UUID().uuidString.prefix(8))"
        pending[traceId] = (context: context, startTime: Date())

        TFLog.log(
            TFLog.perf,
            category: context.event.category,
            level: "DEBUG",
            "[perf:begin] \(context.event.rawValue)",
            project: context.project,
            workspace: context.workspace
        )
        return traceId
    }

    /// 结束追踪并记录快照。
    func end(_ traceId: String) {
        guard enabled, !traceId.isEmpty, let record = pending.removeValue(forKey: traceId) else { return }
        let endTime = Date()
        let durationMs = endTime.timeIntervalSince(record.startTime) * 1000
        let snapshot = TFPerformanceSnapshot(
            id: traceId,
            context: record.context,
            startTime: record.startTime,
            endTime: endTime,
            durationMs: durationMs
        )
        snapshots.append(snapshot)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }

        let metaStr = record.context.metadata.isEmpty ? "" : " meta=\(record.context.metadata)"
        TFLog.log(
            TFLog.perf,
            category: record.context.event.category,
            level: "INFO",
            "[perf:end] \(record.context.event.rawValue) duration=\(String(format: "%.1f", durationMs))ms\(metaStr)",
            project: record.context.project,
            workspace: record.context.workspace
        )
    }

    /// 清空所有快照和待处理追踪。
    func reset() {
        pending.removeAll()
        snapshots.removeAll()
    }
}
