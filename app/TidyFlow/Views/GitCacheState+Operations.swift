import Foundation
import TidyFlowShared

// MARK: - GitCacheState Stage/Unstage / Branch / Commit / Rebase / Merge / Integration API

extension GitCacheState {

    // MARK: - Phase C3-2a: Git Stage/Unstage API

    func handleGitOpResult(_ result: GitOpResult) {
        let opKey = GitOpInFlight(op: result.op, path: result.path, scope: result.scope)
        let wsCacheKey = workspaceCacheKey(workspace: result.workspace, project: result.project)
        gitOpsInFlight[wsCacheKey]?.remove(opKey)

        if result.op == "switch_branch" {
            branchSwitchInFlight.removeValue(forKey: wsCacheKey)
            if result.ok {
                fetchGitBranches(workspaceKey: result.workspace)
                fetchGitStatus(workspaceKey: result.workspace)
                onCloseAllDiffTabs?(wsCacheKey)
            }
            return
        }

        if result.op == "create_branch" {
            branchCreateInFlight.removeValue(forKey: wsCacheKey)
            if result.ok {
                fetchGitBranches(workspaceKey: result.workspace)
                fetchGitStatus(workspaceKey: result.workspace)
                onCloseAllDiffTabs?(wsCacheKey)
            }
            return
        }

        if result.ok {
            fetchGitStatus(workspaceKey: result.workspace)

            if let path = result.path,
               selectedProjectName == result.project,
               selectedWorkspaceKey == result.workspace,
               getActiveDiffPath?() == path {
                if result.op == "discard" {
                    onCloseDiffTab?(wsCacheKey, path)
                } else {
                    onRefreshActiveDiff?()
                }
            }
        }
    }

    func gitStage(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        let opKey = GitOpInFlight(op: "stage", path: path, scope: scope)
        if gitOpsInFlight[wsCacheKey] == nil {
            gitOpsInFlight[wsCacheKey] = []
        }
        gitOpsInFlight[wsCacheKey]?.insert(opKey)
        wsClient?.requestGitStage(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope
        )
    }

    func gitUnstage(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        let opKey = GitOpInFlight(op: "unstage", path: path, scope: scope)
        if gitOpsInFlight[wsCacheKey] == nil {
            gitOpsInFlight[wsCacheKey] = []
        }
        gitOpsInFlight[wsCacheKey]?.insert(opKey)
        wsClient?.requestGitUnstage(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope
        )
    }

    func gitDiscard(workspaceKey: String, path: String?, scope: String, includeUntracked: Bool = false) {
        guard connectionState == .connected else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        let opKey = GitOpInFlight(op: "discard", path: path, scope: scope)
        if gitOpsInFlight[wsCacheKey] == nil {
            gitOpsInFlight[wsCacheKey] = []
        }
        gitOpsInFlight[wsCacheKey]?.insert(opKey)
        wsClient?.requestGitDiscard(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path,
            scope: scope,
            includeUntracked: includeUntracked
        )
    }

    func isGitOpInFlight(workspaceKey: String, path: String?, op: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        guard let ops = gitOpsInFlight[wsCacheKey] else { return false }
        return ops.contains { $0.op == op && $0.path == path }
    }

