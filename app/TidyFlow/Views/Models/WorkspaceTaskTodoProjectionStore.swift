import Foundation
import Combine
import Observation

struct WorkspaceTaskRowProjection: Identifiable, Equatable {
    let id: String
    let title: String
    let status: WorkspaceTaskStatus
    let iconName: String
    let statusSummary: String
    let lastOutputLine: String?
    let canCancel: Bool

    init(_ item: WorkspaceTaskItem, canCancel: Bool) {
        id = item.id
        title = item.title
        status = item.status
        iconName = item.iconName
        statusSummary = item.statusSummaryText()
        lastOutputLine = Self.trimmedNonEmptyText(item.lastOutputLine)
        self.canCancel = canCancel
    }

    private static func trimmedNonEmptyText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct WorkspaceTaskSectionProjection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [WorkspaceTaskRowProjection]
}

struct WorkspaceTaskListProjection: Equatable {
    let workspaceKey: String
    let hasWorkspace: Bool
    let terminalTaskCount: Int
    let sections: [WorkspaceTaskSectionProjection]

    static let empty = WorkspaceTaskListProjection(
        workspaceKey: "",
        hasWorkspace: false,
        terminalTaskCount: 0,
        sections: []
    )
}

enum WorkspaceTaskListProjectionSemantics {
    static func make(
        workspaceKey: String,
        tasks: [WorkspaceTaskItem],
        canCancel: (WorkspaceTaskItem) -> Bool
    ) -> WorkspaceTaskListProjection {
        WorkspaceTaskListProjection(
            workspaceKey: workspaceKey,
            hasWorkspace: !workspaceKey.isEmpty,
            terminalTaskCount: tasks.filter { $0.status.isTerminal }.count,
            sections: [
                makeSection(
                    title: WorkspaceTaskStatus.running.sectionTitle,
                    items: tasks.filter { $0.status.isActive },
                    canCancel: canCancel
                ),
                makeSection(
                    title: WorkspaceTaskStatus.failed.sectionTitle,
                    items: tasks.filter { $0.status == .failed || $0.status == .unknown },
                    canCancel: canCancel
                ),
                makeSection(
                    title: WorkspaceTaskStatus.completed.sectionTitle,
                    items: tasks.filter { $0.status == .completed },
                    canCancel: canCancel
                ),
                makeSection(
                    title: WorkspaceTaskStatus.cancelled.sectionTitle,
                    items: tasks.filter { $0.status == .cancelled },
                    canCancel: canCancel
                )
            ]
            .filter { !$0.items.isEmpty }
        )
    }

    private static func makeSection(
        title: String,
        items: [WorkspaceTaskItem],
        canCancel: (WorkspaceTaskItem) -> Bool
    ) -> WorkspaceTaskSectionProjection {
        WorkspaceTaskSectionProjection(
            id: title,
            title: title,
            items: items.map { WorkspaceTaskRowProjection($0, canCancel: canCancel($0)) }
        )
    }
}

@MainActor
@Observable
final class WorkspaceTaskListProjectionStore {
    private(set) var projection: WorkspaceTaskListProjection = .empty

#if os(iOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: MobileAppState?
    @ObservationIgnored private var boundProject: String?
    @ObservationIgnored private var boundWorkspace: String?

    func bind(appState: MobileAppState, project: String, workspace: String) {
        guard boundAppState !== appState || boundProject != project || boundWorkspace != workspace else {
            refresh(appState: appState, project: project, workspace: workspace)
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

        appState.taskStore.$tasksByKey
            .sink { _ in refresh() }
            .store(in: &cancellables)

        refresh()
    }

    func refresh(appState: MobileAppState, project: String, workspace: String) {
        let workspaceKey = appState.globalWorkspaceKey(project: project, workspace: workspace)
        let tasks = appState.tasksForWorkspace(project: project, workspace: workspace)
        _ = updateProjection(
            WorkspaceTaskListProjectionSemantics.make(
                workspaceKey: workspaceKey,
                tasks: tasks,
                canCancel: appState.canCancelTask
            )
        )
    }
#endif

    @discardableResult
    func updateProjection(_ next: WorkspaceTaskListProjection) -> Bool {
        guard projection != next else { return false }
        projection = next
        return true
    }
}

struct WorkspaceTodoRowProjection: Identifiable, Equatable {
    let id: String
    let title: String
    let note: String?
    let status: WorkspaceTodoStatus

