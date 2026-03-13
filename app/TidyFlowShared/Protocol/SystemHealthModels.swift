import Foundation

// MARK: - 系统健康诊断与自修复共享模型（WI-001 / WI-004）
//
// 与 `core/src/server/protocol/health.rs` 保持语义一致。
// macOS 与 iOS 双端均消费此文件，不允许在各端各自定义健康模型。
//
// ## 多项目隔离原则
// - 每个 incident 必须携带 context（project / workspace / session_id / cycle_id）
// - repair action 必须按 project/workspace 边界执行，不得跨工作区误施加

// MARK: - 公共归属上下文

/// 健康事件归属上下文（兼容多项目 / 多工作区 / 多会话并行场景）
public struct HealthContext: Codable, Equatable, Hashable, Sendable {
    public var project: String?
    public var workspace: String?
    public var sessionId: String?
    public var cycleId: String?

    public static let system = HealthContext()

    public init(project: String? = nil, workspace: String? = nil,
                sessionId: String? = nil, cycleId: String? = nil) {
        self.project = project
        self.workspace = workspace
        self.sessionId = sessionId
        self.cycleId = cycleId
    }

    public static func forWorkspace(project: String, workspace: String) -> HealthContext {
        HealthContext(project: project, workspace: workspace)
    }

    enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case sessionId = "session_id"
        case cycleId = "cycle_id"
    }

    public static func from(json: [String: Any]?) -> HealthContext {
        guard let json else { return .system }
        return HealthContext(
            project: json["project"] as? String,
            workspace: json["workspace"] as? String,
            sessionId: json["session_id"] as? String,
            cycleId: json["cycle_id"] as? String
        )
    }
}

// MARK: - Incident 枚举类型

/// 异常严重级别
public enum IncidentSeverity: String, Codable, Comparable, CaseIterable {
    case info
    case warning
    case critical

    private var sortOrder: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: IncidentSeverity, rhs: IncidentSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// 异常可恢复性
public enum IncidentRecoverability: String, Codable, CaseIterable {
    /// 可由系统自动修复
    case recoverable
    /// 需要人工干预
    case manual
    /// 永久性故障（进程重启方可恢复）
    case permanent
}

/// 异常来源
public enum IncidentSource: String, Codable, CaseIterable {
    case coreProcess = "core_process"
    case coreWorkspaceCache = "core_workspace_cache"
    case coreEvolution = "core_evolution"
    case coreLog = "core_log"
    case clientConnectivity = "client_connectivity"
    case clientState = "client_state"
}

// MARK: - 健康异常条目

/// 标准化健康异常条目
public struct HealthIncident: Codable, Identifiable, Equatable {
    public let incidentId: String
    public let severity: IncidentSeverity
    public let recoverability: IncidentRecoverability
    public let source: IncidentSource
    public let rootCause: String
    public let summary: String?
    public let firstSeenAt: UInt64
    public let lastSeenAt: UInt64
    public let context: HealthContext

    public var id: String { incidentId }

    public init(incidentId: String, severity: IncidentSeverity,
                recoverability: IncidentRecoverability, source: IncidentSource,
                rootCause: String, summary: String? = nil,
                firstSeenAt: UInt64, lastSeenAt: UInt64, context: HealthContext) {
        self.incidentId = incidentId
        self.severity = severity
        self.recoverability = recoverability
        self.source = source
        self.rootCause = rootCause
        self.summary = summary
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case incidentId = "incident_id"
        case severity, recoverability, source
        case rootCause = "root_cause"
        case summary
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case context
    }

    public static func from(json: [String: Any]) -> HealthIncident? {
        guard let incidentId = json["incident_id"] as? String,
              let severityRaw = json["severity"] as? String,
              let severity = IncidentSeverity(rawValue: severityRaw),
              let recoverabilityRaw = json["recoverability"] as? String,
              let recoverability = IncidentRecoverability(rawValue: recoverabilityRaw),
              let sourceRaw = json["source"] as? String,
              let source = IncidentSource(rawValue: sourceRaw),
              let rootCause = json["root_cause"] as? String,
              let firstSeenAt = json["first_seen_at"] as? UInt64,
              let lastSeenAt = json["last_seen_at"] as? UInt64
        else { return nil }
        return HealthIncident(
            incidentId: incidentId,
            severity: severity,
            recoverability: recoverability,
            source: source,
            rootCause: rootCause,
            summary: json["summary"] as? String,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            context: HealthContext.from(json: json["context"] as? [String: Any])
        )
    }
}

// MARK: - 系统整体健康状态

/// 系统整体健康状态
public enum SystemHealthStatus: String, Codable, CaseIterable {
    case healthy
    case degraded
    case unhealthy
}

// MARK: - 系统健康快照（Core 权威真源）

/// 系统健康快照（由 Core 聚合推送，双端消费）
public struct SystemHealthSnapshot: Codable {
    public let snapshotAt: UInt64
    public let overallStatus: SystemHealthStatus
    public let incidents: [HealthIncident]
    public let recentRepairs: [RepairAuditEntry]
    /// 调度优化建议列表（v1.44，Core 权威输出）
    public let schedulingRecommendations: [SchedulingRecommendation]
    /// 预测异常摘要列表（v1.44，Core 权威输出）
    public let predictiveAnomalies: [PredictiveAnomaly]
    /// 按 (project, workspace) 隔离的观测历史聚合（v1.44）
    public let observationAggregates: [ObservationAggregate]

    public init(snapshotAt: UInt64, overallStatus: SystemHealthStatus,
                incidents: [HealthIncident], recentRepairs: [RepairAuditEntry] = [],
                schedulingRecommendations: [SchedulingRecommendation] = [],
                predictiveAnomalies: [PredictiveAnomaly] = [],
                observationAggregates: [ObservationAggregate] = []) {
        self.snapshotAt = snapshotAt
        self.overallStatus = overallStatus
        self.incidents = incidents
        self.recentRepairs = recentRepairs
        self.schedulingRecommendations = schedulingRecommendations
        self.predictiveAnomalies = predictiveAnomalies
        self.observationAggregates = observationAggregates
    }

    enum CodingKeys: String, CodingKey {
        case snapshotAt = "snapshot_at"
        case overallStatus = "overall_status"
        case incidents
        case recentRepairs = "recent_repairs"
        case schedulingRecommendations = "scheduling_recommendations"
        case predictiveAnomalies = "predictive_anomalies"
        case observationAggregates = "observation_aggregates"
    }

    /// 过滤指定 project+workspace 的 incidents（nil 表示系统级）
    public func incidents(for project: String?, workspace: String?) -> [HealthIncident] {
        incidents.filter { incident in
            incident.context.project == project && incident.context.workspace == workspace
        }
    }

    /// 过滤指定 project+workspace 的预测异常
    public func predictiveAnomalies(for project: String?, workspace: String?) -> [PredictiveAnomaly] {
        predictiveAnomalies.filter { anomaly in
            anomaly.context.project == project && anomaly.context.workspace == workspace
        }
    }

    /// 过滤指定 project+workspace 的调度优化建议（系统级建议始终包含）
    public func schedulingRecommendations(for project: String?, workspace: String?) -> [SchedulingRecommendation] {
        schedulingRecommendations.filter { rec in
            let isSystemLevel = rec.context.project == nil && rec.context.workspace == nil
            let isWorkspaceLevel = rec.context.project == project && rec.context.workspace == workspace
            return isSystemLevel || isWorkspaceLevel
        }
    }

    /// 获取指定 project+workspace 的观测聚合
    public func observationAggregate(for project: String, workspace: String) -> ObservationAggregate? {
        observationAggregates.first { $0.project == project && $0.workspace == workspace }
    }

    /// 取所有可自动修复的 incidents
    public var recoverableIncidents: [HealthIncident] {
        incidents.filter { $0.recoverability == .recoverable }
    }

