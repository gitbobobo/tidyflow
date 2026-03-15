import Foundation
import TidyFlowShared

// MARK: - GitCacheState Stage/Unstage / Branch / Commit / Rebase / Merge / Integration API

extension GitCacheState {

    // MARK: - Phase C3-2a: Git Stage/Unstage API

    func handleGitOpResult(_ result: GitOpResult) {
        let wsCacheKey = workspaceCacheKey(workspace: result.workspace, project: result.project)

        // 共享驱动更新状态并执行网络副作用（requestStatus / requestBranches）
        applyGitInput(.gitOpResult(result), project: result.project, workspace: result.workspace)

        // 平台特定副作用：分支操作成功后关闭所有 diff tabs
        if result.op == "switch_branch" || result.op == "create_branch" {
            if result.ok {
                onCloseAllDiffTabs?(wsCacheKey)
            }
            return
        }

        // stage/unstage/discard 成功后的 diff tab 处理
        if result.ok {
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
        applyGitInput(.stage(path: path, scope: scope), project: selectedProjectName, workspace: workspaceKey)
    }

    func gitUnstage(workspaceKey: String, path: String?, scope: String) {
        guard connectionState == .connected else { return }
        applyGitInput(.unstage(path: path, scope: scope), project: selectedProjectName, workspace: workspaceKey)
    }

    func gitDiscard(workspaceKey: String, path: String?, scope: String, includeUntracked: Bool = false) {
        guard connectionState == .connected else { return }
        applyGitInput(.discard(path: path, scope: scope, includeUntracked: includeUntracked), project: selectedProjectName, workspace: workspaceKey)
    }

    func isGitOpInFlight(workspaceKey: String, path: String?, op: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        guard let state = workspaceGitState[wsCacheKey] else { return false }
        return state.opsInFlight.contains { $0.op == op && $0.path == path }
    }

    func hasAnyGitOpInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        guard let state = workspaceGitState[wsCacheKey] else { return false }
        return !state.opsInFlight.isEmpty
    }

    // MARK: - Phase C3-3a: Git Branch API

    func handleGitBranchesResult(_ result: GitBranchesResult) {
        applyGitInput(.gitBranchesResult(result), project: result.project, workspace: result.workspace)
    }

    func fetchGitBranches(workspaceKey: String, cacheMode: HTTPQueryCacheMode = .default) {
        let projectName = selectedProjectName
        guard connectionState == .connected else {
            let key = workspaceCacheKey(workspace: workspaceKey)
            var state = workspaceGitState[key] ?? .empty
            state.branchCache.error = "Disconnected"
            state.branchCache.isLoading = false
            workspaceGitState[key] = state
            return
        }
        applyGitInput(.refreshBranches(cacheMode: cacheMode), project: projectName, workspace: workspaceKey)
    }

