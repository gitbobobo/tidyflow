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

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
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
        terminalErrorMessage: String? = nil
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
    }
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

    static let empty = EvolutionPipelineProjection(
        project: "",
        workspace: nil,
        workspaceReady: false,
        workspaceContextKey: "",
        scheduler: .empty,
        control: .empty,
        currentItem: nil,
        blockingRequest: nil,
        cycleHistories: []
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

        return EvolutionPipelineProjection(
            project: project,
            workspace: workspace,
            workspaceReady: workspaceReady,
            workspaceContextKey: workspaceContextKey,
            scheduler: appState.evolutionScheduler,
            control: EvolutionControlProjection(
                appState.evolutionControlCapability(project: project, workspace: workspace)
            ),
            currentItem: workspace.flatMap { appState.evolutionItem(project: project, workspace: $0) },
            blockingRequest: activeBlockingRequest(
                blocking: appState.evolutionBlockingRequired,
                project: project,
                workspace: workspace,
                normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
            ),
            cycleHistories: mappedCycleHistories ?? workspaceKey.map { key in
                (appState.evolutionCycleHistories[key] ?? []).map(mapCycleHistory)
            } ?? []
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
            currentItem: appState.evolutionItem(project: project, workspace: workspace),
            blockingRequest: activeBlockingRequest(
                blocking: appState.evolutionBlockingRequired,
                project: project,
                workspace: workspace,
                normalizeWorkspace: appState.normalizeEvolutionWorkspaceName
            ),
            cycleHistories: mappedCycleHistories
                ?? (appState.evolutionCycleHistories[workspaceKey] ?? []).map(mapCycleHistory)
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
            terminalErrorMessage: cycle.terminalErrorMessage
        )
    }

    private static func rfc3339Date(from value: String?) -> Date? {
        guard let text = trimmedNonEmptyText(value) else { return nil }
        return rfc3339Formatter.date(from: text) ?? rfc3339FallbackFormatter.date(from: text)
    }

    private static func trimmedNonEmptyText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isExecutionCompletedStatus(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return false
        }
        return ![
            "running",
            "pending",
            "queued",
            "in_progress",
            "processing"
        ].contains(normalized)
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

        appState.$selectedProjectName.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedWorkspaceKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionScheduler.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionWorkspaceItems.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionCycleHistories.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionBlockingRequired.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionPendingActionByWorkspace.sink { _ in refresh() }.store(in: &cancellables)

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

        appState.$evolutionScheduler.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionWorkspaceItems.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionCycleHistories.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionBlockingRequired.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionPendingActionByWorkspace.sink { _ in refresh() }.store(in: &cancellables)

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