    public static func from(json: [String: Any]) -> SystemHealthSnapshot? {
        guard let snapshotAt = json["snapshot_at"] as? UInt64,
              let statusRaw = json["overall_status"] as? String,
              let overallStatus = SystemHealthStatus(rawValue: statusRaw)
        else { return nil }
        let incidents = (json["incidents"] as? [[String: Any]] ?? []).compactMap {
            HealthIncident.from(json: $0)
        }
        let recentRepairs = (json["recent_repairs"] as? [[String: Any]] ?? []).compactMap {
            RepairAuditEntry.from(json: $0)
        }
        let schedulingRecommendations = (json["scheduling_recommendations"] as? [[String: Any]] ?? []).compactMap {
            SchedulingRecommendation.from(json: $0)
        }
        let predictiveAnomalies = (json["predictive_anomalies"] as? [[String: Any]] ?? []).compactMap {
            PredictiveAnomaly.from(json: $0)
        }
        let observationAggregates = (json["observation_aggregates"] as? [[String: Any]] ?? []).compactMap {
            ObservationAggregate.from(json: $0)
        }
        return SystemHealthSnapshot(
            snapshotAt: snapshotAt,
            overallStatus: overallStatus,
            incidents: incidents,
            recentRepairs: recentRepairs,
            schedulingRecommendations: schedulingRecommendations,
            predictiveAnomalies: predictiveAnomalies,
            observationAggregates: observationAggregates
        )
    }
}

// MARK: - 调度优化建议（v1.44: 智能调度与预测性故障检测）

/// 调度优化建议类型
public enum SchedulingRecommendationKind: String, Codable, CaseIterable {
    case reduceConcurrency = "reduce_concurrency"
    case increaseConcurrency = "increase_concurrency"
    case adjustPriority = "adjust_priority"
    case enableDegradation = "enable_degradation"
    case deferQueuing = "defer_queuing"
}

/// 资源压力级别（Core 权威判定，客户端不重新推导）
public enum ResourcePressureLevel: String, Codable, Comparable, CaseIterable {
    case low
    case moderate
    case high
    case critical

