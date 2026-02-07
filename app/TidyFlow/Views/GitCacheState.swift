import Foundation
import Combine
import SwiftUI

/// 独立的 Git 缓存状态对象
/// 从 AppState 拆分出来，避免 Git 高频更新触发全局视图刷新
class GitCacheState: ObservableObject {

    // MARK: - @Published 属性（原 AppState 中的 Git 相关属性）

    // Phase C2-2a: Diff Cache (key: "workspace:path:mode" -> DiffCache)
    @Published var diffCache: [String: DiffCache] = [:]

    // Phase C3-1: Git Status Cache (workspace key -> GitStatusCache)
    @Published var gitStatusCache: [String: GitStatusCache] = [:]

    // Git Log Cache (workspace key -> GitLogCache)
    @Published var gitLogCache: [String: GitLogCache] = [:]

    // Git Show Cache (workspace key + sha -> GitShowCache)
    @Published var gitShowCache: [String: GitShowCache] = [:]

    // Phase C3-2a: Git operation in-flight tracking (workspace key -> Set<GitOpInFlight>)
    @Published var gitOpsInFlight: [String: Set<GitOpInFlight>] = [:]

    // Phase C3-3a: Git Branch Cache (workspace key -> GitBranchCache)
    @Published var gitBranchCache: [String: GitBranchCache] = [:]
    // Phase C3-3a: Branch switch in-flight (workspace key -> target branch)
    @Published var branchSwitchInFlight: [String: String] = [:]
    // Phase C3-3b: Branch create in-flight (workspace key -> new branch name)
    @Published var branchCreateInFlight: [String: String] = [:]

    // Phase C3-4a: Commit message per workspace
    @Published var commitMessage: [String: String] = [:]
    // Phase C3-4a: Commit in-flight (workspace key -> true)
    @Published var commitInFlight: [String: Bool] = [:]

    // Phase UX-3a: Git operation status cache (workspace key -> GitOpStatusCache)
    @Published var gitOpStatusCache: [String: GitOpStatusCache] = [:]
    // Phase UX-3a: Rebase in-flight (workspace key -> true)
    @Published var rebaseInFlight: [String: Bool] = [:]

    // Phase UX-3b: Git integration status cache (workspace key -> GitIntegrationStatusCache)
    @Published var gitIntegrationStatusCache: [String: GitIntegrationStatusCache] = [:]
    // Phase UX-3b: Merge in-flight (workspace key -> true)
    @Published var mergeInFlight: [String: Bool] = [:]
    // Phase UX-4: Rebase onto default in-flight (workspace key -> true)
    @Published var rebaseOntoDefaultInFlight: [String: Bool] = [:]

    // Git 状态索引缓存（资源管理器用，workspace key -> GitStatusIndex）
    private var gitStatusIndexCache: [String: GitStatusIndex] = [:]

    // MARK: - 由 AppState 注入的依赖

    weak var wsClient: WSClient?
    var getProjectName: (() -> String)?
    var getConnectionState: (() -> ConnectionState)?
    var getSelectedWorkspaceKey: (() -> String?)?

    // 跨域回调（handleGitOpResult 需要操作 tab）
    var onCloseAllDiffTabs: ((String) -> Void)?
    var onCloseDiffTab: ((String, String) -> Void)?
    var onRefreshActiveDiff: (() -> Void)?
    var getActiveDiffPath: (() -> String?)?
    var getActiveDiffMode: (() -> DiffMode)?

    // MARK: - 便捷属性

    private var selectedProjectName: String {
        getProjectName?() ?? "default"
    }

    private var connectionState: ConnectionState {
        getConnectionState?() ?? .disconnected
    }

    private var selectedWorkspaceKey: String? {
        getSelectedWorkspaceKey?()
    }

    // MARK: - Cache Key 辅助方法

    private func diffCacheKey(workspace: String, path: String, mode: String) -> String {
        return "\(workspace):\(path):\(mode)"
    }

    private func gitStatusCacheKey(project: String, workspace: String) -> String {
        return "\(project):\(workspace)"
    }

