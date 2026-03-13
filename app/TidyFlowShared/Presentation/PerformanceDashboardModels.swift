import Foundation

// MARK: - 统一 surface 标识

/// 仪表盘追踪的产品 surface，与 baselines.json surface_id 保持一致。
/// 注意：此枚举的 rawValue 必须与 apple_client_perf_baselines.json 中各场景的 surface_id 一致，不得随意重命名。
public enum PerformanceTrackedSurface: String, Equatable, Hashable, CaseIterable, Codable, Sendable {
    /// 聊天会话界面（对应 baselines: chat_stream, chat_stream_workspace_switch）
    case chatSession = "chat_session"
    /// 自主进化工作区面板（对应 baselines: evolution_panel, evolution_panel_multi_workspace）
    case evolutionWorkspace = "evolution_workspace"

    /// 对应的场景 ID 列表（用于从回归报告中匹配）
    public var scenarioIds: [String] {
        switch self {
        case .chatSession:
            return ["chat_stream", "chat_stream_workspace_switch"]
        case .evolutionWorkspace:
            return ["evolution_panel", "evolution_panel_multi_workspace"]
        }
    }

    /// 人类可读名称
    public var displayName: String {
        switch self {
        case .chatSession:        return "聊天"
        case .evolutionWorkspace: return "Evolution"
        }
    }
}

// MARK: - 预算状态

/// 性能预算状态，直接映射比较器 pass/warn/fail，语义不允许在 UI 层二次推导。
public enum PerformanceBudgetStatus: String, Equatable, Comparable, Hashable, Codable, Sendable {
    case pass = "pass"
    case warn = "warn"
    case fail = "fail"
    /// 无基线数据可用（报告缺失、场景未覆盖等）
    case unknown = "unknown"

    public static func < (lhs: PerformanceBudgetStatus, rhs: PerformanceBudgetStatus) -> Bool {
        let order: [PerformanceBudgetStatus] = [.pass, .warn, .fail, .unknown]
        let li = order.firstIndex(of: lhs) ?? 0
        let ri = order.firstIndex(of: rhs) ?? 0
        return li < ri
    }

    /// 是否阻断发布
    public var isReleaseBlocking: Bool {
        self == .fail
    }

    /// 颜色语义（macOS/iOS 共享，视图层只消费此属性，不重新判断）
    public var colorSemanticName: String {
        switch self {
        case .pass:    return "green"
        case .warn:    return "yellow"
        case .fail:    return "red"
        case .unknown: return "gray"
        }
    }

    /// 简短标签
    public var label: String {
        switch self {
        case .pass:    return "正常"
        case .warn:    return "接近预算"
        case .fail:    return "超预算"
        case .unknown: return "无数据"
        }
    }
}

// MARK: - 趋势点

/// 性能趋势时间序列中的单个采样点。
/// 所有计算在共享层完成，UI 只消费此结构。
public struct PerformanceTrendPoint: Equatable, Codable, Sendable {
    /// 采样时间戳（Unix 毫秒）
    public let timestampMs: Int64
    /// 关键指标 P95 值（毫秒），无值时为 nil
    public let p95Ms: Double?
    /// 内存增量（字节），无值时为 nil
    public let memoryDeltaBytes: Int64?
    /// 对应的预算状态
    public let budgetStatus: PerformanceBudgetStatus

    public init(
        timestampMs: Int64,
        p95Ms: Double?,
        memoryDeltaBytes: Int64?,
        budgetStatus: PerformanceBudgetStatus
    ) {
        self.timestampMs = timestampMs
        self.p95Ms = p95Ms
        self.memoryDeltaBytes = memoryDeltaBytes
        self.budgetStatus = budgetStatus
    }
}

// MARK: - 回归报告摘要

/// 最近一次 perf-regression 报告的 surface 级别摘要，供 UI 直接消费。
public struct PerformanceRegressionSummary: Equatable, Codable, Sendable {
    /// 整体裁决
    public let overall: PerformanceBudgetStatus
    /// 退化原因列表（从比较器 issues 字段映射）
    public let degradationReasons: [String]
    /// 最差场景 ID
    public let worstScenarioId: String?
    /// 报告生成时间
    public let generatedAt: Date

