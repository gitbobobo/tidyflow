import Foundation
import Combine
import Observation
import TidyFlowShared

struct GitWorkspaceProjection: Equatable {
    let workspaceKey: String?
    let workspaceReady: Bool
    /// 是否已经拿到过一次 Git 状态结果；用于区分首次加载与后台刷新。
    let hasResolvedStatus: Bool
    let snapshot: GitPanelSemanticSnapshot
    let currentBranchDisplay: String
    let branchDivergenceText: String
    let stagedItems: [GitStatusItem]
    let trackedUnstagedItems: [GitStatusItem]
    let untrackedItems: [GitStatusItem]
    let unstagedItems: [GitStatusItem]
    let stagedPaths: [String]
    let stagedCount: Int
    let trackedUnstagedCount: Int
    let untrackedCount: Int
    let unstagedCount: Int
    let isLoading: Bool
    let isGitRepo: Bool
    let hasStagedChanges: Bool
    let hasTrackedChanges: Bool
    let hasUntrackedChanges: Bool
    let hasUnstagedChanges: Bool
    let isEmpty: Bool
    let isStageAllInFlight: Bool
    let canStageAll: Bool
    let canDiscardAll: Bool

    static let empty = GitWorkspaceProjection(
        workspaceKey: nil,
        workspaceReady: false,
        hasResolvedStatus: false,
        snapshot: .empty(),
        currentBranchDisplay: "未知分支",
        branchDivergenceText: GitPanelSemanticSnapshot.empty().branchDivergenceText,
        stagedItems: [],
        trackedUnstagedItems: [],
        untrackedItems: [],
        unstagedItems: [],
        stagedPaths: [],
        stagedCount: 0,
        trackedUnstagedCount: 0,
        untrackedCount: 0,
        unstagedCount: 0,
        isLoading: false,
        isGitRepo: false,
        hasStagedChanges: false,
        hasTrackedChanges: false,
        hasUntrackedChanges: false,
        hasUnstagedChanges: false,
        isEmpty: true,
        isStageAllInFlight: false,
        canStageAll: false,
        canDiscardAll: false
    )
}

enum GitWorkspaceProjectionSemantics {
    static func make(
        workspaceKey: String?,
        snapshot: GitPanelSemanticSnapshot,
        isStageAllInFlight: Bool,
        hasResolvedStatus: Bool,
        unknownBranchDisplayName: String = "未知分支"
    ) -> GitWorkspaceProjection {
        let stagedItems = snapshot.stagedItems
        let trackedUnstagedItems = snapshot.trackedUnstagedItems
        let untrackedItems = snapshot.untrackedItems
        let unstagedItems = snapshot.unstagedItems
        let hasUnstagedChanges = !unstagedItems.isEmpty
        let hasTrackedChanges = snapshot.hasTrackedChanges
        let hasUntrackedChanges = snapshot.hasUntrackedChanges

        return GitWorkspaceProjection(
            workspaceKey: workspaceKey,
            workspaceReady: workspaceKey != nil,
            hasResolvedStatus: hasResolvedStatus,
            snapshot: snapshot,
            currentBranchDisplay: normalizedBranchDisplay(
                currentBranch: snapshot.currentBranch,
                fallback: unknownBranchDisplayName
            ),
            branchDivergenceText: snapshot.branchDivergenceText,
            stagedItems: stagedItems,
            trackedUnstagedItems: trackedUnstagedItems,
            untrackedItems: untrackedItems,
            unstagedItems: unstagedItems,
            stagedPaths: stagedItems.map(\.path),
            stagedCount: stagedItems.count,
            trackedUnstagedCount: trackedUnstagedItems.count,
            untrackedCount: untrackedItems.count,
            unstagedCount: unstagedItems.count,
            isLoading: snapshot.isLoading,
            isGitRepo: snapshot.isGitRepo,
            hasStagedChanges: snapshot.hasStagedChanges,
            hasTrackedChanges: hasTrackedChanges,
            hasUntrackedChanges: hasUntrackedChanges,
            hasUnstagedChanges: hasUnstagedChanges,
            isEmpty: snapshot.isEmpty,
            isStageAllInFlight: isStageAllInFlight,
            canStageAll: hasUnstagedChanges && !isStageAllInFlight,
            canDiscardAll: hasTrackedChanges || hasUntrackedChanges
        )
    }