    private var sortOrder: Int {
        switch self {
        case .low: return 0
        case .moderate: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ResourcePressureLevel, rhs: ResourcePressureLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// 调度优化建议条目（Core 权威输出，客户端只消费）
public struct SchedulingRecommendation: Codable, Identifiable, Equatable {
    public let recommendationId: String
    public let kind: SchedulingRecommendationKind
    public let pressureLevel: ResourcePressureLevel
    public let reason: String
    public let summary: String?
    public let suggestedValue: Int64?
    public let context: HealthContext
    public let generatedAt: UInt64
    public let expiresAt: UInt64

    public var id: String { recommendationId }

    public init(recommendationId: String, kind: SchedulingRecommendationKind,
                pressureLevel: ResourcePressureLevel, reason: String,
                summary: String? = nil, suggestedValue: Int64? = nil,
                context: HealthContext, generatedAt: UInt64, expiresAt: UInt64) {
        self.recommendationId = recommendationId
        self.kind = kind
        self.pressureLevel = pressureLevel
        self.reason = reason
        self.summary = summary
        self.suggestedValue = suggestedValue
        self.context = context
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case recommendationId = "recommendation_id"
        case kind
        case pressureLevel = "pressure_level"
        case reason, summary
        case suggestedValue = "suggested_value"
        case context
        case generatedAt = "generated_at"
        case expiresAt = "expires_at"
    }

    /// 建议是否仍在有效期内
    public func isValid(at nowMs: UInt64) -> Bool {
        nowMs < expiresAt
    }

    public static func from(json: [String: Any]) -> SchedulingRecommendation? {
        guard let recommendationId = json["recommendation_id"] as? String,
              let kindRaw = json["kind"] as? String,
              let kind = SchedulingRecommendationKind(rawValue: kindRaw),
              let pressureLevelRaw = json["pressure_level"] as? String,
              let pressureLevel = ResourcePressureLevel(rawValue: pressureLevelRaw),
              let reason = json["reason"] as? String,
              let generatedAt = json["generated_at"] as? UInt64,
              let expiresAt = json["expires_at"] as? UInt64
        else { return nil }
        return SchedulingRecommendation(
            recommendationId: recommendationId,
            kind: kind,
            pressureLevel: pressureLevel,
            reason: reason,
            summary: json["summary"] as? String,
            suggestedValue: json["suggested_value"] as? Int64,
            context: HealthContext.from(json: json["context"] as? [String: Any]),
            generatedAt: generatedAt,
            expiresAt: expiresAt
        )
    }
}

// MARK: - 预测异常摘要（v1.44: 智能调度与预测性故障检测）

/// 预测异常类型
public enum PredictiveAnomalyKind: String, Codable, CaseIterable {
    case performanceDegradation = "performance_degradation"
    case resourceExhaustion = "resource_exhaustion"
    case recurringFailure = "recurring_failure"
    case rateLimitRisk = "rate_limit_risk"
    case cacheEfficiencyDrop = "cache_efficiency_drop"
}

/// 预测置信度
public enum PredictionConfidence: String, Codable, Comparable, CaseIterable {
    case low
    case medium
    case high

    private var sortOrder: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: PredictionConfidence, rhs: PredictionConfidence) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// 预测时间窗口
public struct PredictionTimeWindow: Codable, Equatable {
    public let startAt: UInt64
    public let endAt: UInt64

    public init(startAt: UInt64, endAt: UInt64) {
        self.startAt = startAt
        self.endAt = endAt
    }

    enum CodingKeys: String, CodingKey {
        case startAt = "start_at"
        case endAt = "end_at"
    }
}

/// 预测异常摘要条目（Core 权威输出，客户端不根据零散 metrics 推理）
public struct PredictiveAnomaly: Codable, Identifiable, Equatable {
    public let anomalyId: String
    public let kind: PredictiveAnomalyKind
    public let confidence: PredictionConfidence
    public let rootCause: String
    public let summary: String?
    public let timeWindow: PredictionTimeWindow
    public let relatedIncidentIds: [String]
    public let context: HealthContext
    public let score: Double
    public let predictedAt: UInt64

    public var id: String { anomalyId }

    public init(anomalyId: String, kind: PredictiveAnomalyKind,
                confidence: PredictionConfidence, rootCause: String,
                summary: String? = nil, timeWindow: PredictionTimeWindow,
                relatedIncidentIds: [String] = [], context: HealthContext,
                score: Double, predictedAt: UInt64) {
        self.anomalyId = anomalyId
        self.kind = kind
        self.confidence = confidence
        self.rootCause = rootCause
        self.summary = summary
        self.timeWindow = timeWindow
        self.relatedIncidentIds = relatedIncidentIds
        self.context = context
        self.score = score
        self.predictedAt = predictedAt
    }

    enum CodingKeys: String, CodingKey {
        case anomalyId = "anomaly_id"
        case kind, confidence
        case rootCause = "root_cause"
        case summary
        case timeWindow = "time_window"
        case relatedIncidentIds = "related_incident_ids"
        case context, score
        case predictedAt = "predicted_at"
    }

    public static func from(json: [String: Any]) -> PredictiveAnomaly? {
        guard let anomalyId = json["anomaly_id"] as? String,
              let kindRaw = json["kind"] as? String,
              let kind = PredictiveAnomalyKind(rawValue: kindRaw),
              let confidenceRaw = json["confidence"] as? String,
              let confidence = PredictionConfidence(rawValue: confidenceRaw),
              let rootCause = json["root_cause"] as? String,
              let twJson = json["time_window"] as? [String: Any],
              let twStart = twJson["start_at"] as? UInt64,
              let twEnd = twJson["end_at"] as? UInt64,
              let score = json["score"] as? Double,
              let predictedAt = json["predicted_at"] as? UInt64
        else { return nil }
        return PredictiveAnomaly(
            anomalyId: anomalyId,
            kind: kind,
            confidence: confidence,
            rootCause: rootCause,
            summary: json["summary"] as? String,
            timeWindow: PredictionTimeWindow(startAt: twStart, endAt: twEnd),
            relatedIncidentIds: json["related_incident_ids"] as? [String] ?? [],
            context: HealthContext.from(json: json["context"] as? [String: Any]),
            score: score,
            predictedAt: predictedAt
        )
    }
}

// MARK: - 观测历史聚合（v1.44: 按 (project, workspace) 隔离）

/// 工作区观测历史聚合摘要（Core 权威输出，按 (project, workspace) 独立存储和恢复）
public struct ObservationAggregate: Codable, Equatable {
    public let project: String
    public let workspace: String
    public let windowStart: UInt64
    public let windowEnd: UInt64
    public let cycleSuccessCount: UInt32
    public let cycleFailureCount: UInt32
    public let avgCycleDurationMs: UInt64?
    public let lastCycleDurationMs: UInt64?
    public let consecutiveFailures: UInt32
    public let cacheHitRatio: Double?
    public let rateLimitHitCount: UInt32
    public let pressureLevel: ResourcePressureLevel
    public let healthScore: Double
    public let aggregatedAt: UInt64

    public init(project: String, workspace: String,
                windowStart: UInt64, windowEnd: UInt64,
                cycleSuccessCount: UInt32, cycleFailureCount: UInt32,
                avgCycleDurationMs: UInt64? = nil, lastCycleDurationMs: UInt64? = nil,
                consecutiveFailures: UInt32, cacheHitRatio: Double? = nil,
                rateLimitHitCount: UInt32, pressureLevel: ResourcePressureLevel,
                healthScore: Double, aggregatedAt: UInt64) {
        self.project = project
        self.workspace = workspace
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.cycleSuccessCount = cycleSuccessCount
        self.cycleFailureCount = cycleFailureCount
        self.avgCycleDurationMs = avgCycleDurationMs
        self.lastCycleDurationMs = lastCycleDurationMs
        self.consecutiveFailures = consecutiveFailures
        self.cacheHitRatio = cacheHitRatio
        self.rateLimitHitCount = rateLimitHitCount
        self.pressureLevel = pressureLevel
        self.healthScore = healthScore
        self.aggregatedAt = aggregatedAt
    }

    enum CodingKeys: String, CodingKey {
        case project, workspace
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case cycleSuccessCount = "cycle_success_count"
        case cycleFailureCount = "cycle_failure_count"
        case avgCycleDurationMs = "avg_cycle_duration_ms"
        case lastCycleDurationMs = "last_cycle_duration_ms"
        case consecutiveFailures = "consecutive_failures"
        case cacheHitRatio = "cache_hit_ratio"
        case rateLimitHitCount = "rate_limit_hit_count"
        case pressureLevel = "pressure_level"
        case healthScore = "health_score"
        case aggregatedAt = "aggregated_at"
    }

    public static func from(json: [String: Any]) -> ObservationAggregate? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let windowStart = json["window_start"] as? UInt64,
              let windowEnd = json["window_end"] as? UInt64,
              let cycleSuccessCount = json["cycle_success_count"] as? UInt32,
              let cycleFailureCount = json["cycle_failure_count"] as? UInt32,
              let consecutiveFailures = json["consecutive_failures"] as? UInt32,
              let rateLimitHitCount = json["rate_limit_hit_count"] as? UInt32,
              let pressureLevelRaw = json["pressure_level"] as? String,
              let pressureLevel = ResourcePressureLevel(rawValue: pressureLevelRaw),
              let healthScore = json["health_score"] as? Double,
              let aggregatedAt = json["aggregated_at"] as? UInt64
        else { return nil }
        return ObservationAggregate(
            project: project,
            workspace: workspace,
            windowStart: windowStart,
            windowEnd: windowEnd,
            cycleSuccessCount: cycleSuccessCount,
            cycleFailureCount: cycleFailureCount,
            avgCycleDurationMs: json["avg_cycle_duration_ms"] as? UInt64,
            lastCycleDurationMs: json["last_cycle_duration_ms"] as? UInt64,
            consecutiveFailures: consecutiveFailures,
            cacheHitRatio: json["cache_hit_ratio"] as? Double,
            rateLimitHitCount: rateLimitHitCount,
            pressureLevel: pressureLevel,
            healthScore: healthScore,
            aggregatedAt: aggregatedAt
        )
    }
}

// MARK: - Repair Action（修复动作）

/// 可执行的修复动作类型
public enum RepairActionKind: String, Codable, CaseIterable {
    case refreshHealthSnapshot = "refresh_health_snapshot"
    case invalidateWorkspaceCache = "invalidate_workspace_cache"
    case rebuildWorkspaceCache = "rebuild_workspace_cache"
    case restoreSubscriptions = "restore_subscriptions"
}

/// 修复动作请求
public struct RepairActionRequest: Codable {
    public let requestId: String
    public let action: RepairActionKind
    public let context: HealthContext
    public let incidentId: String?

    public init(requestId: String = UUID().uuidString,
                action: RepairActionKind,
                context: HealthContext,
                incidentId: String? = nil) {
        self.requestId = requestId
        self.action = action
        self.context = context
        self.incidentId = incidentId
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case action, context
        case incidentId = "incident_id"
    }
}

/// 修复执行结果
public enum RepairOutcome: String, Codable {
    case success
    case alreadyHealthy = "already_healthy"
    case failed
    case partialSuccess = "partial_success"
}

/// 修复执行审计记录
public struct RepairAuditEntry: Codable, Identifiable {
    public let requestId: String
    public let action: RepairActionKind
    public let context: HealthContext
    public let incidentId: String?
    public let outcome: RepairOutcome
    public let trigger: String
    public let startedAt: UInt64
    public let durationMs: UInt64
    public let resultSummary: String?
    public let incidentResolved: Bool

    public var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case action, context
        case incidentId = "incident_id"
        case outcome, trigger
        case startedAt = "started_at"
        case durationMs = "duration_ms"
        case resultSummary = "result_summary"
        case incidentResolved = "incident_resolved"
    }

    public static func from(json: [String: Any]) -> RepairAuditEntry? {
        guard let requestId = json["request_id"] as? String,
              let actionRaw = json["action"] as? String,
              let action = RepairActionKind(rawValue: actionRaw),
              let outcomeRaw = json["outcome"] as? String,
              let outcome = RepairOutcome(rawValue: outcomeRaw),
              let trigger = json["trigger"] as? String,
              let startedAt = json["started_at"] as? UInt64,
              let durationMs = json["duration_ms"] as? UInt64,
              let incidentResolved = json["incident_resolved"] as? Bool
        else { return nil }
        return RepairAuditEntry(
            requestId: requestId,
            action: action,
            context: HealthContext.from(json: json["context"] as? [String: Any]),
            incidentId: json["incident_id"] as? String,
            outcome: outcome,
            trigger: trigger,
            startedAt: startedAt,
            durationMs: durationMs,
            resultSummary: json["result_summary"] as? String,
            incidentResolved: incidentResolved
        )
    }

    init(requestId: String, action: RepairActionKind, context: HealthContext,
         incidentId: String?, outcome: RepairOutcome, trigger: String,
         startedAt: UInt64, durationMs: UInt64, resultSummary: String?,
         incidentResolved: Bool) {
        self.requestId = requestId
        self.action = action
        self.context = context
        self.incidentId = incidentId
        self.outcome = outcome
        self.trigger = trigger
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.resultSummary = resultSummary
        self.incidentResolved = incidentResolved
    }
}

// MARK: - 客户端健康上报与状态

/// 客户端连接质量
public enum ClientConnectivity: String, Codable, CaseIterable {
    case good
    case degraded
    case lost
}

/// incident 过滤与 repair action 可用条件（双端共享语义，不在视图层重复推导）
public struct HealthFilterConfig {
    /// 最小展示级别
    public let minimumSeverity: IncidentSeverity
    /// 是否只展示当前 project/workspace 的 incidents
    public let scopedToCurrentWorkspace: Bool

