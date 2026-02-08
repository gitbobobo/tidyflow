import Foundation

// MARK: - GitCacheState Diff / Status / Log / Show API

extension GitCacheState {

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
            stagedCount: result.stagedCount,
            currentBranch: result.currentBranch,
            defaultBranch: result.defaultBranch,
            aheadBy: result.aheadBy,
            behindBy: result.behindBy,
            comparedBranch: result.comparedBranch
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
}