    func hasAnyGitOpInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        guard let ops = gitOpsInFlight[wsCacheKey] else { return false }
        return !ops.isEmpty
    }

    // MARK: - Phase C3-3a: Git Branch API

    func handleGitBranchesResult(_ result: GitBranchesResult) {
        let wsCacheKey = workspaceCacheKey(workspace: result.workspace, project: result.project)
        let cache = GitBranchCache(
            current: result.current,
            branches: result.branches,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        gitBranchCache[wsCacheKey] = cache
    }

    func fetchGitBranches(workspaceKey: String, cacheMode: HTTPQueryCacheMode = .default) {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        guard connectionState == .connected else {
            var cache = gitBranchCache[wsCacheKey] ?? GitBranchCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            gitBranchCache[wsCacheKey] = cache
            return
        }
        // 已经在加载中时跳过冗余的 @Published 写入
        let existing = gitBranchCache[wsCacheKey]
        if existing?.isLoading == true {
            wsClient?.requestGitBranches(project: selectedProjectName, workspace: workspaceKey, cacheMode: cacheMode)
            return
        }
        var cache = existing ?? GitBranchCache.empty()
        cache.isLoading = true
        cache.error = nil
        gitBranchCache[wsCacheKey] = cache
        wsClient?.requestGitBranches(project: selectedProjectName, workspace: workspaceKey, cacheMode: cacheMode)
    }

    func refreshGitBranches() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitBranches(workspaceKey: ws, cacheMode: .forceRefresh)
    }

    func getGitBranchCache(workspaceKey: String) -> GitBranchCache? {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return gitBranchCache[wsCacheKey]
    }

    func gitSwitchBranch(workspaceKey: String, branch: String) {
        guard connectionState == .connected else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        branchSwitchInFlight[wsCacheKey] = branch
        wsClient?.requestGitSwitchBranch(
            project: selectedProjectName,
            workspace: workspaceKey,
            branch: branch
        )
    }

    func gitCreateBranch(workspaceKey: String, branch: String) {
        guard connectionState == .connected else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        branchCreateInFlight[wsCacheKey] = branch
        wsClient?.requestGitCreateBranch(
            project: selectedProjectName,
            workspace: workspaceKey,
            branch: branch
        )
    }

    func isBranchCreateInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return branchCreateInFlight[wsCacheKey] != nil
    }

    func isBranchSwitchInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return branchSwitchInFlight[wsCacheKey] != nil
    }

    // MARK: - Phase C3-4a: Git Commit API

    func handleGitCommitResult(_ result: GitCommitResult) {
        let wsCacheKey = workspaceCacheKey(workspace: result.workspace, project: result.project)
        commitInFlight.removeValue(forKey: wsCacheKey)
        if result.ok {
            commitMessage.removeValue(forKey: wsCacheKey)
            fetchGitStatus(workspaceKey: result.workspace)
        }
    }

    func gitCommit(workspaceKey: String, message: String) {
        guard connectionState == .connected else { return }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        commitInFlight[wsCacheKey] = true
        wsClient?.requestGitCommit(
            project: selectedProjectName,
            workspace: workspaceKey,
            message: trimmedMessage
        )
    }

    func isCommitInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return commitInFlight[wsCacheKey] == true
    }

    func hasStagedChanges(workspaceKey: String) -> Bool {
        return getGitSemanticSnapshot(workspaceKey: workspaceKey).hasStagedChanges
    }

    func stagedCount(workspaceKey: String) -> Int {
        return getGitSemanticSnapshot(workspaceKey: workspaceKey).stagedItems.count
    }

    // MARK: - Phase UX-3a: Git Rebase API

    func handleGitRebaseResult(_ result: GitRebaseResult) {
        let wsCacheKey = workspaceCacheKey(workspace: result.workspace, project: result.project)
        rebaseInFlight.removeValue(forKey: wsCacheKey)
        var cache = gitOpStatusCache[wsCacheKey] ?? GitOpStatusCache.empty()
        cache.isLoading = false
        cache.updatedAt = Date()
        if result.state == "conflict" {
            cache.state = .rebasing
            cache.conflicts = result.conflicts
            cache.conflictFiles = result.conflictFiles
            // 同步更新冲突向导缓存快照
            let wizardKey = conflictWizardKey(project: result.project, workspace: result.workspace, context: "workspace")
            var wizard = conflictWizardCache[wizardKey] ?? ConflictWizardCache.empty()
            wizard.snapshot = ConflictSnapshot(
                context: "workspace",
                files: result.conflictFiles,
                allResolved: result.conflictFiles.isEmpty
            )
            wizard.updatedAt = Date()
            conflictWizardCache[wizardKey] = wizard
        } else if result.state == "completed" || result.state == "aborted" {
            cache.state = .normal
            cache.conflicts = []
            cache.conflictFiles = []
        }
        gitOpStatusCache[wsCacheKey] = cache
        fetchGitStatus(workspaceKey: result.workspace)
    }

    func handleGitOpStatusResult(_ result: GitOpStatusResult) {
        let wsCacheKey = workspaceCacheKey(workspace: result.workspace, project: result.project)
        var cache = gitOpStatusCache[wsCacheKey] ?? GitOpStatusCache.empty()
        cache.state = result.state
        cache.conflicts = result.conflicts
        cache.conflictFiles = result.conflictFiles
        cache.isLoading = false
        cache.updatedAt = Date()
        gitOpStatusCache[wsCacheKey] = cache
        // 同步更新冲突向导缓存快照
        if result.state != .normal && !result.conflictFiles.isEmpty {
            let wizardKey = conflictWizardKey(project: result.project, workspace: result.workspace, context: "workspace")
            var wizard = conflictWizardCache[wizardKey] ?? ConflictWizardCache.empty()
            wizard.snapshot = ConflictSnapshot(
                context: "workspace",
                files: result.conflictFiles,
                allResolved: result.conflictFiles.isEmpty
            )
            wizard.updatedAt = Date()
            conflictWizardCache[wizardKey] = wizard
        }
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
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        rebaseInFlight[wsCacheKey] = true
        var cache = gitOpStatusCache[wsCacheKey] ?? GitOpStatusCache.empty()
        cache.isLoading = true
        gitOpStatusCache[wsCacheKey] = cache
        wsClient?.requestGitRebase(
            project: selectedProjectName,
            workspace: workspaceKey,
            ontoBranch: ontoBranch
        )
    }

    func gitRebaseContinue(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        rebaseInFlight[wsCacheKey] = true
        wsClient?.requestGitRebaseContinue(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func gitRebaseAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        rebaseInFlight[wsCacheKey] = true
        wsClient?.requestGitRebaseAbort(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func fetchGitOpStatus(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        var cache = gitOpStatusCache[wsCacheKey] ?? GitOpStatusCache.empty()
        cache.isLoading = true
        gitOpStatusCache[wsCacheKey] = cache
        wsClient?.requestGitOpStatus(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func getGitOpStatusCache(workspaceKey: String) -> GitOpStatusCache? {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return gitOpStatusCache[wsCacheKey]
    }

    func isRebaseInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return rebaseInFlight[wsCacheKey] == true
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
            cache.conflictFiles = result.conflictFiles
            // 同步更新冲突向导缓存快照（集成工作树上下文）
            let wizardKey = conflictWizardKey(project: result.project, workspace: "", context: "integration")
            var wizard = conflictWizardCache[wizardKey] ?? ConflictWizardCache.empty()
            wizard.snapshot = ConflictSnapshot(
                context: "integration",
                files: result.conflictFiles,
                allResolved: result.conflictFiles.isEmpty
            )
            wizard.updatedAt = Date()
            conflictWizardCache[wizardKey] = wizard
        } else if result.state == .completed || result.state == .idle {
            cache.state = .idle
            cache.conflicts = []
            cache.conflictFiles = []
        }
        gitIntegrationStatusCache[result.project] = cache
        if selectedProjectName == result.project,
           let workspace = selectedWorkspaceKey {
            fetchGitStatus(workspaceKey: workspace)
        }
    }

    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult) {
        var cache = gitIntegrationStatusCache[result.project] ?? GitIntegrationStatusCache.empty()
        cache.state = result.state
        cache.conflicts = result.conflicts
        cache.conflictFiles = result.conflictFiles
        cache.isLoading = false
        cache.updatedAt = Date()
        cache.branchAheadBy = result.branchAheadBy
        cache.branchBehindBy = result.branchBehindBy
        cache.comparedBranch = result.comparedBranch
        gitIntegrationStatusCache[result.project] = cache
        // 同步更新冲突向导缓存快照
        if result.state == .conflict && !result.conflictFiles.isEmpty {
            let wizardKey = conflictWizardKey(project: result.project, workspace: "", context: "integration")
            var wizard = conflictWizardCache[wizardKey] ?? ConflictWizardCache.empty()
            wizard.snapshot = ConflictSnapshot(
                context: "integration",
                files: result.conflictFiles,
                allResolved: result.conflictFiles.isEmpty
            )
            wizard.updatedAt = Date()
            conflictWizardCache[wizardKey] = wizard
        }
    }

    func gitMergeToDefault(workspaceKey: String, defaultBranch: String = "main") {
        guard connectionState == .connected else { return }
        let projectKey = selectedProjectName
        mergeInFlight[projectKey] = true
        var cache = gitIntegrationStatusCache[projectKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[projectKey] = cache
        wsClient?.requestGitMergeToDefault(
            project: selectedProjectName,
            workspace: workspaceKey,
            defaultBranch: defaultBranch
        )
    }

    func gitMergeContinue(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let projectKey = selectedProjectName
        mergeInFlight[projectKey] = true
        wsClient?.requestGitMergeContinue(
            project: selectedProjectName
        )
    }

    func gitMergeAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let projectKey = selectedProjectName
        mergeInFlight[projectKey] = true
        wsClient?.requestGitMergeAbort(
            project: selectedProjectName
        )
    }

    func fetchGitIntegrationStatus(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let projectKey = selectedProjectName
        var cache = gitIntegrationStatusCache[projectKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[projectKey] = cache
        wsClient?.requestGitIntegrationStatus(
            project: selectedProjectName
        )
    }

    func getGitIntegrationStatusCache(workspaceKey: String) -> GitIntegrationStatusCache? {
        let projectKey = selectedProjectName
        return gitIntegrationStatusCache[projectKey]
    }

    func isMergeInFlight(workspaceKey: String) -> Bool {
        let projectKey = selectedProjectName
        return mergeInFlight[projectKey] == true
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
        if selectedProjectName == result.project,
           let workspace = selectedWorkspaceKey {
            fetchGitStatus(workspaceKey: workspace)
        }
    }

    func gitRebaseOntoDefault(workspaceKey: String, defaultBranch: String = "main") {
        guard connectionState == .connected else { return }
        let projectKey = selectedProjectName
        rebaseOntoDefaultInFlight[projectKey] = true
        var cache = gitIntegrationStatusCache[projectKey] ?? GitIntegrationStatusCache.empty()
        cache.isLoading = true
        gitIntegrationStatusCache[projectKey] = cache
        wsClient?.requestGitRebaseOntoDefault(
            project: selectedProjectName,
            workspace: workspaceKey,
            defaultBranch: defaultBranch
        )
    }

    func gitRebaseOntoDefaultContinue(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let projectKey = selectedProjectName
        rebaseOntoDefaultInFlight[projectKey] = true
        wsClient?.requestGitRebaseOntoDefaultContinue(
            project: selectedProjectName
        )
    }

    func gitRebaseOntoDefaultAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }
        let projectKey = selectedProjectName
        rebaseOntoDefaultInFlight[projectKey] = true
        wsClient?.requestGitRebaseOntoDefaultAbort(
            project: selectedProjectName
        )
    }

    func isRebaseOntoDefaultInFlight(workspaceKey: String) -> Bool {
        let projectKey = selectedProjectName
        return rebaseOntoDefaultInFlight[projectKey] == true
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

    // MARK: - v1.40: 冲突向导 API

    /// 构造冲突向导缓存键
    /// - context: "workspace" 或 "integration"
    /// - workspace 为空字符串表示 integration 上下文
    func conflictWizardKey(project: String, workspace: String, context: String) -> String {
        if context == "integration" {
            return "\(project):integration"
        }
        return "\(project):\(workspace)"
    }

    /// 接收冲突文件四路对比详情
    func handleGitConflictDetailResult(_ result: GitConflictDetailResult) {
        let key = conflictWizardKey(project: result.project, workspace: result.workspace, context: result.context)
        var wizard = conflictWizardCache[key] ?? ConflictWizardCache.empty()
        wizard.currentDetail = GitConflictDetailResultCache(from: result)
        wizard.selectedFilePath = result.path
        wizard.isLoading = false
        wizard.updatedAt = Date()
        conflictWizardCache[key] = wizard
    }

    /// 接收冲突解决动作结果，更新快照
    func handleGitConflictActionResult(_ result: GitConflictActionResult) {
        let key = conflictWizardKey(project: result.project, workspace: result.workspace, context: result.context)
        var wizard = conflictWizardCache[key] ?? ConflictWizardCache.empty()
        wizard.snapshot = result.snapshot
        wizard.isLoading = false
        wizard.updatedAt = Date()
        // 如果当前选中文件已解决，清空详情
        if result.ok, result.path == wizard.selectedFilePath {
            wizard.currentDetail = nil
        }
        conflictWizardCache[key] = wizard
    }

    /// 主动请求单文件冲突详情
    func fetchConflictDetail(project: String, workspace: String, path: String, context: String) {
        guard connectionState == .connected else { return }
        let key = conflictWizardKey(project: project, workspace: workspace, context: context)
        var wizard = conflictWizardCache[key] ?? ConflictWizardCache.empty()
        wizard.isLoading = true
        conflictWizardCache[key] = wizard
        wsClient?.requestGitConflictDetail(project: project, workspace: workspace, path: path, context: context)
    }

    /// 接受我方版本（ours）解决冲突
    func conflictAcceptOurs(project: String, workspace: String, path: String, context: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitConflictAcceptOurs(project: project, workspace: workspace, path: path, context: context)
    }

    /// 接受对方版本（theirs）解决冲突
    func conflictAcceptTheirs(project: String, workspace: String, path: String, context: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitConflictAcceptTheirs(project: project, workspace: workspace, path: path, context: context)
    }

    /// 保留双方内容（both）解决冲突
    func conflictAcceptBoth(project: String, workspace: String, path: String, context: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitConflictAcceptBoth(project: project, workspace: workspace, path: path, context: context)
    }

    /// 手动标记文件已解决
    func conflictMarkResolved(project: String, workspace: String, path: String, context: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitConflictMarkResolved(project: project, workspace: workspace, path: path, context: context)
    }

    /// 查询冲突向导缓存（快照 + 选中文件 + 详情）
    func getConflictWizardCache(project: String, workspace: String, context: String) -> ConflictWizardCache {
        let key = conflictWizardKey(project: project, workspace: workspace, context: context)
        return conflictWizardCache[key] ?? ConflictWizardCache.empty()
    }
}
