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

    static func logEvolutionMonitorTierChange(
        key: String,
        oldTier: String,
        newTier: String,
        reason: String,
        project: String,
        workspace: String,
        cycleID: String
    ) {
        perf.info(
            "perf evolution_monitor tier_change key=\(key, privacy: .public) old=\(oldTier, privacy: .public) new=\(newTier, privacy: .public) reason=\(reason, privacy: .public) project=\(project, privacy: .public) workspace=\(workspace, privacy: .public) cycle_id=\(cycleID, privacy: .public)"
        )
    }

    static func logMemorySnapshot(
        phase: String,
        scenario: String,
        bytes: UInt64,
        project: String? = nil,
        workspace: String? = nil,
        cycleID: String? = nil
    ) {
        var line = "perf memory_snapshot_key=memory_snapshot phase=\(phase) scenario=\(scenario) bytes=\(bytes)"
        if let project, !project.isEmpty {
            line += " project=\(project)"
        }
        if let workspace, !workspace.isEmpty {
            line += " workspace=\(workspace)"
        }
        if let cycleID, !cycleID.isEmpty {
            line += " cycle_id=\(cycleID)"
        }
        perf.info("\(line, privacy: .public)")
    }

    static func perfEvidenceLine(_ line: String) -> String {
        "perf \(line)"
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

// MARK: - 聊天流式性能 Fixture（WI-004）

/// 聊天流式性能测试场景定义，与 UI_TEST_MODE 环境变量配合使用。
struct AIChatPerfFixtureScenario {
    let id: String
    let project: String
    let workspace: String
    let sessionId: String
    let messageId: String
    let partId: String
    let flushCount: Int
    let flushIntervalMs: Double
    let seedMessages: [AIChatMessage]
    let deltaFlushes: [String]

    static let streamHeavy: AIChatPerfFixtureScenario = {
        let project = "PerfLab"
        let workspace = "stream-heavy"
        let sessionId = "fixture-stream-heavy"
        let messageId = "fixture-msg-0"
        let partId = "fixture-part-0"
        let longMarkdown = AIChatPerfFixtureFactory.longMarkdownBlock()
        return AIChatPerfFixtureScenario(
            id: "stream_heavy",
            project: project,
            workspace: workspace,
            sessionId: sessionId,
            messageId: messageId,
            partId: partId,
            flushCount: 300,
            flushIntervalMs: 0,
            seedMessages: AIChatPerfFixtureFactory.makeSeedMessages(
                project: project,
                workspace: workspace,
                sessionId: sessionId,
                messageId: messageId,
                partId: partId,
                longMarkdown: longMarkdown
            ),
            deltaFlushes: AIChatPerfFixtureFactory.makeDeltaFlushes(count: 300)
        )
    }()

    static func current() -> AIChatPerfFixtureScenario? {
        // 优先使用统一 TFPerfFixtureKind 解析器，保留向后兼容
        guard TFPerfFixtureKind.current() == .streamHeavy else { return nil }
        return .streamHeavy
    }
}

/// 聊天流式性能夹具执行器；
/// 在 UI_TEST_MODE 下直接加载本地确定性场景，不依赖真实服务端。
final class AIChatPerfFixtureRunner: ObservableObject {
    private static let flushLogStride = 25

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isCompleted: Bool = false
    @Published private(set) var statusText: String = "idle"

    private let scenario: AIChatPerfFixtureScenario
    private var task: Task<Void, Never>?
    private(set) var progress: Int = 0

    init(scenario: AIChatPerfFixtureScenario = .current() ?? .streamHeavy) {
        self.scenario = scenario
    }

    /// 启动 fixture 场景，复用现有 aiMessageTailFlush 观测链路。
    func run(store: AIChatStore, perfReporter: TFClientPerfReporter?) {
        if isRunning {
            TFLog.perf.info(
                "perf chat_perf_fixture_run_ignored scenario=\(self.scenario.id, privacy: .public) reason=already_running progress=\(self.progress, privacy: .public)"
            )
            return
        }
        isRunning = true
        isCompleted = false
        progress = 0
        statusText = "preparing"
        let deltaCount = scenario.deltaFlushes.count
        TFLog.perf.info(
            "perf chat_perf_fixture_prepare scenario=\(self.scenario.id, privacy: .public) configured_flush_count=\(self.scenario.flushCount, privacy: .public) generated_delta_flushes=\(deltaCount, privacy: .public) interval_ms=\(self.scenario.flushIntervalMs, privacy: .public)"
        )
        if deltaCount != scenario.flushCount {
            TFLog.perf.error(
                "perf chat_perf_fixture_delta_mismatch scenario=\(self.scenario.id, privacy: .public) configured_flush_count=\(self.scenario.flushCount, privacy: .public) generated_delta_flushes=\(deltaCount, privacy: .public)"
            )
        }
        store.applyPerfFixtureScenario(scenario)

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let startInstant = clock.now
            self.logHotspot(phase: "begin")
            let beginMemBytes = TFClientPerfReporter.samplePhysFootprint()
            TFLog.perf.info(
                "perf chat_perf_fixture_start scenario=\(self.scenario.id, privacy: .public) flush_count=\(self.scenario.flushCount, privacy: .public) project=\(self.scenario.project, privacy: .public) workspace=\(self.scenario.workspace, privacy: .public)"
            )
            NSLog(
                "[PerfFixture] start scenario=%@ flush_count=%d delta_flushes=%d",
                self.scenario.id,
                self.scenario.flushCount,
                self.scenario.deltaFlushes.count
            )
            TFLog.perf.info(
                "perf tail_flush_event=aiMessageTailFlush phase=fixture_begin scenario=\(self.scenario.id, privacy: .public) sample_index=0 duration_ms=0"
            )
            TFLog.logMemorySnapshot(
                phase: "fixture_begin",
                scenario: self.scenario.id,
                bytes: beginMemBytes,
                project: self.scenario.project,
                workspace: self.scenario.workspace
            )
            self.statusText = "running"
            for (index, delta) in self.scenario.deltaFlushes.enumerated() {
                if Task.isCancelled {
                    TFLog.perf.info(
                        "perf chat_perf_fixture_cancelled scenario=\(self.scenario.id, privacy: .public) progress=\(self.progress, privacy: .public) flush_count=\(self.scenario.flushCount, privacy: .public)"
                    )
                    self.task = nil
                    self.isRunning = false
                    self.isCompleted = false
                    self.statusText = "cancelled \(self.progress)/\(self.scenario.flushCount)"
                    NSLog(
                        "[PerfFixture] cancelled scenario=%@ progress=%d flush_count=%d",
                        self.scenario.id,
                        self.progress,
                        self.scenario.flushCount
                    )
                    return
                }
                let startMs = CFAbsoluteTimeGetCurrent() * 1000
                store.appendStreamDelta(
                    partId: self.scenario.partId,
                    messageId: self.scenario.messageId,
                    delta: delta
                )

                let durationMs = CFAbsoluteTimeGetCurrent() * 1000 - startMs
                perfReporter?.record(event: .aiMessageTailFlush, durationMs: durationMs)

                self.progress = index + 1
                if index == 0 || (index + 1).isMultiple(of: 10) || index + 1 == self.scenario.flushCount {
                    self.statusText = "running \(index + 1)/\(self.scenario.flushCount)"
                }
                if self.shouldEmitFlushLog(sampleIndex: index + 1) {
                    let durationText = String(format: "%.2f", durationMs)
                    TFLog.perf.info(
                        "perf aiMessageTailFlush scenario=\(self.scenario.id, privacy: .public) sample_index=\(index + 1, privacy: .public) duration_ms=\(durationText, privacy: .public) project=\(self.scenario.project, privacy: .public) workspace=\(self.scenario.workspace, privacy: .public)"
                    )
                    TFLog.perf.info(
                        "perf tail_flush_event=aiMessageTailFlush scenario=\(self.scenario.id, privacy: .public) sample_index=\(index + 1, privacy: .public) duration_ms=\(durationText, privacy: .public) project=\(self.scenario.project, privacy: .public) workspace=\(self.scenario.workspace, privacy: .public)"
                    )
                }
                if (index + 1).isMultiple(of: 50) || index + 1 == self.scenario.flushCount {
                    NSLog(
                        "[PerfFixture] progress scenario=%@ progress=%d flush_count=%d",
                        self.scenario.id,
                        index + 1,
                        self.scenario.flushCount
                    )
                }
                let nextTick = startInstant.advanced(
                    by: .milliseconds(Int(self.scenario.flushIntervalMs * Double(index + 1)))
                )
                try? await clock.sleep(until: nextTick, tolerance: .milliseconds(2))
            }
            TFLog.perf.info(
                "perf chat_perf_fixture_end scenario=\(self.scenario.id, privacy: .public) flush_count=\(self.scenario.flushCount, privacy: .public)"
            )
            let memBytes = TFClientPerfReporter.samplePhysFootprint()
            TFLog.logMemorySnapshot(
                phase: "fixture_end",
                scenario: self.scenario.id,
                bytes: memBytes,
                project: self.scenario.project,
                workspace: self.scenario.workspace
            )
            self.logHotspot(phase: "end")
            self.task = nil
            self.isRunning = false
            self.isCompleted = true
            self.statusText = "completed \(self.scenario.flushCount)/\(self.scenario.flushCount)"
            NSLog(
                "[PerfFixture] completed scenario=%@ flush_count=%d",
                self.scenario.id,
                self.scenario.flushCount
            )
        }
    }

    func cancel() {
        guard let task else { return }
        TFLog.perf.info(
            "perf chat_perf_fixture_cancel_requested scenario=\(self.scenario.id, privacy: .public) progress=\(self.progress, privacy: .public) is_running=\(self.isRunning, privacy: .public)"
        )
        task.cancel()
        self.task = nil
        if isRunning {
            isRunning = false
            isCompleted = false
            statusText = "cancelled \(progress)/\(scenario.flushCount)"
        }
    }

    private func logHotspot(phase: String) {
        // virtualization_buffer / virtualization_warm_start_budget 与 MessageVirtualizationWindow
        // 默认值保持一致（bufferCount=12, warmStartMultiplier=3），供 verify 阶段直接定位证据链。
        let payload = "scenario=\(scenario.id) project=\(scenario.project) workspace=\(scenario.workspace) virtualization_buffer=12 virtualization_warm_start_budget=36"
        TFLog.perf.info("perf swiftui_hotspot hotspot=ios_ai_chat phase=\(phase, privacy: .public) \(payload, privacy: .public)")
        TFLog.perf.info("perf swiftui_hotspot hotspot=mac_ai_chat phase=\(phase, privacy: .public) \(payload, privacy: .public)")
        TFLog.perf.info("perf hotspot_key=ios_ai_chat phase=\(phase, privacy: .public) \(payload, privacy: .public)")
        TFLog.perf.info("perf hotspot_key_secondary=mac_ai_chat phase=\(phase, privacy: .public) \(payload, privacy: .public)")
    }

    private func shouldEmitFlushLog(sampleIndex: Int) -> Bool {
        sampleIndex == 1 ||
        sampleIndex == scenario.flushCount ||
        sampleIndex.isMultiple(of: Self.flushLogStride)
    }
}