    public static let empty = PerformanceRegressionSummary(
        overall: .unknown,
        degradationReasons: [],
        worstScenarioId: nil,
        generatedAt: .distantPast
    )

    public init(
        overall: PerformanceBudgetStatus,
        degradationReasons: [String],
        worstScenarioId: String?,
        generatedAt: Date
    ) {
        self.overall = overall
        self.degradationReasons = degradationReasons
        self.worstScenarioId = worstScenarioId
        self.generatedAt = generatedAt
    }
}

// MARK: - 仪表盘投影

/// 产品 UI 直接消费的性能仪表盘投影，按 (project, workspace, surface) 隔离。
/// 只消费，不写回 Core；macOS/iOS 共享同一投影类型。
public struct PerformanceDashboardProjection: Equatable, Sendable {
    /// 所属 project
    public let project: String
    /// 所属 workspace
    public let workspace: String
    /// surface
    public let surface: PerformanceTrackedSurface
    /// 当前预算状态（来自最新实时快照或最近一次回归报告）
    public let budgetStatus: PerformanceBudgetStatus
    /// 最近趋势点（时序，升序，最多 60 个）
    public let trendPoints: [PerformanceTrendPoint]
    /// 最近一次基线回归结果摘要
    public let regressionSummary: PerformanceRegressionSummary
    /// 退化原因（合并实时诊断和回归报告）
    public let degradationReasons: [String]
    /// 投影生成时间戳
    public let projectedAt: Date

    public static func empty(
        project: String = "",
        workspace: String = "",
        surface: PerformanceTrackedSurface = .chatSession
    ) -> PerformanceDashboardProjection {
        PerformanceDashboardProjection(
            project: project,
            workspace: workspace,
            surface: surface,
            budgetStatus: .unknown,
            trendPoints: [],
            regressionSummary: .empty,
            degradationReasons: [],
            projectedAt: .distantPast
        )
    }

    public init(
        project: String,
        workspace: String,
        surface: PerformanceTrackedSurface,
        budgetStatus: PerformanceBudgetStatus,
        trendPoints: [PerformanceTrendPoint],
        regressionSummary: PerformanceRegressionSummary,
        degradationReasons: [String],
        projectedAt: Date
    ) {
        self.project = project
        self.workspace = workspace
        self.surface = surface
        self.budgetStatus = budgetStatus
        self.trendPoints = trendPoints
        self.regressionSummary = regressionSummary
        self.degradationReasons = degradationReasons
        self.projectedAt = projectedAt
    }

    /// 趋势是否在变差（最近 5 个点中超预算比例 > 0.4）
    public var isTrendDegrading: Bool {
        let recent = trendPoints.suffix(5)
        guard recent.count >= 3 else { return false }
        let badCount = recent.filter { $0.budgetStatus >= .warn }.count
        return Double(badCount) / Double(recent.count) > 0.4
    }

    /// 最近一个趋势点的 P95 值
    public var latestP95Ms: Double? {
        trendPoints.last?.p95Ms
    }
}

// MARK: - scope key

/// 性能历史 scope key，用于隔离不同 project/workspace/surface/session 的历史趋势。
public struct PerformanceScopeKey: Hashable, Equatable, Codable, Sendable {
    public let project: String
    public let workspace: String
    public let surface: PerformanceTrackedSurface
    /// session id（聊天会话）或 cycle id（Evolution 循环），为空时使用 workspace 级别隔离
    public let sessionOrCycleId: String

    public init(
        project: String,
        workspace: String,
        surface: PerformanceTrackedSurface,
        sessionOrCycleId: String = ""
    ) {
        self.project = project
        self.workspace = workspace
        self.surface = surface
        self.sessionOrCycleId = sessionOrCycleId
    }

    /// 字符串形式（用于日志、文件名等）
    public var stringKey: String {
        let base = "\(project)/\(workspace)/\(surface.rawValue)"
        return sessionOrCycleId.isEmpty ? base : "\(base)/\(sessionOrCycleId)"
    }
}

// MARK: - 性能仪表盘 Store