    private func gitLogCacheKey(project: String, workspace: String) -> String {
        return "\(project):\(workspace)"
    }

    // MARK: - Phase C2-2a: Git Diff API

    func handleGitDiffResult(_ result: GitDiffResult) {
        let key = diffCacheKey(workspace: result.workspace, path: result.path, mode: result.mode)
        let parsedLines = DiffParser.parse(result.text)
        let cache = DiffCache(
            text: result.text,
            parsedLines: parsedLines,
            isLoading: false,
            error: nil,
            isBinary: result.isBinary,
            truncated: result.truncated,
            code: result.code,
            updatedAt: Date()
        )
        diffCache[key] = cache
    }

    func fetchGitDiff(workspaceKey: String, path: String, mode: DiffMode) {
        guard connectionState == .connected else {
            let key = diffCacheKey(workspace: workspaceKey, path: path, mode: mode.rawValue)
            var cache = diffCache[key] ?? DiffCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            diffCache[key] = cache
            return
        }
        let key = diffCacheKey(workspace: workspaceKey, path: path, mode: mode.rawValue)
        var cache = diffCache[key] ?? DiffCache.empty()
        cache.isLoading = true
        cache.error = nil
        diffCache[key] = cache
        wsClient?.requestGitDiff(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            mode: mode.rawValue
        )
    }

    func getDiffCache(workspaceKey: String, path: String, mode: DiffMode) -> DiffCache? {
        let key = diffCacheKey(workspace: workspaceKey, path: path, mode: mode.rawValue)
        return diffCache[key]
    }

    func refreshActiveDiff() {
        guard let ws = selectedWorkspaceKey,
              let path = getActiveDiffPath?() else { return }
        let mode = getActiveDiffMode?() ?? .working
        fetchGitDiff(workspaceKey: ws, path: path, mode: mode)
    }

    func isFileDeleted(workspaceKey: String, path: String, mode: DiffMode) -> Bool {
        guard let cache = getDiffCache(workspaceKey: workspaceKey, path: path, mode: mode) else {
            return false
        }
        return cache.code.hasPrefix("D")
    }

    // MARK: - Phase C3-1: Git Status API

    func handleGitStatusResult(_ result: GitStatusResult) {
        let key = gitStatusCacheKey(project: result.project, workspace: result.workspace)
        let cache = GitStatusCache(
            items: result.items,
            isLoading: false,
            error: result.error,
            isGitRepo: result.isGitRepo,
            updatedAt: Date(),
            hasStagedChanges: result.hasStagedChanges,
            stagedCount: result.stagedCount
        )
        gitStatusCache[key] = cache
        gitStatusIndexCache.removeValue(forKey: key)
    }

    func fetchGitStatus(workspaceKey: String) {
        let projectName = selectedProjectName
        let key = gitStatusCacheKey(project: projectName, workspace: workspaceKey)
        guard connectionState == .connected else {
            var cache = gitStatusCache[key] ?? GitStatusCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitStatusCache[key] = cache
            return
        }
        var cache = gitStatusCache[key] ?? GitStatusCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitStatusCache[key] = cache
        wsClient?.requestGitStatus(project: projectName, workspace: workspaceKey)
    }

