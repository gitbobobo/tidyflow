import Foundation
import Combine

// MARK: - 后台任务类型

enum BackgroundTaskType: String, CaseIterable {
    case aiCommit
    case aiMerge

    var displayName: String {
        switch self {
        case .aiCommit: return "task.aiCommit".localized
        case .aiMerge: return "task.aiMerge".localized
        }
    }

    var iconName: String {
        switch self {
        case .aiCommit: return "sparkles"
        case .aiMerge: return "cpu"
        }
    }

    /// 阻塞任务：同一工作空间同时只能运行一个
    var isBlocking: Bool { true }
}

// MARK: - 后台任务状态

enum BackgroundTaskStatus: String {
    case pending
    case running
    case completed
    case failed
}

// MARK: - 后台任务上下文

/// AI 提交上下文
struct AICommitContext {
    let workspaceKey: String
    let workspacePath: String
    let projectPath: String?
}

/// AI 合并上下文
struct AIMergeContext {
    let projectName: String
    let workspaceName: String
}

enum BackgroundTaskContext {
    case aiCommit(AICommitContext)
    case aiMerge(AIMergeContext)
}

// MARK: - 后台任务结果

enum BackgroundTaskResult {
    case aiCommit(AICommitResult)
    case aiMerge(AIMergeResult)

    var success: Bool {
        switch self {
        case .aiCommit(let r): return r.success
        case .aiMerge(let r): return r.success
        }
    }

    var message: String {
        switch self {
        case .aiCommit(let r): return r.message
        case .aiMerge(let r): return r.message
        }
    }
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
    var startedAt: Date?
    var completedAt: Date?

    init(type: BackgroundTaskType, context: BackgroundTaskContext, workspaceGlobalKey: String) {
        self.type = type
        self.context = context
        self.workspaceGlobalKey = workspaceGlobalKey
        self.createdAt = Date()
    }

    var displayTitle: String {
        type.displayName
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
