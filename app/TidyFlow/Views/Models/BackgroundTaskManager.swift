import Foundation
import Combine

/// 后台任务管理器，以工作空间为粒度管理任务队列
class BackgroundTaskManager: ObservableObject {
    /// 等待队列（按 workspaceGlobalKey 索引）
    @Published var pendingQueues: [String: [BackgroundTask]] = [:]
    /// 每个工作空间最多一个阻塞任务在运行
    @Published var runningBlockingTask: [String: BackgroundTask] = [:]
    /// 非阻塞任务（可并行运行）
    @Published var runningNonBlockingTasks: [String: [BackgroundTask]] = [:]
    /// 已完成历史（每个工作空间最多 5 条）
    @Published var completedQueues: [String: [BackgroundTask]] = [:]

    private let maxCompletedPerWorkspace = 5

    // MARK: - 入队

    func enqueue(_ task: BackgroundTask) {
        let key = task.workspaceGlobalKey
        if pendingQueues[key] == nil {
            pendingQueues[key] = []
        }
        pendingQueues[key]?.append(task)
    }

    // MARK: - 调度

    /// 非阻塞任务直接执行（不进入等待队列）
    func executeNonBlockingTask(_ task: BackgroundTask, appState: AppState) {
        executeTask(task, appState: appState)
    }

    func scheduleNext(for key: String, appState: AppState) {
        // 若已有阻塞任务在运行，等待
        if runningBlockingTask[key] != nil { return }

        // 取出队列头部任务
        guard var queue = pendingQueues[key], !queue.isEmpty else { return }
        let task = queue.removeFirst()
        pendingQueues[key] = queue

        executeTask(task, appState: appState)
    }

    // MARK: - 执行

    private func executeTask(_ task: BackgroundTask, appState: AppState) {
        let key = task.workspaceGlobalKey
        task.status = .running
        task.startedAt = Date()

        // 项目命令的阻塞性由命令配置决定
        let shouldBlock: Bool
        switch task.context {
        case .projectCommand(let ctx):
            shouldBlock = ctx.blocking
        default:
            shouldBlock = task.type.isBlocking
        }

        if shouldBlock {
            runningBlockingTask[key] = task
        } else {
            if runningNonBlockingTasks[key] == nil {
                runningNonBlockingTasks[key] = []
            }
            runningNonBlockingTasks[key]?.append(task)
        }

        Task {
            let result = await performTask(task, appState: appState)
            await MainActor.run {
                completeTask(task, result: result, appState: appState)
            }
        }
    }

    /// 实际执行任务逻辑
    private func performTask(
        _ task: BackgroundTask,
        appState: AppState
    ) async -> BackgroundTaskResult {
        switch task.context {
        case .aiCommit(let ctx):
            let result = await appState.executeAICommit(
                workspaceKey: ctx.workspaceKey,
                workspacePath: ctx.workspacePath,
                projectPath: ctx.projectPath
            )
            return .aiCommit(result)
        case .aiMerge(let ctx):
            let result = await appState.executeAIMerge(
                projectName: ctx.projectName,
                workspaceName: ctx.workspaceName
            )
            return .aiMerge(result)
        case .projectCommand(let ctx):
            let result = await appState.executeProjectCommand(
                projectName: ctx.projectName,
                workspaceName: ctx.workspaceName,
                commandId: ctx.commandId
            )
            return .projectCommand(result)
        }
    }

    // MARK: - 完成

    private func completeTask(
        _ task: BackgroundTask,
        result: BackgroundTaskResult,
        appState: AppState
    ) {
        let key = task.workspaceGlobalKey
        task.status = {
            switch result.resultStatus {
            case .success: return .completed
            case .failed: return .failed
            case .unknown: return .unknown
            }
        }()
        task.result = result
        task.completedAt = Date()

        // 从 running 移除
        if runningBlockingTask[key]?.id == task.id {
            runningBlockingTask.removeValue(forKey: key)
        }
        runningNonBlockingTasks[key]?.removeAll { $0.id == task.id }

        // 加入 completed 队列
        if completedQueues[key] == nil {
            completedQueues[key] = []
        }
        completedQueues[key]?.insert(task, at: 0)
        // 截断超出上限的历史
        if let count = completedQueues[key]?.count, count > maxCompletedPerWorkspace {
            completedQueues[key] = Array(completedQueues[key]!.prefix(maxCompletedPerWorkspace))
        }

        // 刷新 Git 缓存
        refreshGitCache(for: task, appState: appState)

        // 驱动下一个任务
        scheduleNext(for: key, appState: appState)
    }

    /// 任务完成后刷新 Git 缓存
    private func refreshGitCache(for task: BackgroundTask, appState: AppState) {
        guard let result = task.result, result.resultStatus == .success else { return }
        switch task.context {
        case .aiCommit(let ctx):
            appState.gitCache.fetchGitStatus(workspaceKey: ctx.workspaceKey)
            appState.gitCache.fetchGitLog(workspaceKey: ctx.workspaceKey)
        case .aiMerge:
            appState.gitCache.fetchGitStatus(workspaceKey: "default")
            appState.gitCache.fetchGitLog(workspaceKey: "default")
        case .projectCommand:
            // 项目命令完成后不自动刷新 Git 缓存
            break
        }
    }

    // MARK: - 队列操作

    /// 取消指定工作空间的所有任务（pending + running + completed）
    func cancelAllTasks(for key: String) {
        pendingQueues.removeValue(forKey: key)
        runningBlockingTask.removeValue(forKey: key)
        completedQueues.removeValue(forKey: key)
    }

    /// 从 pending 队列删除任务
    func removePendingTask(_ taskId: UUID) {
        for (key, queue) in pendingQueues {
            if let idx = queue.firstIndex(where: { $0.id == taskId }) {
                pendingQueues[key]?.remove(at: idx)
                return
            }
        }
    }

    /// 调整 pending 队列顺序
    func reorderPendingTasks(for key: String, fromOffsets: IndexSet, toOffset: Int) {
        pendingQueues[key]?.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    // MARK: - 查询

    /// 活跃任务数量（pending + running）
    func activeTaskCount(for key: String) -> Int {
        let pending = pendingQueues[key]?.count ?? 0
        let running = runningBlockingTask[key] != nil ? 1 : 0
        let nonBlocking = runningNonBlockingTasks[key]?.count ?? 0
        return pending + running + nonBlocking
    }

    /// 所有运行中任务
    func allRunningTasks(for key: String) -> [BackgroundTask] {
        var result: [BackgroundTask] = []
        if let task = runningBlockingTask[key] {
            result.append(task)
        }
        if let tasks = runningNonBlockingTasks[key] {
            result.append(contentsOf: tasks)
        }
        return result
    }

    /// 等待中任务
    func pendingTasks(for key: String) -> [BackgroundTask] {
        pendingQueues[key] ?? []
    }

    /// 已完成任务
    func completedTasks(for key: String) -> [BackgroundTask] {
        completedQueues[key] ?? []
    }
}
