import Foundation
import SwiftUI

// MARK: - 统一任务类型

/// 工作区后台任务类型（Apple 端跨平台共享语义）
/// macOS 和 iOS 均使用此枚举，不再各自维护独立的任务类型定义。
public enum WorkspaceTaskType: String, CaseIterable, Equatable, Codable {
    case aiCommit
    case aiMerge
    case projectCommand

    /// 默认展示名称（不带项目上下文）
    public var defaultDisplayName: String {
        switch self {
        case .aiCommit: return "task.aiCommit".localized
        case .aiMerge: return "task.aiMerge".localized
        case .projectCommand: return "task.projectCommand".localized
        }
    }


    /// 默认图标名
    public var defaultIconName: String {
        switch self {
        case .aiCommit: return "sparkles"
        case .aiMerge: return "cpu"
        case .projectCommand: return "terminal"
        }
    }

    /// 类型层面默认是否阻塞（项目命令的实际阻塞性由命令配置决定）
    public var isBlockingByDefault: Bool {
        switch self {
        case .aiCommit, .aiMerge: return true
        case .projectCommand: return false
        }
    }
}

// MARK: - 统一任务状态

/// 工作区后台任务状态（Apple 端跨平台共享语义）
/// macOS 和 iOS 均使用此枚举，保证同一底层状态在两端判定结果一致。
public enum WorkspaceTaskStatus: String, Equatable, Codable {
    case pending
    case running
    case completed
    case failed
    case unknown
    case cancelled

    // MARK: - 状态归一化

    /// 是否为活跃状态（pending 或 running）
    public var isActive: Bool {
        self == .pending || self == .running
    }

    /// 是否为终态（不再变化）
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .unknown, .cancelled: return true
        case .pending, .running: return false
        }
    }

    // MARK: - 展示派生

    /// 终态图标名
    public var completedIconName: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .pending: return "clock"
        case .running: return "circle"
        }
    }

    /// 终态图标颜色
    public var completedIconColor: Color {
        switch self {
        case .completed: return .green
        case .failed: return .red
        case .unknown: return .orange
        case .cancelled: return .secondary
        case .pending, .running: return .secondary
        }
    }

    /// 展示用状态文本
    public var statusText: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "运行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .unknown: return "未知"
        case .cancelled: return "已取消"
        }
    }

    /// 分组标题（供任务列表分区使用）
    public var sectionTitle: String {
        switch self {
        case .pending, .running: return "进行中"
        case .completed: return "已完成"
        case .failed, .unknown: return "失败"
        case .cancelled: return "已取消"
        }
    }

    // MARK: - 排序权重（活跃 < 完成，保证活跃任务排在前面）

    /// 排序权重（值越小越靠前）
    public var sortWeight: Int {
        switch self {
        case .running: return 0
        case .pending: return 1
        case .completed: return 2
        case .failed: return 3
        case .unknown: return 4
        case .cancelled: return 5
        }
    }
}

// MARK: - 共享任务视图模型

/// 工作区后台任务的平台无关视图模型。
/// 同时作为 iOS 端的任务数据模型，以及 macOS 端 BackgroundTask 向共享存储同步的快照格式。
public struct WorkspaceTaskItem: Identifiable, Equatable {
    public let id: String
    public let project: String
    public let workspace: String
    /// 工作区全局键，格式："\(project):\(workspace)"
    public let workspaceGlobalKey: String
    public let type: WorkspaceTaskType
    public var title: String
    public var iconName: String
    public var status: WorkspaceTaskStatus
    public var message: String
    public let createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    /// 项目命令 ID（仅 projectCommand 类型有效）
    public var commandId: String?
    /// Rust Core 分配的远程任务 ID
    public var remoteTaskId: String?
    /// 项目命令实时输出最后一行（运行中展示用）
    public var lastOutputLine: String?
    /// 是否可被用户取消
    public var isCancellable: Bool
    /// Core 权威输出的运行耗时（毫秒）；优先使用此值，若为 nil 则回退到本地计算
    public var coreDurationMs: UInt64?
    /// 失败诊断码（Core 权威输出，仅失败时有值）
    public var errorCode: String?
    /// 失败诊断详情（Core 权威输出，仅失败时有值）
    public var errorDetail: String?
    /// 是否可安全重试（Core 权威判定）
    public var retryable: Bool