    func refreshGitBranches() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchGitBranches(workspaceKey: ws, cacheMode: .forceRefresh)
    }

    func getGitBranchCache(workspaceKey: String) -> GitBranchCache? {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return workspaceGitState[wsCacheKey]?.branchCache
    }

    func gitSwitchBranch(workspaceKey: String, branch: String) {
        guard connectionState == .connected else { return }
        applyGitInput(.switchBranch(name: branch), project: selectedProjectName, workspace: workspaceKey)
    }

    func gitCreateBranch(workspaceKey: String, branch: String) {
        guard connectionState == .connected else { return }
        applyGitInput(.createBranch(name: branch), project: selectedProjectName, workspace: workspaceKey)
    }

    func isBranchCreateInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return workspaceGitState[wsCacheKey]?.isBranchCreateInFlight ?? false
    }

    func isBranchSwitchInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return workspaceGitState[wsCacheKey]?.isBranchSwitchInFlight ?? false
    }

    // MARK: - Phase C3-4a: Git Commit API

    func handleGitCommitResult(_ result: GitCommitResult) {
        applyGitInput(.gitCommitResult(result), project: result.project, workspace: result.workspace)
    }

    func gitCommit(workspaceKey: String, message: String) {
        guard connectionState == .connected else { return }
        applyGitInput(.commit(message: message), project: selectedProjectName, workspace: workspaceKey)
    }

    func isCommitInFlight(workspaceKey: String) -> Bool {
        let wsCacheKey = workspaceCacheKey(workspace: workspaceKey)
        return workspaceGitState[wsCacheKey]?.isCommitInFlight ?? false
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
        // v1.60: workspace sequencer 扩展字段
        cache.operationKind = result.operationKind
        cache.pendingCommits = result.pendingCommits
        cache.currentCommit = result.currentCommit
        cache.rollbackReceipt = result.rollbackReceipt
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

    // MARK: - v1.60: Cherry-pick/Revert/Rollback

    func gitCherryPickContinue(workspaceKey: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitCherryPickContinue(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func gitCherryPickAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitCherryPickAbort(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func gitRevertContinue(workspaceKey: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitRevertContinue(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func gitRevertAbort(workspaceKey: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitRevertAbort(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func gitWorkspaceOpRollback(workspaceKey: String) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitWorkspaceOpRollback(
            project: selectedProjectName,
            workspace: workspaceKey
        )
    }

    func gitCherryPick(workspaceKey: String, commitShas: [String]) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitCherryPick(
            project: selectedProjectName,
            workspace: workspaceKey,
            commitShas: commitShas
        )
    }

    func gitRevert(workspaceKey: String, commitShas: [String]) {
        guard connectionState == .connected else { return }
        wsClient?.requestGitRevert(
            project: selectedProjectName,
            workspace: workspaceKey,
            commitShas: commitShas
        )
    }

    func handleGitSequencerResult(_ result: GitSequencerResult) {
        let wsCacheKey = workspaceCacheKey(workspace: result.workspace, project: result.project)
        // 刷新 status / log / op-status
        fetchGitStatus(workspaceKey: result.workspace)
        fetchGitLog(workspaceKey: result.workspace, cacheMode: .forceRefresh)
        fetchGitOpStatus(workspaceKey: result.workspace)
        // 冲突时同步更新冲突向导缓存
        if result.state == "conflict" && !result.conflictFiles.isEmpty {
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
        // 更新 op-status 缓存中间态
        var cache = gitOpStatusCache[wsCacheKey] ?? GitOpStatusCache.empty()
        cache.operationKind = result.operationKind
        cache.currentCommit = result.currentCommit
        cache.updatedAt = Date()
        gitOpStatusCache[wsCacheKey] = cache
    }

    func handleGitWorkspaceOpRollbackResult(_ result: GitWorkspaceOpRollbackResult) {
        // 刷新 status / log / op-status
        fetchGitStatus(workspaceKey: result.workspace)
        fetchGitLog(workspaceKey: result.workspace, cacheMode: .forceRefresh)
        fetchGitOpStatus(workspaceKey: result.workspace)
    }

    // MARK: - v1.50: Git Stash API

    /// 接收 stash 列表结果
    func handleGitStashListResult(_ result: GitStashListResult) {
        let key = stashCacheKey(project: result.project, workspace: result.workspace)
        stashListCache[key] = GitStashListCache(
            entries: result.entries,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        // 如果没有选中的 stash，自动选中最新条目
        if selectedStashId[key] == nil, let first = result.entries.first {
            selectedStashId[key] = first.stashId
        }
    }

    /// 接收 stash 详情结果
    func handleGitStashShowResult(_ result: GitStashShowResult) {
        let showKey = stashShowCacheKey(project: result.project, workspace: result.workspace, stashId: result.stashId)
        stashShowCache[showKey] = GitStashShowCache(
            stashId: result.stashId,
            entry: result.entry,
            files: result.files,
            diffText: result.diffText,
            isBinarySummaryTruncated: result.isBinarySummaryTruncated,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
    }

    /// 接收 stash 操作结果
    func handleGitStashOpResult(_ result: GitStashOpResult) {
        let key = stashCacheKey(project: result.project, workspace: result.workspace)
        stashOpInFlight[key] = false

        if result.ok {
            stashLastError.removeValue(forKey: key)
        } else {
            stashLastError[key] = result.message ?? "Stash operation failed"
        }

        // 成功后刷新 stash 列表和 git status
        if result.ok || result.state == "conflict" {
            wsClient?.requestGitStashList(project: result.project, workspace: result.workspace, cacheMode: .forceRefresh)
            applyGitInput(.gitStatusChanged, project: result.project, workspace: result.workspace)
        }

        // 如果产生冲突，桥接到现有冲突向导
        if result.state == "conflict" && !result.conflictFiles.isEmpty {
            let wizardKey = conflictWizardKey(project: result.project, workspace: result.workspace, context: "workspace")
            var wizard = conflictWizardCache[wizardKey] ?? ConflictWizardCache.empty()
            wizard.snapshot = ConflictSnapshot(
                context: "workspace",
                files: result.conflictFiles,
                allResolved: false
            )
            wizard.updatedAt = Date()
            conflictWizardCache[wizardKey] = wizard
        }
    }

    /// 请求 stash 列表
    func fetchStashList(project: String, workspace: String, cacheMode: HTTPQueryCacheMode = .default) {
        guard connectionState == .connected else { return }
        let key = stashCacheKey(project: project, workspace: workspace)
        var cache = stashListCache[key] ?? GitStashListCache.empty()
        cache.isLoading = true
        stashListCache[key] = cache
        wsClient?.requestGitStashList(project: project, workspace: workspace, cacheMode: cacheMode)
    }

    /// 请求 stash 详情
    func fetchStashShow(project: String, workspace: String, stashId: String) {
        guard connectionState == .connected else { return }
        let showKey = stashShowCacheKey(project: project, workspace: workspace, stashId: stashId)
        var cache = stashShowCache[showKey] ?? GitStashShowCache.empty(stashId: stashId)
        cache.isLoading = true
        stashShowCache[showKey] = cache
        wsClient?.requestGitStashShow(project: project, workspace: workspace, stashId: stashId)
    }

    /// 保存新 stash
    func stashSave(project: String, workspace: String, message: String?, includeUntracked: Bool = false, keepIndex: Bool = false, paths: [String] = []) {
        guard connectionState == .connected else { return }
        let key = stashCacheKey(project: project, workspace: workspace)
        stashOpInFlight[key] = true
        wsClient?.requestGitStashSave(project: project, workspace: workspace, message: message, includeUntracked: includeUntracked, keepIndex: keepIndex, paths: paths)
    }

    /// Apply stash
    func stashApply(project: String, workspace: String, stashId: String) {
        guard connectionState == .connected else { return }
        let key = stashCacheKey(project: project, workspace: workspace)
        stashOpInFlight[key] = true
        wsClient?.requestGitStashApply(project: project, workspace: workspace, stashId: stashId)
    }

    /// Pop stash
    func stashPop(project: String, workspace: String, stashId: String) {
        guard connectionState == .connected else { return }
        let key = stashCacheKey(project: project, workspace: workspace)
        stashOpInFlight[key] = true
        wsClient?.requestGitStashPop(project: project, workspace: workspace, stashId: stashId)
    }

    /// Drop stash
    func stashDrop(project: String, workspace: String, stashId: String) {
        guard connectionState == .connected else { return }
        let key = stashCacheKey(project: project, workspace: workspace)
        stashOpInFlight[key] = true
        wsClient?.requestGitStashDrop(project: project, workspace: workspace, stashId: stashId)
    }

    /// 按文件恢复 stash
    func stashRestorePaths(project: String, workspace: String, stashId: String, paths: [String]) {
        guard connectionState == .connected else { return }
        let key = stashCacheKey(project: project, workspace: workspace)
        stashOpInFlight[key] = true
        wsClient?.requestGitStashRestorePaths(project: project, workspace: workspace, stashId: stashId, paths: paths)
    }

    /// 查询 stash 列表缓存
    func getStashListCache(project: String, workspace: String) -> GitStashListCache {
        let key = stashCacheKey(project: project, workspace: workspace)
        return stashListCache[key] ?? GitStashListCache.empty()
    }

    /// 查询 stash 详情缓存
    func getStashShowCache(project: String, workspace: String, stashId: String) -> GitStashShowCache {
        let showKey = stashShowCacheKey(project: project, workspace: workspace, stashId: stashId)
        return stashShowCache[showKey] ?? GitStashShowCache.empty(stashId: stashId)
    }
}