    public static let `default` = HealthFilterConfig(
        minimumSeverity: .warning,
        scopedToCurrentWorkspace: false
    )

    public init(minimumSeverity: IncidentSeverity, scopedToCurrentWorkspace: Bool) {
        self.minimumSeverity = minimumSeverity
        self.scopedToCurrentWorkspace = scopedToCurrentWorkspace
    }

    /// 过滤 incident 列表
    public func filter(_ incidents: [HealthIncident],
                       project: String? = nil, workspace: String? = nil) -> [HealthIncident] {
        incidents.filter { incident in
            guard incident.severity >= minimumSeverity else { return false }
            if scopedToCurrentWorkspace {
                return incident.context.project == project && incident.context.workspace == workspace
            }
            return true
        }
    }
}

/// repair action 可用性评估（双端共享语义）
public struct RepairActionAvailability {
    public let action: RepairActionKind
    public let isAvailable: Bool
    public let reason: String?

    public static func evaluate(
        action: RepairActionKind,
        snapshot: SystemHealthSnapshot?,
        context: HealthContext
    ) -> RepairActionAvailability {
        guard let snapshot else {
            return RepairActionAvailability(action: action, isAvailable: false, reason: "无健康快照")
        }
        switch action {
        case .refreshHealthSnapshot:
            return RepairActionAvailability(action: action, isAvailable: true, reason: nil)
        case .invalidateWorkspaceCache, .rebuildWorkspaceCache:
            let hasWorkspaceIncident = snapshot.incidents.contains { incident in
                incident.context.project == context.project &&
                incident.context.workspace == context.workspace &&
                incident.source == .coreWorkspaceCache
            }
            return RepairActionAvailability(
                action: action,
                isAvailable: context.project != nil && context.workspace != nil,
                reason: hasWorkspaceIncident ? nil : "无缓存相关异常"
            )
        case .restoreSubscriptions:
            return RepairActionAvailability(
                action: action,
                isAvailable: snapshot.incidents.contains { $0.source == .clientConnectivity },
                reason: nil
            )
        }
    }
}

// MARK: - 恢复状态迁移（双端共享语义）

/// incident 修复状态（双端共享，不在各端视图层各自推导）
public enum IncidentRepairState: Equatable {
    case idle
    case repairing(requestId: String)
    case repaired(requestId: String)
    case repairFailed(requestId: String, summary: String?)
}

// MARK: - 工作区恢复元数据（双端共享语义）

/// 工作区崩溃恢复元数据
///
/// 与 `core/src/workspace/state.rs` `WorkspaceRecoveryMeta` 保持语义一致。
/// 按 `(project, workspace)` 路由消费，不允许跨工作区混用。
public struct WorkspaceRecoveryMeta: Codable, Equatable {
    /// 恢复状态：`none` | `interrupted` | `recovering` | `recovered`
    public let recoveryState: String
    /// 恢复游标（上次已知执行位置）
    public let recoveryCursor: String?
    /// 失败上下文（JSON 字符串）
    public let failedContext: String?
    /// 中断发生时间（ISO 8601 字符串）
    public let interruptedAt: String?

    public init(recoveryState: String, recoveryCursor: String? = nil,
                failedContext: String? = nil, interruptedAt: String? = nil) {
        self.recoveryState = recoveryState
        self.recoveryCursor = recoveryCursor
        self.failedContext = failedContext
        self.interruptedAt = interruptedAt
    }

    enum CodingKeys: String, CodingKey {
        case recoveryState = "recovery_state"
        case recoveryCursor = "recovery_cursor"
        case failedContext = "failed_context"
        case interruptedAt = "interrupted_at"
    }

    /// 是否处于需要关注的中断/恢复中状态
    public var needsAttention: Bool {
        recoveryState == "interrupted" || recoveryState == "recovering"
    }
}

/// system_snapshot workspace_item 中的恢复状态摘要（按 (project, workspace) 隔离）
public struct WorkspaceRecoverySummary: Equatable {
    /// 工作区所属项目
    public let project: String
    /// 工作区名称
    public let workspace: String
    /// 恢复状态
    public let recoveryState: String
    /// 恢复游标
    public let recoveryCursor: String?

    public var needsAttention: Bool {
        recoveryState == "interrupted" || recoveryState == "recovering"
    }

    /// 从 system_snapshot workspace_item JSON 解析（缺失时返回 nil）
    public static func from(json: [String: Any], project: String, workspace: String) -> WorkspaceRecoverySummary? {
        guard let state = json["recovery_state"] as? String else { return nil }
        return WorkspaceRecoverySummary(
            project: project,
            workspace: workspace,
            recoveryState: state,
            recoveryCursor: json["recovery_cursor"] as? String
        )
    }
}

// MARK: - 统一性能指标快照（v1.42 可观测性收敛）

/// WS 管线阶段延迟与吞吐指标（共享模型，Core 权威输出）
public struct WsPipelineMetrics: Codable, Equatable {
    /// 最近一次采样（毫秒）
    public let lastMs: UInt64
    /// 历史峰值（毫秒）
    public let maxMs: UInt64
    /// 采样总次数
    public let count: UInt64

    public init(lastMs: UInt64 = 0, maxMs: UInt64 = 0, count: UInt64 = 0) {
        self.lastMs = lastMs
        self.maxMs = maxMs
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case lastMs = "last_ms"
        case maxMs = "max_ms"
        case count
    }

    public static func from(json: [String: Any]?) -> WsPipelineMetrics {
        guard let json else { return WsPipelineMetrics() }
        return WsPipelineMetrics(
            lastMs: json["last_ms"] as? UInt64 ?? 0,
            maxMs: json["max_ms"] as? UInt64 ?? 0,
            count: json["count"] as? UInt64 ?? 0
        )
    }
}

/// 统一性能指标快照（全局计数器，不按工作区隔离）
///
/// 由 Core `system_snapshot` 输出，客户端只消费，不允许本地派生。
/// macOS 与 iOS 共享同一模型，不在各端各自定义。
public struct PerfMetricsSnapshot: Codable, Equatable {
    public var wsTaskBroadcastLagTotal: UInt64
    public var wsTaskBroadcastQueueDepth: UInt64
    public var wsTaskBroadcastSkippedSingleReceiverTotal: UInt64
    public var wsTaskBroadcastSkippedEmptyTargetTotal: UInt64
    public var wsTaskBroadcastFilteredTargetTotal: UInt64
    public var terminalUnackedTimeoutTotal: UInt64
    public var terminalReclaimedTotal: UInt64
    public var terminalScrollbackTrimTotal: UInt64
    public var projectCommandOutputThrottledTotal: UInt64
    public var projectCommandOutputEmittedTotal: UInt64
    public var wsOutboundLoopTick: WsPipelineMetrics
    public var wsOutboundSelectWait: WsPipelineMetrics
    public var wsOutboundHandle: WsPipelineMetrics
    public var wsDecode: WsPipelineMetrics
    public var wsDispatch: WsPipelineMetrics
    public var wsEncode: WsPipelineMetrics
    public var wsOutboundQueueDepth: UInt64
    public var wsBatchFlushSize: UInt64
    public var wsBatchFlushCount: UInt64
    public var aiSubscriberFanout: UInt64
    public var aiSubscriberFanoutMax: UInt64
    public var evolutionCycleUpdateEmittedTotal: UInt64
    public var evolutionCycleUpdateDebouncedTotal: UInt64
    public var evolutionSnapshotFallbackTotal: UInt64

