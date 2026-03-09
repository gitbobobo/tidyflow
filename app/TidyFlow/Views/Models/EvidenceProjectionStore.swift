import Foundation
import Combine
import Observation
import TidyFlowShared

struct EvidenceItemProjection: Identifiable, Equatable {
    let id: String
    let itemID: String
    let deviceType: String
    let evidenceType: String
    let order: Int
    let path: String
    let title: String
    let description: String
    let scenario: String?
    let subsystem: String?
    let createdAt: String?
    let sizeBytes: UInt64
    let exists: Bool
    let mimeType: String

    init(_ item: EvidenceItemInfoV2) {
        id = item.itemID
        itemID = item.itemID
        deviceType = item.deviceType
        evidenceType = item.evidenceType
        order = item.order
        path = item.path
        title = item.title
        description = item.description
        scenario = item.scenario
        subsystem = item.subsystem
        createdAt = item.createdAt
        sizeBytes = item.sizeBytes
        exists = item.exists
        mimeType = item.mimeType
    }

    var isScreenshotLike: Bool {
        evidenceType == "screenshot" || mimeType.hasPrefix("image/")
    }

    var rawValue: EvidenceItemInfoV2 {
        EvidenceItemInfoV2(
            itemID: itemID,
            deviceType: deviceType,
            evidenceType: evidenceType,
            order: order,
            path: path,
            title: title,
            description: description,
            scenario: scenario,
            subsystem: subsystem,
            createdAt: createdAt,
            sizeBytes: sizeBytes,
            exists: exists,
            mimeType: mimeType
        )
    }
}

struct EvidenceDeviceSectionProjection: Identifiable, Equatable {
    let id: String
    let deviceType: String
    let items: [EvidenceItemProjection]

    init(deviceType: String, items: [EvidenceItemProjection]) {
        id = deviceType
        self.deviceType = deviceType
        self.items = items
    }
}

struct EvidenceTabCountProjection: Identifiable, Equatable {
    let tab: EvidenceTabType
    let count: Int

    var id: String { tab.rawValue }
}

struct EvidenceProjection: Equatable {
    let project: String
    let workspace: String?
    let workspaceReady: Bool
    let workspaceContextKey: String
    let selectedTab: EvidenceTabType
    let snapshotAvailable: Bool
    let snapshotLoading: Bool
    let snapshotError: String?
    let snapshotUpdatedAt: String?
    let currentTabItemCount: Int
    let tabCounts: [EvidenceTabCountProjection]
    let deviceSections: [EvidenceDeviceSectionProjection]
    let allItemIDs: Set<String>
    let screenshotItemIDs: Set<String>

    static let empty = EvidenceProjection(
        project: "",
        workspace: nil,
        workspaceReady: false,
        workspaceContextKey: "",
        selectedTab: .screenshot,
        snapshotAvailable: false,
        snapshotLoading: false,
        snapshotError: nil,
        snapshotUpdatedAt: nil,
        currentTabItemCount: 0,
        tabCounts: EvidenceTabType.allCases.map { EvidenceTabCountProjection(tab: $0, count: 0) },
        deviceSections: [],
        allItemIDs: [],
        screenshotItemIDs: []
    )

    var currentTabItems: [EvidenceItemProjection] {
        deviceSections.flatMap(\.items)
    }

    func tabCount(for tab: EvidenceTabType) -> Int {
        tabCounts.first(where: { $0.tab == tab })?.count ?? 0
    }
}

enum EvidenceProjectionSemantics {
    static func make(
        project: String,
        workspace: String?,
        selectedTab: EvidenceTabType,
        snapshot: EvidenceSnapshotV2?,
        snapshotLoading: Bool,
        snapshotError: String?
    ) -> EvidenceProjection {
        let workspaceReady = !(workspace ?? "").isEmpty
        let workspaceContextKey = workspaceReady ? "\(project)/\(workspace ?? "")" : project
        let tabCounts = EvidenceTabType.allCases.map { tab in
            EvidenceTabCountProjection(
                tab: tab,
                count: snapshot.map { tab.itemCount(in: $0) } ?? 0
            )
        }

        let currentItems = (snapshot.map { selectedTab.filteredItems(from: $0) } ?? []).map(EvidenceItemProjection.init)
        let deviceSections = makeDeviceSections(items: currentItems)

        return EvidenceProjection(
            project: project,
            workspace: workspace,
            workspaceReady: workspaceReady,
            workspaceContextKey: workspaceContextKey,
            selectedTab: selectedTab,
            snapshotAvailable: snapshot != nil,
            snapshotLoading: snapshotLoading,
            snapshotError: snapshotError,
            snapshotUpdatedAt: snapshot?.updatedAt,
            currentTabItemCount: currentItems.count,
            tabCounts: tabCounts,
            deviceSections: deviceSections,
            allItemIDs: Set(snapshot?.items.map(\.itemID) ?? []),
            screenshotItemIDs: Set(
                (snapshot?.items ?? [])
                    .filter { $0.evidenceType == "screenshot" || $0.mimeType.hasPrefix("image/") }
                    .map(\.itemID)
            )
        )
    }

