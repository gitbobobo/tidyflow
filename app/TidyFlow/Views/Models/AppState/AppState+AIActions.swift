import Foundation

extension AppState {
    // MARK: - AI 任务 continuation 管理

    /// 注册 AI 提交 continuation，返回路由 key
    private func registerAICommitContinuation(
        project: String,
        workspace: String,
        continuation: @escaping (AICommitResult) -> Void
    ) -> String {
        let key = "\(project):\(workspace)"
        aiCommitContinuations[key] = continuation
        return key
    }

    /// 注册 AI 合并 continuation，返回路由 key
    private func registerAIMergeContinuation(
        project: String,
        workspace: String,
        continuation: @escaping (AIMergeResult) -> Void
    ) -> String {
        let key = "\(project):\(workspace)"
        aiMergeContinuations[key] = continuation
        return key
    }

    // MARK: - AI 结果回调处理

    func handleAITaskCancelled(_ result: AITaskCancelled) {
        scheduleWorkspaceSidebarStatusRefresh(projectName: result.project)
    }

    /// 处理 Evolution AutoCommit 结果（来自 WebSocket）
    func handleEvoAutoCommitResult(_ result: EvoAutoCommitResult) {
        scheduleWorkspaceSidebarStatusRefresh(projectName: result.project)
        let key = "\(result.project):\(result.workspace)"
        if let continuation = aiCommitContinuations.removeValue(forKey: key) {
            // 本地发起的任务：转换为 AICommitResult 并恢复 continuation
            let commits = result.commits.map {
                AICommitEntry(sha: $0.sha, message: $0.message, files: $0.files)
            }
            let status: TaskResultStatus = result.success ? .success : .failed
            let aiResult = AICommitResult(
                resultStatus: status,
                message: result.message,
                commits: commits,
                rawOutput: ""
            )
            continuation(aiResult)
        } else {
            // 远程任务：非本地发起，创建远程任务条目并直接标记完成
            let wsKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
            let task = BackgroundTask(
                type: .aiCommit,
                context: .aiCommit(AICommitContext(
                    projectName: result.project,
                    workspaceKey: result.workspace,
                    workspacePath: "",
                    projectPath: nil
                )),
                workspaceGlobalKey: wsKey
            )
            let commits = result.commits.map {
                AICommitEntry(sha: $0.sha, message: $0.message, files: $0.files)
            }
            let status: TaskResultStatus = result.success ? .success : .failed
            let aiResult = AICommitResult(
                resultStatus: status,
                message: result.message,
                commits: commits,
                rawOutput: ""
            )
            taskManager.completeRemoteTask(task, result: .aiCommit(aiResult), appState: self)
            TFLog.app.info("远程 AI 提交结果: \(result.project, privacy: .public)/\(result.workspace, privacy: .public)")
        }
    }

    /// 处理 AI 合并结果（来自 WebSocket）
    func handleGitAIMergeResult(_ result: GitAIMergeResult) {
        scheduleWorkspaceSidebarStatusRefresh(projectName: result.project)
        let key = "\(result.project):\(result.workspace)"
        if let continuation = aiMergeContinuations.removeValue(forKey: key) {
            // 本地发起的任务：转换为 AIMergeResult 并恢复 continuation
            let status: TaskResultStatus = result.success ? .success : .failed
            let aiResult = AIMergeResult(
                resultStatus: status,
                message: result.message,
                conflicts: result.conflicts,
                rawOutput: ""
            )
            continuation(aiResult)
        } else {
            // 远程任务：非本地发起，创建远程任务条目并直接标记完成
            let wsKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
            let task = BackgroundTask(
                type: .aiMerge,
                context: .aiMerge(AIMergeContext(
                    projectName: result.project,
                    workspaceName: result.workspace
                )),
                workspaceGlobalKey: wsKey
            )
            let status: TaskResultStatus = result.success ? .success : .failed
            let aiResult = AIMergeResult(
                resultStatus: status,
                message: result.message,
                conflicts: result.conflicts,
                rawOutput: ""
            )
            taskManager.completeRemoteTask(task, result: .aiMerge(aiResult), appState: self)
            TFLog.app.info("远程 AI 合并结果: \(result.project, privacy: .public)/\(result.workspace, privacy: .public)")
        }
    }

    // MARK: - AI Agent 智能提交

    /// 执行 AI 智能提交（通过 WebSocket 委托 Rust Core）
    func executeAICommit(projectName: String, workspaceKey: String, task: BackgroundTask? = nil) async -> AICommitResult {
        return await withCheckedContinuation { continuation in
            let _ = registerAICommitContinuation(
                project: projectName,
                workspace: workspaceKey
            ) { result in
                continuation.resume(returning: result)
            }

            // 触发侧边栏状态刷新，获取 Rust 端最新任务运行态
            scheduleWorkspaceSidebarStatusRefresh(projectName: projectName, debounce: 0.08)
            wsClient.requestEvoAutoCommit(
                project: projectName,
                workspace: workspaceKey
            )
        }
    }

