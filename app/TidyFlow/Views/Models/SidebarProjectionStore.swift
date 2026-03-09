import Foundation
import Combine
import TidyFlowShared

// MARK: - 侧边栏投影存储
//
// SidebarActivityIndicatorProjection、SidebarWorkspaceProjection、
// SidebarProjectProjection 以及 SidebarProjectionSemantics 的共享语义方法
// 已迁移至 TidyFlowShared/Presentation/SidebarProjectionModels.swift。
// 此文件仅保留平台特定的构建方法与投影存储类。

extension SidebarProjectionSemantics {

#if os(macOS)
    static func buildMacProjects(
        appState: AppState,
        terminalStore: TerminalStore,
        unseenCompletionKeys: Set<String>
    ) -> [SidebarProjectProjection] {
        let sortedIndices = ProjectSortingSemantics.sortedIndices(
            appState.projects,
            shortcutKeyFinder: { project in
                Self.macProjectMinShortcutKey(project: project, appState: appState)
            },
            earliestTerminalTimeFinder: { project in
                Self.macProjectEarliestTerminalTime(project: project, terminalStore: terminalStore)
            }
        )

        var projects: [SidebarProjectProjection] = []
        projects.reserveCapacity(sortedIndices.count)

        for index in sortedIndices where index < appState.projects.count {
            let project = appState.projects[index]
            let defaultWorkspace = appState.defaultWorkspace(for: project) ?? project.workspaces.first
            let primaryWorkspaceName = defaultWorkspace?.name
            let defaultGlobalWorkspaceKey = defaultWorkspace.map {
                appState.globalWorkspaceKey(projectName: project.name, workspaceName: $0.name)
            }
            let shortcutText = shortcutDisplayText(
                defaultGlobalWorkspaceKey.flatMap { appState.getWorkspaceShortcutKey(workspaceKey: $0) }
            )
            let terminalCount = defaultGlobalWorkspaceKey.flatMap {
                appState.workspaceTabs[$0]?.filter { $0.kind == .terminal }.count
            } ?? 0
            let hasOpenTabs = defaultGlobalWorkspaceKey.map {
                !(appState.workspaceTabs[$0] ?? []).isEmpty
            } ?? false
            let isDeleting = defaultGlobalWorkspaceKey.map {
                appState.deletingWorkspaces.contains($0)
            } ?? false
            let hasUnseenCompletion = defaultGlobalWorkspaceKey.map {
                unseenCompletionKeys.contains($0)
            } ?? false
            let activityIndicators = activityIndicators(
                chatIconName: (defaultWorkspace?.sidebarStatus.hasStreamingChat == true)
                    ? "bubble.left.and.bubble.right.fill"
                    : nil,
                hasActiveEvolutionLoop: defaultWorkspace?.sidebarStatus.hasActiveEvolutionLoop == true,
                taskIconName: defaultWorkspace?.sidebarStatus.taskIconName
            )

            let visibleWorkspaces = appState.sidebarVisibleWorkspaces(for: project).map { workspace in
                let globalWorkspaceKey = appState.globalWorkspaceKey(
                    projectName: project.name,
                    workspaceName: workspace.name
                )
                return SidebarWorkspaceProjection(
                    id: globalWorkspaceKey,
                    projectName: project.name,
                    projectPath: project.path,
                    workspaceName: workspace.name,
                    workspacePath: workspace.root,
                    branch: nil,
                    statusText: nil,
                    isDefault: workspace.isDefault,
                    isSelected: appState.selectedProjectId == project.id &&
                        appState.selectedWorkspaceKey == workspace.name,
                    globalWorkspaceKey: globalWorkspaceKey,
                    shortcutDisplayText: shortcutDisplayText(
                        appState.getWorkspaceShortcutKey(workspaceKey: globalWorkspaceKey)
                    ),
                    terminalCount: appState.workspaceTabs[globalWorkspaceKey]?.filter { $0.kind == .terminal }.count ?? 0,
                    hasOpenTabs: !(appState.workspaceTabs[globalWorkspaceKey] ?? []).isEmpty,
                    isDeleting: appState.deletingWorkspaces.contains(globalWorkspaceKey),
                    hasUnseenCompletion: unseenCompletionKeys.contains(globalWorkspaceKey),
                    activityIndicators: Self.activityIndicators(
                        chatIconName: workspace.sidebarStatus.hasStreamingChat
                            ? "bubble.left.and.bubble.right.fill"
                            : nil,
                        hasActiveEvolutionLoop: workspace.sidebarStatus.hasActiveEvolutionLoop,
                        taskIconName: workspace.sidebarStatus.taskIconName
                    )
                )
            }

            projects.append(
                SidebarProjectProjection(
                id: "mac-project-\(project.id.uuidString)",
                projectID: project.id,
                projectName: project.name,
                projectPath: project.path,
                primaryWorkspaceName: primaryWorkspaceName,
                defaultWorkspaceName: defaultWorkspace?.name,
                defaultWorkspacePath: defaultWorkspace?.root ?? project.path,
                defaultGlobalWorkspaceKey: defaultGlobalWorkspaceKey,
                isSelectedDefaultWorkspace: appState.isSelectedProjectDefaultWorkspace(project),
                shortcutDisplayText: shortcutText,
                terminalCount: terminalCount,
                hasOpenTabs: hasOpenTabs,
                isDeleting: isDeleting,
                hasUnseenCompletion: hasUnseenCompletion,
                activityIndicators: activityIndicators,
                visibleWorkspaces: visibleWorkspaces,
                isLoadingWorkspaces: project.workspaces.isEmpty
            )
            )
        }

        return projects
    }