    public static let empty = PerfMetricsSnapshot(
        wsTaskBroadcastLagTotal: 0, wsTaskBroadcastQueueDepth: 0,
        wsTaskBroadcastSkippedSingleReceiverTotal: 0,
        wsTaskBroadcastSkippedEmptyTargetTotal: 0,
        wsTaskBroadcastFilteredTargetTotal: 0,
        terminalUnackedTimeoutTotal: 0, terminalReclaimedTotal: 0,
        terminalScrollbackTrimTotal: 0,
        projectCommandOutputThrottledTotal: 0, projectCommandOutputEmittedTotal: 0,
        wsOutboundLoopTick: .init(), wsOutboundSelectWait: .init(),
        wsOutboundHandle: .init(), wsDecode: .init(),
        wsDispatch: .init(), wsEncode: .init(),
        wsOutboundQueueDepth: 0, wsBatchFlushSize: 0, wsBatchFlushCount: 0,
        aiSubscriberFanout: 0, aiSubscriberFanoutMax: 0,
        evolutionCycleUpdateEmittedTotal: 0, evolutionCycleUpdateDebouncedTotal: 0,
        evolutionSnapshotFallbackTotal: 0
    )

    enum CodingKeys: String, CodingKey {
        case wsTaskBroadcastLagTotal = "ws_task_broadcast_lag_total"
        case wsTaskBroadcastQueueDepth = "ws_task_broadcast_queue_depth"
        case wsTaskBroadcastSkippedSingleReceiverTotal = "ws_task_broadcast_skipped_single_receiver_total"
        case wsTaskBroadcastSkippedEmptyTargetTotal = "ws_task_broadcast_skipped_empty_target_total"
        case wsTaskBroadcastFilteredTargetTotal = "ws_task_broadcast_filtered_target_total"
        case terminalUnackedTimeoutTotal = "terminal_unacked_timeout_total"
        case terminalReclaimedTotal = "terminal_reclaimed_total"
        case terminalScrollbackTrimTotal = "terminal_scrollback_trim_total"
        case projectCommandOutputThrottledTotal = "project_command_output_throttled_total"
        case projectCommandOutputEmittedTotal = "project_command_output_emitted_total"
        case wsOutboundLoopTick = "ws_outbound_loop_tick"
        case wsOutboundSelectWait = "ws_outbound_select_wait"
        case wsOutboundHandle = "ws_outbound_handle"
        case wsDecode = "ws_decode"
        case wsDispatch = "ws_dispatch"
        case wsEncode = "ws_encode"
        case wsOutboundQueueDepth = "ws_outbound_queue_depth"
        case wsBatchFlushSize = "ws_batch_flush_size"
        case wsBatchFlushCount = "ws_batch_flush_count"
        case aiSubscriberFanout = "ai_subscriber_fanout"
        case aiSubscriberFanoutMax = "ai_subscriber_fanout_max"
        case evolutionCycleUpdateEmittedTotal = "evolution_cycle_update_emitted_total"
        case evolutionCycleUpdateDebouncedTotal = "evolution_cycle_update_debounced_total"
        case evolutionSnapshotFallbackTotal = "evolution_snapshot_fallback_total"
    }

    public static func from(json: [String: Any]?) -> PerfMetricsSnapshot {
        guard let json else { return .empty }
        return PerfMetricsSnapshot(
            wsTaskBroadcastLagTotal: json["ws_task_broadcast_lag_total"] as? UInt64 ?? 0,
            wsTaskBroadcastQueueDepth: json["ws_task_broadcast_queue_depth"] as? UInt64 ?? 0,
            wsTaskBroadcastSkippedSingleReceiverTotal: json["ws_task_broadcast_skipped_single_receiver_total"] as? UInt64 ?? 0,
            wsTaskBroadcastSkippedEmptyTargetTotal: json["ws_task_broadcast_skipped_empty_target_total"] as? UInt64 ?? 0,
            wsTaskBroadcastFilteredTargetTotal: json["ws_task_broadcast_filtered_target_total"] as? UInt64 ?? 0,
            terminalUnackedTimeoutTotal: json["terminal_unacked_timeout_total"] as? UInt64 ?? 0,
            terminalReclaimedTotal: json["terminal_reclaimed_total"] as? UInt64 ?? 0,
            terminalScrollbackTrimTotal: json["terminal_scrollback_trim_total"] as? UInt64 ?? 0,
            projectCommandOutputThrottledTotal: json["project_command_output_throttled_total"] as? UInt64 ?? 0,
            projectCommandOutputEmittedTotal: json["project_command_output_emitted_total"] as? UInt64 ?? 0,
            wsOutboundLoopTick: .from(json: json["ws_outbound_loop_tick"] as? [String: Any]),
            wsOutboundSelectWait: .from(json: json["ws_outbound_select_wait"] as? [String: Any]),
            wsOutboundHandle: .from(json: json["ws_outbound_handle"] as? [String: Any]),
            wsDecode: .from(json: json["ws_decode"] as? [String: Any]),
            wsDispatch: .from(json: json["ws_dispatch"] as? [String: Any]),
            wsEncode: .from(json: json["ws_encode"] as? [String: Any]),
            wsOutboundQueueDepth: json["ws_outbound_queue_depth"] as? UInt64 ?? 0,
            wsBatchFlushSize: json["ws_batch_flush_size"] as? UInt64 ?? 0,
            wsBatchFlushCount: json["ws_batch_flush_count"] as? UInt64 ?? 0,
            aiSubscriberFanout: json["ai_subscriber_fanout"] as? UInt64 ?? 0,
            aiSubscriberFanoutMax: json["ai_subscriber_fanout_max"] as? UInt64 ?? 0,
            evolutionCycleUpdateEmittedTotal: json["evolution_cycle_update_emitted_total"] as? UInt64 ?? 0,
            evolutionCycleUpdateDebouncedTotal: json["evolution_cycle_update_debounced_total"] as? UInt64 ?? 0,
            evolutionSnapshotFallbackTotal: json["evolution_snapshot_fallback_total"] as? UInt64 ?? 0
        )
    }
}

/// 结构化日志关联上下文摘要（全局，不按工作区隔离）
///
/// 由 Core `system_snapshot` 输出，供调试面板快速关联日志文件与快照。
public struct LogContextSummary: Codable, Equatable {
    /// 当天日志文件完整路径
    public let logFile: String
    /// 日志保留天数
    public let retentionDays: UInt64
    /// TIDYFLOW_PERF_LOG 是否启用
    public let perfLoggingEnabled: Bool

    public static let empty = LogContextSummary(logFile: "", retentionDays: 7, perfLoggingEnabled: false)

    public init(logFile: String, retentionDays: UInt64, perfLoggingEnabled: Bool) {
        self.logFile = logFile
        self.retentionDays = retentionDays
        self.perfLoggingEnabled = perfLoggingEnabled
    }

    enum CodingKeys: String, CodingKey {
        case logFile = "log_file"
        case retentionDays = "retention_days"
        case perfLoggingEnabled = "perf_logging_enabled"
    }

    public static func from(json: [String: Any]?) -> LogContextSummary {
        guard let json else { return .empty }
        return LogContextSummary(
            logFile: json["log_file"] as? String ?? "",
            retentionDays: json["retention_days"] as? UInt64 ?? 7,
            perfLoggingEnabled: json["perf_logging_enabled"] as? Bool ?? false
        )
    }
}

/// 统一可观测性快照（聚合 system_snapshot 中的所有观测字段）
///
/// 由 WSClient 在收到 system_snapshot 时一次性解析，macOS 和 iOS 共享同一模型。
/// 各子字段由 Core 权威输出，客户端不在本地推导任何计算值。
public struct ObservabilitySnapshot {
    /// 工作区缓存指标（按 (project, workspace) 隔离）
    public let cacheMetrics: SystemSnapshotCacheMetrics
    /// 统一性能指标（全局）
    public let perfMetrics: PerfMetricsSnapshot
    /// 结构化日志上下文（全局）
    public let logContext: LogContextSummary

    public static let empty = ObservabilitySnapshot(
        cacheMetrics: SystemSnapshotCacheMetrics(index: [:]),
        perfMetrics: .empty,
        logContext: .empty
    )