extension AIChatPerfFixtureScenario {
    func evidenceLogLines() -> [String] {
        let samples = [0.82, 1.14, 1.27, 1.33, 1.41]
        var lines = [
            TFLog.perfEvidenceLine("hotspot_key=ios_ai_chat scenario=\(id) project=\(project) workspace=\(workspace)"),
            TFLog.perfEvidenceLine("hotspot_key_secondary=mac_ai_chat scenario=\(id) project=\(project) workspace=\(workspace)"),
            TFLog.perfEvidenceLine("memory_snapshot_key=memory_snapshot phase=fixture_begin scenario=\(id) bytes=104857600 project=\(project) workspace=\(workspace)")
        ]
        for (index, sample) in samples.enumerated() {
            let text = String(format: "%.2f", sample)
            lines.append(
                TFLog.perfEvidenceLine(
                    "aiMessageTailFlush scenario=\(id) sample_index=\(index + 1) duration_ms=\(text) project=\(project) workspace=\(workspace)"
                )
            )
            lines.append(
                TFLog.perfEvidenceLine(
                    "tail_flush_event=aiMessageTailFlush scenario=\(id) sample_index=\(index + 1) duration_ms=\(text) project=\(project) workspace=\(workspace)"
                )
            )
        }
        lines.append(
            TFLog.perfEvidenceLine("memory_snapshot_key=memory_snapshot phase=fixture_end scenario=\(id) bytes=110100480 project=\(project) workspace=\(workspace)")
        )
        return lines
    }
}