    private static func normalizedBranchDisplay(currentBranch: String?, fallback: String) -> String {
        guard let currentBranch else { return fallback }
        let trimmed = currentBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

@MainActor
@Observable
final class GitWorkspaceProjectionStore {
    private(set) var projection: GitWorkspaceProjection = .empty

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    private func parseWorkspaceIdentity(from workspaceKey: String?) -> (project: String, workspace: String) {
        guard let workspaceKey, !workspaceKey.isEmpty else { return ("", "") }
        let parts = workspaceKey.components(separatedBy: "/")
        guard let project = parts.first else { return ("", "") }
        let workspace = parts.dropFirst().joined(separator: "/")
        return (project, workspace)
    }

    private func workspaceContext(project: String, workspace: String) -> String {
        "git_panel:project=\(project):workspace=\(workspace)"
    }

    #if os(macOS)
    @ObservationIgnored private weak var boundMacAppState: AppState?
    @ObservationIgnored private weak var boundGitCache: GitCacheState?

    func bind(appState: AppState, gitCache: GitCacheState) {
        guard boundMacAppState !== appState || boundGitCache !== gitCache else {
            refresh(appState: appState, gitCache: gitCache)
            return
        }

        boundMacAppState = appState
        boundGitCache = gitCache
        cancellables.removeAll()

        let refresh = { [weak self, weak appState, weak gitCache] in
            guard let self, let appState, let gitCache else { return }
            self.refresh(appState: appState, gitCache: gitCache)
        }

        appState.$selectedProjectName.sink { _ in refresh() }.store(in: &cancellables)
        appState.$selectedWorkspaceKey.sink { _ in refresh() }.store(in: &cancellables)
        gitCache.$workspaceGitState.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: AppState, gitCache: GitCacheState) {
        let workspaceKey = appState.selectedWorkspaceKey
        let snapshot = workspaceKey.map { gitCache.getGitSemanticSnapshot(workspaceKey: $0) } ?? .empty()
        let next = GitWorkspaceProjectionSemantics.make(
            workspaceKey: workspaceKey,
            snapshot: snapshot,
            isStageAllInFlight: workspaceKey.map { gitCache.isGitOpInFlight(workspaceKey: $0, path: nil, op: "stage") } ?? false,
            hasResolvedStatus: workspaceKey.map { gitCache.hasResolvedGitStatus(workspaceKey: $0) } ?? false
        )
        _ = updateProjection(next)
    }
    #endif

    #if os(iOS)
    @ObservationIgnored private weak var boundMobileAppState: MobileAppState?
    @ObservationIgnored private var boundProject: String?
    @ObservationIgnored private var boundWorkspace: String?

    func bind(appState: MobileAppState, project: String, workspace: String) {
        guard boundMobileAppState !== appState || boundProject != project || boundWorkspace != workspace else {
            refresh(appState: appState, project: project, workspace: workspace)
            return
        }

        boundMobileAppState = appState
        boundProject = project
        boundWorkspace = workspace
        cancellables.removeAll()

        let refresh = { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refresh(appState: appState, project: project, workspace: workspace)
        }

        appState.$workspaceGitState.sink { _ in refresh() }.store(in: &cancellables)

        refresh()
    }

    func refresh(appState: MobileAppState, project: String, workspace: String) {
        let workspaceKey = appState.globalWorkspaceKey(project: project, workspace: workspace)
        let sharedState = appState.workspaceGitState[workspaceKey]
        let snapshot = sharedState?.semanticSnapshot
            ?? appState.gitDetailStateForWorkspace(project: project, workspace: workspace).semanticSnapshot
        let next = GitWorkspaceProjectionSemantics.make(
            workspaceKey: workspaceKey,
            snapshot: snapshot,
            isStageAllInFlight: sharedState?.isStageAllInFlight ?? false,
            hasResolvedStatus: sharedState?.hasResolvedStatus ?? true
        )
        _ = updateProjection(next)
    }
    #endif

    private var perfReporter: TFClientPerfReporter? {
        #if os(macOS)
        if let reporter = boundMacAppState?.perfReporter {
            return reporter
        }
        #endif
        #if os(iOS)
        if let reporter = boundMobileAppState?.perfReporter {
            return reporter
        }
        #endif
        return nil
    }

    @discardableResult
    func updateProjection(_ next: GitWorkspaceProjection) -> Bool {
        guard projection != next else { return false }
        let startMs = CFAbsoluteTimeGetCurrent() * 1000
        projection = next
        let durationMs = CFAbsoluteTimeGetCurrent() * 1000 - startMs
        // 共享性能热点：git_panel_projection 延迟记录
        let identity = parseWorkspaceIdentity(from: next.workspaceKey)
        let itemCount = next.stagedCount + next.unstagedCount + next.untrackedCount
        TFLog.logPerfSample(
            event: TFPerformanceEvent.gitPanelProjection.rawValue,
            durationMs: durationMs,
            project: identity.project,
            workspace: identity.workspace,
            surface: "git_panel",
            scenario: "git_panel",
            extra: [
                "workspace_context": workspaceContext(project: identity.project, workspace: identity.workspace),
                "staged_count": "\(next.stagedCount)",
                "unstaged_count": "\(next.unstagedCount)",
                "untracked_count": "\(next.untrackedCount)",
                "item_count": "\(itemCount)"
            ]
        )
        // 共享 Git 面板投影热点 —— 记录到性能上报窗口
        perfReporter?.record(event: .gitPanelProjection, durationMs: durationMs)
        return true
    }
}
