import Foundation

// MARK: - 跨平台工作区视图状态机
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// macOS 与 iOS 双端通过同一组纯业务输入驱动状态变化，
// 不再各自在平台层维护重复的选中状态推导逻辑。
//
// 设计约束：
// - 状态机不持有任何平台类型（无 Color、View、NSObject 等）
// - 多项目场景：globalKey 包含项目名，不同项目的同名工作区被隔离在不同槽位
// - 状态机本身是 ObservableObject 的替代层；平台层负责在需要时将变化同步给 UI 框架

/// 跨平台工作区视图状态机。
/// 双端通过 `apply(_:)` 驱动状态迁移；选中态通过 `selected` 属性读取。
public final class WorkspaceViewStateMachine: @unchecked Sendable {

    // MARK: - 状态存储

    /// 当前选中的工作区视图状态；为 nil 表示无选中（如未连接或连接刚初始化）
    public private(set) var selected: WorkspaceViewState?

    // MARK: - 初始化

    public init() {}

    // MARK: - 状态迁移入口

    /// 应用输入事件并更新状态。返回迁移后的选中状态（可能为 nil）。
    /// 工作区切换时自动重置 AI 聊天舞台状态，确保多工作区间不串台。
    /// - Returns: 迁移后的 `selected` 快照
    @discardableResult
    public func apply(_ input: WorkspaceViewStateInput) -> WorkspaceViewState? {
        switch input {
        case .select(let projectName, let workspaceName, let projectId):
            let next = WorkspaceViewState(
                projectName: projectName,
                workspaceName: workspaceName,
                projectId: projectId,
                isRestored: false
            )
            if selected != next { resetAIChatStage() }
            selected = next
            return next

        case .restore(let projectName, let workspaceName):
            let next = WorkspaceViewState(
                projectName: projectName,
                workspaceName: workspaceName,
                projectId: nil,
                isRestored: true
            )
            if selected != next { resetAIChatStage() }
            selected = next
            return next

        case .clear:
            resetAIChatStage()
            selected = nil
            return nil
        }
    }

    // MARK: - AI 聊天舞台状态追踪
    //
    // WorkspaceViewStateMachine 与 AIChatStageLifecycle 的协调约束：
    //
    // 1. 工作区切换时，本状态机 resetAIChatStage() 先于平台层触发。
    //    平台层在收到新工作区选中事件后，应调用 lifecycle.apply(.forceReset) 或
    //    lifecycle.apply(.close) 确保状态机本体也回到 idle。
    // 2. 本状态机的 aiChatStagePhase/aiChatStageContextKey 仅为投影缓存，
    //    不是生命周期权威状态——权威状态始终以 AIChatStageLifecycle.state 为准。
    // 3. 断开连接场景由平台层直接调用 lifecycle.apply(.forceReset)，
    //    本状态机不参与断连判断。

    /// 当前工作区关联的 AI 聊天舞台阶段。
    /// 跟随工作区切换自动重置为 idle，确保多工作区间不串台。
    public private(set) var aiChatStagePhase: String = "idle"

    /// 当前工作区关联的 AI 聊天舞台上下文键（`project::workspace::aiTool`）。
    /// 为 nil 表示无活跃聊天舞台。
    public private(set) var aiChatStageContextKey: String?

    /// 更新 AI 聊天舞台阶段。调用方在 `AIChatStageLifecycle.apply()` 后
    /// 应同步调用此方法，确保 `WorkspaceViewStateMachine` 始终持有最新舞台状态。
    public func updateAIChatStage(phase: String, contextKey: String?) {
        aiChatStagePhase = phase
        aiChatStageContextKey = contextKey
    }

    /// 重置 AI 聊天舞台状态为 idle。
    /// 在工作区切换、断开连接等场景中由状态机自动调用。
    public func resetAIChatStage() {
        aiChatStagePhase = "idle"
        aiChatStageContextKey = nil
    }

    // MARK: - 查询接口

    /// 判断指定的 project+workspace 组合是否为当前选中状态。
    /// 使用项目名 + 工作区名精确匹配，不依赖 UUID，兼容 iOS 场景。
    public func isSelected(projectName: String, workspaceName: String) -> Bool {
        guard let selected else { return false }
        return selected.projectName == projectName && selected.workspaceName == workspaceName
    }

    /// 通过全局键（"project:workspace"）判断是否为当前选中状态。
    public func isSelected(globalKey: String) -> Bool {
        guard let selected else { return false }
        return selected.globalKey == globalKey
    }

    /// 如果当前已选中给定全局键，返回当前状态；否则返回 nil。
    public func selectedState(ifGlobalKey key: String) -> WorkspaceViewState? {
        isSelected(globalKey: key) ? selected : nil
    }
}
