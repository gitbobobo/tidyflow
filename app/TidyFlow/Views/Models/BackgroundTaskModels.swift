import Foundation
import Combine
import SwiftUI

// MARK: - 后台任务类型

enum BackgroundTaskType: String, CaseIterable {
    case aiCommit
    case aiMerge
    case projectCommand

    var displayName: String {
        switch self {
        case .aiCommit: return "task.aiCommit".localized
        case .aiMerge: return "task.aiMerge".localized
        case .projectCommand: return "task.projectCommand".localized
        }
    }

    var iconName: String {
        switch self {
        case .aiCommit: return "sparkles"
        case .aiMerge: return "cpu"
        case .projectCommand: return "terminal"
        }
    }

    /// 阻塞任务：同一工作空间同时只能运行一个
    var isBlocking: Bool {
        switch self {
        case .aiCommit, .aiMerge: return true
        case .projectCommand: return false // 由命令配置决定
        }
    }
}

// MARK: - 后台任务状态

enum BackgroundTaskStatus: String {
    case pending
    case running
    case completed
    case failed
    case unknown
    case cancelled

    /// 已完成任务行的图标名
    var completedIconName: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        default: return "circle"
        }
    }

    /// 已完成任务行的图标颜色
    var completedIconColor: Color {
        switch self {
        case .completed: return .green
        case .failed: return .red
        case .unknown: return .orange
        case .cancelled: return .secondary
        default: return .secondary
        }
    }
}

/// 任务结果状态（三态）
enum TaskResultStatus {
    case success
    case failed
    case unknown

    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .success: return .green
        case .failed: return .red
        case .unknown: return .orange
        }
    }

    /// AI 合并结果弹窗的显示文本
    var mergeDisplayText: String {
        switch self {
        case .success: return "sidebar.aiMerge.success".localized
        case .failed: return "sidebar.aiMerge.failed".localized
        case .unknown: return "sidebar.aiMerge.unknown".localized
        }
    }

    /// AI 提交结果弹窗的显示文本
    var commitDisplayText: String {
        switch self {
        case .success: return "git.aiCommit.success".localized
        case .failed: return "git.aiCommit.failed".localized
        case .unknown: return "git.aiCommit.unknown".localized
        }
    }
}

// MARK: - 后台任务上下文

/// AI 提交上下文
struct AICommitContext {
    let projectName: String
    let workspaceKey: String
    let workspacePath: String
    let projectPath: String?
}

/// AI 合并上下文
struct AIMergeContext {
    let projectName: String
    let workspaceName: String
}

/// 项目命令上下文
struct ProjectCommandContext {
    let projectName: String
    let workspaceName: String
    let commandId: String
    let commandName: String
    let commandIcon: String
    let blocking: Bool
}

enum BackgroundTaskContext {
    case aiCommit(AICommitContext)
    case aiMerge(AIMergeContext)
    case projectCommand(ProjectCommandContext)
}

// MARK: - 后台任务结果

enum BackgroundTaskResult {
    case aiCommit(AICommitResult)
    case aiMerge(AIMergeResult)
    case projectCommand(ProjectCommandResult)

    var resultStatus: TaskResultStatus {
        switch self {
        case .aiCommit(let r): return r.resultStatus
        case .aiMerge(let r): return r.resultStatus
        case .projectCommand(let r): return r.ok ? .success : .failed
        }
    }

    var message: String {
        switch self {
        case .aiCommit(let r): return r.message
        case .aiMerge(let r): return r.message
        case .projectCommand(let r): return r.message
        }
    }

    /// 摘要行：用于状态栏单行展示
    var summaryLine: String {
        switch self {
        case .aiCommit(let r): return r.message
        case .aiMerge(let r): return r.message
        case .projectCommand(let r):
            return r.ok ? "task.command.success".localized : "task.command.failed".localized
        }
    }
}

/// 项目命令执行结果
struct ProjectCommandResult {
    let ok: Bool
    let message: String
}

// MARK: - 后台任务

class BackgroundTask: ObservableObject, Identifiable {
    let id = UUID()
    let type: BackgroundTaskType
    let context: BackgroundTaskContext
    let workspaceGlobalKey: String
    let createdAt: Date

    @Published var status: BackgroundTaskStatus = .pending
    @Published var result: BackgroundTaskResult?
    /// 项目命令实时输出的最后一行（运行中展示用）
    @Published var lastOutputLine: String?
    var startedAt: Date?
    var completedAt: Date?
    /// AI 任务的进程句柄，用于停止任务
    var process: Process?
    /// Rust Core 分配的 task_id（项目命令用于关联实时输出）
    var remoteTaskId: String?

    init(type: BackgroundTaskType, context: BackgroundTaskContext, workspaceGlobalKey: String) {
        self.type = type
        self.context = context
        self.workspaceGlobalKey = workspaceGlobalKey
        self.createdAt = Date()
    }

    var displayTitle: String {
        switch context {
        case .projectCommand(let ctx):
            return ctx.commandName
        default:
            return type.displayName
        }
    }

    /// 任务行展示用图标名：项目命令用命令定义的 icon，其他类型用类型的默认 icon
    var taskIconName: String {
        switch context {
        case .projectCommand(let ctx):
            return ctx.commandIcon
        default:
            return type.iconName
        }
    }

    /// 格式化耗时文本
    var durationText: String {
        guard let start = startedAt else { return "" }
        let end = completedAt ?? Date()
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let secs = seconds % 60
        return "\(minutes)m \(secs)s"
    }
}
