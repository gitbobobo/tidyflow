import Foundation

// MARK: - 跨平台工作区视图状态模型
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// macOS 与 iOS 双端通过同一套值类型表达"当前选中的工作区"，
// 不再各自从视图状态反推 project + workspace 组合。

/// 工作区视图状态快照：唯一确定当前用户所在的工作区上下文。
/// 使用 project/workspace 全局键建模，兼容多项目并行场景下同名工作区的隔离。
public struct WorkspaceViewState: Equatable, Hashable, Sendable {
    /// 项目名称
    public let projectName: String
    /// 工作区名称
    public let workspaceName: String
    /// 项目唯一 ID（macOS 已有 UUID，iOS 通过确定性算法生成；可为 nil 表示未知）
    public let projectId: UUID?
    /// 此状态是否由持久化恢复（用于区分用户主动选择与断线重连后的自动恢复）
    public let isRestored: Bool

    /// 全局工作区键，格式为 "project:workspace"，可安全用作缓存键与状态槽位键。
    public var globalKey: String {
        let p = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(p):\(w)"
    }

    public init(
        projectName: String,
        workspaceName: String,
        projectId: UUID? = nil,
        isRestored: Bool = false
    ) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.projectId = projectId
        self.isRestored = isRestored
    }
}

// MARK: - 工作区视图状态输入

/// 共享状态机的输入事件枚举。
/// 调用方只能通过此枚举触发状态迁移，不能直接写入状态字段，保证迁移路径统一。
public enum WorkspaceViewStateInput: Equatable, Sendable {
    /// 用户主动选择指定工作区
    case select(projectName: String, workspaceName: String, projectId: UUID?)
    /// 从持久化状态恢复选中（无需 UUID，兼容 iOS）
    case restore(projectName: String, workspaceName: String)
    /// 清除选中（如断开连接、项目被删除等场景）
    case clear
}
