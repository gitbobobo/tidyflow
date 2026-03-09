import Foundation
import Combine
import Observation
import TidyFlowShared

struct WorkspaceTerminalProjection: Identifiable, Equatable {
    let id: String
    let termId: String
    let title: String
    let shortId: String
    let iconName: String
    let isPinned: Bool
    let aiStatus: TerminalAIStatus
    let hasTerminalsToRight: Bool
}

struct WorkspaceRunningTaskProjection: Identifiable, Equatable {
    let id: String
    let iconName: String
    let title: String
    let message: String
    let canCancel: Bool
}

struct WorkspaceOverviewProjection: Equatable {
    let gitSnapshot: GitPanelSemanticSnapshot
    let hasActiveConflicts: Bool
    let terminals: [WorkspaceTerminalProjection]
    let runningTasks: [WorkspaceRunningTaskProjection]
    let completedTaskCount: Int
    let pendingTodoCount: Int
    let projectCommands: [ProjectCommand]

    static let empty = WorkspaceOverviewProjection(
        gitSnapshot: GitPanelSemanticSnapshot.empty(),
        hasActiveConflicts: false,
        terminals: [],
        runningTasks: [],
        completedTaskCount: 0,
        pendingTodoCount: 0,
        projectCommands: []
    )
}

enum WorkspaceOverviewProjectionSemantics {
    static func make(
        gitSnapshot: GitPanelSemanticSnapshot,
        hasActiveConflicts: Bool,
        terminals: [WorkspaceTerminalProjection],
        runningTasks: [WorkspaceRunningTaskProjection],
        completedTaskCount: Int,
        pendingTodoCount: Int,
        projectCommands: [ProjectCommand]
    ) -> WorkspaceOverviewProjection {
        WorkspaceOverviewProjection(
            gitSnapshot: gitSnapshot,
            hasActiveConflicts: hasActiveConflicts,
            terminals: terminals,
            runningTasks: runningTasks,
            completedTaskCount: completedTaskCount,
            pendingTodoCount: pendingTodoCount,
            projectCommands: projectCommands
        )
    }
}

@MainActor
@Observable
final class WorkspaceOverviewProjectionStore {
    private(set) var projection: WorkspaceOverviewProjection = .empty

    #if os(iOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: MobileAppState?
    @ObservationIgnored private var boundProject: String?
    @ObservationIgnored private var boundWorkspace: String?

    func bind(appState: MobileAppState, project: String, workspace: String) {
        guard boundAppState !== appState || boundProject != project || boundWorkspace != workspace else {
            return
        }
        boundAppState = appState
        boundProject = project
        boundWorkspace = workspace
        cancellables.removeAll()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refresh(appState: appState, project: project, workspace: workspace)
        }

        appState.$activeTerminals.sink { _ in refresh() }.store(in: &cancellables)
        appState.$workspaceGitDetailState.sink { _ in refresh() }.store(in: &cancellables)
        appState.$conflictWizardCache.sink { _ in refresh() }.store(in: &cancellables)
        appState.taskStore.$tasksByKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.$workspaceTodosByKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.$customCommands.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: MobileAppState, project: String, workspace: String) {
        let terminals = appState.terminalsForWorkspace(project: project, workspace: workspace)
        let aiStatus = appState.terminalAIStatus(projectName: project, workspaceName: workspace)
        let terminalProjections = terminals.enumerated().map { index, term in
            let presentation = appState.terminalPresentation(for: term.termId)
            return WorkspaceTerminalProjection(
                id: term.termId,
                termId: term.termId,
                title: presentation?.name ?? "终端 \(index + 1)",
                shortId: String(term.termId.prefix(8)),
                iconName: presentation?.icon ?? "terminal",
                isPinned: presentation?.isPinned == true,
                aiStatus: aiStatus,
                hasTerminalsToRight: index < terminals.count - 1
            )
        }
        let runningTasks = appState.runningTasksForWorkspace(project: project, workspace: workspace)
        let taskProjections = runningTasks.map { task in
            WorkspaceRunningTaskProjection(
                id: task.id,
                iconName: task.iconName,
                title: task.title,
                message: task.message,
                canCancel: appState.canCancelTask(task)
            )
        }
        let wsKey = "\(project):\(workspace)"
        let integrationKey = "\(project):integration"
        let next = WorkspaceOverviewProjectionSemantics.make(
            gitSnapshot: appState.gitDetailStateForWorkspace(project: project, workspace: workspace).semanticSnapshot,
            hasActiveConflicts: (appState.conflictWizardCache[wsKey]?.hasActiveConflicts == true) ||
                (appState.conflictWizardCache[integrationKey]?.hasActiveConflicts == true),
            terminals: terminalProjections,
            runningTasks: taskProjections,
            completedTaskCount: appState.tasksForWorkspace(project: project, workspace: workspace)
                .filter { !$0.status.isActive }
                .count,
            pendingTodoCount: appState.pendingTodoCountForWorkspace(project: project, workspace: workspace),
            projectCommands: appState.projectCommands(for: project)
        )
        _ = updateProjection(next)
    }
    #endif

    @discardableResult
    func updateProjection(_ next: WorkspaceOverviewProjection) -> Bool {
        guard projection != next else { return false }
        projection = next
        return true
    }
}