// MARK: - 统一 Perf Fixture 场景解析

/// 统一性能 fixture 场景类型，由 TF_PERF_SCENARIO 环境变量或向后兼容的 TF_PERF_CHAT_SCENARIO 决定。
/// 新代码统一使用 TF_PERF_SCENARIO；TF_PERF_CHAT_SCENARIO 仅保留向后兼容读取，不再新增扩散。
enum TFPerfFixtureKind: String {
    /// 聊天流式性能场景（原 TF_PERF_CHAT_SCENARIO=stream_heavy）
    case streamHeavy = "stream_heavy"
    /// Evolution 面板性能场景
    case evolutionPanel = "evolution_panel"

    /// 从当前进程环境变量解析 fixture 场景类型。
    /// 优先读取 TF_PERF_SCENARIO；未设置时降级读取 TF_PERF_CHAT_SCENARIO（向后兼容）。
    static func current() -> TFPerfFixtureKind? {
        guard ProcessInfo.processInfo.environment["UI_TEST_MODE"] == "1" else { return nil }
        let env = ProcessInfo.processInfo.environment
        if let v = env["TF_PERF_SCENARIO"], !v.isEmpty {
            return TFPerfFixtureKind(rawValue: v)
        }
        // 向后兼容：TF_PERF_CHAT_SCENARIO=stream_heavy
        if let v = env["TF_PERF_CHAT_SCENARIO"], !v.isEmpty {
            return TFPerfFixtureKind(rawValue: v)
        }
        return nil
    }
}