    public init(cacheMetrics: SystemSnapshotCacheMetrics, perfMetrics: PerfMetricsSnapshot, logContext: LogContextSummary) {
        self.cacheMetrics = cacheMetrics
        self.perfMetrics = perfMetrics
        self.logContext = logContext
    }
}

// MARK: - 统一运行状态面板模型（v1.43 收敛）

/// 统一运行状态条目（聚合任务与演化两类运行态的通用字段）
///
/// 由共享状态层集中派生，macOS 和 iOS 使用同一模型消费面板数据。
/// 所有字段按 `(project, workspace)` 隔离，Core 权威输出。
public enum RunStatusEntryKind: String, Equatable {
    case task
    case evolution
}

/// 运行状态条目的终态分类（面板分组依据）
public enum RunStatusTerminalGroup: String, Equatable {
    case active
    case failed
    case completed
}

/// 通用重试描述符（任务和演化共用），保留归属边界
public struct UnifiedRetryDescriptor: Equatable {
    public let project: String
    public let workspace: String
    public let kind: RunStatusEntryKind
    /// 任务重试时的 commandId（仅 task 类型有效）
    public let taskCommandId: String?
    /// 演化重试时的 cycleId（仅 evolution 类型有效）
    public let cycleId: String?

    public var workspaceGlobalKey: String {
        "\(project):\(workspace)"
    }
}

// MARK: - 质量门禁裁决（WI-002: Evolution 自动门禁）

/// 门禁裁决结果
public enum GateVerdict: String, Codable, CaseIterable {
    case pass
    case fail
    case skip
}

/// 门禁失败原因码
public enum GateFailureReason: Codable, Equatable {
    case systemUnhealthy
    case criticalIncident
    case evidenceIncomplete
    case protocolInconsistent
    case coreRegressionFailed
    case appleVerificationFailed
    /// 热点性能回归检查失败（measured_ns 超出 fail_ratio_limit 或 absolute_budget_ns）
    case performanceRegressionFailed
    case custom(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            switch raw {
            case "system_unhealthy": self = .systemUnhealthy
            case "critical_incident": self = .criticalIncident
            case "evidence_incomplete": self = .evidenceIncomplete
            case "protocol_inconsistent": self = .protocolInconsistent
            case "core_regression_failed": self = .coreRegressionFailed
            case "apple_verification_failed": self = .appleVerificationFailed
            case "performance_regression_failed": self = .performanceRegressionFailed
            default: self = .custom(raw)
            }
        } else {
            let obj = try decoder.container(keyedBy: CodingKeys.self)
            let value = try obj.decode(String.self, forKey: .custom)
            self = .custom(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .systemUnhealthy: try container.encode("system_unhealthy")
        case .criticalIncident: try container.encode("critical_incident")
        case .evidenceIncomplete: try container.encode("evidence_incomplete")
        case .protocolInconsistent: try container.encode("protocol_inconsistent")
        case .coreRegressionFailed: try container.encode("core_regression_failed")
        case .appleVerificationFailed: try container.encode("apple_verification_failed")
        case .performanceRegressionFailed: try container.encode("performance_regression_failed")
        case .custom(let value): try container.encode(value)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case custom
    }
}

/// 质量门禁裁决记录
///
/// 按 `(project, workspace, cycle_id)` 隔离存储和传播，
/// 不会因同名工作区或重连而串用其他项目状态。
public struct GateDecision: Codable, Equatable {
    public var verdict: GateVerdict
    public var failureReasons: [GateFailureReason]
    public var project: String
    public var workspace: String
    public var cycleId: String
    public var healthStatus: SystemHealthStatus
    public var retryCount: UInt32
    public var bypassed: Bool
    public var bypassReason: String?
    public var decidedAt: UInt64

    enum CodingKeys: String, CodingKey {
        case verdict
        case failureReasons = "failure_reasons"
        case project, workspace
        case cycleId = "cycle_id"
        case healthStatus = "health_status"
        case retryCount = "retry_count"
        case bypassed
        case bypassReason = "bypass_reason"
        case decidedAt = "decided_at"
    }

    public static func from(json: [String: Any]) -> GateDecision? {
        guard let verdictRaw = json["verdict"] as? String,
              let verdict = GateVerdict(rawValue: verdictRaw),
              let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cycleId = json["cycle_id"] as? String,
              let healthStatusRaw = json["health_status"] as? String,
              let healthStatus = SystemHealthStatus(rawValue: healthStatusRaw),
              let decidedAt = json["decided_at"] as? UInt64 else { return nil }
        let failureReasons: [GateFailureReason] = (json["failure_reasons"] as? [String])?.compactMap { raw in
            switch raw {
            case "system_unhealthy": return .systemUnhealthy
            case "critical_incident": return .criticalIncident
            case "evidence_incomplete": return .evidenceIncomplete
            case "protocol_inconsistent": return .protocolInconsistent
            case "core_regression_failed": return .coreRegressionFailed
            case "apple_verification_failed": return .appleVerificationFailed
            case "performance_regression_failed": return .performanceRegressionFailed
            default: return .custom(raw)
            }
        } ?? []
        return GateDecision(
            verdict: verdict,
            failureReasons: failureReasons,
            project: project,
            workspace: workspace,
            cycleId: cycleId,
            healthStatus: healthStatus,
            retryCount: (json["retry_count"] as? UInt32) ?? 0,
            bypassed: (json["bypassed"] as? Bool) ?? false,
            bypassReason: json["bypass_reason"] as? String,
            decidedAt: decidedAt
        )
    }
}

// MARK: - 智能演化分析摘要（v1.45: 统一分析契约）

/// 瓶颈类型分类（Core 权威判定，客户端不得重新推导）
public enum BottleneckKind: String, Codable, CaseIterable {
    case resource
    case rateLimit = "rate_limit"
    case recurringFailure = "recurring_failure"
    case performanceDegradation = "performance_degradation"
    case configuration
    case protocolInconsistency = "protocol_inconsistency"
}

/// 分析建议的归属范围
public enum AnalysisScopeLevel: String, Codable, CaseIterable {
    case system
    case workspace
}

/// 优化建议条目
public struct OptimizationSuggestion: Codable, Equatable {
    public var suggestionId: String
    public var scope: AnalysisScopeLevel
    public var action: String
    public var summary: String
    public var priority: Int
    public var expectedImpact: String?
    public var context: HealthContext

    enum CodingKeys: String, CodingKey {
        case suggestionId = "suggestion_id"
        case scope, action, summary, priority
        case expectedImpact = "expected_impact"
        case context
    }

    public static func from(json: [String: Any]) -> OptimizationSuggestion? {
        guard let suggestionId = json["suggestion_id"] as? String,
              let scopeStr = json["scope"] as? String,
              let scope = AnalysisScopeLevel(rawValue: scopeStr),
              let action = json["action"] as? String,
              let summary = json["summary"] as? String,
              let priority = json["priority"] as? Int else { return nil }
        return OptimizationSuggestion(
            suggestionId: suggestionId,
            scope: scope,
            action: action,
            summary: summary,
            priority: priority,
            expectedImpact: json["expected_impact"] as? String,
            context: .from(json: json["context"] as? [String: Any])
        )
    }
}

/// 瓶颈分析条目
public struct BottleneckEntry: Codable, Equatable {
    public var bottleneckId: String
    public var kind: BottleneckKind
    public var reasonCode: String
    public var riskScore: Double
    public var evidenceSummary: String
    public var context: HealthContext
    public var relatedIds: [String]
    public var detectedAt: UInt64

    enum CodingKeys: String, CodingKey {
        case bottleneckId = "bottleneck_id"
        case kind
        case reasonCode = "reason_code"
        case riskScore = "risk_score"
        case evidenceSummary = "evidence_summary"
        case context
        case relatedIds = "related_ids"
        case detectedAt = "detected_at"
    }

