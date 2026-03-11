import Foundation
import Combine
import Observation
import TidyFlowShared

struct PipelineCycleStageEntry: Identifiable, Equatable {
    let id: String
    let stage: String
    let agent: String
    let aiToolName: String
    let aiToolRawValue: String?
    let sessionID: String?
    let startedAt: String?
    let status: String?
    let durationSeconds: TimeInterval

    init(
        id: String,
        stage: String,
        agent: String,
        aiToolName: String = "",
        aiToolRawValue: String? = nil,
        sessionID: String? = nil,
        startedAt: String? = nil,
        status: String? = nil,
        durationSeconds: TimeInterval
    ) {
        self.id = id
        self.stage = stage
        self.agent = agent
        self.aiToolName = aiToolName
        self.aiToolRawValue = aiToolRawValue
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.status = status
        self.durationSeconds = durationSeconds
    }

    var formattedDuration: String {
        if durationSeconds < 60 {
            return "\(Int(durationSeconds))s"
        } else {
            let minutes = Int(durationSeconds) / 60
            let seconds = Int(durationSeconds) % 60
            return "\(minutes)m\(String(format: "%02d", seconds))s"
        }
    }
}

struct PipelineCycleHistory: Identifiable, Equatable {
    let id: String
    let title: String?
    let status: String?
    let round: Int
    let stages: [String]
    let startDate: Date
    let stageEntries: [PipelineCycleStageEntry]
    let terminalReasonCode: String?
    let terminalErrorMessage: String?
    /// 循环总耗时（毫秒），由 Core 权威输出
    let durationMs: UInt64?
    /// 失败诊断码（与 terminal_reason_code 对齐）
    let errorCode: String?
    /// 是否可安全重试（Core 判定）
    let retryable: Bool

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// 格式化总耗时文本
    var formattedTotalDuration: String? {
        guard let ms = durationMs else { return nil }
        let seconds = Int(ms / 1000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        return "\(minutes)m\(String(format: "%02d", secs))s"
    }

    /// 失败摘要
    var failureSummary: String? {
        guard let status, status.hasPrefix("failed") else { return nil }
        var parts: [String] = []
        if let code = errorCode { parts.append("[\(code)]") }
        if let msg = terminalErrorMessage { parts.append(msg) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    init(
        id: String,
        title: String? = nil,
        status: String? = nil,
        round: Int,
        stages: [String],
        startDate: Date,
        stageEntries: [PipelineCycleStageEntry],
        terminalReasonCode: String? = nil,
        terminalErrorMessage: String? = nil,
        durationMs: UInt64? = nil,
        errorCode: String? = nil,
        retryable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.round = round
        self.stages = stages
        self.startDate = startDate
        self.stageEntries = stageEntries
        self.terminalReasonCode = terminalReasonCode
        self.terminalErrorMessage = terminalErrorMessage
        self.durationMs = durationMs
        self.errorCode = errorCode
        self.retryable = retryable
    }
}

struct PipelineStandbyAgent: Equatable {
    let stage: String
    let isLoopable: Bool
}

struct EvolutionControlProjection: Equatable {
    let canStart: Bool
    let canStop: Bool
    let canResume: Bool
    let isStartPending: Bool
    let isStopPending: Bool
    let isResumePending: Bool
    let startReason: String?
    let stopReason: String?
    let resumeReason: String?

    static let empty = EvolutionControlProjection(
        canStart: false,
        canStop: false,
        canResume: false,
        isStartPending: false,
        isStopPending: false,
        isResumePending: false,
        startReason: nil,
        stopReason: nil,
        resumeReason: nil
    )

#if os(macOS)
    init(_ capability: EvolutionControlCapability) {
        canStart = capability.canStart
        canStop = capability.canStop
        canResume = capability.canResume
        isStartPending = capability.isStartPending
        isStopPending = capability.isStopPending
        isResumePending = capability.isResumePending
        startReason = capability.startReason
        stopReason = capability.stopReason
        resumeReason = capability.resumeReason
    }
#endif

    init(
        canStart: Bool,
        canStop: Bool,
        canResume: Bool,
        isStartPending: Bool,
        isStopPending: Bool,
        isResumePending: Bool,
        startReason: String? = nil,
        stopReason: String? = nil,
        resumeReason: String? = nil
    ) {
        self.canStart = canStart
        self.canStop = canStop
        self.canResume = canResume
        self.isStartPending = isStartPending
        self.isStopPending = isStopPending
        self.isResumePending = isResumePending
        self.startReason = startReason
        self.stopReason = stopReason
        self.resumeReason = resumeReason
    }
}

struct EvolutionBlockerOptionProjection: Identifiable, Equatable {
    let id: String
    let optionID: String
    let label: String
    let description: String

    init(_ option: EvolutionBlockerOptionV2) {
        id = option.optionID
        optionID = option.optionID
        label = option.label
        description = option.description
    }
}

struct EvolutionBlockerItemProjection: Identifiable, Equatable {
    let id: String
    let blockerID: String
    let status: String
    let cycleID: String
    let stage: String
    let createdAt: String
    let source: String
    let title: String
    let description: String
    let questionType: String
    let options: [EvolutionBlockerOptionProjection]
    let allowCustomInput: Bool

    init(_ item: EvolutionBlockerItemV2) {
        id = item.blockerID
        blockerID = item.blockerID
        status = item.status
        cycleID = item.cycleID
        stage = item.stage
        createdAt = item.createdAt
        source = item.source
        title = item.title
        description = item.description
        questionType = item.questionType
        options = item.options.map(EvolutionBlockerOptionProjection.init)
        allowCustomInput = item.allowCustomInput
    }
}

struct EvolutionBlockingRequestProjection: Identifiable, Equatable {
    let id: String
    let project: String
    let workspace: String
    let trigger: String
    let cycleID: String?
    let stage: String?
    let blockerFilePath: String
    let unresolvedItems: [EvolutionBlockerItemProjection]

    init(_ blocking: EvolutionBlockingRequiredV2) {
        project = blocking.project
        workspace = blocking.workspace
        trigger = blocking.trigger
        cycleID = blocking.cycleID
        stage = blocking.stage
        blockerFilePath = blocking.blockerFilePath
        unresolvedItems = blocking.unresolvedItems.map(EvolutionBlockerItemProjection.init)
        id = [
            blocking.project,
            blocking.workspace,
            blocking.cycleID ?? "none",
            blocking.stage ?? "none",
            blocking.trigger
        ].joined(separator: "::")
    }
}

struct EvolutionPipelineProjection: Equatable {
    let project: String
    let workspace: String?
    let workspaceReady: Bool
    let workspaceContextKey: String
    let scheduler: EvolutionSchedulerInfoV2
    let control: EvolutionControlProjection
    let currentItem: EvolutionWorkspaceItemV2?
    let blockingRequest: EvolutionBlockingRequestProjection?
    let cycleHistories: [PipelineCycleHistory]
    /// 预计算：当前正在运行的代理列表
    let runningAgents: [EvolutionAgentInfoV2]
    /// 预计算：待命代理列表（已排序、去重）
    let standbyAgents: [PipelineStandbyAgent]
    /// 预计算：当前循环总耗时文本
    let totalDurationText: String?
    /// 预计算：当前循环是否处于失败状态
    let isCurrentCycleFailed: Bool
    /// 预计算：当前循环的失败摘要（error_code + terminal_error_message）
    let currentCycleFailureSummary: String?
    /// 预计算：当前循环是否可重试
    let isCurrentCycleRetryable: Bool
    /// v1.44：当前工作区的预测投影（调度建议与预测异常摘要）
    let predictionProjection: WorkspacePredictionProjection
    /// v1.45：当前活跃工作区的分析摘要（从 Core 权威输出消费，不重新推导）
    let analysisSummaries: [EvolutionAnalysisSummary]

    /// 当前工作区的瓶颈数量（UI 展示用）
    var activeBottleneckCount: Int {
        analysisSummaries.reduce(0) { $0 + $1.bottlenecks.count }
    }

    /// 系统级优化建议数量
    var systemSuggestionCount: Int {
        analysisSummaries.flatMap(\.suggestions).filter { $0.scope == .system }.count
    }

    /// 最高风险评分（所有活跃工作区中）
    var maxRiskScore: Double {
        analysisSummaries.map(\.overallRiskScore).max() ?? 0.0
    }

    static let empty = EvolutionPipelineProjection(
        project: "",
        workspace: nil,
        workspaceReady: false,
        workspaceContextKey: "",
        scheduler: .empty,
        control: .empty,
        currentItem: nil,
        blockingRequest: nil,
        cycleHistories: [],
        runningAgents: [],
        standbyAgents: [],
        totalDurationText: nil,
        isCurrentCycleFailed: false,
        currentCycleFailureSummary: nil,
        isCurrentCycleRetryable: false,
        predictionProjection: .empty,
        analysisSummaries: []
    )
}

enum EvolutionPipelineProjectionSemantics {
#if os(macOS)
    @MainActor
    static func make(
        appState: AppState,
        mappedCycleHistories: [PipelineCycleHistory]? = nil
    ) -> EvolutionPipelineProjection {
        let project = appState.selectedProjectName
        let workspace = appState.selectedWorkspaceKey
        let normalizedWorkspace = appState.normalizeEvolutionWorkspaceName(workspace ?? "")
        let workspaceReady = !(workspace ?? "").isEmpty
        let workspaceContextKey = workspaceReady ? "\(project)/\(normalizedWorkspace)" : project
        let workspaceKey = workspaceReady
            ? appState.globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
            : nil

        let currentItem = workspace.flatMap { appState.evolutionItem(project: project, workspace: $0) }
        let hotData = precomputeHotData(currentItem: currentItem)

        return EvolutionPipelineProjection(
            project: project,
            workspace: workspace,
            workspaceReady: workspaceReady,
            workspaceContextKey: workspaceContextKey,
            scheduler: appState.evolutionScheduler,
            control: EvolutionControlProjection(
                appState.evolutionControlCapability(project: project, workspace: workspace)
            ),
            currentItem: currentItem,
            blockingRequest: activeBlockingRequest(
                blocking: appState.evolutionBlockingRequired,
                project: project,
                workspace: workspace,
                normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
            ),
            cycleHistories: mappedCycleHistories ?? workspaceKey.map { key in
                (appState.evolutionCycleHistories[key] ?? []).map(mapCycleHistory)
            } ?? [],
            runningAgents: hotData.runningAgents,
            standbyAgents: hotData.standbyAgents,
            totalDurationText: hotData.totalDurationText,
            isCurrentCycleFailed: hotData.isCurrentCycleFailed,
            currentCycleFailureSummary: hotData.currentCycleFailureSummary,
            isCurrentCycleRetryable: hotData.isCurrentCycleRetryable,
            predictionProjection: appState.predictionProjection(
                project: project, workspace: workspace ?? ""
            ),
            analysisSummaries: []
        )
    }
#endif

#if os(iOS)
    @MainActor
    static func make(
        appState: MobileAppState,
        project: String,
        workspace: String,
        mappedCycleHistories: [PipelineCycleHistory]? = nil
    ) -> EvolutionPipelineProjection {
        let normalizedWorkspace = appState.normalizeEvolutionWorkspaceName(workspace)
        let workspaceKey = appState.globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        let controlState = appState.evolutionControlState(project: project, workspace: workspace)
        let currentItem = appState.evolutionItem(project: project, workspace: workspace)
        let hotData = precomputeHotData(currentItem: currentItem)

        return EvolutionPipelineProjection(
            project: project,
            workspace: workspace,
            workspaceReady: true,
            workspaceContextKey: "\(project)/\(normalizedWorkspace)",
            scheduler: appState.evolutionScheduler,
            control: EvolutionControlProjection(
                canStart: controlState.canStart,
                canStop: controlState.canStop,
                canResume: controlState.canResume,
                isStartPending: controlState.isStartPending,
                isStopPending: controlState.isStopPending,
                isResumePending: controlState.isResumePending
            ),
            currentItem: currentItem,
            blockingRequest: activeBlockingRequest(
                blocking: appState.evolutionBlockingRequired,
                project: project,
                workspace: workspace,
                normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
            ),
            cycleHistories: mappedCycleHistories
                ?? (appState.evolutionCycleHistories[workspaceKey] ?? []).map(mapCycleHistory),
            runningAgents: hotData.runningAgents,
            standbyAgents: hotData.standbyAgents,
            totalDurationText: hotData.totalDurationText,
            isCurrentCycleFailed: hotData.isCurrentCycleFailed,
            currentCycleFailureSummary: hotData.currentCycleFailureSummary,
            isCurrentCycleRetryable: hotData.isCurrentCycleRetryable,
            predictionProjection: appState.predictionProjection(
                project: project, workspace: workspace
            ),
            analysisSummaries: []
        )
    }
#endif

    @MainActor
    static func activeBlockingRequest(
        blocking: EvolutionBlockingRequiredV2?,
        project: String,
        workspace: String?,
        normalizeWorkspace: @MainActor (String) -> String
    ) -> EvolutionBlockingRequestProjection? {
        guard let blocking, let workspace else { return nil }
        guard blocking.project == project else { return nil }
        guard normalizeWorkspace(blocking.workspace) == normalizeWorkspace(workspace) else { return nil }
        return EvolutionBlockingRequestProjection(blocking)
    }

    // MARK: - 预计算热点数据

    private struct HotData {
        let runningAgents: [EvolutionAgentInfoV2]
        let standbyAgents: [PipelineStandbyAgent]
        let totalDurationText: String?
        let isCurrentCycleFailed: Bool
        let currentCycleFailureSummary: String?
        let isCurrentCycleRetryable: Bool
    }

    private static func precomputeHotData(currentItem: EvolutionWorkspaceItemV2?) -> HotData {
        let agents = currentItem?.agents ?? []
        let runningAgents = agents.filter {
            $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running"
        }

        // 待命代理：排除运行中和已完成的阶段
        let runningStages = Set(runningAgents.map(\.stage))
        let completedStatuses: Set<String> = [
            "completed", "done", "success", "succeeded", "已完成", "完成"
        ]
        let completedStages = Set(
            agents
                .filter { completedStatuses.contains($0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
                .map(\.stage)
        )
        let candidateStages = Array(Set(agents.map(\.stage))).sorted { lhs, rhs in
            EvolutionStageSemantics.stageSortOrder(lhs) < EvolutionStageSemantics.stageSortOrder(rhs)
        }
        let standbyAgents = candidateStages.compactMap { stage -> PipelineStandbyAgent? in
            guard !runningStages.contains(stage) && !completedStages.contains(stage) else { return nil }
            return PipelineStandbyAgent(stage: stage, isLoopable: EvolutionStageSemantics.isRepeatableStage(stage))
        }

        // 总耗时文本
        let totalDurationText = computeTotalDurationText(currentItem: currentItem, agents: agents)

        // 失败状态与重试资格
        let status = currentItem?.status.lowercased() ?? ""
        let isFailed = status.hasPrefix("failed")
        let failureSummary: String? = {
            guard isFailed else { return nil }
            var parts: [String] = []
            if let code = currentItem?.errorCode { parts.append("[\(code)]") }
            if let msg = currentItem?.terminalErrorMessage { parts.append(msg) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }()
        let isRetryable = currentItem?.retryable ?? false

        return HotData(
            runningAgents: runningAgents,
            standbyAgents: standbyAgents,
            totalDurationText: totalDurationText,
            isCurrentCycleFailed: isFailed,
            currentCycleFailureSummary: failureSummary,
            isCurrentCycleRetryable: isRetryable
        )
    }

    private static func computeTotalDurationText(
        currentItem: EvolutionWorkspaceItemV2?,
        agents: [EvolutionAgentInfoV2]
    ) -> String? {
        let completedExecutions = (currentItem?.executions ?? [])
            .filter { isExecutionCompletedStatus($0.status) }
        var latestByKey: [String: EvolutionSessionExecutionEntryV2] = [:]
        for entry in completedExecutions {
            let key = "\(entry.stage)|\(entry.agent)"
            if let existing = latestByKey[key] {
                if entry.startedAt > existing.startedAt {
                    latestByKey[key] = entry
                }
            } else {
                latestByKey[key] = entry
            }
        }
        let totalMs = latestByKey.values.compactMap(\.durationMs).reduce(0, +)
        if totalMs > 0 {
            return formatDuration(TimeInterval(totalMs) / 1000.0)
        }
        let agentTotalMs = agents.compactMap(\.durationMs).reduce(0, +)
        guard agentTotalMs > 0 else { return nil }
        return formatDuration(TimeInterval(agentTotalMs) / 1000.0)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        } else {
            let minutes = totalSeconds / 60
            let secs = totalSeconds % 60
            return "\(minutes)m\(String(format: "%02d", secs))s"
        }
    }

    static func mapCycleHistory(_ cycle: EvolutionCycleHistoryItemV2) -> PipelineCycleHistory {
        let startDate = rfc3339Date(from: cycle.createdAt) ?? Date()
        let executionEntries = cycle.executions
            .filter { isExecutionCompletedStatus($0.status) }
            .sorted { lhs, rhs in
                switch (lhs.startedAt.isEmpty, rhs.startedAt.isEmpty) {
                case (false, false):
                    if lhs.startedAt != rhs.startedAt {
                        return lhs.startedAt < rhs.startedAt
                    }
                case (false, true):
                    return true
                case (true, false):
                    return false
                case (true, true):
                    break
                }
                return lhs.sessionID < rhs.sessionID
            }
            .map { execution in
                PipelineCycleStageEntry(
                    id: "\(cycle.cycleID)_\(execution.sessionID)_\(execution.startedAt)",
                    stage: EvolutionStageSemantics.runtimeStageKey(execution.stage),
                    agent: execution.agent,
                    aiToolName: execution.aiTool,
                    aiToolRawValue: trimmedNonEmptyText(execution.aiTool),
                    sessionID: execution.sessionID,
                    startedAt: trimmedNonEmptyText(execution.startedAt),
                    status: execution.status,
                    durationSeconds: execution.durationMs.map { TimeInterval($0) / 1000.0 } ?? 0
                )
            }
        let entries: [PipelineCycleStageEntry]
        if executionEntries.isEmpty {
            entries = cycle.stages.map { stage in
                PipelineCycleStageEntry(
                    id: "\(cycle.cycleID)_\(stage.stage)",
                    stage: EvolutionStageSemantics.runtimeStageKey(stage.stage),
                    agent: stage.agent,
                    aiToolName: stage.aiTool,
                    aiToolRawValue: trimmedNonEmptyText(stage.aiTool),
                    status: stage.status,
                    durationSeconds: stage.durationMs.map { TimeInterval($0) / 1000.0 } ?? 0
                )
            }
        } else {
            entries = executionEntries
        }

        return PipelineCycleHistory(
            id: cycle.cycleID,
            title: cycle.title,
            status: cycle.status,
            round: cycle.globalLoopRound,
            stages: entries.map(\.stage),
            startDate: startDate,
            stageEntries: entries,
            terminalReasonCode: cycle.terminalReasonCode,
            terminalErrorMessage: cycle.terminalErrorMessage,
            durationMs: cycle.durationMs,
            errorCode: cycle.errorCode,
            retryable: cycle.retryable
        )
    }

    private static func rfc3339Date(from value: String?) -> Date? {
        EvolutionPipelineDateFormatting.rfc3339Date(from: value)
    }

    private static func trimmedNonEmptyText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isExecutionCompletedStatus(_ status: String) -> Bool {
        EvolutionPipelineDateFormatting.isExecutionCompletedStatus(status)
    }

    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let rfc3339FallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - 进化面板共享日期/状态工具

/// 进化面板各组件共享的日期解析与执行状态判断，避免多处重复定义格式化器
enum EvolutionPipelineDateFormatting {
    static let rfc3339Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let rfc3339FallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func rfc3339Date(from value: String?) -> Date? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return rfc3339Formatter.date(from: trimmed) ?? rfc3339FallbackFormatter.date(from: trimmed)
    }

    /// 判断执行状态是否为"已完成"（非运行中/待处理状态均视为已完成）
    static func isExecutionCompletedStatus(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        return !["running", "pending", "queued", "in_progress", "processing"].contains(normalized)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 {
            return "\(total)s"
        } else {
            let minutes = total / 60
            let secs = total % 60
            return "\(minutes)m\(String(format: "%02d", secs))s"
        }
    }

    static func formatDurationMs(_ ms: UInt64) -> String {
        formatDuration(TimeInterval(ms) / 1000.0)
    }
}

@MainActor
@Observable
final class EvolutionPipelineProjectionStore {
    private(set) var projection: EvolutionPipelineProjection = .empty

    @ObservationIgnored
    private var lastSourceSnapshot: SourceSnapshot?
    @ObservationIgnored
    private var cycleHistoryCache = CycleHistoryCache()

    private struct SourceSnapshot: Equatable {
        let project: String
        let workspace: String?
        let scheduler: EvolutionSchedulerInfoV2
        let control: EvolutionControlProjection
        let currentItemSignature: Int?
        let blockingSignature: Int
        let cycleHistorySignature: Int
    }

    private struct CycleHistoryCache {
        var workspaceKey: String = ""
        var signature: Int = 0
        var mapped: [PipelineCycleHistory] = []
    }

    #if os(macOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: AppState?

    func bind(appState: AppState) {
        guard boundAppState !== appState else {
            refreshIfNeeded(appState: appState)
            return
        }
        boundAppState = appState
        cancellables.removeAll()
        lastSourceSnapshot = nil
        cycleHistoryCache = CycleHistoryCache()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refreshIfNeeded(appState: appState)
        }

        // 合并多路订阅为单一管道，避免同一次状态更新触发多次 refresh
        Publishers.MergeMany([
            appState.$selectedProjectName.map { _ in () }.eraseToAnyPublisher(),
            appState.$selectedWorkspaceKey.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionScheduler.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionWorkspaceItems.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionCycleHistories.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionBlockingRequired.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionPendingActionByWorkspace.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
        .sink { _ in refresh() }
        .store(in: &cancellables)

        refresh()
    }

    func refresh(appState: AppState) {
        let snapshot = makeSourceSnapshot(appState: appState)
        let rawCycleHistories = rawCycleHistories(
            appState: appState,
            project: snapshot.project,
            workspace: snapshot.workspace
        )
        lastSourceSnapshot = snapshot
        _ = updateProjection(
            EvolutionPipelineProjectionSemantics.make(
                appState: appState,
                mappedCycleHistories: mappedCycleHistories(
                    workspaceKey: workspaceKey(
                        project: snapshot.project,
                        workspace: snapshot.workspace,
                        normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
                    ),
                    rawCycleHistories: rawCycleHistories,
                    signature: snapshot.cycleHistorySignature
                )
            )
        )
    }
    #endif

    #if os(iOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: MobileAppState?
    @ObservationIgnored private var boundProject: String?
    @ObservationIgnored private var boundWorkspace: String?

    func bind(appState: MobileAppState, project: String, workspace: String) {
        guard boundAppState !== appState || boundProject != project || boundWorkspace != workspace else {
            refreshIfNeeded(appState: appState, project: project, workspace: workspace)
            return
        }
        boundAppState = appState
        boundProject = project
        boundWorkspace = workspace
        cancellables.removeAll()
        lastSourceSnapshot = nil
        cycleHistoryCache = CycleHistoryCache()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refreshIfNeeded(appState: appState, project: project, workspace: workspace)
        }

        // 合并多路订阅为单一管道，避免同一次状态更新触发多次 refresh
        Publishers.MergeMany([
            appState.$evolutionScheduler.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionWorkspaceItems.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionCycleHistories.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionBlockingRequired.map { _ in () }.eraseToAnyPublisher(),
            appState.$evolutionPendingActionByWorkspace.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
        .sink { _ in refresh() }
        .store(in: &cancellables)

        refresh()
    }

    func refresh(appState: MobileAppState, project: String, workspace: String) {
        let snapshot = makeSourceSnapshot(appState: appState, project: project, workspace: workspace)
        let rawCycleHistories = rawCycleHistories(
            appState: appState,
            project: project,
            workspace: workspace
        )
        lastSourceSnapshot = snapshot
        _ = updateProjection(
            EvolutionPipelineProjectionSemantics.make(
                appState: appState,
                project: project,
                workspace: workspace,
                mappedCycleHistories: mappedCycleHistories(
                    workspaceKey: workspaceKey(
                        project: project,
                        workspace: workspace,
                        normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
                    ),
                    rawCycleHistories: rawCycleHistories,
                    signature: snapshot.cycleHistorySignature
                )
            )
        )
    }
    #endif

    #if os(macOS)
    private func refreshIfNeeded(appState: AppState) {
        let snapshot = makeSourceSnapshot(appState: appState)
        guard snapshot != lastSourceSnapshot else { return }
        refresh(appState: appState)
    }

    private func makeSourceSnapshot(appState: AppState) -> SourceSnapshot {
        let project = appState.selectedProjectName
        let workspace = appState.selectedWorkspaceKey
        return SourceSnapshot(
            project: project,
            workspace: workspace,
            scheduler: appState.evolutionScheduler,
            control: EvolutionControlProjection(
                appState.evolutionControlCapability(project: project, workspace: workspace)
            ),
            currentItemSignature: workspace.flatMap { appState.evolutionItem(project: project, workspace: $0)?.projectionSignature },
            blockingSignature: blockingSignature(
                EvolutionPipelineProjectionSemantics.activeBlockingRequest(
                    blocking: appState.evolutionBlockingRequired,
                    project: project,
                    workspace: workspace,
                    normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
                )
            ),
            cycleHistorySignature: cycleHistorySignature(
                rawCycleHistories(appState: appState, project: project, workspace: workspace)
            )
        )
    }
    #endif

    #if os(iOS)
    private func refreshIfNeeded(appState: MobileAppState, project: String, workspace: String) {
        let snapshot = makeSourceSnapshot(appState: appState, project: project, workspace: workspace)
        guard snapshot != lastSourceSnapshot else { return }
        refresh(appState: appState, project: project, workspace: workspace)
    }

    private func makeSourceSnapshot(
        appState: MobileAppState,
        project: String,
        workspace: String
    ) -> SourceSnapshot {
        let controlState = appState.evolutionControlState(project: project, workspace: workspace)
        return SourceSnapshot(
            project: project,
            workspace: workspace,
            scheduler: appState.evolutionScheduler,
            control: EvolutionControlProjection(
                canStart: controlState.canStart,
                canStop: controlState.canStop,
                canResume: controlState.canResume,
                isStartPending: controlState.isStartPending,
                isStopPending: controlState.isStopPending,
                isResumePending: controlState.isResumePending
            ),
            currentItemSignature: appState.evolutionItem(project: project, workspace: workspace)?.projectionSignature,
            blockingSignature: blockingSignature(
                EvolutionPipelineProjectionSemantics.activeBlockingRequest(
                    blocking: appState.evolutionBlockingRequired,
                    project: project,
                    workspace: workspace,
                    normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
                )
            ),
            cycleHistorySignature: cycleHistorySignature(
                rawCycleHistories(appState: appState, project: project, workspace: workspace)
            )
        )
    }
    #endif

    #if os(macOS)
    private func rawCycleHistories(
        appState: AppState,
        project: String,
        workspace: String?
    ) -> [EvolutionCycleHistoryItemV2] {
        guard let key = workspaceKey(
            project: project,
            workspace: workspace,
            normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
        ) else {
            return []
        }
        return appState.evolutionCycleHistories[key] ?? []
    }
    #endif

    #if os(iOS)
    private func rawCycleHistories(
        appState: MobileAppState,
        project: String,
        workspace: String
    ) -> [EvolutionCycleHistoryItemV2] {
        guard let key = workspaceKey(
            project: project,
            workspace: workspace,
            normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
        ) else {
            return []
        }
        return appState.evolutionCycleHistories[key] ?? []
    }
    #endif

    private func workspaceKey(
        project: String,
        workspace: String?,
        normalizeWorkspace: @MainActor (String) -> String
    ) -> String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        return "\(project):\(normalizeWorkspace(workspace))"
    }

    private func mappedCycleHistories(
        workspaceKey: String?,
        rawCycleHistories: [EvolutionCycleHistoryItemV2],
        signature: Int
    ) -> [PipelineCycleHistory] {
        guard let workspaceKey else { return [] }
        if cycleHistoryCache.workspaceKey == workspaceKey,
           cycleHistoryCache.signature == signature {
            return cycleHistoryCache.mapped
        }
        let mapped = rawCycleHistories.map(EvolutionPipelineProjectionSemantics.mapCycleHistory)
        cycleHistoryCache = CycleHistoryCache(
            workspaceKey: workspaceKey,
            signature: signature,
            mapped: mapped
        )
        return mapped
    }

    private func cycleHistorySignature(_ histories: [EvolutionCycleHistoryItemV2]) -> Int {
        var hasher = Hasher()
        hasher.combine(histories.count)
        for history in histories {
            hasher.combine(history.cycleID)
            hasher.combine(history.updatedAt)
            hasher.combine(history.status)
            hasher.combine(history.globalLoopRound)
            hasher.combine(history.executions.count)
            hasher.combine(history.stages.count)
            hasher.combine(history.terminalReasonCode ?? "")
            hasher.combine(history.terminalErrorMessage ?? "")
        }
        return hasher.finalize()
    }

    private func blockingSignature(_ blocking: EvolutionBlockingRequestProjection?) -> Int {
        var hasher = Hasher()
        hasher.combine(blocking?.id ?? "")
        hasher.combine(blocking?.trigger ?? "")
        hasher.combine(blocking?.cycleID ?? "")
        hasher.combine(blocking?.stage ?? "")
        hasher.combine(blocking?.unresolvedItems.count ?? 0)
        for item in blocking?.unresolvedItems ?? [] {
            hasher.combine(item.blockerID)
            hasher.combine(item.status)
            hasher.combine(item.options.count)
        }
        return hasher.finalize()
    }

    @discardableResult
    func updateProjection(_ next: EvolutionPipelineProjection) -> Bool {
        guard next != projection else { return false }
        projection = next
        return true
    }
}