/// 共享性能仪表盘 Store。
/// 职责：消费实时 `PerformanceObservabilitySnapshot` 和最近一次回归报告，
/// 生成按 (project, workspace, surface) 隔离的有界历史趋势与预算状态投影。
///
/// 规则（macOS/iOS 共享，不允许各自重算）：
/// - 趋势历史：实时 15 分钟全量 + 持久化最近 24 小时降采样（每 5 分钟一个点）
/// - 内存上限：每个 key 最多 500 个实时点 + 288 个降采样点
/// - 过期淘汰：超过 24 小时的点自动删除
/// - 空态：报告文件缺失时返回 `.unknown`，不报错
/// - 工作区切换时调用 `clearRealtimeBuffer(for:)` 清空对应实时缓存
@MainActor
public final class PerformanceDashboardStore: ObservableObject {

    // MARK: - 常量（共享规则，不允许平台层覆盖）

    /// 实时趋势保留点数上限（约 15 分钟 × 1样本/秒）
    public static let realtimeBufferLimit = 900
    /// 降采样趋势保留点数上限（24h × 12点/h）
    public static let downsampledBufferLimit = 288
    /// 降采样间隔（秒）
    public static let downsampleIntervalSeconds: TimeInterval = 300
    /// 过期淘汰时限（秒）
    public static let expirySeconds: TimeInterval = 86400

    // MARK: - 内部存储

    private var realtimeBuffers: [PerformanceScopeKey: [PerformanceTrendPoint]] = [:]
    private var downsampledBuffers: [PerformanceScopeKey: [PerformanceTrendPoint]] = [:]
    private var regressionSummaries: [PerformanceTrackedSurface: PerformanceRegressionSummary] = [:]
    private var lastDownsampleAt: [PerformanceScopeKey: Date] = [:]

    @Published public private(set) var projections: [PerformanceScopeKey: PerformanceDashboardProjection] = [:]

    public init() {}

    // MARK: - 实时快照摄入

    /// 从实时 `PerformanceObservabilitySnapshot` 摄入趋势点。
    /// 应在收到 `system_snapshot.performance_observability` 更新时调用。
    public func ingestSnapshot(
        _ snapshot: PerformanceObservabilitySnapshot,
        project: String,
        workspace: String,
        sessionOrCycleId: String = ""
    ) {
        guard !project.isEmpty, !workspace.isEmpty else { return }
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let chatKey = PerformanceScopeKey(
            project: project, workspace: workspace,
            surface: .chatSession, sessionOrCycleId: sessionOrCycleId
        )
        let chatClientMetrics = snapshot.clientMetrics.filter {
            $0.project == project && $0.workspace.lowercased() == workspace.lowercased()
        }
        if let latestClient = chatClientMetrics.last {
            let p95 = Double(latestClient.aiMessageTailFlush.p95Ms)
            let memDelta = latestClient.memory.deltaFromBaselineBytes
            let budgetStatus = chatBudgetStatus(p95Ms: p95)
            let point = PerformanceTrendPoint(
                timestampMs: nowMs, p95Ms: p95 > 0 ? p95 : nil,
                memoryDeltaBytes: memDelta, budgetStatus: budgetStatus
            )
            appendRealtime(point, to: chatKey)
        }

        let evoKey = PerformanceScopeKey(
            project: project, workspace: workspace,
            surface: .evolutionWorkspace, sessionOrCycleId: sessionOrCycleId
        )
        let evoWorkspaceMetrics = snapshot.workspaceMetrics.filter {
            $0.project == project && $0.workspace.lowercased() == workspace.lowercased()
        }
        let hasWarningDiagnosis = snapshot.diagnoses.contains {
            $0.severity >= .warning &&
            ($0.context.project == nil || $0.context.project == project) &&
            ($0.context.workspace == nil || $0.context.workspace?.lowercased() == workspace.lowercased())
        }
        let evoBudget: PerformanceBudgetStatus = hasWarningDiagnosis ? .warn : .pass
        let evoPoint = PerformanceTrendPoint(
            timestampMs: nowMs, p95Ms: nil,
            memoryDeltaBytes: chatClientMetrics.last?.memory.deltaFromBaselineBytes,
            budgetStatus: evoBudget
        )
        let _ = evoWorkspaceMetrics
        appendRealtime(evoPoint, to: evoKey)

        rebuildProjection(for: chatKey, now: now)
        rebuildProjection(for: evoKey, now: now)

        maybeDownsample(key: chatKey, now: now)
        maybeDownsample(key: evoKey, now: now)
    }

