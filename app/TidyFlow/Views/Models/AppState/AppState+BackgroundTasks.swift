import Foundation

extension AppState {
    // MARK: - 后台任务便捷方法

    /// 提交后台任务，返回创建的任务（若校验失败返回 nil）
    @discardableResult
    func submitBackgroundTask(
        type: BackgroundTaskType,
        context: BackgroundTaskContext
    ) -> BackgroundTask? {
        // 根据上下文推导 workspaceGlobalKey
        let key: String
        switch context {
        case .aiCommit(let ctx):
            key = "\(ctx.projectName):\(ctx.workspaceKey)"
        case .aiMerge(let ctx):
            // AI 合并虽然从功能分支入口触发，但实际修改落在默认工作空间
            let defaultWorkspaceName = projects
                .first(where: { $0.name == ctx.projectName })?
                .workspaces
                .first(where: { $0.isDefault })?
                .name ?? "default"
            key = "\(ctx.projectName):\(defaultWorkspaceName)"
        case .projectCommand(let ctx):
            key = "\(ctx.projectName):\(ctx.workspaceName)"
        }

        let task = BackgroundTask(type: type, context: context, workspaceGlobalKey: key)

        // 非阻塞项目命令直接执行，不进入等待队列
        if case .projectCommand(let ctx) = context, !ctx.blocking {
            taskManager.executeNonBlockingTask(task, appState: self)
        } else {
            taskManager.enqueue(task)
            taskManager.scheduleNext(for: key, appState: self)
        }
        return task
    }

    /// 移除等待中的后台任务
    func removeBackgroundTask(_ task: BackgroundTask) {
        taskManager.removePendingTask(task.id)
    }

    /// 停止正在运行的后台任务
    func stopBackgroundTask(_ task: BackgroundTask) {
        taskManager.stopRunningTask(task.id, appState: self)
    }

    /// 调整等待队列顺序
    func reorderPendingTasks(for key: String, fromOffsets: IndexSet, toOffset: Int) {
        taskManager.reorderPendingTasks(for: key, fromOffsets: fromOffsets, toOffset: toOffset)
    }

    // MARK: - 统一重试

    /// 重试失败的后台任务。使用 `RetryDescriptor` 中的归属键路由到正确的 project/workspace，
    /// 不依赖当前选中工作区。
    func retryTask(descriptor: RetryDescriptor) {
        switch descriptor.taskType {
        case .aiCommit:
            wsClient.requestEvoAutoCommit(
                project: descriptor.project,
                workspace: descriptor.workspace
            )
        case .aiMerge:
            wsClient.requestGitAIMerge(
                project: descriptor.project,
                workspace: descriptor.workspace
            )
        case .projectCommand:
            guard let commandId = descriptor.commandId else { return }
            wsClient.requestRunProjectCommand(
                project: descriptor.project,
                workspace: descriptor.workspace,
                commandId: commandId
            )
        }
    }

    /// 重试失败的演化循环。使用描述符中的归属键路由，不依赖当前选中工作区。
    func retryEvolutionCycle(project: String, workspace: String) {
        resumeEvolution(project: project, workspace: workspace)
    }

    // MARK: - 统一取消（WorkspaceTaskItem → BackgroundTask 路由）

    /// 通过 WorkspaceTaskItem.id 停止运行中任务
    func stopTask(byItemId itemId: String) {
        guard let uuid = UUID(uuidString: itemId) else { return }
        taskManager.stopRunningTask(uuid, appState: self)
    }
}