    private static func macProjectEarliestTerminalTime(
        project: ProjectModel,
        terminalStore: TerminalStore
    ) -> Date? {
        var earliest: Date?
        for workspace in project.workspaces {
            let key = "\(project.name):\(workspace.name)"
            if let time = terminalStore.workspaceTerminalOpenTime[key] {
                if earliest == nil || time < earliest! {
                    earliest = time
                }
            }
        }
        return earliest
    }

    private static func macProjectMinShortcutKey(
        project: ProjectModel,
        appState: AppState
    ) -> Int {
        var minKey = Int.max
        for workspace in project.workspaces {
            let workspaceKey = workspace.isDefault
                ? "\(project.name)/(default)"
                : "\(project.name)/\(workspace.name)"
            if let shortcutKey = appState.getWorkspaceShortcutKey(workspaceKey: workspaceKey),
               let num = Int(shortcutKey) {
                minKey = min(minKey, num == 0 ? 10 : num)
            }
        }
        return minKey
    }
#endif

#if os(iOS)
    @MainActor
    static func buildMobileProjects(appState: MobileAppState) -> [SidebarProjectProjection] {
        let sortedProjects = ProjectSortingSemantics.sortedProjects(
            appState.projects,
            shortcutKeyFinder: { project in
                Self.mobileProjectMinShortcutKey(project: project, appState: appState)
            },
            earliestTerminalTimeFinder: { project in
                Self.mobileProjectEarliestTerminalTime(project: project, appState: appState)
            },
            nameExtractor: { $0.name }
        )

        return sortedProjects.map { project in
            let workspaces = appState.workspacesForProject(project.name)
            let defaultWorkspace = appState.defaultWorkspaceForProject(project.name) ?? workspaces.first
            let primaryWorkspaceName = defaultWorkspace?.name ?? workspaces.first?.name
            let primaryWorkspaceGlobalKey = primaryWorkspaceName.map {
                appState.globalWorkspaceKey(project: project.name, workspace: $0)
            }
            let visibleWorkspaces = appState.sidebarVisibleWorkspacesForProject(project.name).map { workspace in
                let globalWorkspaceKey = appState.globalWorkspaceKey(project: project.name, workspace: workspace.name)
                return SidebarWorkspaceProjection(
                    id: globalWorkspaceKey,
                    projectName: project.name,
                    projectPath: project.root,
                    workspaceName: workspace.name,
                    workspacePath: workspace.root,
                    branch: workspace.branch,
                    statusText: workspace.status,
                    isDefault: workspace.name == "default",
                    isSelected: false,
                    globalWorkspaceKey: globalWorkspaceKey,
                    shortcutDisplayText: shortcutDisplayText(
                        appState.getWorkspaceShortcutKey(workspaceKey: globalWorkspaceKey)
                    ),
                    terminalCount: appState.terminalsForWorkspace(project: project.name, workspace: workspace.name).count,
                    hasOpenTabs: !appState.terminalsForWorkspace(project: project.name, workspace: workspace.name).isEmpty,
                    isDeleting: false,
                    hasUnseenCompletion: appState.taskStore.unseenCompletionKeys.contains(globalWorkspaceKey),
                    activityIndicators: Self.mobileActivityIndicators(
                        appState: appState,
                        project: project.name,
                        workspace: workspace.name
                    )
                )
            }

            let primaryIndicators = primaryWorkspaceName.map {
                Self.mobileActivityIndicators(appState: appState, project: project.name, workspace: $0)
            } ?? []
            let shortcutText = shortcutDisplayText(
                primaryWorkspaceGlobalKey.flatMap { appState.getWorkspaceShortcutKey(workspaceKey: $0) }
            )

            return SidebarProjectProjection(
                id: "ios-project-\(project.name)",
                projectID: nil,
                projectName: project.name,
                projectPath: project.root,
                primaryWorkspaceName: primaryWorkspaceName,
                defaultWorkspaceName: defaultWorkspace?.name,
                defaultWorkspacePath: defaultWorkspace?.root ?? project.root,
                defaultGlobalWorkspaceKey: primaryWorkspaceGlobalKey,
                isSelectedDefaultWorkspace: false,
                shortcutDisplayText: shortcutText,
                terminalCount: primaryWorkspaceName.map {
                    appState.terminalsForWorkspace(project: project.name, workspace: $0).count
                } ?? 0,
                hasOpenTabs: primaryWorkspaceName.map {
                    !appState.terminalsForWorkspace(project: project.name, workspace: $0).isEmpty
                } ?? false,
                isDeleting: false,
                hasUnseenCompletion: primaryWorkspaceGlobalKey.map {
                    appState.taskStore.unseenCompletionKeys.contains($0)
                } ?? false,
                activityIndicators: primaryIndicators,
                visibleWorkspaces: visibleWorkspaces,
                isLoadingWorkspaces: workspaces.isEmpty
            )
        }
    }

