import Foundation
import Combine
import SwiftUI

// MARK: - 后台任务类型（复用共享语义，保留 typealias 供已有 macOS 代码无缝使用）

typealias BackgroundTaskType = WorkspaceTaskType

extension WorkspaceTaskType {
    /// macOS 兼容别名：用于旧代码对 displayName 的引用
    var displayName: String { defaultDisplayName }
    /// macOS 兼容别名：用于旧代码对 iconName 的引用
    var iconName: String { defaultIconName }
    /// macOS 兼容别名：用于旧代码对 isBlocking 的引用（项目命令实际阻塞性由命令配置决定）
    var isBlocking: Bool { isBlockingByDefault }
}

// MARK: - 后台任务状态（复用共享语义，保留 typealias 供已有 macOS 代码无缝使用）

typealias BackgroundTaskStatus = WorkspaceTaskStatus

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

// MARK: - 项目诊断模型

/// 诊断严重级（用于顶部圆点和问题列表排序）
enum DiagnosticSeverity: String, Codable, CaseIterable {
    case error
    case warning
    case info
    case none

    /// 严重级排序权重（越大越严重）
    var rank: Int {
        switch self {
        case .error: return 3
        case .warning: return 2
        case .info: return 1
        case .none: return 0
        }
    }

    static func from(token: String) -> DiagnosticSeverity {
        let normalized = token.lowercased()
        if normalized.contains("none")
            || normalized.contains("no_issue")
            || normalized.contains("clean")
            || normalized == "ok" {
            return .none
        }
        if normalized.contains("fatal") || normalized.contains("error") {
            return .error
        }
        if normalized.contains("warn") {
            return .warning
        }
        return .info
    }
}

/// 一条结构化问题
struct ProjectDiagnosticItem: Identifiable, Equatable {
    let id: String
    let severity: DiagnosticSeverity
    let displayPath: String
    /// 编辑器可跳转路径（工作空间相对路径）；nil 代表当前无法跳转
    let editorPath: String?
    let line: Int
    let column: Int?
    let summary: String
    let rawLine: String

    init(
        severity: DiagnosticSeverity,
        displayPath: String,
        editorPath: String?,
        line: Int,
        column: Int?,
        summary: String,
        rawLine: String
    ) {
        self.severity = severity
        self.displayPath = displayPath
        self.editorPath = editorPath
        self.line = line
        self.column = column
        self.summary = summary
        self.rawLine = rawLine
        self.id = "\(severity.rawValue)|\(displayPath)|\(line)|\(column ?? 0)|\(summary)"
    }
}

/// 工作空间级诊断快照（来自最近一次项目命令）
struct WorkspaceDiagnosticsSnapshot {
    let items: [ProjectDiagnosticItem]
    let highestSeverity: DiagnosticSeverity
    let updatedAt: Date
    let sourceCommandId: String?
}

extension WorkspaceDiagnosticsSnapshot {
    static let empty = WorkspaceDiagnosticsSnapshot(
        items: [],
        highestSeverity: .none,
        updatedAt: .distantPast,
        sourceCommandId: nil
    )
}

/// 项目命令一次执行对应的本地跟踪状态（用于 task_id 路由）
final class ProjectCommandExecutionState {
    let localExecutionId: UUID
    let projectName: String
    let workspaceName: String
    let commandId: String
    let workspaceGlobalKey: String
    weak var task: BackgroundTask?
    var remoteTaskId: String?
    var diagnostics: [ProjectDiagnosticItem] = []
    private var diagnosticIds: Set<String> = []
    private(set) var didResume = false
    private let onComplete: (ProjectCommandResult) -> Void

    init(
        localExecutionId: UUID,
        projectName: String,
        workspaceName: String,
        commandId: String,
        workspaceGlobalKey: String,
        task: BackgroundTask,
        onComplete: @escaping (ProjectCommandResult) -> Void
    ) {
        self.localExecutionId = localExecutionId
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.commandId = commandId
        self.workspaceGlobalKey = workspaceGlobalKey
        self.task = task
        self.onComplete = onComplete
    }

    func appendDiagnostic(_ item: ProjectDiagnosticItem) {
        if diagnosticIds.contains(item.id) {
            return
        }
        diagnosticIds.insert(item.id)
        diagnostics.append(item)
    }

    func complete(_ result: ProjectCommandResult) {
        guard !didResume else { return }
        didResume = true
        onComplete(result)
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

    // MARK: - 共享存储快照

    /// 将本地执行任务转换为平台无关的 WorkspaceTaskItem，用于同步至 WorkspaceTaskStore
    func toItem() -> WorkspaceTaskItem {
        let parts = workspaceGlobalKey.split(separator: ":", maxSplits: 1)
        let project = parts.count >= 1 ? String(parts[0]) : ""
        let workspace = parts.count >= 2 ? String(parts[1]) : ""
        return WorkspaceTaskItem(
            id: id.uuidString,
            project: project,
            workspace: workspace,
            workspaceGlobalKey: workspaceGlobalKey,
            type: type,
            title: displayTitle,
            iconName: taskIconName,
            status: status,
            message: result?.message ?? lastOutputLine ?? "",
            createdAt: createdAt,
            startedAt: startedAt,
            completedAt: completedAt,
            commandId: {
                if case .projectCommand(let ctx) = context { return ctx.commandId }
                return nil
            }(),
            remoteTaskId: remoteTaskId,
            lastOutputLine: lastOutputLine,
            isCancellable: status.isActive
        )
    }
}