    func refreshGitStatus() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitStatus(workspaceKey: ws)
    }

    func getGitStatusCache(workspaceKey: String) -> GitStatusCache? {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        return gitStatusCache[key]
    }

    func getGitStatusIndex(workspaceKey: String) -> GitStatusIndex {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        if let index = gitStatusIndexCache[key] {
            return index
        }
        if let cache = gitStatusCache[key] {
            let index = GitStatusIndex(from: cache)
            gitStatusIndexCache[key] = index
            return index
        }
        return GitStatusIndex()
    }

    func shouldFetchGitStatus(workspaceKey: String) -> Bool {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        guard let cache = gitStatusCache[key] else { return true }
        return cache.isExpired && !cache.isLoading
    }

    // MARK: - Git Log (Commit History) API

    func handleGitLogResult(_ result: GitLogResult) {
        let key = gitLogCacheKey(project: result.project, workspace: result.workspace)
        let cache = GitLogCache(
            entries: result.entries,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        gitLogCache[key] = cache
    }

    func fetchGitLog(workspaceKey: String, limit: Int = 50) {
        let projectName = selectedProjectName
        let key = gitLogCacheKey(project: projectName, workspace: workspaceKey)
        guard connectionState == .connected else {
            var cache = gitLogCache[key] ?? GitLogCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitLogCache[key] = cache
            return
        }
        var cache = gitLogCache[key] ?? GitLogCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitLogCache[key] = cache
        wsClient?.requestGitLog(project: projectName, workspace: workspaceKey, limit: limit)
    }

    func refreshGitLog() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitLog(workspaceKey: ws)
    }

    func getGitLogCache(workspaceKey: String) -> GitLogCache? {
        let key = gitLogCacheKey(project: selectedProjectName, workspace: workspaceKey)
        return gitLogCache[key]
    }

    func shouldFetchGitLog(workspaceKey: String) -> Bool {
        let key = gitLogCacheKey(project: selectedProjectName, workspace: workspaceKey)
        guard let cache = gitLogCache[key] else { return true }
        return cache.isExpired && !cache.isLoading
    }

    // MARK: - Git Show (单个 commit 详情) API

    func handleGitShowResult(_ result: GitShowResult) {
        let cacheKey = "\(result.workspace):\(result.sha)"
        let cache = GitShowCache(
            result: result,
            isLoading: false,
            error: nil
        )
        gitShowCache[cacheKey] = cache
    }

    func fetchGitShow(workspaceKey: String, sha: String) {
        let cacheKey = "\(workspaceKey):\(sha)"
        guard connectionState == .connected else {
            gitShowCache[cacheKey] = GitShowCache(
                result: nil,
                isLoading: false,
                error: "Disconnected"
            )
            return
        }
        if let existing = gitShowCache[cacheKey], existing.result != nil {
            return
        }
        gitShowCache[cacheKey] = GitShowCache(
            result: nil,
            isLoading: true,
            error: nil
        )
        wsClient?.requestGitShow(project: selectedProjectName, workspace: workspaceKey, sha: sha)
    }

    func getGitShowCache(workspaceKey: String, sha: String) -> GitShowCache? {
        let cacheKey = "\(workspaceKey):\(sha)"
        return gitShowCache[cacheKey]
    }

    // MARK: - Phase C3-2a: Git Stage/Unstage API

    func handleGitOpResult(_ result: GitOpResult) {
        let opKey = GitOpInFlight(op: result.op, path: result.path, scope: result.scope)
        gitOpsInFlight[result.workspace]?.remove(opKey)

        if result.op == "switch_branch" {
            branchSwitchInFlight.removeValue(forKey: result.workspace)
            if result.ok {
                fetchGitBranches(workspaceKey: result.workspace)
                fetchGitStatus(workspaceKey: result.workspace)
                onCloseAllDiffTabs?(result.workspace)
            }
            return
        }

        if result.op == "create_branch" {
            branchCreateInFlight.removeValue(forKey: result.workspace)
            if result.ok {
                fetchGitBranches(workspaceKey: result.workspace)
                fetchGitStatus(workspaceKey: result.workspace)
                onCloseAllDiffTabs?(result.workspace)
            }
            return
        }

        if result.ok {
            fetchGitStatus(workspaceKey: result.workspace)

            if let path = result.path,
               selectedWorkspaceKey == result.workspace,
               getActiveDiffPath?() == path {
                if result.op == "discard" {
                    onCloseDiffTab?(result.workspace, path)
                } else {
                    onRefreshActiveDiff?()
                }
            }
        }
    }

    func gitStage(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else { return }
        let opKey = GitOpInFlight(op: "stage", path: path, scope: scope)
        if gitOpsInFlight[workspaceKey] == nil {
            gitOpsInFlight[workspaceKey] = []
        }
        gitOpsInFlight[workspaceKey]?.insert(opKey)
        wsClient?.requestGitStage(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope
        )
    }

    func gitUnstage(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else { return }
        let opKey = GitOpInFlight(op: "unstage", path: path, scope: scope)
        if gitOpsInFlight[workspaceKey] == nil {
            gitOpsInFlight[workspaceKey] = []
        }
        gitOpsInFlight[workspaceKey]?.insert(opKey)
        wsClient?.requestGitUnstage(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope
        )
    }

    func gitDiscard(workspaceKey: String, path: String?, scope: String, includeUntracked: Bool = false) {
        guard connectionState == .connected else { return }
        let opKey = GitOpInFlight(op: "discard", path: path, scope: scope)
        if gitOpsInFlight[workspaceKey] == nil {
            gitOpsInFlight[workspaceKey] = []
        }
        gitOpsInFlight[workspaceKey]?.insert(opKey)
        wsClient?.requestGitDiscard(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope,
            includeUntracked: includeUntracked
        )
    }

    func isGitOpInFlight(workspaceKey: String, path: String?, op: String) -> Bool {
        guard let ops = gitOpsInFlight[workspaceKey] else { return false }
        return ops.contains { $0.op == op && $0.path == path }
    }

    func hasAnyGitOpInFlight(workspaceKey: String) -> Bool {
        guard let ops = gitOpsInFlight[workspaceKey] else { return false }
        return !ops.isEmpty
    }

    // MARK: - Phase C3-3a: Git Branch API

    func handleGitBranchesResult(_ result: GitBranchesResult) {
        let cache = GitBranchCache(
            current: result.current,
            branches: result.branches,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        gitBranchCache[result.workspace] = cache
    }

    func fetchGitBranches(workspaceKey: String) {
        guard connectionState == .connected else {
            var cache = gitBranchCache[workspaceKey] ?? GitBranchCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitBranchCache[workspaceKey] = cache
            return
        }
        var cache = gitBranchCache[workspaceKey] ?? GitBranchCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitBranchCache[workspaceKey] = cache
        wsClient?.requestGitBranches(project: selectedProjectName, workspace: workspaceKey)
    }

    func refreshGitBranches() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitBranches(workspaceKey: ws)
    }

    func getGitBranchCache(workspaceKey: String) -> GitBranchCache? {
        return gitBranchCache[workspaceKey]
    }

    func gitSwitchBranch(workspaceKey: String, branch: String) {
        guard connectionState == .connected else { return }
        branchSwitchInFlight[workspaceKey] = branch
        wsClient?.requestGitSwitchBranch(
            project: selectedProjectName,
            workspace: workspaceKey,
            branch: branch
        )
    }

    func gitCreateBranch(workspaceKey: String, branch: String) {
        guard connectionState == .connected else { return }
        branchCreateInFlight[workspaceKey] = branch
        wsClient?.requestGitCreateBranch(
            project: selectedProjectName,
            workspace: workspaceKey,
            branch: branch
        )
    }

    func isBranchCreateInFlight(workspaceKey: String) -> Bool {
        return branchCreateInFlight[workspaceKey] != nil
    }

    func isBranchSwitchInFlight(workspaceKey: String) -> Bool {
        return branchSwitchInFlight[workspaceKey] != nil
    }

    // MARK: - Phase C3-4a: Git Commit API

    func handleGitCommitResult(_ result: GitCommitResult) {
        commitInFlight.removeValue(forKey: result.workspace)
        if result.ok {
            commitMessage.removeValue(forKey: result.workspace)
            fetchGitStatus(workspaceKey: result.workspace)
        }
    }

    func gitCommit(workspaceKey: String, message: String) {
        guard connectionState == .connected else { return }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        commitInFlight[workspaceKey] = true
        wsClient?.requestGitCommit(
            project: selectedProjectName,
            workspace: workspaceKey,
            message: trimmedMessage
        )
    }

    func isCommitInFlight(workspaceKey: String) -> Bool {
        return commitInFlight[workspaceKey] == true
    }

    func hasStagedChanges(workspaceKey: String) -> Bool {
        return gitStatusCache[workspaceKey]?.hasStagedChanges ?? false
    }

    func stagedCount(workspaceKey: String) -> Int {
        return gitStatusCache[workspaceKey]?.stagedCount ?? 0
    }

    // MARK: - Phase UX-3a: Git Rebase API

    func handleGitRebaseResult(_ result: GitRebaseResult) {
        rebaseInFlight.removeValue(forKey: result.workspace)
        var cache = gitOpStatusCache[result.workspace] ?? GitOpStatusCache.empty()
        cache.isLoading = false
        cache.updatedAt = Date()
        if result.state == "conflict" {
            cache.state = .rebasing
            cache.conflicts = result.conflicts
        } else if result.state == "completed" || result.state == "aborted" {
            cache.state = .normal
            cache.conflicts = []
        }
        gitOpStatusCache[result.workspace] = cache
        fetchGitStatus(workspaceKey: result.workspace)
    }

    func handleGitOpStatusResult(_ result: GitOpStatusResult) {
        var cache = gitOpStatusCache[result.workspace] ?? GitOpStatusCache.empty()
        cache.state = result.state
        cache.conflicts = result.conflicts
        cache.isLoading = false
        cache.updatedAt = Date()
        gitOpStatusCache[result.workspace] = cache
    }

    func gitFetch(workspaceKey: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitFetch(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func gitRebase(workspaceKey: String, ontoBranch: String) {
        guard connectionState == .connected else { return }
        rebaseInFlight[workspaceKey] = true
        var cache = gitOpStatusCache[workspaceKey] ?? GitOpStatusCache.empty()
        cache.isLoading = true
        gitOpStatusCache[workspaceKey] = cache
        wsClient?.requestGitRebase(
            project: selectedProjectName,
            workspace: workspaceKey,
            ontoBranch: ontoBranch
        )
    }

    func gitRebaseContinue(workspaceKey: String) {
        guard connectionState == .connected else { return }
        rebaseInFlight[workspaceKey] = true
        wsClient?.requestGitRebaseContinue(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func gitRebaseAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }
        rebaseInFlight[workspaceKey] = true
        wsClient?.requestGitRebaseAbort(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func fetchGitOpStatus(workspaceKey: String) {
        guard connectionState == .connected else { return }
        var cache = gitOpStatusCache[workspaceKey] ?? GitOpStatusCache.empty()
        cache.isLoading = true
        gitOpStatusCache[workspaceKey] = cache
        wsClient?.requestGitOpStatus(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func getGitOpStatusCache(workspaceKey: String) -> GitOpStatusCache? {
        return gitOpStatusCache[workspaceKey]
    }

    func isRebaseInFlight(workspaceKey: String) -> Bool {
        return rebaseInFlight[workspaceKey] == true
    }

    // MARK: - Phase UX-3b: Git Integration Merge API

    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) {
        mergeInFlight.removeValue(forKey: result.project)
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = false
        cache.updatedAt = Date()
        if result.state == .conflict {
            cache.state = .conflict
            cache.conflicts = result.conflicts
        } else if result.state == .completed || result.state == .idle {
            cache.state = .idle
            cache.conflicts = []
        }
        gitIntegrationStatusCache[result.project] = cache
        fetchGitStatus(workspaceKey: result.project)
    }

    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult) {
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.state = result.state
        cache.conflicts = result.conflicts
        cache.isLoading = false
        cache.updatedAt = Date()
        cache.branchAheadBy = result.branchAheadBy
        cache.branchBehindBy = result.branchBehindBy
        cache.comparedBranch = result.comparedBranch
        gitIntegrationStatusCache[result.project] = cache
    }

    func gitMergeToDefault(workspaceKey: String, defaultBranch: String = "main") {
        guard connectionState == .connected else { return }
        mergeInFlight[workspaceKey] = true
        var cache = gitIntegrationStatusCache[workspaceKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[workspaceKey] = cache
        wsClient?.requestGitMergeToDefault(
            project: selectedProjectName,
            workspace: workspaceKey,
            defaultBranch: defaultBranch
        )
    }

    func gitMergeContinue(workspaceKey: String) {
        guard connectionState == .connected else { return }
        mergeInFlight[workspaceKey] = true
        wsClient?.requestGitMergeContinue(
            project: selectedProjectName
        )
    }

    func gitMergeAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }
        mergeInFlight[workspaceKey] = true
        wsClient?.requestGitMergeAbort(
            project: selectedProjectName
        )
    }

    func fetchGitIntegrationStatus(workspaceKey: String) {
        guard connectionState == .connected else { return }
        var cache = gitIntegrationStatusCache[workspaceKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[workspaceKey] = cache
        wsClient?.requestGitIntegrationStatus(
            project: selectedProjectName
        )
    }

    func getGitIntegrationStatusCache(workspaceKey: String) -> GitIntegrationStatusCache? {
        return gitIntegrationStatusCache[workspaceKey]
    }

    func isMergeInFlight(workspaceKey: String) -> Bool {
        return mergeInFlight[workspaceKey] == true
    }

    // MARK: - Phase UX-4: Git Rebase onto Default API

    func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult) {
        rebaseOntoDefaultInFlight.removeValue(forKey: result.project)
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = false
        cache.updatedAt = Date()
        if result.state == .rebaseConflict {
            cache.state = .rebaseConflict
            cache.conflicts = result.conflicts
        } else if result.state == .rebasing {
            cache.state = .rebasing
            cache.conflicts = []
        } else if result.state == .completed || result.state == .idle {
            cache.state = .idle
            cache.conflicts = []
        }
        gitIntegrationStatusCache[result.project] = cache
        fetchGitStatus(workspaceKey: result.project)
    }

    func gitRebaseOntoDefault(workspaceKey: String, defaultBranch: String = "main") {
        guard connectionState == .connected else { return }
        rebaseOntoDefaultInFlight[workspaceKey] = true
        var cache = gitIntegrationStatusCache[workspaceKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[workspaceKey] = cache
        wsClient?.requestGitRebaseOntoDefault(
            project: selectedProjectName,
            workspace: workspaceKey,
            defaultBranch: defaultBranch
        )
    }

    func gitRebaseOntoDefaultContinue(workspaceKey: String) {
        guard connectionState == .connected else { return }
        rebaseOntoDefaultInFlight[workspaceKey] = true
        wsClient?.requestGitRebaseOntoDefaultContinue(
            project: selectedProjectName
        )
    }

    func gitRebaseOntoDefaultAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }
        rebaseOntoDefaultInFlight[workspaceKey] = true
        wsClient?.requestGitRebaseOntoDefaultAbort(
            project: selectedProjectName
        )
    }

    func isRebaseOntoDefaultInFlight(workspaceKey: String) -> Bool {
        return rebaseOntoDefaultInFlight[workspaceKey] == true
    }

    // MARK: - Phase UX-5: Git Reset Integration Worktree API

    func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult) {
        mergeInFlight.removeValue(forKey: result.project)
        rebaseOntoDefaultInFlight.removeValue(forKey: result.project)
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.state = .idle
        cache.conflicts = []
        cache.isLoading = false
        cache.updatedAt = Date()
        if let path = result.path {
            cache.integrationPath = path
        }
        gitIntegrationStatusCache[result.project] = cache
    }

    func gitResetIntegrationWorktree(workspaceKey: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitResetIntegrationWorktree(
            project: selectedProjectName
        )
    }

    // MARK: - Phase UX-6: Git Check Branch Up To Date API

    func gitCheckBranchUpToDate(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let parts = workspaceKey.split(separator: "/")
        let workspace = parts.count == 2 ? String(parts[1]) : workspaceKey
        wsClient?.requestGitCheckBranchUpToDate(
            project: selectedProjectName,
            workspace: workspace
        )
    }
}