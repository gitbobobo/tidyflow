import Foundation

// MARK: - 统一协调层协议模型
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 定义 Core 协调层与客户端之间的共享协议类型。
// 对应 Rust Core 的 coordinator 模块。
//
// 设计约束：
// - 所有类型与 Core Rust 定义保持语义一致
// - 客户端只消费协调层状态，不自行推导
// - 多工作区通过 globalKey ("project:workspace") 隔离

// MARK: - 协调层身份模型

/// 工作区级协调身份，唯一定位一个 (project, workspace) 上下文。
/// 与 Core 的 WorkspaceCoordinatorId 语义对齐。
public struct CoordinatorWorkspaceId: Equatable, Hashable, Sendable, Codable {
    public let project: String
    public let workspace: String

    /// 全局键，格式 "project:workspace"，与 WorkspaceViewState.globalKey 语义一致。
    public var globalKey: String {
        "\(project):\(workspace)"
    }

    public init(project: String, workspace: String) {
        self.project = project
        self.workspace = workspace
    }

    /// 从全局键解析。
    public static func fromGlobalKey(_ key: String) -> CoordinatorWorkspaceId? {
        guard let colonIndex = key.firstIndex(of: ":") else { return nil }
        let project = String(key[key.startIndex..<colonIndex])
        let workspace = String(key[key.index(after: colonIndex)...])
        guard !project.isEmpty, !workspace.isEmpty else { return nil }
        return CoordinatorWorkspaceId(project: project, workspace: workspace)
    }

    /// 从 WorkspaceViewState 构造。
    public static func from(viewState: WorkspaceViewState) -> CoordinatorWorkspaceId {
        CoordinatorWorkspaceId(project: viewState.projectName, workspace: viewState.workspaceName)
    }
}

// MARK: - 领域相位

/// AI 领域协调相位
public enum AiDomainPhase: String, Equatable, Hashable, Sendable, Codable {
    /// 无活跃 AI 会话
    case idle
    /// 至少一个会话正在执行
    case active
    /// 存在失败会话且无活跃会话
    case faulted
}

/// 终端领域协调相位
public enum TerminalDomainPhase: String, Equatable, Hashable, Sendable, Codable {
    /// 无存活终端
    case idle
    /// 至少一个终端正在运行
    case active
    /// 至少一个终端异常退出且无活跃终端
    case faulted
}

/// 文件领域协调相位
public enum FileDomainPhase: String, Equatable, Hashable, Sendable, Codable {
    /// 文件子系统未激活
    case idle
    /// 文件子系统正常运行中
    case ready
    /// 文件子系统降级或恢复中
    case degraded
    /// 文件子系统不可用
    case error
}

/// 协调层整体健康度
public enum CoordinatorHealth: String, Equatable, Hashable, Sendable, Codable {
    /// 所有领域正常
    case healthy
    /// 至少一个领域降级
    case degraded
    /// 至少一个领域故障
    case faulted
}

// MARK: - 领域子状态

/// AI 领域展示六态（v1.46，标签栏专用）
///
/// 由 Core 聚合计算，客户端直接消费，不自行推导。
/// 与 Core 的 `AiDisplayStatus` 枚举保持语义一致。
public enum AiDisplayStatus: String, Equatable, Hashable, Sendable, Codable {
    /// 无活跃 AI 执行，空闲
    case idle
    /// AI 正在执行（工具调用中）
    case running
    /// AI 等待用户输入
    case awaitingInput = "awaiting_input"
    /// AI 成功完成
    case success
    /// AI 执行失败
    case failure
    /// AI 被取消
    case cancelled
}

