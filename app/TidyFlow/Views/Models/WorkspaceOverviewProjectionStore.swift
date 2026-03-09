import Foundation
import Combine
import Observation
import TidyFlowShared

// MARK: - 工作区概览投影存储
//
// WorkspaceTerminalProjection、WorkspaceRunningTaskProjection、
// WorkspaceOverviewProjection 以及 WorkspaceOverviewProjectionSemantics
// 已迁移至 TidyFlowShared/Presentation/WorkspaceOverviewProjection.swift。
// 此文件仅保留平台特定的绑定与刷新逻辑。

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
                aiStatus: aiStatus.toSharedProjection(),
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

    #if os(macOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: AppState?
    @ObservationIgnored private var boundProject: String?
    @ObservationIgnored private var boundWorkspace: String?

    func bind(appState: AppState, project: String, workspace: String) {
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

        appState.$workspaceTabs.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedProjectId.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedWorkspaceKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.gitCache.$gitStatusCache.sink { _ in refresh() }.store(in: &cancellables)
        appState.gitCache.$conflictWizardCache.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: AppState, project: String, workspace: String) {
        let globalKey = "\(project):\(workspace)"
        let integrationKey = "\(project):integration"
        let tabs = appState.workspaceTabs[globalKey] ?? []
        let terminalTabs = tabs.filter { $0.kind == .terminal }
        let terminalProjections = terminalTabs.enumerated().map { index, tab in
            WorkspaceTerminalProjection(
                id: tab.id.uuidString,
                termId: tab.id.uuidString,
                title: tab.title,
                shortId: String(tab.id.uuidString.prefix(8)),
                iconName: tab.commandIcon ?? "terminal",
                isPinned: tab.isPinned,
                aiStatus: .idle,
                hasTerminalsToRight: index < terminalTabs.count - 1
            )
        }
        let next = WorkspaceOverviewProjectionSemantics.make(
            gitSnapshot: appState.gitCache.getGitSemanticSnapshot(workspaceKey: workspace),
            hasActiveConflicts: (appState.gitCache.conflictWizardCache[globalKey]?.hasActiveConflicts == true) ||
                (appState.gitCache.conflictWizardCache[integrationKey]?.hasActiveConflicts == true),
            terminals: terminalProjections,
            runningTasks: [],
            completedTaskCount: 0,
            pendingTodoCount: 0,
            projectCommands: appState.projects
                .first(where: { $0.name == project })?.commands ?? []
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

