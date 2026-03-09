import Foundation

// MARK: - 跨平台工作区概览投影模型
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// macOS 与 iOS 双端消费同一组概览投影结构，
// 不允许平台层各自定义同义模型导致字段与规则漂移。
//
// 依赖：GitPanelSemanticSnapshot（定义于 GitProtocolModels.swift，同属 TidyFlowShared）

// MARK: - 终端 AI 状态投影（平台无关）

/// 终端行中 AI 代理状态的纯数据投影。
/// 替代应用层 `TerminalAIStatus`（含 SwiftUI Color），使 WorkspaceTerminalProjection
/// 可安全放入 TidyFlowShared 而不引入 UI 框架依赖。
/// 平台层根据 `colorToken` 自行映射为对应框架的颜色类型。
public struct WorkspaceTerminalAIStatusProjection: Equatable, Sendable {
    /// 是否需要在 UI 显示状态指示器（空闲时为 false）
    public let isVisible: Bool
    /// SF Symbol 图标名称
    public let iconName: String
    /// 无障碍提示文本
    public let hint: String
    /// 颜色语义标记，供平台层映射（"blue" / "green" / "orange" / "red" / "secondary"）
    public let colorToken: String

    public init(isVisible: Bool, iconName: String, hint: String, colorToken: String) {
        self.isVisible = isVisible
        self.iconName = iconName
        self.hint = hint
        self.colorToken = colorToken
    }

    /// 空闲状态（不展示指示器）
    public static let idle = WorkspaceTerminalAIStatusProjection(
        isVisible: false,
        iconName: "circle.fill",
        hint: "",
        colorToken: "secondary"
    )

    /// 运行中状态（AI 正在执行工具）
    public static func running(toolName: String) -> WorkspaceTerminalAIStatusProjection {
        WorkspaceTerminalAIStatusProjection(
            isVisible: true,
            iconName: "hammer.fill",
            hint: "AI 正在执行: \(toolName)",
            colorToken: "blue"
        )
    }
}

// MARK: - 终端行投影

/// 工作区概览中单条终端行的投影。
/// 包含 project/workspace 范围信息（通过 `id` 即 `termId` 与调用方的工作区范围关联）。
public struct WorkspaceTerminalProjection: Identifiable, Equatable, Sendable {
    /// 终端唯一 ID（termId）
    public let id: String
    /// 终端 ID（与 id 相同，保留此字段用于明确语义）
    public let termId: String
    /// 终端展示名称
    public let title: String
    /// 终端 ID 的前 8 位（用于辅助展示）
    public let shortId: String
    /// SF Symbol 图标名称
    public let iconName: String
    /// 是否已固定
    public let isPinned: Bool
    /// AI 状态投影
    public let aiStatus: WorkspaceTerminalAIStatusProjection
    /// 此终端右侧是否还有其他终端（用于 iOS 横滑时的分隔线）
    public let hasTerminalsToRight: Bool

    public init(
        id: String,
        termId: String,
        title: String,
        shortId: String,
        iconName: String,
        isPinned: Bool,
        aiStatus: WorkspaceTerminalAIStatusProjection,
        hasTerminalsToRight: Bool
    ) {
        self.id = id
        self.termId = termId
        self.title = title
        self.shortId = shortId
        self.iconName = iconName
        self.isPinned = isPinned
        self.aiStatus = aiStatus
        self.hasTerminalsToRight = hasTerminalsToRight
    }
}

// MARK: - 后台任务行投影

/// 工作区概览中单条后台任务行的投影。
public struct WorkspaceRunningTaskProjection: Identifiable, Equatable, Sendable {
    /// 任务唯一 ID
    public let id: String
    /// SF Symbol 图标名称
    public let iconName: String
    /// 任务展示标题
    public let title: String
    /// 任务状态/进度消息
    public let message: String
    /// 是否允许取消
    public let canCancel: Bool

    public init(id: String, iconName: String, title: String, message: String, canCancel: Bool) {
        self.id = id
        self.iconName = iconName
        self.title = title
        self.message = message
        self.canCancel = canCancel
    }
}

// MARK: - 工作区概览投影

/// 工作区概览页的完整投影：Git 状态、终端列表、后台任务、待办数量与快捷命令。
/// 双端消费同一结构，保证相同输入产生一致的概览摘要结果。
public struct WorkspaceOverviewProjection: Equatable, Sendable {
    /// Git 面板语义快照（来自 TidyFlowShared）
    public let gitSnapshot: GitPanelSemanticSnapshot
    /// 是否有活跃的 Git 冲突（需要向用户提示）
    public let hasActiveConflicts: Bool
    /// 活跃终端列表
    public let terminals: [WorkspaceTerminalProjection]
    /// 正在运行的后台任务列表
    public let runningTasks: [WorkspaceRunningTaskProjection]
    /// 已完成任务数量
    public let completedTaskCount: Int
    /// 待办事项数量
    public let pendingTodoCount: Int
    /// 项目级快捷命令列表
    public let projectCommands: [ProjectCommand]

    public init(
        gitSnapshot: GitPanelSemanticSnapshot,
        hasActiveConflicts: Bool,
        terminals: [WorkspaceTerminalProjection],
        runningTasks: [WorkspaceRunningTaskProjection],
        completedTaskCount: Int,
        pendingTodoCount: Int,
        projectCommands: [ProjectCommand]
    ) {
        self.gitSnapshot = gitSnapshot
        self.hasActiveConflicts = hasActiveConflicts
        self.terminals = terminals
        self.runningTasks = runningTasks
        self.completedTaskCount = completedTaskCount
        self.pendingTodoCount = pendingTodoCount
        self.projectCommands = projectCommands
    }

    /// 空投影（用于初始化状态或未选中工作区时的占位）
    public static let empty = WorkspaceOverviewProjection(
        gitSnapshot: GitPanelSemanticSnapshot.empty(),
        hasActiveConflicts: false,
        terminals: [],
        runningTasks: [],
        completedTaskCount: 0,
        pendingTodoCount: 0,
        projectCommands: []
    )
}

// MARK: - 工作区概览投影语义层

/// 工作区概览投影的纯转换层。
/// 调用方通过此枚举的静态方法组装概览投影，禁止在平台层各自复制拼装规则。
public enum WorkspaceOverviewProjectionSemantics {
    /// 从各输入域组装完整的工作区概览投影。
    public static func make(
        gitSnapshot: GitPanelSemanticSnapshot,
        hasActiveConflicts: Bool,
        terminals: [WorkspaceTerminalProjection],
        runningTasks: [WorkspaceRunningTaskProjection],
        completedTaskCount: Int,
        pendingTodoCount: Int,
        projectCommands: [ProjectCommand]
    ) -> WorkspaceOverviewProjection {
        WorkspaceOverviewProjection(
            gitSnapshot: gitSnapshot,
            hasActiveConflicts: hasActiveConflicts,
            terminals: terminals,
            runningTasks: runningTasks,
            completedTaskCount: completedTaskCount,
            pendingTodoCount: pendingTodoCount,
            projectCommands: projectCommands
        )
    }
}