/// AI 领域子状态
public struct AiDomainState: Equatable, Sendable {
    public let phase: AiDomainPhase
    public let activeSessionCount: Int
    public let totalSessionCount: Int
    /// 标签栏展示六态（v1.46）
    public let displayStatus: AiDisplayStatus
    /// 当前运行中的工具名（仅 running 状态时存在）
    public let activeToolName: String?
    /// 最近失败的错误摘要（仅 failure 状态时存在）
    public let lastErrorMessage: String?
    /// 展示状态最近变化的时间戳（Unix ms，v1.46）
    public let displayUpdatedAt: Int64

    public init(
        phase: AiDomainPhase = .idle,
        activeSessionCount: Int = 0,
        totalSessionCount: Int = 0,
        displayStatus: AiDisplayStatus = .idle,
        activeToolName: String? = nil,
        lastErrorMessage: String? = nil,
        displayUpdatedAt: Int64 = 0
    ) {
        self.phase = phase
        self.activeSessionCount = activeSessionCount
        self.totalSessionCount = totalSessionCount
        self.displayStatus = displayStatus
        self.activeToolName = activeToolName
        self.lastErrorMessage = lastErrorMessage
        self.displayUpdatedAt = displayUpdatedAt
    }

    public static func from(json: [String: Any]) -> AiDomainState {
        let phase = AiDomainPhase(rawValue: json["phase"] as? String ?? "idle") ?? .idle
        let active = json["active_session_count"] as? Int ?? 0
        let total = json["total_session_count"] as? Int ?? 0
        let displayStatus = AiDisplayStatus(rawValue: json["display_status"] as? String ?? "idle") ?? .idle
        let activeToolName = json["active_tool_name"] as? String
        let lastErrorMessage = json["last_error_message"] as? String
        let displayUpdatedAt = json["display_updated_at"] as? Int64 ?? 0
        return AiDomainState(
            phase: phase,
            activeSessionCount: active,
            totalSessionCount: total,
            displayStatus: displayStatus,
            activeToolName: activeToolName,
            lastErrorMessage: lastErrorMessage,
            displayUpdatedAt: displayUpdatedAt
        )
    }
}

/// 终端领域子状态
public struct TerminalDomainState: Equatable, Sendable {
    public let phase: TerminalDomainPhase
    public let aliveCount: Int
    public let totalCount: Int

    public init(phase: TerminalDomainPhase = .idle, aliveCount: Int = 0, totalCount: Int = 0) {
        self.phase = phase
        self.aliveCount = aliveCount
        self.totalCount = totalCount
    }

    public static func from(json: [String: Any]) -> TerminalDomainState {
        let phase = TerminalDomainPhase(rawValue: json["phase"] as? String ?? "idle") ?? .idle
        let alive = json["alive_count"] as? Int ?? 0
        let total = json["total_count"] as? Int ?? 0
        return TerminalDomainState(phase: phase, aliveCount: alive, totalCount: total)
    }
}

/// 文件领域子状态
public struct FileDomainState: Equatable, Sendable {
    public let phase: FileDomainPhase
    public let watcherActive: Bool
    public let indexingInProgress: Bool

    public init(phase: FileDomainPhase = .idle, watcherActive: Bool = false, indexingInProgress: Bool = false) {
        self.phase = phase
        self.watcherActive = watcherActive
        self.indexingInProgress = indexingInProgress
    }

    public static func from(json: [String: Any]) -> FileDomainState {
        let phase = FileDomainPhase(rawValue: json["phase"] as? String ?? "idle") ?? .idle
        let watcher = json["watcher_active"] as? Bool ?? false
        let indexing = json["indexing_in_progress"] as? Bool ?? false
        return FileDomainState(phase: phase, watcherActive: watcher, indexingInProgress: indexing)
    }
}

// MARK: - 工作区协调聚合状态

/// 工作区级协调聚合状态
///
/// 由 Core 产生，客户端只消费不推导。
/// 每个 (project, workspace) 一个实例。
public struct WorkspaceCoordinatorState: Equatable, Sendable {
    public let id: CoordinatorWorkspaceId
    public let ai: AiDomainState
    public let terminal: TerminalDomainState
    public let file: FileDomainState
    public let health: CoordinatorHealth
    public let generatedAt: String
    public let version: UInt64

