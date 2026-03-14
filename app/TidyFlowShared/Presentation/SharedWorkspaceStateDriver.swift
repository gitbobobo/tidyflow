// SharedWorkspaceStateDriver.swift
// TidyFlowShared
//
// 跨平台工作区状态驱动：定义共享的纯值类型和纯函数入口。
// 共享层只输出描述和迁移结果，不直接发送网络请求，不依赖平台 UI 框架。

import Foundation

// MARK: - SharedWorkspaceContext

/// 跨平台工作区上下文：调用方在构造前完成 workspace 归一化。
/// `globalKey` 规则与 `WorkspaceKeySemantics` 保持一致（`"{project}:{workspace}"`）。
public struct SharedWorkspaceContext: Equatable, Hashable, Sendable {
    public let projectName: String
    public let workspaceName: String
    public let globalKey: String

    public init(projectName: String, workspaceName: String, globalKey: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.globalKey = globalKey
    }
}

// MARK: - WorkspaceSelectionTransition

/// 工作区切换迁移结果：统一双端在工作区切换时的副作用决策。
public struct WorkspaceSelectionTransition: Equatable, Sendable {
    public let isContextChanged: Bool
    public let shouldResetAIChatStage: Bool
    public let shouldResetTerminalLifecycle: Bool
    public let shouldClearPreviousWorkspaceSessionList: Bool

    public init(
        isContextChanged: Bool,
        shouldResetAIChatStage: Bool,
        shouldResetTerminalLifecycle: Bool,
        shouldClearPreviousWorkspaceSessionList: Bool
    ) {
        self.isContextChanged = isContextChanged
        self.shouldResetAIChatStage = shouldResetAIChatStage
        self.shouldResetTerminalLifecycle = shouldResetTerminalLifecycle
        self.shouldClearPreviousWorkspaceSessionList = shouldClearPreviousWorkspaceSessionList
    }
}

// MARK: - AISessionListRequestDescriptor

/// AI 会话列表请求描述：共享层只决定"是否允许请求、请求的上下文和参数"。
/// 平台层再把它映射到 `wsClient.requestAISessionList(...)` 调用。
public struct AISessionListRequestDescriptor: Equatable, Sendable {
    public let projectName: String
    public let workspaceName: String
    /// 工具过滤标识符；nil 表示请求全部会话。
    public let filter: String?
    public let limit: Int
    public let cursor: String?
    public let append: Bool
    public let forceRefresh: Bool

    public init(
        projectName: String,
        workspaceName: String,
        filter: String?,
        limit: Int,
        cursor: String?,
        append: Bool,
        forceRefresh: Bool
    ) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.filter = filter
        self.limit = limit
        self.cursor = cursor
        self.append = append
        self.forceRefresh = forceRefresh
    }
}

// MARK: - EvolutionPlanDocumentRequestDescriptor

/// Evolution 计划文档请求描述。
/// `path` 始终是 `.tidyflow/evolution/<cycleID>/plan.md`。
public struct EvolutionPlanDocumentRequestDescriptor: Equatable, Sendable {
    public let projectName: String
    public let workspaceName: String
    public let path: String

    public init(projectName: String, workspaceName: String, path: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.path = path
    }
}

// MARK: - SharedWorkspaceStateDriver

/// 跨平台工作区状态驱动器：纯函数入口，不持有平台可变状态。
public enum SharedWorkspaceStateDriver {

    /// 计算工作区切换迁移结果。
    /// - Parameters:
    ///   - previous: 切换前的工作区上下文（nil 表示首次选择）。
    ///   - current: 切换到的目标工作区上下文。
    /// - Returns: 迁移决策，描述哪些副作用需要执行。
    public static func computeTransition(
        from previous: SharedWorkspaceContext?,
        to current: SharedWorkspaceContext
    ) -> WorkspaceSelectionTransition {
        let changed = previous?.globalKey != current.globalKey
        return WorkspaceSelectionTransition(
            isContextChanged: changed,
            shouldResetAIChatStage: changed,
            shouldResetTerminalLifecycle: changed,
            shouldClearPreviousWorkspaceSessionList: changed
        )
    }

    /// 生成 AI 会话列表请求描述（首屏或指定页）。
    /// 工作区未选中时返回 nil。
    /// - Parameters:
    ///   - context: 当前工作区上下文（nil 表示未选中）。
    ///   - isConnectionReady: 连接是否就绪。
    ///   - filter: 工具过滤标识符（nil = 全部）。
    ///   - limit: 每页数量。
    ///   - cursor: 分页游标（nil = 首页）。
    ///   - append: 是否追加到已有列表。
    ///   - forceRefresh: 是否强制刷新缓存。
    public static func makeAISessionListRequest(
        context: SharedWorkspaceContext?,
        isConnectionReady: Bool,
        filter: String?,
        limit: Int,
        cursor: String?,
        append: Bool,
        forceRefresh: Bool
    ) -> AISessionListRequestDescriptor? {
        guard let context,
              !context.projectName.isEmpty,
              !context.workspaceName.isEmpty,
              isConnectionReady else { return nil }
        return AISessionListRequestDescriptor(
            projectName: context.projectName,
            workspaceName: context.workspaceName,
            filter: filter,
            limit: limit,
            cursor: cursor,
            append: append,
            forceRefresh: forceRefresh
        )
    }

    /// 生成 AI 会话列表首屏 bootstrap 请求描述。
    /// 等价于 `makeAISessionListRequest` 的 force=true, filter=nil 首屏版本。
    public static func makeBootstrapAISessionListRequest(
        context: SharedWorkspaceContext?,
        isConnectionReady: Bool,
        limit: Int = 50
    ) -> AISessionListRequestDescriptor? {
        return makeAISessionListRequest(
            context: context,
            isConnectionReady: isConnectionReady,
            filter: nil,
            limit: limit,
            cursor: nil,
            append: false,
            forceRefresh: true
        )
    }

    /// 生成 Evolution 计划文档请求描述。
    /// 工作区未选中、连接未就绪或 cycleID 为空时返回 nil。
    public static func makeEvolutionPlanDocumentRequest(
        context: SharedWorkspaceContext?,
        isConnectionReady: Bool,
        cycleID: String
    ) -> EvolutionPlanDocumentRequestDescriptor? {
        guard let context,
              !context.projectName.isEmpty,
              !context.workspaceName.isEmpty,
              isConnectionReady,
              !cycleID.isEmpty else { return nil }
        let path = ".tidyflow/evolution/\(cycleID)/plan.md"
        return EvolutionPlanDocumentRequestDescriptor(
            projectName: context.projectName,
            workspaceName: context.workspaceName,
            path: path
        )
    }
}
