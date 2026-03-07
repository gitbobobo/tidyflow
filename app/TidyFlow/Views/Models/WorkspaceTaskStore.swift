import Foundation
import Combine

/// 以 project/workspace 为隔离键管理工作区后台任务的共享存储（跨平台 Observable）。
///
/// - macOS：`BackgroundTaskManager` 负责任务执行，执行后通过 `upsert` 同步快照至此存储；
///   视图层从此存储读取展示数据，控制操作（stop/remove）仍通过 AppState 路由。
/// - iOS：`MobileAppState` 直接创建和变更 `WorkspaceTaskItem`，以此存储作为唯一任务源。
///
/// 多项目、多工作区下各工作区任务通过 `workspaceGlobalKey`（"\(project):\(workspace)"）隔离，
/// 不同工作区的 task id、命令路由不会互相干扰。
public class WorkspaceTaskStore: ObservableObject {

    // MARK: - 状态

    @Published public private(set) var tasksByKey: [String: [WorkspaceTaskItem]] = [:]
    /// 有"未读完成"的工作区键集合（用于侧边栏铃铛提示），用户切到对应工作区后清除
    @Published public private(set) var unseenCompletionKeys: Set<String> = []

    private let maxCompletedPerWorkspace: Int

    public init(maxCompletedPerWorkspace: Int = 5) {
        self.maxCompletedPerWorkspace = maxCompletedPerWorkspace
    }

    // MARK: - 查询

    public func allTasks(for key: String) -> [WorkspaceTaskItem] {
        tasksByKey[key] ?? []
    }

    /// 活跃任务（pending + running），按排序键升序
    public func activeTasks(for key: String) -> [WorkspaceTaskItem] {
        (tasksByKey[key] ?? [])
            .filter { $0.status.isActive }
            .sorted { a, b in
                if a.status.sortWeight != b.status.sortWeight {
                    return a.status.sortWeight < b.status.sortWeight
                }
                return a.createdAt < b.createdAt
            }
    }

    /// 运行中任务
    public func runningTasks(for key: String) -> [WorkspaceTaskItem] {
        (tasksByKey[key] ?? []).filter { $0.status == .running }
    }

    /// 等待中任务，按创建时间升序（先进先出）
    public func pendingTasks(for key: String) -> [WorkspaceTaskItem] {
        (tasksByKey[key] ?? [])
            .filter { $0.status == .pending }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 已完成任务（completed / failed / unknown / cancelled），按完成时间倒序（newest first）
    public func completedTasks(for key: String) -> [WorkspaceTaskItem] {
        (tasksByKey[key] ?? [])
            .filter { $0.status.isTerminal }
            .sorted { lhs, rhs in
                let lDate = lhs.completedAt ?? lhs.createdAt
                let rDate = rhs.completedAt ?? rhs.createdAt
                return lDate > rDate
            }
    }

    /// 活跃任务总数（pending + running）
    public func activeCount(for key: String) -> Int {
        (tasksByKey[key] ?? []).filter { $0.status.isActive }.count
    }

    /// 侧边栏活动图标：优先展示运行中首个任务的图标，其次等待中
    public func sidebarActiveIconName(for key: String) -> String? {
        let tasks = tasksByKey[key] ?? []
        if let running = tasks.first(where: { $0.status == .running }) {
            return running.iconName
        }
        if let pending = tasks.first(where: { $0.status == .pending }) {
            return pending.iconName
        }
        return nil
    }

    // MARK: - 变更（iOS 直接使用；macOS 通过 BackgroundTaskManager 路由）

    /// 插入或更新任务快照。
    /// - Parameters:
    ///   - item: 任务视图模型
    ///   - currentWorkspaceKey: 当前用户正在查看的工作区键；若终态任务所在工作区不是当前区，则标记未读
    public func upsert(_ item: WorkspaceTaskItem, currentWorkspaceKey: String? = nil) {
        let key = item.workspaceGlobalKey
        var list = tasksByKey[key] ?? []
        if let idx = list.firstIndex(where: { $0.id == item.id }) {
            let wasActive = list[idx].status.isActive
            list[idx] = item
            tasksByKey[key] = list
            // 从活跃变为终态时，可能触发未读标记
            if wasActive && item.status.isTerminal {
                markUnseenIfNeeded(key: key, currentWorkspaceKey: currentWorkspaceKey)
            }
        } else {
            list.append(item)
            tasksByKey[key] = list
        }
    }

    /// 批量更新某工作区的所有任务（供 macOS BackgroundTaskManager 全量同步使用）
    public func replaceAll(for key: String, with items: [WorkspaceTaskItem], currentWorkspaceKey: String? = nil) {
        let oldItems = tasksByKey[key] ?? []
        let hadActive = oldItems.contains { $0.status.isActive }
        tasksByKey[key] = items
        // 若之前有活跃任务，现在全部已终态，标记未读（若不是当前工作区）
        let hasActive = items.contains { $0.status.isActive }
        if hadActive && !hasActive {
            markUnseenIfNeeded(key: key, currentWorkspaceKey: currentWorkspaceKey)
        }
    }

    /// 删除指定任务（用于移除等待中任务）
    public func remove(id: String) {
        for (key, var list) in tasksByKey {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                list.remove(at: idx)
                tasksByKey[key] = list.isEmpty ? nil : list
                return
            }
        }
    }

    /// 直接变更指定任务（iOS 内部使用）
    public func mutate(id: String, _ body: (inout WorkspaceTaskItem) -> Void) {
        for (key, var list) in tasksByKey {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                let wasActive = list[idx].status.isActive
                body(&list[idx])
                let isTerminal = list[idx].status.isTerminal
                tasksByKey[key] = list
                if wasActive && isTerminal {
                    // 不在此处触发 unseenCompletion，由调用方决定
                }
                return
            }
        }
    }
    /// 清除指定工作区的已完成（终态）任务
    public func clearCompleted(for key: String) {
        guard var list = tasksByKey[key] else { return }
        list.removeAll { $0.status.isTerminal }
        tasksByKey[key] = list.isEmpty ? nil : list
    }

    /// 截断超出历史上限的已完成任务（保留最新的 maxCompletedPerWorkspace 条终态任务）
    public func trimCompleted(for key: String) {
        guard var list = tasksByKey[key] else { return }
        let active = list.filter { $0.status.isActive }
        var completed = list.filter { $0.status.isTerminal }
        if completed.count > maxCompletedPerWorkspace {
            completed.sort { lhs, rhs in
                (lhs.completedAt ?? lhs.createdAt) > (rhs.completedAt ?? rhs.createdAt)
            }
            completed = Array(completed.prefix(maxCompletedPerWorkspace))
        }
        list = active + completed
        tasksByKey[key] = list.isEmpty ? nil : list
    }

    // MARK: - 未读完成管理

    /// 用户切换到某工作区后清除其未读标记
    public func markSeen(for key: String) {
        unseenCompletionKeys.remove(key)
    }

    private func markUnseenIfNeeded(key: String, currentWorkspaceKey: String?) {
        if key != currentWorkspaceKey {
            unseenCompletionKeys.insert(key)
        }
    }
}