    public init(
        id: CoordinatorWorkspaceId,
        ai: AiDomainState = AiDomainState(),
        terminal: TerminalDomainState = TerminalDomainState(),
        file: FileDomainState = FileDomainState(),
        health: CoordinatorHealth = .healthy,
        generatedAt: String = "",
        version: UInt64 = 0
    ) {
        self.id = id
        self.ai = ai
        self.terminal = terminal
        self.file = file
        self.health = health
        self.generatedAt = generatedAt
        self.version = version
    }

    /// 从 Core 协议 JSON 解析
    public static func from(json: [String: Any]) -> WorkspaceCoordinatorState? {
        guard let idJson = json["id"] as? [String: Any],
              let project = idJson["project"] as? String,
              let workspace = idJson["workspace"] as? String else {
            return nil
        }

        let id = CoordinatorWorkspaceId(project: project, workspace: workspace)
        let ai = AiDomainState.from(json: json["ai"] as? [String: Any] ?? [:])
        let terminal = TerminalDomainState.from(json: json["terminal"] as? [String: Any] ?? [:])
        let file = FileDomainState.from(json: json["file"] as? [String: Any] ?? [:])
        let health = CoordinatorHealth(rawValue: json["health"] as? String ?? "healthy") ?? .healthy
        let generatedAt = json["generated_at"] as? String ?? ""
        let version = json["version"] as? UInt64 ?? 0

        return WorkspaceCoordinatorState(
            id: id,
            ai: ai,
            terminal: terminal,
            file: file,
            health: health,
            generatedAt: generatedAt,
            version: version
        )
    }

    /// 是否所有领域均为 Idle
    public var isIdle: Bool {
        ai.phase == .idle && terminal.phase == .idle && file.phase == .idle
    }
}

// MARK: - 一致性校验结果

/// 不一致严重级别
public enum InconsistencySeverity: String, Equatable, Sendable, Codable {
    case warning
    case error
    case critical
}

/// 检测到的不一致条目
public struct CoordinatorInconsistency: Equatable, Sendable {
    public let kind: String
    public let workspaceId: CoordinatorWorkspaceId
    public let description: String
    public let severity: InconsistencySeverity

    public static func from(json: [String: Any]) -> CoordinatorInconsistency? {
        guard let kind = json["kind"] as? String,
              let wsJson = json["workspace_id"] as? [String: Any],
              let project = wsJson["project"] as? String,
              let workspace = wsJson["workspace"] as? String else {
            return nil
        }
        return CoordinatorInconsistency(
            kind: kind,
            workspaceId: CoordinatorWorkspaceId(project: project, workspace: workspace),
            description: json["description"] as? String ?? "",
            severity: InconsistencySeverity(rawValue: json["severity"] as? String ?? "warning") ?? .warning
        )
    }
}

/// 恢复决策
public struct CoordinatorRecoveryDecision: Equatable, Sendable {
    public let action: String
    public let priority: Int
    public let idempotent: Bool
    public let triggeredBy: String
    public let description: String

    public static func from(json: [String: Any]) -> CoordinatorRecoveryDecision? {
        guard let action = json["action"] as? String else { return nil }
        return CoordinatorRecoveryDecision(
            action: action,
            priority: json["priority"] as? Int ?? 99,
            idempotent: json["idempotent"] as? Bool ?? false,
            triggeredBy: json["triggered_by"] as? String ?? "",
            description: json["description"] as? String ?? ""
        )
    }
}

/// 一致性校验结果
public struct CoordinatorConsistencyResult: Equatable, Sendable {
    public let inconsistencies: [CoordinatorInconsistency]
    public let recoveryDecisions: [CoordinatorRecoveryDecision]
    public let isConsistent: Bool