    public static func from(json: [String: Any]) -> BottleneckEntry? {
        guard let bottleneckId = json["bottleneck_id"] as? String,
              let kindStr = json["kind"] as? String,
              let kind = BottleneckKind(rawValue: kindStr),
              let reasonCode = json["reason_code"] as? String,
              let riskScore = json["risk_score"] as? Double,
              let evidenceSummary = json["evidence_summary"] as? String else { return nil }
        return BottleneckEntry(
            bottleneckId: bottleneckId,
            kind: kind,
            reasonCode: reasonCode,
            riskScore: riskScore,
            evidenceSummary: evidenceSummary,
            context: .from(json: json["context"] as? [String: Any]),
            relatedIds: (json["related_ids"] as? [String]) ?? [],
            detectedAt: (json["detected_at"] as? UInt64) ?? 0
        )
    }
}

/// 智能演化分析摘要
///
/// 统一的可机读结构，聚合质量门禁结论、瓶颈识别、风险评分、
/// 证据摘要和优化建议。按 `(project, workspace, cycle_id)` 隔离。
public struct EvolutionAnalysisSummary: Codable, Equatable {
    public var project: String
    public var workspace: String
    public var cycleId: String
    public var gateDecision: GateDecision?
    public var bottlenecks: [BottleneckEntry]
    public var overallRiskScore: Double
    public var healthScore: Double
    public var pressureLevel: ResourcePressureLevel
    public var predictiveAnomalyIds: [String]
    public var suggestions: [OptimizationSuggestion]
    public var analyzedAt: UInt64
    public var expiresAt: UInt64

    enum CodingKeys: String, CodingKey {
        case project, workspace
        case cycleId = "cycle_id"
        case gateDecision = "gate_decision"
        case bottlenecks
        case overallRiskScore = "overall_risk_score"
        case healthScore = "health_score"
        case pressureLevel = "pressure_level"
        case predictiveAnomalyIds = "predictive_anomaly_ids"
        case suggestions
        case analyzedAt = "analyzed_at"
        case expiresAt = "expires_at"
    }

    public static func from(json: [String: Any]) -> EvolutionAnalysisSummary? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cycleId = json["cycle_id"] as? String else { return nil }
        let gateDecision: GateDecision? = (json["gate_decision"] as? [String: Any]).flatMap { GateDecision.from(json: $0) }
        let bottlenecks = (json["bottlenecks"] as? [[String: Any]])?.compactMap { BottleneckEntry.from(json: $0) } ?? []
        let suggestions = (json["suggestions"] as? [[String: Any]])?.compactMap { OptimizationSuggestion.from(json: $0) } ?? []
        return EvolutionAnalysisSummary(
            project: project,
            workspace: workspace,
            cycleId: cycleId,
            gateDecision: gateDecision,
            bottlenecks: bottlenecks,
            overallRiskScore: (json["overall_risk_score"] as? Double) ?? 0.0,
            healthScore: (json["health_score"] as? Double) ?? 1.0,
            pressureLevel: ResourcePressureLevel(rawValue: (json["pressure_level"] as? String) ?? "low") ?? .low,
            predictiveAnomalyIds: (json["predictive_anomaly_ids"] as? [String]) ?? [],
            suggestions: suggestions,
            analyzedAt: (json["analyzed_at"] as? UInt64) ?? 0,
            expiresAt: (json["expires_at"] as? UInt64) ?? 0
        )
    }
}

// MARK: - 全链路性能可观测共享类型（WI-001）

/// 延迟指标滚动窗口
public struct LatencyMetricWindow: Codable, Equatable, Sendable {
    public var lastMs: UInt64
    public var avgMs: UInt64
    public var p95Ms: UInt64
    public var maxMs: UInt64
    public var sampleCount: UInt64
    public var windowSize: UInt64

    public static let empty = LatencyMetricWindow(lastMs: 0, avgMs: 0, p95Ms: 0, maxMs: 0, sampleCount: 0, windowSize: 128)

    public init(lastMs: UInt64 = 0, avgMs: UInt64 = 0, p95Ms: UInt64 = 0,
                maxMs: UInt64 = 0, sampleCount: UInt64 = 0, windowSize: UInt64 = 128) {
        self.lastMs = lastMs
        self.avgMs = avgMs
        self.p95Ms = p95Ms
        self.maxMs = maxMs
        self.sampleCount = sampleCount
        self.windowSize = windowSize
    }

    enum CodingKeys: String, CodingKey {
        case lastMs = "last_ms"
        case avgMs = "avg_ms"
        case p95Ms = "p95_ms"
        case maxMs = "max_ms"
        case sampleCount = "sample_count"
        case windowSize = "window_size"
    }
}

/// 内存使用快照
public struct MemoryUsageSnapshot: Codable, Equatable, Sendable {
    public var currentBytes: UInt64
    public var peakBytes: UInt64
    public var deltaFromBaselineBytes: Int64
    public var virtualBytes: UInt64?
    public var sampleCount: UInt64

    public static let empty = MemoryUsageSnapshot(currentBytes: 0, peakBytes: 0, deltaFromBaselineBytes: 0, sampleCount: 0)

    public init(currentBytes: UInt64 = 0, peakBytes: UInt64 = 0,
                deltaFromBaselineBytes: Int64 = 0, virtualBytes: UInt64? = nil, sampleCount: UInt64 = 0) {
        self.currentBytes = currentBytes
        self.peakBytes = peakBytes
        self.deltaFromBaselineBytes = deltaFromBaselineBytes
        self.virtualBytes = virtualBytes
        self.sampleCount = sampleCount
    }

    enum CodingKeys: String, CodingKey {
        case currentBytes = "current_bytes"
        case peakBytes = "peak_bytes"
        case deltaFromBaselineBytes = "delta_from_baseline_bytes"
        case virtualBytes = "virtual_bytes"
        case sampleCount = "sample_count"
    }
}

/// 客户端实例性能上报
public struct ClientPerformanceReport: Codable, Equatable, Sendable {
    public var clientInstanceId: String
    public var platform: String
    public var project: String
    public var workspace: String
    public var memory: MemoryUsageSnapshot
    public var workspaceSwitch: LatencyMetricWindow
    public var fileTreeRequest: LatencyMetricWindow
    public var fileTreeExpand: LatencyMetricWindow
    public var aiSessionListRequest: LatencyMetricWindow
    public var aiMessageTailFlush: LatencyMetricWindow
    public var evidencePageAppend: LatencyMetricWindow
    public var reportedAt: UInt64

    public init(clientInstanceId: String, platform: String, project: String, workspace: String,
                memory: MemoryUsageSnapshot = .empty,
                workspaceSwitch: LatencyMetricWindow = .empty,
                fileTreeRequest: LatencyMetricWindow = .empty,
                fileTreeExpand: LatencyMetricWindow = .empty,
                aiSessionListRequest: LatencyMetricWindow = .empty,
                aiMessageTailFlush: LatencyMetricWindow = .empty,
                evidencePageAppend: LatencyMetricWindow = .empty,
                reportedAt: UInt64 = 0) {
        self.clientInstanceId = clientInstanceId
        self.platform = platform
        self.project = project
        self.workspace = workspace
        self.memory = memory
        self.workspaceSwitch = workspaceSwitch
        self.fileTreeRequest = fileTreeRequest
        self.fileTreeExpand = fileTreeExpand
        self.aiSessionListRequest = aiSessionListRequest
        self.aiMessageTailFlush = aiMessageTailFlush
        self.evidencePageAppend = evidencePageAppend
        self.reportedAt = reportedAt
    }

    enum CodingKeys: String, CodingKey {
        case clientInstanceId = "client_instance_id"
        case platform, project, workspace, memory
        case workspaceSwitch = "workspace_switch"
        case fileTreeRequest = "file_tree_request"
        case fileTreeExpand = "file_tree_expand"
        case aiSessionListRequest = "ai_session_list_request"
        case aiMessageTailFlush = "ai_message_tail_flush"
        case evidencePageAppend = "evidence_page_append"
        case reportedAt = "reported_at"
    }
}

/// 工作区关键路径性能快照
public struct WorkspacePerformanceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var project: String
    public var workspace: String
    public var systemSnapshotBuild: LatencyMetricWindow
    public var workspaceFileIndexRefresh: LatencyMetricWindow
    public var workspaceGitStatusRefresh: LatencyMetricWindow
    public var evolutionSnapshotRead: LatencyMetricWindow
    public var snapshotAt: UInt64

