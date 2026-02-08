import Foundation

// MARK: - GitCacheState Stage/Unstage / Branch / Commit / Rebase / Merge / Integration API

extension GitCacheState {

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