    @MainActor
    private static func mobileActivityIndicators(
        appState: MobileAppState,
        project: String,
        workspace: String
    ) -> [SidebarActivityIndicatorProjection] {
        let chatIconName: String?
        if let status = appState.workspaceAIStatus(project: project, workspace: workspace) {
            switch status.normalizedStatus {
            case "running":
                chatIconName = "bolt.circle.fill"
            case "awaiting_input":
                chatIconName = "hourglass.circle.fill"
            case "success":
                chatIconName = "checkmark.circle.fill"
            case "failure", "error":
                chatIconName = "xmark.octagon.fill"
            case "cancelled":
                chatIconName = "minus.circle.fill"
            default:
                chatIconName = "bubble.left.and.bubble.right.fill"
            }
        } else {
            chatIconName = nil
        }
        return activityIndicators(
            chatIconName: chatIconName,
            hasActiveEvolutionLoop: appState.hasWorkspaceActiveEvolutionLoop(project: project, workspace: workspace),
            taskIconName: appState.activeTaskIconForWorkspace(project: project, workspace: workspace)
        )
    }

    @MainActor
    private static func mobileProjectEarliestTerminalTime(
        project: ProjectInfo,
        appState: MobileAppState
    ) -> Date? {
        var earliest: Date?
        for workspace in appState.workspacesForProject(project.name) {
            let key = appState.globalWorkspaceKey(project: project.name, workspace: workspace.name)
            if let time = appState.workspaceTerminalOpenTime[key] {
                if earliest == nil || time < earliest! {
                    earliest = time
                }
            }
        }
        return earliest
    }