    // MARK: - 回归报告摄入

    /// 从磁盘读取最近一次 perf-regression 报告并更新摘要。
    /// 应在 app 启动和 perf-regression 完成后调用。
    public func loadRegressionReport(atPath path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        let generatedAtStr = json["generated_at"] as? String ?? ""
        let generatedAt = ISO8601DateFormatter().date(from: generatedAtStr) ?? Date()
        let scenarios = json["scenarios"] as? [[String: Any]] ?? []
        let overallStr = json["overall"] as? String ?? "unknown"
        let overallStatus = PerformanceBudgetStatus(rawValue: overallStr) ?? .unknown

        var bySurface: [PerformanceTrackedSurface: [[String: Any]]] = [:]
        for scenario in scenarios {
            let surfaceIdStr = scenario["surface_id"] as? String ?? ""
            let effectiveSurfaceId: String
            if !surfaceIdStr.isEmpty {
                effectiveSurfaceId = surfaceIdStr
            } else {
                // 向后兼容：surface_id 可能不在旧格式 scenario 里，按 scenario_id 推断
                let sid = scenario["scenario_id"] as? String ?? ""
                effectiveSurfaceId = sid.hasPrefix("evolution") ? "evolution_workspace" : "chat_session"
            }
            guard let surface = PerformanceTrackedSurface(rawValue: effectiveSurfaceId) else { continue }
            bySurface[surface, default: []].append(scenario)
        }

        for surface in PerformanceTrackedSurface.allCases {
            let surfaceScenarios = bySurface[surface] ?? []
            var worstStatus: PerformanceBudgetStatus = .unknown
            var worstScenarioId: String? = nil
            var allIssues: [String] = []
            for sc in surfaceScenarios {
                let scStatus = PerformanceBudgetStatus(rawValue: sc["overall"] as? String ?? "") ?? .unknown
                let scId = sc["scenario_id"] as? String
                if scStatus > worstStatus {
                    worstStatus = scStatus
                    worstScenarioId = scId
                }
                if let issues = sc["issues"] as? [String] {
                    allIssues.append(contentsOf: issues)
                }
            }
            let finalStatus = surfaceScenarios.isEmpty ? overallStatus : worstStatus
            regressionSummaries[surface] = PerformanceRegressionSummary(
                overall: finalStatus,
                degradationReasons: allIssues,
                worstScenarioId: worstScenarioId,
                generatedAt: generatedAt
            )
        }

        for key in projections.keys {
            rebuildProjection(for: key, now: Date())
        }
    }

    // MARK: - 清空实时缓冲（工作区切换时调用）

    /// 清空指定 key 的实时缓冲，防止工作区切换后残留数据。
    public func clearRealtimeBuffer(for key: PerformanceScopeKey) {
        realtimeBuffers[key] = nil
        projections[key] = nil
    }

    /// 清空某个 project/workspace 下所有 surface 的实时缓冲。
    public func clearRealtimeBuffers(project: String, workspace: String) {
        let keysToRemove = realtimeBuffers.keys.filter {
            $0.project == project && $0.workspace == workspace
        }
        for key in keysToRemove {
            realtimeBuffers.removeValue(forKey: key)
            projections.removeValue(forKey: key)
        }
    }

    // MARK: - 投影访问

    /// 获取指定 scope 的仪表盘投影，不存在时返回空态。
    public func projection(for key: PerformanceScopeKey) -> PerformanceDashboardProjection {
        projections[key] ?? .empty(project: key.project, workspace: key.workspace, surface: key.surface)
    }

    /// 获取最近一次回归报告摘要。
    public func regressionSummary(for surface: PerformanceTrackedSurface) -> PerformanceRegressionSummary {
        regressionSummaries[surface] ?? .empty
    }

    // MARK: - 私有辅助

