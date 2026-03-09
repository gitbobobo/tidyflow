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
public struct HealthContext: Codable, Equatable, Hashable {
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

    public init(snapshotAt: UInt64, overallStatus: SystemHealthStatus,
                incidents: [HealthIncident], recentRepairs: [RepairAuditEntry] = []) {
        self.snapshotAt = snapshotAt
        self.overallStatus = overallStatus
        self.incidents = incidents
        self.recentRepairs = recentRepairs
    }

    enum CodingKeys: String, CodingKey {
        case snapshotAt = "snapshot_at"
        case overallStatus = "overall_status"
        case incidents
        case recentRepairs = "recent_repairs"
    }

    /// 过滤指定 project+workspace 的 incidents（nil 表示系统级）
    public func incidents(for project: String?, workspace: String?) -> [HealthIncident] {
        incidents.filter { incident in
            incident.context.project == project && incident.context.workspace == workspace
        }
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
        return SystemHealthSnapshot(
            snapshotAt: snapshotAt,
            overallStatus: overallStatus,
            incidents: incidents,
            recentRepairs: recentRepairs
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