    public init(
        id: String,
        project: String,
        workspace: String,
        workspaceGlobalKey: String,
        type: WorkspaceTaskType,
        title: String,
        iconName: String,
        status: WorkspaceTaskStatus,
        message: String,
        createdAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        commandId: String? = nil,
        remoteTaskId: String? = nil,
        lastOutputLine: String? = nil,
        isCancellable: Bool = false,
        coreDurationMs: UInt64? = nil,
        errorCode: String? = nil,
        errorDetail: String? = nil,
        retryable: Bool = false
    ) {
        self.id = id
        self.project = project
        self.workspace = workspace
        self.workspaceGlobalKey = workspaceGlobalKey
        self.type = type
        self.title = title
        self.iconName = iconName
        self.status = status
        self.message = message
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.commandId = commandId
        self.remoteTaskId = remoteTaskId
        self.lastOutputLine = lastOutputLine
        self.isCancellable = isCancellable
        self.coreDurationMs = coreDurationMs
        self.errorCode = errorCode
        self.errorDetail = errorDetail
        self.retryable = retryable
    }

    // MARK: - 展示派生

    /// 格式化耗时文本：优先使用 Core 权威耗时，回退到本地计算
    public var durationText: String {
        if let ms = coreDurationMs {
            let seconds = Int(ms / 1000)
            if seconds < 60 { return "\(seconds)s" }
            let minutes = seconds / 60
            let secs = seconds % 60
            return "\(minutes)m \(secs)s"
        }
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

    /// 失败摘要文本（包含诊断码，供面板列表展示）
    public var failureSummary: String? {
        guard status == .failed else { return nil }
        var parts: [String] = []
        if let code = errorCode {
            parts.append("[\(code)]")
        }
        if !message.isEmpty {
            parts.append(message)
        } else if let detail = errorDetail {
            // 截取首行作为摘要
            let firstLine = detail.split(separator: "\n").first.map(String.init) ?? detail
            parts.append(firstLine)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 重试描述符（仅当 retryable=true 时有值，包含重试所需的归属上下文）
    public var retryDescriptor: RetryDescriptor? {
        guard retryable else { return nil }
        return RetryDescriptor(
            project: project,
            workspace: workspace,
            taskType: type,
            commandId: commandId
        )
    }

    /// 状态摘要文本（供 iOS 任务列表行使用）
    public func statusSummaryText(now: Date = Date()) -> String {
        var parts = [status.statusText]
        if !message.isEmpty {
            parts.append(message)
        }
        if let completedAt = completedAt, status.isTerminal {
            parts.append(Self.relativeTimeString(from: completedAt, now: now))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 排序

    /// 排序键：活跃任务排前，同分按创建时间倒序（newer first）
    public var sortKey: (Int, TimeInterval) {
        (status.sortWeight, -createdAt.timeIntervalSinceReferenceDate)
    }

    // MARK: - 工具

    public static func relativeTimeString(from date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86400))天前"
    }
}

// MARK: - 重试描述符

/// 任务重试所需的归属上下文，保留 project/workspace/command 边界。
/// 面板层只对 `retryable=true` 的任务生成此描述符，不能退回单项目假设。
public struct RetryDescriptor: Equatable {
    public let project: String
    public let workspace: String
    public let taskType: WorkspaceTaskType
    public let commandId: String?

    /// 工作区全局键
    public var workspaceGlobalKey: String {
        "\(project):\(workspace)"
    }
}

// MARK: - 运行状态分组快照

/// 按 (project, workspace) 隔离的运行状态分组快照，由共享存储集中派生。
/// macOS 和 iOS 均使用此结构消费分组数据，不在视图层重复分组逻辑。
public struct WorkspaceRunStatusGroup: Equatable {
    /// 工作区全局键
    public let workspaceGlobalKey: String
    public let project: String
    public let workspace: String
    /// 运行中任务（pending + running）
    public let activeTasks: [WorkspaceTaskItem]
    /// 失败任务（最近失败排前）
    public let failedTasks: [WorkspaceTaskItem]
    /// 已完成任务（不含失败，最近完成排前）
    public let completedTasks: [WorkspaceTaskItem]
    /// 可重试的失败任务数
    public var retryableCount: Int {
        failedTasks.filter { $0.retryable }.count
    }
    /// 是否有失败需要关注
    public var hasFailures: Bool {
        !failedTasks.isEmpty
    }
}