    @MainActor
    private static func mobileProjectMinShortcutKey(
        project: ProjectInfo,
        appState: MobileAppState
    ) -> Int {
        var minKey = Int.max
        for workspace in appState.workspacesForProject(project.name) {
            let workspaceKey = workspace.name == "default"
                ? "\(project.name)/(default)"
                : "\(project.name)/\(workspace.name)"
            if let shortcut = appState.getWorkspaceShortcutKey(workspaceKey: workspaceKey),
               let num = Int(shortcut) {
                minKey = min(minKey, num == 0 ? 10 : num)
            }
        }
        return minKey
    }
#endif
}

#if os(macOS)
@MainActor
final class MacSidebarProjectionStore: ObservableObject {
    @Published private(set) var projects: [SidebarProjectProjection] = []

    private var cancellables: Set<AnyCancellable> = []
    private weak var boundAppState: AppState?

    func bind(appState: AppState, terminalStore: TerminalStore, taskStore: WorkspaceTaskStore) {
        guard boundAppState !== appState else { return }
        boundAppState = appState
        cancellables.removeAll()

        let refresh = { [weak self, weak appState, weak terminalStore, weak taskStore] in
            guard let self, let appState, let terminalStore, let taskStore else { return }
            self.refresh(appState: appState, terminalStore: terminalStore, taskStore: taskStore)
        }

        appState.$projects.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedProjectId.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedWorkspaceKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.$workspaceTabs.sink { _ in refresh() }.store(in: &cancellables)
        appState.$deletingWorkspaces.sink { _ in refresh() }.store(in: &cancellables)
        terminalStore.$workspaceTerminalOpenTime.sink { _ in refresh() }.store(in: &cancellables)
        taskStore.$unseenCompletionKeys.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: AppState, terminalStore: TerminalStore, taskStore: WorkspaceTaskStore) {
        let next = SidebarProjectionSemantics.buildMacProjects(
            appState: appState,
            terminalStore: terminalStore,
            unseenCompletionKeys: taskStore.unseenCompletionKeys
        )
        _ = updateProjects(next)
    }

    @discardableResult
    func updateProjects(_ next: [SidebarProjectProjection]) -> Bool {
        guard next != projects else { return false }
        projects = next
        return true
    }
}
#endif

#if os(iOS)
@MainActor
final class MobileSidebarProjectionStore: ObservableObject {
    @Published private(set) var projects: [SidebarProjectProjection] = []

    private var cancellables: Set<AnyCancellable> = []
    private weak var boundAppState: MobileAppState?

    func bind(appState: MobileAppState) {
        guard boundAppState !== appState else { return }
        boundAppState = appState
        cancellables.removeAll()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refresh(appState: appState)
        }

        appState.$projects.sink { _ in refresh() }.store(in: &cancellables)
        appState.$workspacesByProject.sink { _ in refresh() }.store(in: &cancellables)
        appState.$workspaceTerminalOpenTime.sink { _ in refresh() }.store(in: &cancellables)
        appState.$aiSessionStatusesByTool.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionWorkspaceItems.sink { _ in refresh() }.store(in: &cancellables)
        appState.taskStore.$unseenCompletionKeys.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: MobileAppState) {
        let next = SidebarProjectionSemantics.buildMobileProjects(appState: appState)
        _ = updateProjects(next)
    }

    @discardableResult
    func updateProjects(_ next: [SidebarProjectProjection]) -> Bool {
        guard next != projects else { return false }
        projects = next
        return true
    }
}
#endif
