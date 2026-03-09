#if os(macOS)
import Foundation
import Combine

struct EvolutionPipelineProjection: Equatable {
    let project: String
    let workspace: String?
    let workspaceReady: Bool
    let workspaceContextKey: String
    let currentItem: EvolutionWorkspaceItemV2?
    let cycleHistories: [PipelineCycleHistory]

    static let empty = EvolutionPipelineProjection(
        project: "",
        workspace: nil,
        workspaceReady: false,
        workspaceContextKey: "",
        currentItem: nil,
        cycleHistories: []
    )
}

enum EvolutionPipelineProjectionSemantics {
    static func make(
        appState: AppState,
        mapHistory: (EvolutionCycleHistoryItemV2) -> PipelineCycleHistory
    ) -> EvolutionPipelineProjection {
        let project = appState.selectedProjectName
        let workspace = appState.selectedWorkspaceKey
        let workspaceReady = workspace != nil && !(workspace ?? "").isEmpty
        let normalizedWorkspace = appState.normalizeEvolutionWorkspaceName(workspace ?? "")
        let workspaceContextKey = "\(project)/\(normalizedWorkspace)"
        let currentItem: EvolutionWorkspaceItemV2? = {
            guard let workspace else { return nil }
            return appState.evolutionItem(project: project, workspace: workspace)
        }()
        let cycleHistories: [PipelineCycleHistory] = {
            guard let workspace else { return [] }
            let key = appState.globalWorkspaceKey(
                projectName: project,
                workspaceName: appState.normalizeEvolutionWorkspaceName(workspace)
            )
            return (appState.evolutionCycleHistories[key] ?? []).map(mapHistory)
        }()
        return EvolutionPipelineProjection(
            project: project,
            workspace: workspace,
            workspaceReady: workspaceReady,
            workspaceContextKey: workspaceContextKey,
            currentItem: currentItem,
            cycleHistories: cycleHistories
        )
    }
}

@MainActor
final class EvolutionPipelineProjectionStore: ObservableObject {
    @Published private(set) var projection: EvolutionPipelineProjection = .empty

    private var cancellables: Set<AnyCancellable> = []
    private weak var boundAppState: AppState?

    func bind(
        appState: AppState,
        mapHistory: @escaping (EvolutionCycleHistoryItemV2) -> PipelineCycleHistory
    ) {
        guard boundAppState !== appState else { return }
        boundAppState = appState
        cancellables.removeAll()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refresh(appState: appState, mapHistory: mapHistory)
        }

        appState.$selectedProjectName.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedWorkspaceKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionWorkspaceItems.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evolutionCycleHistories.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(
        appState: AppState,
        mapHistory: (EvolutionCycleHistoryItemV2) -> PipelineCycleHistory
    ) {
        let next = EvolutionPipelineProjectionSemantics.make(appState: appState, mapHistory: mapHistory)
        _ = updateProjection(next)
    }

    @discardableResult
    func updateProjection(_ next: EvolutionPipelineProjection) -> Bool {
        guard next != projection else { return false }
        projection = next
        return true
    }
}
#endif