    public static func from(json: [String: Any]) -> CoordinatorConsistencyResult {
        let inconsistencies = (json["inconsistencies"] as? [[String: Any]] ?? [])
            .compactMap { CoordinatorInconsistency.from(json: $0) }
        let decisions = (json["recovery_decisions"] as? [[String: Any]] ?? [])
            .compactMap { CoordinatorRecoveryDecision.from(json: $0) }
        let isConsistent = json["is_consistent"] as? Bool ?? true
        return CoordinatorConsistencyResult(
            inconsistencies: inconsistencies,
            recoveryDecisions: decisions,
            isConsistent: isConsistent
        )
    }
}

// MARK: - coordinator_snapshot 增量消息（v1.46/v1.47）

/// Core 推送的工作区级 Coordinator 快照增量消息载荷。
///
/// 对应 Rust `ServerMessage::CoordinatorSnapshot`，每条消息对应一个工作区。
/// v1.47 新增 `terminal` 和 `file` 领域子状态，保持向前兼容（未提供时使用 existing 中的值）。
/// 客户端收到后通过 `CoordinatorStateCache.apply(.updateWorkspace(...))` 更新缓存。
public struct CoordinatorWorkspaceSnapshotPayload: Sendable {
    public let project: String
    public let workspace: String
    public let ai: AiDomainState
    /// 终端领域子状态（v1.47，可选；nil 表示本条消息不更新终端域）
    public let terminal: TerminalDomainState?
    /// 文件领域子状态（v1.47，可选；nil 表示本条消息不更新文件域）
    public let file: FileDomainState?
    public let version: UInt64
    public let generatedAt: String

    public init(
        project: String,
        workspace: String,
        ai: AiDomainState,
        terminal: TerminalDomainState? = nil,
        file: FileDomainState? = nil,
        version: UInt64,
        generatedAt: String
    ) {
        self.project = project
        self.workspace = workspace
        self.ai = ai
        self.terminal = terminal
        self.file = file
        self.version = version
        self.generatedAt = generatedAt
    }

    public var workspaceId: CoordinatorWorkspaceId {
        CoordinatorWorkspaceId(project: project, workspace: workspace)
    }

    /// 将增量 payload 合并到现有状态，产生新状态。
    ///
    /// 版本号回退检测：旧快照不应覆盖更新的状态。
    /// 未提供的域保留 existing 中的值，避免无意清零其他域状态。
    public func toWorkspaceCoordinatorState(existing: WorkspaceCoordinatorState?) -> WorkspaceCoordinatorState {
        // 版本号回退检测：旧快照不应覆盖更新的状态
        if let existing, existing.version >= version {
            return existing
        }
        return WorkspaceCoordinatorState(
            id: workspaceId,
            ai: ai,
            terminal: terminal ?? existing?.terminal ?? TerminalDomainState(),
            file: file ?? existing?.file ?? FileDomainState(),
            health: existing?.health ?? .healthy,
            generatedAt: generatedAt,
            version: version
        )
    }

    public static func from(json: [String: Any]) -> CoordinatorWorkspaceSnapshotPayload? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else { return nil }
        let ai = AiDomainState.from(json: json["ai"] as? [String: Any] ?? [:])
        // v1.47: 可选终端/文件域（向前兼容，旧协议不含这些字段时为 nil）
        let terminal: TerminalDomainState? = (json["terminal"] as? [String: Any]).map {
            TerminalDomainState.from(json: $0)
        }
        let file: FileDomainState? = (json["file"] as? [String: Any]).map {
            FileDomainState.from(json: $0)
        }
        let version = json["version"] as? UInt64 ?? 0
        let generatedAt = json["generated_at"] as? String ?? ""
        return CoordinatorWorkspaceSnapshotPayload(
            project: project,
            workspace: workspace,
            ai: ai,
            terminal: terminal,
            file: file,
            version: version,
            generatedAt: generatedAt
        )
    }
}
