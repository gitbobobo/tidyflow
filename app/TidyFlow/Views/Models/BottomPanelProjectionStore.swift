#if os(macOS)
import Foundation
import Combine
import Observation

struct BottomPanelProjection: Equatable {
    let workspaceKey: String?
    let specialPage: WorkspaceSpecialPage?
    let activeCategory: BottomPanelCategory?
    let displayedTabs: [TabModel]
    let activeTab: TabModel?

    static let empty = BottomPanelProjection(
        workspaceKey: nil,
        specialPage: nil,
        activeCategory: nil,
        displayedTabs: [],
        activeTab: nil
    )
}

enum BottomPanelProjectionSemantics {
    static func make(
        workspaceKey: String?,
        specialPage: WorkspaceSpecialPage?,
        activeCategory: BottomPanelCategory?,
        displayedTabs: [TabModel],
        activeTab: TabModel?
    ) -> BottomPanelProjection {
        BottomPanelProjection(
            workspaceKey: workspaceKey,
            specialPage: specialPage,
            activeCategory: activeCategory,
            displayedTabs: displayedTabs,
            activeTab: activeTab
        )
    }
}

@MainActor
@Observable
final class BottomPanelProjectionStore {
    private(set) var projection: BottomPanelProjection = .empty

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: AppState?

    func bind(appState: AppState) {
        guard boundAppState !== appState else { return }
        boundAppState = appState
        cancellables.removeAll()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refresh(appState: appState)
        }

        appState.$selectedProjectName.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedWorkspaceKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.$workspaceSpecialPageByWorkspace.sink { _ in refresh() }.store(in: &cancellables)
        appState.$activeBottomPanelCategoryByWorkspace.sink { _ in refresh() }.store(in: &cancellables)
        appState.$activeTabIdByWorkspace.sink { _ in refresh() }.store(in: &cancellables)
        appState.$workspaceTabs.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: AppState) {
        let workspaceKey = appState.currentGlobalWorkspaceKey
        let next = BottomPanelProjectionSemantics.make(
            workspaceKey: workspaceKey,
            specialPage: workspaceKey.flatMap { appState.workspaceSpecialPageByWorkspace[$0] },
            activeCategory: workspaceKey.map { appState.activeBottomPanelCategory(workspaceKey: $0) },
            displayedTabs: workspaceKey.map { appState.displayedBottomPanelTabs(workspaceKey: $0) } ?? [],
            activeTab: workspaceKey.flatMap { appState.displayedBottomPanelTab(workspaceKey: $0) }
        )
        _ = updateProjection(next)
    }

    @discardableResult
    func updateProjection(_ next: BottomPanelProjection) -> Bool {
        guard projection != next else { return false }
        projection = next
        return true
    }
}
#endif