    init(_ item: WorkspaceTodoItem) {
        id = item.id
        title = item.title
        note = item.note
        status = item.status
    }
}

struct WorkspaceTodoSectionProjection: Identifiable, Equatable {
    let id: String
    let title: String
    let status: WorkspaceTodoStatus
    let items: [WorkspaceTodoRowProjection]
}

struct WorkspaceTodoProjection: Equatable {
    let workspaceKey: String?
    let workspaceReady: Bool
    let totalCount: Int
    let pendingCount: Int
    let sections: [WorkspaceTodoSectionProjection]

    static let empty = WorkspaceTodoProjection(
        workspaceKey: nil,
        workspaceReady: false,
        totalCount: 0,
        pendingCount: 0,
        sections: []
    )
}

enum WorkspaceTodoProjectionSemantics {
    static func make(workspaceKey: String?, items: [WorkspaceTodoItem]) -> WorkspaceTodoProjection {
        WorkspaceTodoProjection(
            workspaceKey: workspaceKey,
            workspaceReady: workspaceKey != nil,
            totalCount: items.count,
            pendingCount: items.filter { $0.status != .completed }.count,
            sections: WorkspaceTodoStatus.allCases.compactMap { status in
                let sectionItems = items.filter { $0.status == status }.map(WorkspaceTodoRowProjection.init)
                guard !sectionItems.isEmpty else { return nil }
                return WorkspaceTodoSectionProjection(
                    id: status.rawValue,
                    title: status.localizedTitle,
                    status: status,
                    items: sectionItems
                )
            }
        )
    }

#if os(macOS)
    @MainActor
    static func make(appState: AppState) -> WorkspaceTodoProjection {
        let workspaceKey = appState.currentGlobalWorkspaceKey
        let items = appState.workspaceTodos(for: workspaceKey)
        return make(workspaceKey: workspaceKey, items: items)
    }
#endif

#if os(iOS)
    @MainActor
    static func make(
        appState: MobileAppState,
        project: String,
        workspace: String
    ) -> WorkspaceTodoProjection {
        let workspaceKey = appState.globalWorkspaceKey(project: project, workspace: workspace)
        let items = appState.todosForWorkspace(project: project, workspace: workspace)
        return make(workspaceKey: workspaceKey, items: items)
    }
#endif
}

@MainActor
@Observable
final class WorkspaceTodoProjectionStore {
    private(set) var projection: WorkspaceTodoProjection = .empty

#if os(macOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: AppState?

    func bind(appState: AppState) {
        guard boundAppState !== appState else {
            refresh(appState: appState)
            return
        }

        boundAppState = appState
        cancellables.removeAll()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refresh(appState: appState)
        }

        appState.$selectedProjectName.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedWorkspaceKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.$clientSettings.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: AppState) {
        _ = updateProjection(WorkspaceTodoProjectionSemantics.make(appState: appState))
    }
#endif

#if os(iOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: MobileAppState?
    @ObservationIgnored private var boundProject: String?
    @ObservationIgnored private var boundWorkspace: String?

    func bind(appState: MobileAppState, project: String, workspace: String) {
        guard boundAppState !== appState || boundProject != project || boundWorkspace != workspace else {
            refresh(appState: appState, project: project, workspace: workspace)
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

        appState.$workspaceTodosByKey
            .sink { _ in refresh() }
            .store(in: &cancellables)

        refresh()
    }

    func refresh(appState: MobileAppState, project: String, workspace: String) {
        _ = updateProjection(
            WorkspaceTodoProjectionSemantics.make(
                appState: appState,
                project: project,
                workspace: workspace
            )
        )
    }
#endif

    @discardableResult
    func updateProjection(_ next: WorkspaceTodoProjection) -> Bool {
        guard projection != next else { return false }
        projection = next
        return true
    }
}