    public var id: String { "\(project)/\(workspace)" }

    public init(project: String, workspace: String,
                systemSnapshotBuild: LatencyMetricWindow = .empty,
                workspaceFileIndexRefresh: LatencyMetricWindow = .empty,
                workspaceGitStatusRefresh: LatencyMetricWindow = .empty,
                evolutionSnapshotRead: LatencyMetricWindow = .empty,
                snapshotAt: UInt64 = 0) {
        self.project = project
        self.workspace = workspace
        self.systemSnapshotBuild = systemSnapshotBuild
        self.workspaceFileIndexRefresh = workspaceFileIndexRefresh
        self.workspaceGitStatusRefresh = workspaceGitStatusRefresh
        self.evolutionSnapshotRead = evolutionSnapshotRead
        self.snapshotAt = snapshotAt
    }

    enum CodingKeys: String, CodingKey {
        case project, workspace
        case systemSnapshotBuild = "system_snapshot_build"
        case workspaceFileIndexRefresh = "workspace_file_index_refresh"
        case workspaceGitStatusRefresh = "workspace_git_status_refresh"
        case evolutionSnapshotRead = "evolution_snapshot_read"
        case snapshotAt = "snapshot_at"
    }
}

/// 性能诊断范围
public enum PerformanceDiagnosisScope: String, Codable, CaseIterable, Sendable {
    case system
    case workspace
    case clientInstance = "client_instance"
}

/// 性能诊断严重度
public enum PerformanceDiagnosisSeverity: String, Codable, Comparable, CaseIterable, Sendable {
    case info
    case warning
    case critical

    private var sortOrder: Int {
        switch self { case .info: return 0; case .warning: return 1; case .critical: return 2 }
    }
    public static func < (lhs: PerformanceDiagnosisSeverity, rhs: PerformanceDiagnosisSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// 性能诊断原因码
public enum PerformanceDiagnosisReason: String, Codable, CaseIterable, Sendable {
    case wsPipelineLatencyHigh = "ws_pipeline_latency_high"
    case workspaceSwitchLatencyHigh = "workspace_switch_latency_high"
    case fileTreeLatencyHigh = "file_tree_latency_high"
    case aiSessionListLatencyHigh = "ai_session_list_latency_high"
    case messageFlushLatencyHigh = "message_flush_latency_high"
    case coreMemoryPressure = "core_memory_pressure"
    case clientMemoryPressure = "client_memory_pressure"
    case memoryGrowthUnbounded = "memory_growth_unbounded"
    case queueBackpressureHigh = "queue_backpressure_high"
    case crossLayerLatencyMismatch = "cross_layer_latency_mismatch"
}

/// 单条性能诊断结果
public struct PerformanceDiagnosis: Codable, Identifiable, Equatable, Sendable {
    public var diagnosisId: String
    public var scope: PerformanceDiagnosisScope
    public var severity: PerformanceDiagnosisSeverity
    public var reason: PerformanceDiagnosisReason
    public var summary: String
    public var evidence: [String]
    public var recommendedAction: String
    public var context: HealthContext
    public var clientInstanceId: String?
    public var diagnosedAt: UInt64

    public var id: String { diagnosisId }

    public init(diagnosisId: String, scope: PerformanceDiagnosisScope,
                severity: PerformanceDiagnosisSeverity, reason: PerformanceDiagnosisReason,
                summary: String, evidence: [String] = [], recommendedAction: String,
                context: HealthContext = .system, clientInstanceId: String? = nil,
                diagnosedAt: UInt64 = 0) {
        self.diagnosisId = diagnosisId
        self.scope = scope
        self.severity = severity
        self.reason = reason
        self.summary = summary
        self.evidence = evidence
        self.recommendedAction = recommendedAction
        self.context = context
        self.clientInstanceId = clientInstanceId
        self.diagnosedAt = diagnosedAt
    }

    enum CodingKeys: String, CodingKey {
        case diagnosisId = "diagnosis_id"
        case scope, severity, reason, summary, evidence
        case recommendedAction = "recommended_action"
        case context
        case clientInstanceId = "client_instance_id"
        case diagnosedAt = "diagnosed_at"
    }
}

/// Core 内存运行时快照
public struct CoreRuntimeMemorySnapshot: Codable, Equatable {
    public var residentBytes: UInt64
    public var virtualBytes: UInt64
    public var physFootprintBytes: UInt64
    public var sampleTimeMs: UInt64

    public static let empty = CoreRuntimeMemorySnapshot(residentBytes: 0, virtualBytes: 0, physFootprintBytes: 0, sampleTimeMs: 0)

    public init(residentBytes: UInt64 = 0, virtualBytes: UInt64 = 0,
                physFootprintBytes: UInt64 = 0, sampleTimeMs: UInt64 = 0) {
        self.residentBytes = residentBytes
        self.virtualBytes = virtualBytes
        self.physFootprintBytes = physFootprintBytes
        self.sampleTimeMs = sampleTimeMs
    }

    enum CodingKeys: String, CodingKey {
        case residentBytes = "resident_bytes"
        case virtualBytes = "virtual_bytes"
        case physFootprintBytes = "phys_footprint_bytes"
        case sampleTimeMs = "sample_time_ms"
    }
}

/// 全链路性能可观测快照（Core 权威真源，双端消费）
public struct PerformanceObservabilitySnapshot: Codable, Equatable {
    public var coreMemory: CoreRuntimeMemorySnapshot
    public var wsPipelineLatency: LatencyMetricWindow
    public var workspaceMetrics: [WorkspacePerformanceSnapshot]
    public var clientMetrics: [ClientPerformanceReport]
    public var diagnoses: [PerformanceDiagnosis]
    public var snapshotAt: UInt64

    public static let empty = PerformanceObservabilitySnapshot(
        coreMemory: .empty, wsPipelineLatency: .empty,
        workspaceMetrics: [], clientMetrics: [], diagnoses: [], snapshotAt: 0
    )

    public init(coreMemory: CoreRuntimeMemorySnapshot = .empty,
                wsPipelineLatency: LatencyMetricWindow = .empty,
                workspaceMetrics: [WorkspacePerformanceSnapshot] = [],
                clientMetrics: [ClientPerformanceReport] = [],
                diagnoses: [PerformanceDiagnosis] = [],
                snapshotAt: UInt64 = 0) {
        self.coreMemory = coreMemory
        self.wsPipelineLatency = wsPipelineLatency
        self.workspaceMetrics = workspaceMetrics
        self.clientMetrics = clientMetrics
        self.diagnoses = diagnoses
        self.snapshotAt = snapshotAt
    }

    /// Rust 侧使用 skip_serializing_if = "Vec::is_empty"，空数组不会序列化到 JSON。
    /// 自定义解码确保缺失的数组键默认为空数组，与 Rust #[serde(default)] 语义对齐。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coreMemory = try container.decode(CoreRuntimeMemorySnapshot.self, forKey: .coreMemory)
        wsPipelineLatency = try container.decode(LatencyMetricWindow.self, forKey: .wsPipelineLatency)
        workspaceMetrics = try container.decodeIfPresent([WorkspacePerformanceSnapshot].self, forKey: .workspaceMetrics) ?? []
        clientMetrics = try container.decodeIfPresent([ClientPerformanceReport].self, forKey: .clientMetrics) ?? []
        diagnoses = try container.decodeIfPresent([PerformanceDiagnosis].self, forKey: .diagnoses) ?? []
        snapshotAt = try container.decode(UInt64.self, forKey: .snapshotAt)
    }

    enum CodingKeys: String, CodingKey {
        case coreMemory = "core_memory"
        case wsPipelineLatency = "ws_pipeline_latency"
        case workspaceMetrics = "workspace_metrics"
        case clientMetrics = "client_metrics"
        case diagnoses
        case snapshotAt = "snapshot_at"
    }
}