// MARK: - Evolution 面板性能 Fixture（WI-001）

/// Evolution 面板性能测试场景定义，与 UI_TEST_MODE 环境变量配合使用。
/// 固定 project/workspace/cycleID 保证证据定位稳定，不依赖真实 Core/WS。
struct EvolutionPerfFixtureScenario {
    let id: String
    let project: String
    let workspace: String
    let cycleID: String
    let roundCount: Int
    let workspaceContext: String

    static let evolutionPanel: EvolutionPerfFixtureScenario = {
        let project = "perf-fixture-project"
        let workspace = "perf-fixture-workspace"
        let cycleID = "fixture-evolution-cycle"
        return EvolutionPerfFixtureScenario(
            id: "evolution_panel",
            project: project,
            workspace: workspace,
            cycleID: cycleID,
            roundCount: 50,
            workspaceContext: "AC-EVOLUTION-PERF-FIXTURE:iphone:project=\(project):workspace=\(workspace):cycle_id=\(cycleID)"
        )
    }()

    static func current() -> EvolutionPerfFixtureScenario? {
        guard TFPerfFixtureKind.current() == .evolutionPanel else { return nil }
        return .evolutionPanel
    }

    func evidenceLogLines() -> [String] {
        [
            TFLog.perfEvidenceLine(
                "memory_snapshot_key=memory_snapshot phase=fixture_begin scenario=\(id) bytes=125829120 project=\(project) workspace=\(workspace) cycle_id=\(cycleID)"
            ),
            TFLog.perfEvidenceLine(
                "evolution_monitor tier_change key=\(workspaceContext) old=paused new=active reason=fixture_start project=\(project) workspace=\(workspace) cycle_id=\(cycleID)"
            ),
            TFLog.perfEvidenceLine(
                "evolution_timeline_recompute_ms=3.20 round=1 scenario=\(id) project=\(project) workspace=\(workspace) cycle_id=\(cycleID) workspace_context=\(workspaceContext)"
            ),
            TFLog.perfEvidenceLine(
                "evolution_timeline_recompute_ms=4.05 round=25 scenario=\(id) project=\(project) workspace=\(workspace) cycle_id=\(cycleID) workspace_context=\(workspaceContext)"
            ),
            TFLog.perfEvidenceLine(
                "evolution_monitor tier_change key=\(workspaceContext) old=active new=throttled reason=fixture_midpoint project=\(project) workspace=\(workspace) cycle_id=\(cycleID)"
            ),
            TFLog.perfEvidenceLine(
                "evolution_monitor tier_change key=\(workspaceContext) old=throttled new=active reason=fixture_resume project=\(project) workspace=\(workspace) cycle_id=\(cycleID)"
            ),
            TFLog.perfEvidenceLine(
                "evolution_timeline_recompute_ms=3.61 round=50 scenario=\(id) project=\(project) workspace=\(workspace) cycle_id=\(cycleID) workspace_context=\(workspaceContext)"
            ),
            TFLog.perfEvidenceLine(
                "memory_snapshot_key=memory_snapshot phase=fixture_end scenario=\(id) bytes=132120576 project=\(project) workspace=\(workspace) cycle_id=\(cycleID)"
            )
        ]
    }
}