    private func appendRealtime(_ point: PerformanceTrendPoint, to key: PerformanceScopeKey) {
        var buf = realtimeBuffers[key] ?? []
        buf.append(point)
        let cutoffMs = Int64((Date().timeIntervalSince1970 - Self.expirySeconds) * 1000)
        buf = buf.filter { $0.timestampMs >= cutoffMs }
        if buf.count > Self.realtimeBufferLimit {
            buf.removeFirst(buf.count - Self.realtimeBufferLimit)
        }
        realtimeBuffers[key] = buf
    }

    private func maybeDownsample(key: PerformanceScopeKey, now: Date) {
        let last = lastDownsampleAt[key] ?? .distantPast
        guard now.timeIntervalSince(last) >= Self.downsampleIntervalSeconds else { return }
        lastDownsampleAt[key] = now
        guard let buf = realtimeBuffers[key], !buf.isEmpty else { return }
        let p95Values = buf.compactMap { $0.p95Ms }.sorted()
        let p95: Double?
        if p95Values.isEmpty {
            p95 = nil
        } else {
            let idx = max(0, Int(Double(p95Values.count) * 0.95) - 1)
            p95 = p95Values[min(idx, p95Values.count - 1)]
        }
        let memDelta = buf.compactMap { $0.memoryDeltaBytes }.last
        let worstStatus = buf.map { $0.budgetStatus }.max() ?? .unknown
        let downsampledPoint = PerformanceTrendPoint(
            timestampMs: Int64(now.timeIntervalSince1970 * 1000),
            p95Ms: p95, memoryDeltaBytes: memDelta, budgetStatus: worstStatus
        )
        var dsBuf = downsampledBuffers[key] ?? []
        dsBuf.append(downsampledPoint)
        let cutoffMs = Int64((now.timeIntervalSince1970 - Self.expirySeconds) * 1000)
        dsBuf = dsBuf.filter { $0.timestampMs >= cutoffMs }
        if dsBuf.count > Self.downsampledBufferLimit {
            dsBuf.removeFirst(dsBuf.count - Self.downsampledBufferLimit)
        }
        downsampledBuffers[key] = dsBuf
    }

    private func rebuildProjection(for key: PerformanceScopeKey, now: Date) {
        let realtime = realtimeBuffers[key] ?? []
        let downsampled = downsampledBuffers[key] ?? []
        let recentRealtime = Array(realtime.suffix(60))
        let recentDownsampled = Array(downsampled.suffix(max(0, 60 - recentRealtime.count)))
        var trendPoints = (recentDownsampled + recentRealtime).sorted { $0.timestampMs < $1.timestampMs }
        if trendPoints.count > 60 {
            trendPoints = Array(trendPoints.suffix(60))
        }

        let regression = regressionSummaries[key.surface] ?? .empty
        let realtimeBudget = realtime.last?.budgetStatus ?? .unknown
        let regressionBudget = regression.overall
        let combinedBudget: PerformanceBudgetStatus
        if realtimeBudget == .unknown {
            combinedBudget = regressionBudget
        } else if regressionBudget == .unknown {
            combinedBudget = realtimeBudget
        } else {
            combinedBudget = max(realtimeBudget, regressionBudget)
        }

        var degradationReasons: [String] = []
        if realtimeBudget >= .warn {
            degradationReasons.append("realtime:\(realtimeBudget.rawValue)")
        }
        degradationReasons.append(contentsOf: regression.degradationReasons.prefix(3))

        let projection = PerformanceDashboardProjection(
            project: key.project,
            workspace: key.workspace,
            surface: key.surface,
            budgetStatus: combinedBudget,
            trendPoints: trendPoints,
            regressionSummary: regression,
            degradationReasons: degradationReasons,
            projectedAt: now
        )
        projections[key] = projection
    }

    /// 聊天 surface 预算判定（基于 ws pipeline P95，与 baselines chat_stream warn/fail 阈值对齐）
    private func chatBudgetStatus(p95Ms: Double) -> PerformanceBudgetStatus {
        if p95Ms <= 0 { return .unknown }
        if p95Ms > 200 { return .fail }
        if p95Ms > 50  { return .warn }
        return .pass
    }
}