    // MARK: - AI Agent 合并

    /// 执行 AI 合并到默认分支（通过 WebSocket 委托 Rust Core）
    func executeAIMerge(
        projectName: String,
        workspaceName: String,
        task: BackgroundTask? = nil
    ) async -> AIMergeResult {
        // 获取 AI Agent 名称
        let agentName = clientSettings.mergeAIAgent

        // 从共享语义快照读取默认分支，避免将当前分支误当作默认分支传递
        let defaultBranch = gitCache.getGitSemanticSnapshot(workspaceKey: workspaceName).defaultBranch ?? "main"

        return await withCheckedContinuation { continuation in
            let _ = registerAIMergeContinuation(
                project: projectName,
                workspace: workspaceName
            ) { result in
                continuation.resume(returning: result)
            }

            // 触发侧边栏状态刷新，获取 Rust 端最新任务运行态
            scheduleWorkspaceSidebarStatusRefresh(projectName: projectName, debounce: 0.08)
            wsClient.requestGitAIMerge(
                project: projectName,
                workspace: workspaceName,
                aiAgent: agentName,
                defaultBranch: defaultBranch
            )
        }
    }

    // MARK: - AI 会话重命名结果处理

    func handleAISessionRenameResult(_ ev: AISessionRenameResult) {
        guard let tool = AIChatTool(rawValue: ev.aiTool) else { return }
        guard let session = aiSessionsForTool(tool).first(where: { $0.id == ev.sessionId })
            ?? cachedAISession(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: tool,
                sessionId: ev.sessionId
            ) else {
            return
        }
        renameSession(
            AISessionInfo(
                projectName: session.projectName,
                workspaceName: session.workspaceName,
                aiTool: session.aiTool,
                id: session.id,
                title: session.title,
                updatedAt: ev.updatedAt > 0 ? ev.updatedAt : session.updatedAt,
                origin: session.origin
            ),
            newTitle: ev.title
        )
    }

    // MARK: - AI 代码审查结果处理

    func handleAICodeReviewResult(_ ev: AICodeReviewResult) {
        latestAICodeReviewResult = ev
    }

    // MARK: - AI 代码补全结果处理

    func handleAICodeCompletionChunk(_ ev: AICodeCompletionChunk) {
        let existing = codeCompletionChunks[ev.requestId] ?? ""
        codeCompletionChunks[ev.requestId] = existing + ev.delta
    }

    func handleAICodeCompletionDone(_ ev: AICodeCompletionDone) {
        latestCodeCompletionResult = ev
        // 流结束后清理分片缓存
        codeCompletionChunks.removeValue(forKey: ev.requestId)
    }

    // MARK: - AI 聊天舞台生命周期入口（macOS）

    /// 进入 AI 聊天舞台。统一入口，macOS 在打开聊天页面或选中工作区时调用。
    func enterAIChatStage(project: String, workspace: String) {
        let result = aiChatStageLifecycle.apply(.enter(
            project: project, workspace: workspace, aiTool: aiChatTool
        ))
        if case .transitioned = result {
            TFLog.app.info(
                "AI chat stage entered: project=\(project, privacy: .public), workspace=\(workspace, privacy: .public), tool=\(self.aiChatTool.rawValue, privacy: .public)"
            )
        }
    }

    /// AI 聊天舞台就绪（订阅确认已收到、消息加载完成）。
    func markAIChatStageReady() {
        aiChatStageLifecycle.apply(.ready)
    }

    /// 关闭 AI 聊天舞台。统一入口，macOS 在离开聊天页面或切换工作区时调用。
    func closeAIChatStage() {
        let result = aiChatStageLifecycle.apply(.close)
        if case .transitioned = result {
            TFLog.app.info("AI chat stage closed")
        }
    }

    /// AI 聊天舞台加载已有会话。统一入口。
    func loadSessionInStage(sessionId: String, aiTool: AIChatTool) {
        aiChatStageLifecycle.apply(.loadSession(sessionId: sessionId, aiTool: aiTool))
    }

    /// AI 聊天舞台新建空会话。统一入口。
    func newSessionInStage() {
        aiChatStageLifecycle.apply(.newSession)
    }

    /// 判断当前舞台是否接受指定上下文的流式事件。
    func aiChatStageAcceptsEvent(project: String, workspace: String, aiTool: AIChatTool) -> Bool {
        aiChatStageLifecycle.acceptsStreamEvent(project: project, workspace: workspace, aiTool: aiTool)
    }
}