    private static func makeDeviceSections(items: [EvidenceItemProjection]) -> [EvidenceDeviceSectionProjection] {
        var orderedDeviceTypes: [String] = []
        var seenDeviceTypes: Set<String> = []

        for item in items where seenDeviceTypes.insert(item.deviceType).inserted {
            orderedDeviceTypes.append(item.deviceType)
        }

        return orderedDeviceTypes.map { deviceType in
            EvidenceDeviceSectionProjection(
                deviceType: deviceType,
                items: items.filter { $0.deviceType == deviceType }
            )
        }
    }
}

@MainActor
@Observable
final class EvidenceProjectionStore {
    private(set) var projection: EvidenceProjection = .empty

    #if os(macOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: AppState?
    @ObservationIgnored private var boundSelectedTab: EvidenceTabType = .screenshot

    func bind(appState: AppState, selectedTab: EvidenceTabType) {
        boundSelectedTab = selectedTab
        guard boundAppState !== appState else {
            refresh(appState: appState, selectedTab: selectedTab)
            return
        }

        boundAppState = appState
        cancellables.removeAll()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refresh(appState: appState, selectedTab: self.boundSelectedTab)
        }

        appState.$selectedProjectName.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedWorkspaceKey.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evidenceSnapshotsByWorkspace.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evidenceLoadingByWorkspace.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evidenceErrorByWorkspace.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: AppState, selectedTab: EvidenceTabType) {
        boundSelectedTab = selectedTab
        let project = appState.selectedProjectName
        let workspace = appState.selectedWorkspaceKey
        let normalizedWorkspace = workspace.map { appState.normalizeEvolutionWorkspaceName($0) }
        let workspaceKey = normalizedWorkspace.map {
            appState.globalWorkspaceKey(projectName: project, workspaceName: $0)
        }
        let next = EvidenceProjectionSemantics.make(
            project: project,
            workspace: workspace,
            selectedTab: selectedTab,
            snapshot: workspace.flatMap { appState.evidenceSnapshot(project: project, workspace: $0) },
            snapshotLoading: workspaceKey.flatMap { appState.evidenceLoadingByWorkspace[$0] } ?? false,
            snapshotError: workspaceKey.flatMap { appState.evidenceErrorByWorkspace[$0] }
        )
        _ = updateProjection(next)
    }
    #endif

    #if os(iOS)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var boundAppState: MobileAppState?
    @ObservationIgnored private var boundProject: String?
    @ObservationIgnored private var boundWorkspace: String?
    @ObservationIgnored private var boundSelectedTab: EvidenceTabType = .screenshot

    func bind(
        appState: MobileAppState,
        project: String,
        workspace: String,
        selectedTab: EvidenceTabType
    ) {
        boundSelectedTab = selectedTab
        guard boundAppState !== appState || boundProject != project || boundWorkspace != workspace else {
            refresh(appState: appState, project: project, workspace: workspace, selectedTab: selectedTab)
            return
        }

        boundAppState = appState
        boundProject = project
        boundWorkspace = workspace
        cancellables.removeAll()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refresh(
                appState: appState,
                project: project,
                workspace: workspace,
                selectedTab: self.boundSelectedTab
            )
        }

        appState.$evidenceSnapshotsByWorkspace.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evidenceLoadingByWorkspace.sink { _ in refresh() }.store(in: &cancellables)
        appState.$evidenceErrorByWorkspace.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(
        appState: MobileAppState,
        project: String,
        workspace: String,
        selectedTab: EvidenceTabType
    ) {
        boundSelectedTab = selectedTab
        let next = EvidenceProjectionSemantics.make(
            project: project,
            workspace: workspace,
            selectedTab: selectedTab,
            snapshot: appState.evidenceSnapshot(project: project, workspace: workspace),
            snapshotLoading: appState.isEvidenceLoading(project: project, workspace: workspace),
            snapshotError: appState.evidenceError(project: project, workspace: workspace)
        )
        _ = updateProjection(next)
    }
    #endif

    @discardableResult
    func updateProjection(_ next: EvidenceProjection) -> Bool {
        guard projection != next else { return false }
        projection = next
        return true
    }
}
