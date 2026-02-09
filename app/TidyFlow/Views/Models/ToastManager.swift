import Foundation
import Combine
import SwiftUI

// MARK: - Toast 通知模型

struct ToastNotification: Identifiable {
    let id = UUID()
    let taskType: BackgroundTaskType
    let resultStatus: TaskResultStatus
    /// 项目名
    let projectName: String
    /// 工作空间/分支名
    let workspaceName: String
    /// 任务显示标题（如命令名）
    let taskTitle: String
    /// 结果摘要
    let message: String
    let createdAt = Date()

    /// 自动消失时长（秒）
    var autoDismissSeconds: TimeInterval {
        switch resultStatus {
        case .success: return 4
        case .failed, .unknown: return 8
        }
    }

    /// 工作空间标识文本，如 "tidyflow / feature-login"
    var workspaceLabel: String {
        "\(projectName) / \(workspaceName)"
    }
}

// MARK: - Toast 管理器

class ToastManager: ObservableObject {
    /// 当前显示的 toast 列表（右下角从下往上堆叠，最多 3 条）
    @Published var toasts: [ToastNotification] = []

    private let maxVisible = 3
    /// 等待显示的队列（超出 maxVisible 的部分）
    private var pendingQueue: [ToastNotification] = []
    /// 用于自动消失的定时器
    private var dismissTimers: [UUID: DispatchWorkItem] = [:]

    /// 推送一条 toast 通知
    func push(_ toast: ToastNotification) {
        if toasts.count >= maxVisible {
            pendingQueue.append(toast)
        } else {
            show(toast)
        }
    }

    /// 手动关闭一条 toast
    func dismiss(_ id: UUID) {
        cancelTimer(for: id)
        withAnimation(.easeInOut(duration: 0.25)) {
            toasts.removeAll { $0.id == id }
        }
        // 显示等待队列中的下一条
        promotePending()
    }

    /// 关闭所有 toast
    func dismissAll() {
        for toast in toasts {
            cancelTimer(for: toast.id)
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            toasts.removeAll()
        }
        pendingQueue.removeAll()
    }

    // MARK: - 内部方法

    private func show(_ toast: ToastNotification) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toasts.append(toast)
        }
        scheduleAutoDismiss(for: toast)
    }

    private func scheduleAutoDismiss(for toast: ToastNotification) {
        let item = DispatchWorkItem { [weak self] in
            self?.dismiss(toast.id)
        }
        dismissTimers[toast.id] = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + toast.autoDismissSeconds,
            execute: item
        )
    }

    private func cancelTimer(for id: UUID) {
        dismissTimers[id]?.cancel()
        dismissTimers.removeValue(forKey: id)
    }

    private func promotePending() {
        guard !pendingQueue.isEmpty, toasts.count < maxVisible else { return }
        let next = pendingQueue.removeFirst()
        show(next)
    }

    /// 从 BackgroundTask 创建 toast 通知
    static func makeToast(from task: BackgroundTask) -> ToastNotification {
        let (projectName, workspaceName) = extractNames(from: task.context)
        let resultStatus = task.result?.resultStatus ?? .unknown
        let message = task.result?.message ?? ""

        return ToastNotification(
            taskType: task.type,
            resultStatus: resultStatus,
            projectName: projectName,
            workspaceName: workspaceName,
            taskTitle: task.displayTitle,
            message: message
        )
    }

    /// 从任务上下文提取项目名和工作空间名
    private static func extractNames(from context: BackgroundTaskContext) -> (String, String) {
        switch context {
        case .aiCommit(let ctx):
            return (ctx.projectName, ctx.workspaceKey)
        case .aiMerge(let ctx):
            return (ctx.projectName, ctx.workspaceName)
        case .projectCommand(let ctx):
            return (ctx.projectName, ctx.workspaceName)
        }
    }
}
