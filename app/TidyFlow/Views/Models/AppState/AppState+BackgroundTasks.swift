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
            key = "\(ctx.projectName):\(ctx.workspaceName)"
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
