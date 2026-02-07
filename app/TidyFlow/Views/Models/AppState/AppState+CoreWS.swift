import Foundation

extension AppState {
    // MARK: - GitCacheState 接线

    func setupGitCache() {
        gitCache.wsClient = wsClient
        gitCache.getProjectName = { [weak self] in
            self?.selectedProjectName ?? "default"
        }
        gitCache.getConnectionState = { [weak self] in
            self?.connectionState ?? .disconnected
        }
        gitCache.getSelectedWorkspaceKey = { [weak self] in
            self?.selectedWorkspaceKey
        }
        gitCache.onCloseAllDiffTabs = { [weak self] workspaceKey in
            self?.closeAllDiffTabs(workspaceKey: workspaceKey)
        }
        gitCache.onCloseDiffTab = { [weak self] workspaceKey, path in
            self?.closeDiffTab(workspaceKey: workspaceKey, path: path)
        }
        gitCache.onRefreshActiveDiff = { [weak self] in
            self?.gitCache.refreshActiveDiff()
        }
        gitCache.getActiveDiffPath = { [weak self] in
            self?.activeDiffPath
        }
        gitCache.getActiveDiffMode = { [weak self] in
            self?.activeDiffMode ?? .working
        }
    }

    // MARK: - Core Process Management

    /// Setup callbacks for Core process events
    func setupCoreCallbacks() {
        coreProcessManager.onCoreReady = { [weak self] port in
            self?.setupWSClient(port: port)
            // Notify CenterContentView to update WebBridge with the port
            self?.onCoreReadyWithPort?(port)
        }

        coreProcessManager.onCoreFailed = { [weak self] message in
            TFLog.core.error("Core failed: \(message, privacy: .public)")
            self?.connectionState = .disconnected
        }

        coreProcessManager.onCoreRestarting = { [weak self] attempt, maxAttempts in
            TFLog.core.warning("Core restarting (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public))")
            // Disconnect WebSocket during restart
            self?.wsClient.disconnect()
            self?.connectionState = .disconnected
        }

        coreProcessManager.onCoreRestartLimitReached = { [weak self] message in
            TFLog.core.error("Core restart limit reached: \(message, privacy: .public)")
            self?.connectionState = .disconnected
        }
    }

    /// Start Core process if not already running
    func startCoreIfNeeded() {
        guard !coreProcessManager.isRunning else {
            return
        }
        coreProcessManager.start()
    }

    /// Restart Core process (for Cmd+R recovery)
    /// Resets auto-restart counter for manual recovery
    func restartCore() {
        wsClient.disconnect()
        coreProcessManager.restart(resetCounter: true)
    }

    /// Stop Core process (called on app termination)
    func stopCore() {
        coreProcessManager.stop()
    }

    // MARK: - WebSocket Setup

