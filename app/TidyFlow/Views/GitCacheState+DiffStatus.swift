import Foundation
import TidyFlowShared

// MARK: - GitCacheState Diff / Status / Log / Show API

extension GitCacheState {

    // MARK: - Phase C2-2a: Git Diff API

    func handleGitDiffResult(_ result: GitDiffResult) {
        let key = diffCacheKey(
            project: result.project,
            workspace: result.workspace,
            path: result.path,
            mode: result.mode
        )
        // Diff 文本解析移至后台线程，避免大文件阻塞 UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
            DispatchQueue.main.async {
                self?.diffCache[key] = cache
            }
        }
    }

    func fetchGitDiff(
        workspaceKey: String,
        path: String,
        mode: DiffMode,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
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
            mode: mode.rawValue,
            cacheMode: cacheMode
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
        applyGitInput(.gitStatusResult(result), project: result.project, workspace: result.workspace)
        let key = gitStatusCacheKey(project: result.project, workspace: result.workspace)
        gitStatusIndexCache.removeValue(forKey: key)
    }

    func fetchGitStatus(workspaceKey: String, cacheMode: HTTPQueryCacheMode = .default) {
        let projectName = selectedProjectName
        guard connectionState == .connected else {
            let key = gitStatusCacheKey(project: projectName, workspace: workspaceKey)
            var state = workspaceGitState[key] ?? .empty
            state.statusCache.error = "Disconnected"
            state.statusCache.isLoading = false
            workspaceGitState[key] = state
            return
        }
        applyGitInput(.refreshStatus(cacheMode: cacheMode), project: projectName, workspace: workspaceKey)
    }

    func refreshGitStatus() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitStatus(workspaceKey: ws, cacheMode: .forceRefresh)
    }

    func getGitStatusCache(workspaceKey: String) -> GitStatusCache? {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        return workspaceGitState[key]?.statusCache
    }

    /// 是否已经拿到过一次该工作区的 Git 状态结果。
    func hasResolvedGitStatus(workspaceKey: String) -> Bool {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        return workspaceGitState[key]?.hasResolvedStatus ?? false
    }

    func getGitStatusIndex(workspaceKey: String) -> GitStatusIndex {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        if let index = gitStatusIndexCache[key] {
            return index
        }
        if let cache = workspaceGitState[key]?.statusCache {
            let index = GitStatusIndex(from: cache)
            gitStatusIndexCache[key] = index
            return index
        }
        return GitStatusIndex()
    }

    func shouldFetchGitStatus(workspaceKey: String) -> Bool {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        guard let cache = workspaceGitState[key]?.statusCache else { return true }
        return cache.isExpired && !cache.isLoading
    }

    /// 返回当前工作区的语义快照；缓存不存在时返回空快照而不是 nil，避免视图层需要 nil 判断
    func getGitSemanticSnapshot(workspaceKey: String) -> GitPanelSemanticSnapshot {
        let key = gitStatusCacheKey(project: selectedProjectName, workspace: workspaceKey)
        return workspaceGitState[key]?.semanticSnapshot ?? .empty()
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

    func fetchGitLog(
        workspaceKey: String,
        limit: Int = 50,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
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
        wsClient?.requestGitLog(project: projectName, workspace: workspaceKey, limit: limit, cacheMode: cacheMode)
    }

    func refreshGitLog() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitLog(workspaceKey: ws, cacheMode: .forceRefresh)
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
        let cacheKey = gitShowCacheKey(
            project: result.project,
            workspace: result.workspace,
            sha: result.sha
        )
        let cache = GitShowCache(
            result: result,
            isLoading: false,
            error: nil
        )
        gitShowCache[cacheKey] = cache
    }

    func fetchGitShow(workspaceKey: String, sha: String, cacheMode: HTTPQueryCacheMode = .default) {
        let cacheKey = gitShowCacheKey(
            project: selectedProjectName,
            workspace: workspaceKey,
            sha: sha
        )
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
        wsClient?.requestGitShow(project: selectedProjectName, workspace: workspaceKey, sha: sha, cacheMode: cacheMode)
    }

    func getGitShowCache(workspaceKey: String, sha: String) -> GitShowCache? {
        let cacheKey = gitShowCacheKey(
            project: selectedProjectName,
            workspace: workspaceKey,
            sha: sha
        )
        return gitShowCache[cacheKey]
    }
}