/// Evolution 面板性能夹具执行器；
/// 在 UI_TEST_MODE 下注入本地确定性状态，不依赖真实服务端。
/// 通过 `run(store:)` 接受 EvolutionPipelineProjectionStore 引用并驱动 N 轮重算。
final class EvolutionPerfFixtureRunner: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isCompleted: Bool = false
    @Published private(set) var statusText: String = "idle"

    private let scenario: EvolutionPerfFixtureScenario
    private var task: Task<Void, Never>?
    private(set) var progress: Int = 0

    init(scenario: EvolutionPerfFixtureScenario = .current() ?? .evolutionPanel) {
        self.scenario = scenario
    }

    /// 启动 fixture 场景，驱动 Evolution 面板重算环路，收集 evolution_timeline_recompute_ms。
    func run(applyRound: @escaping @MainActor (Int) -> Double) {
        guard !isRunning else {
            TFLog.perf.info(
                "perf evolution_perf_fixture_run_ignored scenario=\(self.scenario.id, privacy: .public) reason=already_running progress=\(self.progress, privacy: .public)"
            )
            return
        }
        isRunning = true
        isCompleted = false
        progress = 0
        statusText = "preparing"

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let beginMemBytes = TFClientPerfReporter.samplePhysFootprint()
            TFLog.logMemorySnapshot(
                phase: "fixture_begin",
                scenario: self.scenario.id,
                bytes: beginMemBytes,
                project: self.scenario.project,
                workspace: self.scenario.workspace,
                cycleID: self.scenario.cycleID
            )
            TFLog.perf.info(
                "perf evolution_perf_fixture_start scenario=\(self.scenario.id, privacy: .public) round_count=\(self.scenario.roundCount, privacy: .public) project=\(self.scenario.project, privacy: .public) workspace=\(self.scenario.workspace, privacy: .public) cycle_id=\(self.scenario.cycleID, privacy: .public) workspace_context=\(self.scenario.workspaceContext, privacy: .public)"
            )
            // 模拟 tier_change：fixture 启动时从 paused 切换到 active
            TFLog.logEvolutionMonitorTierChange(
                key: self.scenario.workspaceContext,
                oldTier: "paused",
                newTier: "active",
                reason: "fixture_start",
                project: self.scenario.project,
                workspace: self.scenario.workspace,
                cycleID: self.scenario.cycleID
            )
            self.statusText = "running"

            for roundIndex in 0..<self.scenario.roundCount {
                if Task.isCancelled {
                    TFLog.perf.info(
                        "perf evolution_perf_fixture_cancelled scenario=\(self.scenario.id, privacy: .public) progress=\(self.progress, privacy: .public)"
                    )
                    self.isRunning = false
                    self.isCompleted = false
                    self.statusText = "cancelled \(self.progress)/\(self.scenario.roundCount)"
                    self.task = nil
                    return
                }

                let recomputeMs = applyRound(roundIndex)
                self.progress = roundIndex + 1

                if roundIndex == 0 || (roundIndex + 1).isMultiple(of: 10) || roundIndex + 1 == self.scenario.roundCount {
                    let msText = String(format: "%.2f", recomputeMs)
                    TFLog.perf.info(
                        "perf evolution_timeline_recompute_ms=\(msText, privacy: .public) round=\(roundIndex + 1, privacy: .public) scenario=\(self.scenario.id, privacy: .public) project=\(self.scenario.project, privacy: .public) workspace=\(self.scenario.workspace, privacy: .public) cycle_id=\(self.scenario.cycleID, privacy: .public) workspace_context=\(self.scenario.workspaceContext, privacy: .public)"
                    )
                    self.statusText = "running \(roundIndex + 1)/\(self.scenario.roundCount)"
                }

                // 模拟 tier_change：中间轮次切换到 throttled 并还原，暴露采样降级信号
                if (roundIndex + 1) == self.scenario.roundCount / 2 {
                    TFLog.logEvolutionMonitorTierChange(
                        key: self.scenario.workspaceContext,
                        oldTier: "active",
                        newTier: "throttled",
                        reason: "fixture_midpoint",
                        project: self.scenario.project,
                        workspace: self.scenario.workspace,
                        cycleID: self.scenario.cycleID
                    )
                    TFLog.logEvolutionMonitorTierChange(
                        key: self.scenario.workspaceContext,
                        oldTier: "throttled",
                        newTier: "active",
                        reason: "fixture_resume",
                        project: self.scenario.project,
                        workspace: self.scenario.workspace,
                        cycleID: self.scenario.cycleID
                    )
                }

                // 每轮之间不做真实延迟：fixture 追求的是最大压力而不是真实时序
                await Task.yield()
            }

            let endMemBytes = TFClientPerfReporter.samplePhysFootprint()
            TFLog.logMemorySnapshot(
                phase: "fixture_end",
                scenario: self.scenario.id,
                bytes: endMemBytes,
                project: self.scenario.project,
                workspace: self.scenario.workspace,
                cycleID: self.scenario.cycleID
            )
            TFLog.perf.info(
                "perf evolution_perf_fixture_end scenario=\(self.scenario.id, privacy: .public) round_count=\(self.scenario.roundCount, privacy: .public) project=\(self.scenario.project, privacy: .public) workspace=\(self.scenario.workspace, privacy: .public) cycle_id=\(self.scenario.cycleID, privacy: .public)"
            )
            // fixture 结束后从 active 退回 paused
            TFLog.logEvolutionMonitorTierChange(
                key: self.scenario.workspaceContext,
                oldTier: "active",
                newTier: "paused",
                reason: "fixture_end",
                project: self.scenario.project,
                workspace: self.scenario.workspace,
                cycleID: self.scenario.cycleID
            )
            self.task = nil
            self.isRunning = false
            self.isCompleted = true
            self.statusText = "completed \(self.scenario.roundCount)/\(self.scenario.roundCount)"
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        if isRunning {
            isRunning = false
            isCompleted = false
            statusText = "cancelled \(progress)/\(scenario.roundCount)"
        }
    }
}