    private func setupWSClient(port: Int) {
        wsClient.onConnectionStateChanged = { [weak self] connected in
            self?.connectionState = connected ? .connected : .disconnected
            if connected {
                self?.wsClient.requestListProjects()
                self?.wsClient.requestGetClientSettings()
            }
        }

        wsClient.onFileIndexResult = { [weak self] result in
            self?.handleFileIndexResult(result)
        }

        // 处理文件列表结果
        wsClient.onFileListResult = { [weak self] result in
            self?.handleFileListResult(result)
        }

        // Phase C2-2a: Handle git diff results
        wsClient.onGitDiffResult = { [weak self] result in
            self?.gitCache.handleGitDiffResult(result)
        }

        // Phase C3-1: Handle git status results
        wsClient.onGitStatusResult = { [weak self] result in
            self?.gitCache.handleGitStatusResult(result)
        }

        // Handle git log results
        wsClient.onGitLogResult = { [weak self] result in
            self?.gitCache.handleGitLogResult(result)
        }

        // Handle git show results (single commit details)
        wsClient.onGitShowResult = { [weak self] result in
            self?.gitCache.handleGitShowResult(result)
        }

        // Phase C3-2a: Handle git operation results
        wsClient.onGitOpResult = { [weak self] result in
            self?.gitCache.handleGitOpResult(result)
        }

        // Phase C3-3a: Handle git branches results
        wsClient.onGitBranchesResult = { [weak self] result in
            self?.gitCache.handleGitBranchesResult(result)
        }

        // Phase C3-4a: Handle git commit results
        wsClient.onGitCommitResult = { [weak self] result in
            self?.gitCache.handleGitCommitResult(result)
        }

        // Phase UX-3a: Handle git rebase results
        wsClient.onGitRebaseResult = { [weak self] result in
            self?.gitCache.handleGitRebaseResult(result)
        }

        // Phase UX-3a: Handle git op status results
        wsClient.onGitOpStatusResult = { [weak self] result in
            self?.gitCache.handleGitOpStatusResult(result)
        }

        // Phase UX-3b: Handle git merge to default results
        wsClient.onGitMergeToDefaultResult = { [weak self] result in
            self?.gitCache.handleGitMergeToDefaultResult(result)
        }

        // Phase UX-3b: Handle git integration status results
        wsClient.onGitIntegrationStatusResult = { [weak self] result in
            self?.gitCache.handleGitIntegrationStatusResult(result)
        }

        // Phase UX-4: Handle git rebase onto default results
        wsClient.onGitRebaseOntoDefaultResult = { [weak self] result in
            self?.gitCache.handleGitRebaseOntoDefaultResult(result)
        }

        // Phase UX-5: Handle git reset integration worktree results
        wsClient.onGitResetIntegrationWorktreeResult = { [weak self] result in
            self?.gitCache.handleGitResetIntegrationWorktreeResult(result)
        }

        // UX-2: Handle project import results
        wsClient.onProjectImported = { [weak self] result in
            self?.handleProjectImported(result)
        }

        // UX-2: Handle project list results
        wsClient.onProjectsList = { [weak self] result in
            self?.handleProjectsList(result)
        }

        // Handle workspaces list results
        wsClient.onWorkspacesList = { [weak self] result in
            self?.handleWorkspacesList(result)
        }

        // UX-2: Handle workspace created results
        wsClient.onWorkspaceCreated = { [weak self] result in
            self?.handleWorkspaceCreated(result)
        }

        // Handle project removed results
        wsClient.onProjectRemoved = { result in
            if !result.ok {
                TFLog.app.error("移除项目失败: \(result.message ?? "未知错误", privacy: .public)")
            }
        }

        // Handle workspace removed results
        wsClient.onWorkspaceRemoved = { [weak self] result in
            self?.handleWorkspaceRemoved(result)
        }

        // 处理客户端设置结果
        wsClient.onClientSettingsResult = { [weak self] settings in
            self?.clientSettings = settings
            self?.clientSettingsLoaded = true
        }

        wsClient.onClientSettingsSaved = { ok, message in
            if !ok {
                TFLog.app.error("保存设置失败: \(message ?? "未知错误", privacy: .public)")
            }
        }

        // v1.22: 文件监控回调
        wsClient.onWatchSubscribed = { _ in
            // 已订阅文件监控
        }

        wsClient.onWatchUnsubscribed = {
            // 已取消文件监控订阅
        }

        wsClient.onFileChanged = { [weak self] notification in
            // 使相关缓存失效
            self?.invalidateFileCache(project: notification.project, workspace: notification.workspace)
            // 通知编辑器层文件变化
            self?.notifyEditorFileChanged(notification: notification)
        }

        wsClient.onGitStatusChanged = { [weak self] notification in
            // 自动刷新 Git 状态
            self?.gitCache.fetchGitStatus(workspaceKey: notification.workspace)
            // 同时刷新分支信息（可能有新分支创建）
            self?.gitCache.fetchGitBranches(workspaceKey: notification.workspace)
        }

        // v1.23: 文件重命名结果
        wsClient.onFileRenameResult = { [weak self] result in
            self?.handleFileRenameResult(result)
        }

        // v1.23: 文件删除结果
        wsClient.onFileDeleteResult = { [weak self] result in
            self?.handleFileDeleteResult(result)
        }

        // v1.24: 文件复制结果
        wsClient.onFileCopyResult = { [weak self] result in
            self?.handleFileCopyResult(result)
        }

        // v1.25: 文件移动结果
        wsClient.onFileMoveResult = { [weak self] result in
            self?.handleFileMoveResult(result)
        }

        // 文件写入结果（新建文件）
        wsClient.onFileWriteResult = { [weak self] result in
            self?.handleFileWriteResult(result)
        }

        wsClient.onError = { [weak self] errorMsg in
            // Update cache with error if we were loading
            if let ws = self?.selectedWorkspaceKey {
                var cache = self?.fileIndexCache[ws] ?? FileIndexCache.empty()
                if cache.isLoading {
                    cache.isLoading = false
                    cache.error = errorMsg
                    self?.fileIndexCache[ws] = cache
                }
            }
        }

        // Connect to the dynamic port
        wsClient.connect(port: port)
    }

    func handleFileIndexResult(_ result: FileIndexResult) {
        let cache = FileIndexCache(
            items: result.items,
            truncated: result.truncated,
            updatedAt: Date(),
            isLoading: false,
            error: nil
        )
        fileIndexCache[result.workspace] = cache
    }
}
