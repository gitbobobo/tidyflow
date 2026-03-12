import Foundation

// MARK: - 采样档位

/// Evolution 面板实时性能采样档位
public enum EvolutionRealtimeSamplingTier: String, Equatable, CaseIterable, Sendable {
    /// 停止采样：面板不可见、scene inactive、无运行中代理或 WS 断连
    case paused
    /// 高频采样：1s 间隔，低压健康状态
    case live
    /// 平衡采样：2s 间隔，轻度压力
    case balanced
    /// 降级采样：5s 间隔，高压或存在 critical 诊断
    case degraded

    /// 采样间隔（毫秒），paused 返回 nil 表示不采样
    public var intervalMs: Int? {
        switch self {
        case .paused:    return nil
        case .live:      return 1000
        case .balanced:  return 2000
        case .degraded:  return 5000
        }
    }

    /// 是否启用实时动画（degraded/paused 时关闭动画以节省资源）
    public var enableAnimation: Bool {
        switch self {
        case .live, .balanced: return true
        case .degraded, .paused: return false
        }
    }

    /// 档位的人类可读说明
    public var displayName: String {
        switch self {
        case .paused:    return "paused"
        case .live:      return "live(1s)"
        case .balanced:  return "balanced(2s)"
        case .degraded:  return "degraded(5s)"
        }
    }
}

// MARK: - 采样决策

/// Evolution 面板当前采样决策（档位 + 元信息）
public struct EvolutionRealtimeSamplingDecision: Equatable, Sendable {
    /// 当前档位
    public let tier: EvolutionRealtimeSamplingTier
    /// 决定此档位的原因摘要（用于日志与调试）
    public let reason: String
    /// 连续健康采样周期计数（用于迟滞升档判断）
    public let consecutiveHealthyCount: Int

    public init(
        tier: EvolutionRealtimeSamplingTier,
        reason: String,
        consecutiveHealthyCount: Int = 0
    ) {
        self.tier = tier
        self.reason = reason
        self.consecutiveHealthyCount = consecutiveHealthyCount
    }

    /// 是否启用实时动画
    public var enableAnimation: Bool { tier.enableAnimation }

    public static let paused = EvolutionRealtimeSamplingDecision(
        tier: .paused, reason: "initial", consecutiveHealthyCount: 0
    )
}

// MARK: - 实时指标投影

/// Evolution 面板已过滤到当前工作区与客户端实例的实时指标投影
public struct EvolutionRealtimeMetricsProjection: Equatable, Sendable {
    /// 当前工作区过滤后的工作区性能快照（只包含匹配 project/workspace 的条目）
    public let workspaceMetrics: [WorkspacePerformanceSnapshot]
    /// 当前客户端实例过滤后的客户端性能报告
    public let clientMetrics: [ClientPerformanceReport]
    /// 过滤后的诊断结果（已排除与当前工作区/实例无关的诊断）
    public let diagnoses: [PerformanceDiagnosis]
    /// 快照时间戳
    public let snapshotAt: UInt64

    public static let empty = EvolutionRealtimeMetricsProjection(
        workspaceMetrics: [], clientMetrics: [], diagnoses: [], snapshotAt: 0
    )

    public init(
        workspaceMetrics: [WorkspacePerformanceSnapshot],
        clientMetrics: [ClientPerformanceReport],
        diagnoses: [PerformanceDiagnosis],
        snapshotAt: UInt64
    ) {
        self.workspaceMetrics = workspaceMetrics
        self.clientMetrics = clientMetrics
        self.diagnoses = diagnoses
        self.snapshotAt = snapshotAt
    }

    /// 是否存在 critical 级诊断
    public var hasCriticalDiagnosis: Bool {
        diagnoses.contains { $0.severity == .critical }
    }

    /// 是否存在任意诊断（包含 warning 及以上）
    public var hasWarningOrHigher: Bool {
        diagnoses.contains { $0.severity >= .warning }
    }

    /// 最高诊断严重度（无诊断时返回 nil）
    public var maxSeverity: PerformanceDiagnosisSeverity? {
        diagnoses.map(\.severity).max()
    }

    /// 当前工作区内存 delta（字节），取最新的客户端报告
    public var clientMemoryDeltaBytes: Int64 {
        clientMetrics.last?.memory.deltaFromBaselineBytes ?? 0
    }

    /// ws pipeline p95 延迟（ms）
    public var wsPipelineP95Ms: UInt32 {
        workspaceMetrics.first.map { _ in 0 } ?? 0
    }

    /// 签名（用于检测投影是否发生有意义的变化，避免无差别重绘）
    public var signature: Int {
        var h = Hasher()
        h.combine(snapshotAt)
        h.combine(diagnoses.count)
        for d in diagnoses {
            h.combine(d.diagnosisId)
            h.combine(d.severity.rawValue)
            h.combine(d.reason.rawValue)
        }
        h.combine(clientMetrics.count)
        if let last = clientMetrics.last {
            h.combine(last.memory.deltaFromBaselineBytes)
        }
        h.combine(workspaceMetrics.count)
        return h.finalize()
    }
}

