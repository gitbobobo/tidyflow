import Foundation

// MARK: - 跨平台侧边栏投影模型
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// macOS 与 iOS 双端使用同一套投影结果模型，避免双端各自定义同义结构导致语义漂移。
//
// 输入：共享协议模型（ProjectInfo / WorkspaceInfo）+ WorkspaceViewStateMachine 快照
// 输出：稳定的共享投影视图模型（SidebarProjectProjection / SidebarWorkspaceProjection）

// MARK: - 活动指示器投影

/// 侧边栏工作区行的活动指示器（AI、进化循环、任务等）。
public struct SidebarActivityIndicatorProjection: Identifiable, Equatable, Sendable {
    /// 指示器标识，例如 "chat" / "evolution" / "task"
    public let id: String
    /// SF Symbol 名称，用于在侧边栏渲染状态图标
    public let iconName: String

    public init(id: String, iconName: String) {
        self.id = id
        self.iconName = iconName
    }
}

// MARK: - 工作区行投影

/// 侧边栏工作区行的完整投影：包含项目范围信息，禁止省略。
/// 双端消费同一结构，不允许任一端从隐式上下文派生 project/workspace。
public struct SidebarWorkspaceProjection: Identifiable, Equatable, Sendable {
    /// 唯一标识，等于 globalWorkspaceKey
    public let id: String
    /// 所属项目名（保留用于多项目场景，不可省略）
    public let projectName: String
    /// 所属项目路径
    public let projectPath: String?
    /// 工作区名称
    public let workspaceName: String
    /// 工作区根目录路径
    public let workspacePath: String?
    /// 当前 Git 分支（可能为 nil）
    public let branch: String?
    /// 状态文本（如 dirty/clean，来自 Core）
    public let statusText: String?
    /// 是否为项目的默认工作区
    public let isDefault: Bool
    /// 是否为当前选中状态
    public let isSelected: Bool
    /// 全局工作区键，格式为 "project:workspace"
    public let globalWorkspaceKey: String
    /// 快捷键展示文本（如 "⌘1"）
    public let shortcutDisplayText: String?
    /// 此工作区打开的终端数量
    public let terminalCount: Int
    /// 此工作区是否有已打开的标签页
    public let hasOpenTabs: Bool
    /// 是否正在删除中
    public let isDeleting: Bool
    /// 是否有未查看的任务完成通知
    public let hasUnseenCompletion: Bool
    /// 活动指示器列表
    public let activityIndicators: [SidebarActivityIndicatorProjection]

    public init(
        id: String,
        projectName: String,
        projectPath: String?,
        workspaceName: String,
        workspacePath: String?,
        branch: String?,
        statusText: String?,
        isDefault: Bool,
        isSelected: Bool,
        globalWorkspaceKey: String,
        shortcutDisplayText: String?,
        terminalCount: Int,
        hasOpenTabs: Bool,
        isDeleting: Bool,
        hasUnseenCompletion: Bool,
        activityIndicators: [SidebarActivityIndicatorProjection]
    ) {
        self.id = id
        self.projectName = projectName
        self.projectPath = projectPath
        self.workspaceName = workspaceName
        self.workspacePath = workspacePath
        self.branch = branch
        self.statusText = statusText
        self.isDefault = isDefault
        self.isSelected = isSelected
        self.globalWorkspaceKey = globalWorkspaceKey
        self.shortcutDisplayText = shortcutDisplayText
        self.terminalCount = terminalCount
        self.hasOpenTabs = hasOpenTabs
        self.isDeleting = isDeleting
        self.hasUnseenCompletion = hasUnseenCompletion
        self.activityIndicators = activityIndicators
    }
}

// MARK: - 项目行投影

