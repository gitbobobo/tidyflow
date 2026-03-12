import Foundation
import OSLog
import Darwin

/// TidyFlow 日志分类
enum TFLog {
    static let bridge = Logger(subsystem: "cn.tidyflow", category: "bridge")
    static let ws = Logger(subsystem: "cn.tidyflow", category: "ws")
    static let core = Logger(subsystem: "cn.tidyflow", category: "core")
    static let app = Logger(subsystem: "cn.tidyflow", category: "app")
    static let port = Logger(subsystem: "cn.tidyflow", category: "port")
    static let logWriter = Logger(subsystem: "cn.tidyflow", category: "logWriter")
    static let perf = Logger(subsystem: "cn.tidyflow", category: "perf")
    static let observability = Logger(subsystem: "cn.tidyflow", category: "observability")

    /// 统一写入本地系统日志。
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
    }
}

// MARK: - 性能事件定义

/// 统一的性能观测事件点，macOS 与 iOS 共享同一枚举定义。
/// 每个事件携带 project/workspace 以及操作相关定位字段，适配多项目并行场景。
enum TFPerformanceEvent: String, CaseIterable {
    case workspaceSwitch = "workspace_switch"
    case fileTreeRequest = "file_tree_request"
    case fileTreeExpand = "file_tree_expand"
    case workspaceTreeRefresh = "workspace_tree_refresh"
    case aiSessionListRequest = "ai_session_list_request"
    case aiSessionListPage = "ai_session_list_page"
    case aiSessionListRefresh = "ai_session_list_refresh"
    case aiMessageTailFlush = "ai_message_tail_flush"
    case evidencePageAppend = "evidence_page_append"

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

// MARK: - 客户端延迟窗口（WI-003）

/// 客户端侧固定大小滚动延迟窗口（128 样本）
final class ClientLatencyWindow {
    private let windowSize = 128
    private var samples: [Double] = []
    private var maxMs: Double = 0

    func push(_ ms: Double) {
        if samples.count >= windowSize { samples.removeFirst() }
        samples.append(ms)
        if ms > maxMs { maxMs = ms }
    }

    func toMetricWindow() -> LatencyMetricWindow {
        guard !samples.isEmpty else { return .empty }
        let last = samples.last ?? 0
        let avg = samples.reduce(0, +) / Double(samples.count)
        let sorted = samples.sorted()
        let p95Idx = max(0, Int(Double(samples.count) * 0.95) - 1)
        let p95 = sorted[p95Idx]
        return LatencyMetricWindow(
            lastMs: UInt64(last),
            avgMs: UInt64(avg),
            p95Ms: UInt64(p95),
            maxMs: UInt64(maxMs),
            sampleCount: UInt64(samples.count),
            windowSize: UInt64(windowSize)
        )
    }
}

// MARK: - 客户端性能上报器（WI-003）

/// 共享客户端性能采样器与上报器。
/// - 每个进程生成稳定的 client_instance_id
/// - 维护关键路径延迟窗口
/// - 节流策略：每 10s 或累计 16 个新样本触发一次上报
final class TFClientPerfReporter: ObservableObject {
    /// 进程生命周期内稳定的客户端实例 ID
    let clientInstanceId: String = UUID().uuidString

    /// 平台标识（"macos" | "ios"）
    let platform: String

    private let workspaceSwitchWindow = ClientLatencyWindow()
    private let fileTreeRequestWindow = ClientLatencyWindow()
    private let fileTreeExpandWindow = ClientLatencyWindow()
    private let aiSessionListWindow = ClientLatencyWindow()
    private let aiMessageTailFlushWindow = ClientLatencyWindow()
    private let evidencePageAppendWindow = ClientLatencyWindow()

    private var newSampleCount: Int = 0
    private var lastReportTime: Date = Date()
    private let reportInterval: TimeInterval = 10.0
    private let reportSampleThreshold: Int = 16
    private let lock = NSLock()

    /// 内存基线（进程启动时采样）
    private let memoryBaseline: UInt64

    init(platform: String) {
        self.platform = platform
        self.memoryBaseline = TFClientPerfReporter.samplePhysFootprint()
    }

    /// 记录关键路径延迟并判断是否触发上报
    /// - Returns: true 表示应触发上报
    @discardableResult
    func record(event: TFPerformanceEvent, durationMs: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .workspaceSwitch:
            workspaceSwitchWindow.push(durationMs)
        case .fileTreeRequest:
            fileTreeRequestWindow.push(durationMs)
        case .fileTreeExpand:
            fileTreeExpandWindow.push(durationMs)
        case .aiSessionListRequest, .aiSessionListPage, .aiSessionListRefresh:
            aiSessionListWindow.push(durationMs)
        case .aiMessageTailFlush:
            aiMessageTailFlushWindow.push(durationMs)
        case .evidencePageAppend:
            evidencePageAppendWindow.push(durationMs)
        case .workspaceTreeRefresh:
            break
        }
        newSampleCount += 1
        let now = Date()
        let shouldReport = newSampleCount >= reportSampleThreshold
            || now.timeIntervalSince(lastReportTime) >= reportInterval
        if shouldReport {
            newSampleCount = 0
            lastReportTime = now
        }
        return shouldReport
    }

    /// 构建客户端性能上报（需传入当前 project/workspace）
    func buildReport(project: String, workspace: String) -> ClientPerformanceReport {
        lock.lock()
        defer { lock.unlock() }
        let current = TFClientPerfReporter.samplePhysFootprint()
        let delta = Int64(current) - Int64(memoryBaseline)
        return ClientPerformanceReport(
            clientInstanceId: clientInstanceId,
            platform: platform,
            project: project,
            workspace: workspace,
            memory: MemoryUsageSnapshot(
                currentBytes: current,
                peakBytes: current,
                deltaFromBaselineBytes: delta,
                sampleCount: 1
            ),
            workspaceSwitch: workspaceSwitchWindow.toMetricWindow(),
            fileTreeRequest: fileTreeRequestWindow.toMetricWindow(),
            fileTreeExpand: fileTreeExpandWindow.toMetricWindow(),
            aiSessionListRequest: aiSessionListWindow.toMetricWindow(),
            aiMessageTailFlush: aiMessageTailFlushWindow.toMetricWindow(),
            evidencePageAppend: evidencePageAppendWindow.toMetricWindow(),
            reportedAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// 采样当前进程 phys_footprint（字节），使用 task_vm_info
    static func samplePhysFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