// MARK: - 面板性能投影

/// Evolution 面板性能投影（含采样决策与已过滤指标）
public struct EvolutionPipelinePerformanceProjection: Equatable, Sendable {
    /// 当前采样决策
    public let decision: EvolutionRealtimeSamplingDecision
    /// 已过滤的实时指标投影
    public let metrics: EvolutionRealtimeMetricsProjection

    public static let empty = EvolutionPipelinePerformanceProjection(
        decision: .paused,
        metrics: .empty
    )

    public init(
        decision: EvolutionRealtimeSamplingDecision,
        metrics: EvolutionRealtimeMetricsProjection
    ) {
        self.decision = decision
        self.metrics = metrics
    }

    /// 当前采样档位
    public var tier: EvolutionRealtimeSamplingTier { decision.tier }

    /// 是否启用实时动画
    public var enableAnimation: Bool { decision.enableAnimation }
}

// MARK: - 采样语义计算

/// Evolution 实时采样决策语义层
///
/// 负责根据当前可观测输入计算目标档位，不保留任何状态（纯函数）。
/// 迟滞逻辑（连续健康计数）由调用方传入。
public enum EvolutionRealtimeSamplingSemantics {

    // MARK: - 过滤投影

    /// 从全量 PerformanceObservabilitySnapshot 过滤出当前工作区与客户端实例相关的指标
    public static func filterMetrics(
        snapshot: PerformanceObservabilitySnapshot,
        project: String,
        workspace: String,
        clientInstanceId: String
    ) -> EvolutionRealtimeMetricsProjection {
        guard !project.isEmpty, !workspace.isEmpty else {
            return .empty
        }

        let normalizedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let workspaceMetrics = snapshot.workspaceMetrics.filter { m in
            m.project == project
                && m.workspace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedWorkspace
        }

        let clientMetrics = snapshot.clientMetrics.filter { r in
            r.clientInstanceId == clientInstanceId
                && r.project == project
                && r.workspace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedWorkspace
        }

        // 诊断过滤：system 级别诊断保留；workspace/client 级别只保留与当前上下文匹配的条目
        let diagnoses = snapshot.diagnoses.filter { d in
            switch d.scope {
            case .system:
                return true
            case .workspace:
                let ctxProject = d.context.project ?? ""
                let ctxWorkspace = (d.context.workspace ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return ctxProject == project && ctxWorkspace == normalizedWorkspace
            case .clientInstance:
                let matchesInstance = d.clientInstanceId == clientInstanceId
                let ctxProject = d.context.project ?? ""
                let ctxWorkspace = (d.context.workspace ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let matchesWorkspace = ctxProject.isEmpty
                    || (ctxProject == project && (ctxWorkspace.isEmpty || ctxWorkspace == normalizedWorkspace))
                return matchesInstance && matchesWorkspace
            }
        }

        return EvolutionRealtimeMetricsProjection(
            workspaceMetrics: workspaceMetrics,
            clientMetrics: clientMetrics,
            diagnoses: diagnoses,
            snapshotAt: snapshot.snapshotAt
        )
    }

    // MARK: - 档位计算

    /// 计算目标档位（不含迟滞逻辑）
    ///
    /// - Parameters:
    ///   - metrics: 已过滤的实时指标投影
    ///   - runningAgentCount: 当前正在运行的代理数
    ///   - sceneActive: scene 是否活跃
    ///   - panelVisible: 面板是否可见
    ///   - wsConnected: WS 是否已连接
    /// - Returns: 目标档位及决定原因
    public static func targetTier(
        metrics: EvolutionRealtimeMetricsProjection,
        runningAgentCount: Int,
        sceneActive: Bool,
        panelVisible: Bool,
        wsConnected: Bool
    ) -> (tier: EvolutionRealtimeSamplingTier, reason: String) {
        // paused 条件
        guard sceneActive else {
            return (.paused, "scene_inactive")
        }
        guard panelVisible else {
            return (.paused, "panel_not_visible")
        }
        guard wsConnected else {
            return (.paused, "ws_disconnected")
        }
        guard runningAgentCount > 0 else {
            return (.paused, "no_running_agents")
        }

        // degraded 条件（立即降级，不经过迟滞）
        if metrics.hasCriticalDiagnosis {
            let reasons = metrics.diagnoses
                .filter { $0.severity == .critical }
                .map { $0.reason.rawValue }
                .joined(separator: ",")
            return (.degraded, "critical_diagnosis:\(reasons)")
        }
        let memoryDeltaMB = Int64(metrics.clientMemoryDeltaBytes) / (1024 * 1024)
        if memoryDeltaMB >= 192 {
            return (.degraded, "memory_delta_\(memoryDeltaMB)mb")
        }
        let degradedDiagnosisReasons: Set<PerformanceDiagnosisReason> = [
            .clientMemoryPressure, .memoryGrowthUnbounded, .wsPipelineLatencyHigh
        ]
        if metrics.diagnoses.contains(where: { degradedDiagnosisReasons.contains($0.reason) }) {
            let reasons = metrics.diagnoses
                .filter { degradedDiagnosisReasons.contains($0.reason) }
                .map { $0.reason.rawValue }
                .joined(separator: ",")
            return (.degraded, "diagnosis_reason:\(reasons)")
        }

        // 提取 wsPipelineLatency p95（从 workspaceMetrics 取，fallback 到 snapshot 全局）
        // workspaceMetrics 不携带 wsPipelineLatency，此处暂通过 runningAgentCount >= 3 或诊断触发 balanced
        let wsP95Ms: UInt32 = 0 // workspaceMetrics 中无直接 wsPipelineLatency 字段

        // balanced 条件
        if runningAgentCount >= 3 {
            return (.balanced, "running_agents_\(runningAgentCount)")
        }
        if metrics.hasWarningOrHigher {
            return (.balanced, "warning_diagnosis")
        }
        if memoryDeltaMB >= 96 {
            return (.balanced, "memory_delta_\(memoryDeltaMB)mb")
        }
        let _ = wsP95Ms // 当前 workspaceMetrics 不暴露 ws 延迟，预留扩展

        return (.live, "healthy")
    }

    /// 应用迟滞规则，计算最终决策
    ///
    /// 升档需要连续 2 个健康周期；降档立即生效。
    ///
    /// - Parameters:
    ///   - targetTier: 当前输入决定的目标档位
    ///   - targetReason: 目标档位原因
    ///   - currentDecision: 上一次的采样决策
    /// - Returns: 应用迟滞后的最终决策
    public static func applyHysteresis(
        targetTier: EvolutionRealtimeSamplingTier,
        targetReason: String,
        currentDecision: EvolutionRealtimeSamplingDecision
    ) -> EvolutionRealtimeSamplingDecision {
        let currentTier = currentDecision.tier
        let currentHealthy = currentDecision.consecutiveHealthyCount

        // 从 paused 恢复时不做“连续健康”迟滞，避免面板恢复后卡在 paused。
        // 健康目标先回到 balanced，critical/pressure 类目标直接落到其目标档位。
        if currentTier == .paused, targetTier != .paused {
            let resumedTier: EvolutionRealtimeSamplingTier = targetTier == .live ? .balanced : targetTier
            return EvolutionRealtimeSamplingDecision(
                tier: resumedTier,
                reason: targetReason,
                consecutiveHealthyCount: 0
            )
        }

        // 降级立即生效
        let targetOrder = tierOrder(targetTier)
        let currentOrder = tierOrder(currentTier)

        if targetOrder < currentOrder {
            // 降级（paused < live < balanced < degraded 从高到低）
            // 实际上档位排序是：paused(0) < live(1) < balanced(2) < degraded(3)
            // 降级 = targetOrder > currentOrder（向更低频方向）
        }

        // 重新定义：order 越大 = 越慢/越低频
        // paused=3, degraded=2, balanced=1, live=0
        // 降级 = 目标比当前更慢 → 立即生效
        let tgtSlowness = slowness(targetTier)
        let curSlowness = slowness(currentTier)

        if tgtSlowness >= curSlowness {
            // 降级或保持，立即生效，重置健康计数
            return EvolutionRealtimeSamplingDecision(
                tier: targetTier,
                reason: targetReason,
                consecutiveHealthyCount: 0
            )
        }

        // 升档需要迟滞：连续 2 个周期健康才允许
        let newHealthyCount = currentHealthy + 1
        if newHealthyCount >= 2 {
            return EvolutionRealtimeSamplingDecision(
                tier: targetTier,
                reason: "\(targetReason)(hysteresis:\(newHealthyCount))",
                consecutiveHealthyCount: 0
            )
        }
        // 尚未满足迟滞，保持当前档位但递增健康计数
        return EvolutionRealtimeSamplingDecision(
            tier: currentTier,
            reason: "hysteresis_pending(\(targetReason),count:\(newHealthyCount))",
            consecutiveHealthyCount: newHealthyCount
        )
    }

    // MARK: - 辅助

    private static func tierOrder(_ tier: EvolutionRealtimeSamplingTier) -> Int {
        switch tier {
        case .live:      return 0
        case .balanced:  return 1
        case .degraded:  return 2
        case .paused:    return 3
        }
    }

    /// 慢度：数值越大 = 采样越慢/越低频（用于判断升降级方向）
    private static func slowness(_ tier: EvolutionRealtimeSamplingTier) -> Int {
        tierOrder(tier)
    }

    /// 一步计算完整采样决策（targetTier + 迟滞）
    public static func computeDecision(
        metrics: EvolutionRealtimeMetricsProjection,
        runningAgentCount: Int,
        sceneActive: Bool,
        panelVisible: Bool,
        wsConnected: Bool,
        currentDecision: EvolutionRealtimeSamplingDecision
    ) -> EvolutionRealtimeSamplingDecision {
        let (target, reason) = targetTier(
            metrics: metrics,
            runningAgentCount: runningAgentCount,
            sceneActive: sceneActive,
            panelVisible: panelVisible,
            wsConnected: wsConnected
        )
        return applyHysteresis(
            targetTier: target,
            targetReason: reason,
            currentDecision: currentDecision
        )
    }
}