/// 侧边栏项目行的完整投影：包含可见工作区子列表。
/// 双端使用同一结构，保留 project/workspace 范围信息，不依赖隐式当前项目假设。
public struct SidebarProjectProjection: Identifiable, Equatable, Sendable {
    /// 唯一标识（如 "mac-project-UUID" 或 "ios-project-name"）
    public let id: String
    /// 项目 UUID（macOS 有此字段；iOS 通过确定性算法生成时也可携带）
    public let projectID: UUID?
    /// 项目名称
    public let projectName: String
    /// 项目根路径
    public let projectPath: String?
    /// 主工作区名称（通常为 default 工作区）
    public let primaryWorkspaceName: String?
    /// 默认工作区名称
    public let defaultWorkspaceName: String?
    /// 默认工作区路径
    public let defaultWorkspacePath: String?
    /// 默认工作区的全局键
    public let defaultGlobalWorkspaceKey: String?
    /// 当前选中的是否是此项目的默认工作区
    public let isSelectedDefaultWorkspace: Bool
    /// 快捷键展示文本（如 "⌘1"）
    public let shortcutDisplayText: String?
    /// 主工作区终端数量
    public let terminalCount: Int
    /// 主工作区是否有已打开的标签页
    public let hasOpenTabs: Bool
    /// 是否正在删除中
    public let isDeleting: Bool
    /// 是否有未查看的任务完成通知
    public let hasUnseenCompletion: Bool
    /// 活动指示器列表
    public let activityIndicators: [SidebarActivityIndicatorProjection]
    /// 侧边栏中可见的工作区子列表（隐藏 default，只展示分支工作区）
    public let visibleWorkspaces: [SidebarWorkspaceProjection]
    /// 工作区列表是否正在加载（用于展示加载占位符）
    public let isLoadingWorkspaces: Bool

    public init(
        id: String,
        projectID: UUID?,
        projectName: String,
        projectPath: String?,
        primaryWorkspaceName: String?,
        defaultWorkspaceName: String?,
        defaultWorkspacePath: String?,
        defaultGlobalWorkspaceKey: String?,
        isSelectedDefaultWorkspace: Bool,
        shortcutDisplayText: String?,
        terminalCount: Int,
        hasOpenTabs: Bool,
        isDeleting: Bool,
        hasUnseenCompletion: Bool,
        activityIndicators: [SidebarActivityIndicatorProjection],
        visibleWorkspaces: [SidebarWorkspaceProjection],
        isLoadingWorkspaces: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.projectPath = projectPath
        self.primaryWorkspaceName = primaryWorkspaceName
        self.defaultWorkspaceName = defaultWorkspaceName
        self.defaultWorkspacePath = defaultWorkspacePath
        self.defaultGlobalWorkspaceKey = defaultGlobalWorkspaceKey
        self.isSelectedDefaultWorkspace = isSelectedDefaultWorkspace
        self.shortcutDisplayText = shortcutDisplayText
        self.terminalCount = terminalCount
        self.hasOpenTabs = hasOpenTabs
        self.isDeleting = isDeleting
        self.hasUnseenCompletion = hasUnseenCompletion
        self.activityIndicators = activityIndicators
        self.visibleWorkspaces = visibleWorkspaces
        self.isLoadingWorkspaces = isLoadingWorkspaces
    }
}

// MARK: - 侧边栏投影共享语义层

/// 侧边栏投影的共享纯转换层：活动指示器组装与快捷键展示文本。
/// 平台层只调用此枚举提供的静态方法，不自行拼装同类规则。
public enum SidebarProjectionSemantics {

    /// 组装活动指示器列表，规则双端共享：
    /// - AI 聊天活跃时展示气泡图标
    /// - 进化循环运行时展示大脑图标
    /// - 有后台任务时展示任务图标
    public static func activityIndicators(
        chatIconName: String?,
        hasActiveEvolutionLoop: Bool,
        taskIconName: String?
    ) -> [SidebarActivityIndicatorProjection] {
        var items: [SidebarActivityIndicatorProjection] = []
        if let chatIconName {
            items.append(SidebarActivityIndicatorProjection(id: "chat", iconName: chatIconName))
        }
        if hasActiveEvolutionLoop {
            items.append(SidebarActivityIndicatorProjection(id: "evolution", iconName: "brain.head.profile"))
        }
        if let taskIconName {
            items.append(SidebarActivityIndicatorProjection(id: "task", iconName: taskIconName))
        }
        return items
    }

    /// 将快捷键编号转换为展示文本（如 "1" → "⌘1"）。
    public static func shortcutDisplayText(_ shortcutKey: String?) -> String? {
        guard let shortcutKey else { return nil }
        return "⌘\(shortcutKey)"
    }
}
