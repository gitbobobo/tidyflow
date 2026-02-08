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
        }

        let task = BackgroundTask(type: type, context: context, workspaceGlobalKey: key)
        taskManager.enqueue(task)
        taskManager.scheduleNext(for: key, appState: self)
        return task
    }

    /// 移除等待中的后台任务
    func removeBackgroundTask(_ task: BackgroundTask) {
        taskManager.removePendingTask(task.id)
    }

    /// 调整等待队列顺序
    func reorderPendingTasks(for key: String, fromOffsets: IndexSet, toOffset: Int) {
        taskManager.reorderPendingTasks(for: key, fromOffsets: fromOffsets, toOffset: toOffset)
    }
}
