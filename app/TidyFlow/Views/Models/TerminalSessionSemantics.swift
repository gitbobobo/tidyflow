import Foundation
import SwiftUI
import TidyFlowShared

// MARK: - 终端会话共享语义层
//
// 跨平台共享的终端语义工具层，提供统一的终端运行状态归一化、
// AI 会话状态到 TerminalAIStatus 的映射、终端展示信息恢复与同工作区排序规则。
// macOS 与 iOS 通过此层共享规则，不再各自维护同义私有实现。
// 所有键均显式带上 project/workspace/termId 边界，禁止将单项目假设编码进状态派生逻辑。

// MARK: - 终端生命周期相位枚举
//
// 与 AIChatStagePhase 同构，描述终端连接层的生命周期阶段。
// 对应 Core 的 TerminalLifecyclePhase（entering/active/resuming/idle）。

/// 终端连接层生命周期相位。
/// macOS 与 iOS 共用，双端必须通过 `TerminalLifecycleStateMachine.apply(_:)` 驱动迁移。
enum TerminalLifecyclePhase: String, Equatable, Sendable {
    /// 空闲态：无活跃终端上下文
    case idle
    /// 进入中：正在创建/spawn 终端，等待 term_created 或首次输出
    case entering
    /// 活跃态：终端已就绪，输出正常流转
    case active
    /// 恢复中：断线重连后正在重新 attach 与回放 scrollback
    case resuming

    /// 从 Core 协议字符串恢复相位，无法识别的值回退到 idle
    static func from(serverValue: String) -> TerminalLifecyclePhase {
        switch serverValue.lowercased() {
        case "entering": return .entering
        case "active": return .active
        case "resuming": return .resuming
        case "idle": return .idle
        default: return .idle
        }
    }
}

/// 终端生命周期输入事件。
/// 所有状态迁移必须通过此枚举触发，禁止直接写入 phase 字段。
enum TerminalLifecycleInput: Equatable, Sendable {
    /// 创建新终端（对应 Core TermCreate）
    case create(project: String, workspace: String, termId: String)
    /// 终端创建完成（收到 term_created 响应）
    case created(termId: String)
    /// 附着已有终端（对应 Core TermAttach）
    case attach(project: String, workspace: String, termId: String)
    /// 附着完成（收到 term_attached 响应，scrollback 回放就绪）
    case attached(termId: String)
    /// 恢复会话（断线重连后重新 attach）
    case resume(termId: String)
    /// 恢复完成
    case resumeCompleted(termId: String)
    /// 终端关闭（收到 term_closed 或用户主动关闭）
    case close(termId: String)
    /// 断连（WebSocket 断开）
    case disconnect
    /// 强制重置（工作区切换、项目删除等不可恢复场景）
    case forceReset
    /// 从服务端 term_list 恢复（重连后同步 Core 权威相位）
    case restoreFromServer(project: String, workspace: String, termId: String, phase: TerminalLifecyclePhase)
}

/// 终端生命周期状态快照，包含当前相位和关联上下文。
struct TerminalLifecycleState: Equatable, Sendable {
    let phase: TerminalLifecyclePhase
    let project: String
    let workspace: String
    let activeTermId: String?

    /// 终端上下文三元组键，用于多工作区隔离校验
    var contextKey: String {
        "\(project)::\(workspace)::\(activeTermId ?? "")"
    }

    static let idle = TerminalLifecycleState(
        phase: .idle, project: "", workspace: "", activeTermId: nil
    )
}

/// 终端生命周期状态机。
/// 与 `AIChatStageLifecycle` 同构的迁移语义：
///   idle → entering → active ⇄ resuming
///                   ↓         ↓
///                (close) → idle
///
/// 设计约束：
/// - 不持有任何平台类型（无 Color、View、NSObject 等）
/// - 不直接触发网络请求或 UI 刷新，由调用方根据迁移结果执行副作用
/// - 多工作区场景下通过 contextKey 隔离不同终端上下文
final class TerminalLifecycleStateMachine: @unchecked Sendable {

    /// 当前状态
    private(set) var state: TerminalLifecycleState = .idle

    /// 迁移结果
    enum TransitionResult: Equatable {
        /// 迁移成功
        case transitioned(TerminalLifecycleState)
        /// 迁移被忽略（当前阶段不允许该输入）
        case ignored
    }

    /// 应用输入事件并更新状态。返回迁移结果。
    @discardableResult
    func apply(_ input: TerminalLifecycleInput) -> TransitionResult {
        switch input {

        case .create(let project, let workspace, let termId):
            let next = TerminalLifecycleState(
                phase: .entering, project: project, workspace: workspace, activeTermId: termId
            )
            state = next
            return .transitioned(next)

        case .created(let termId):
            // 只有 entering 状态且 termId 匹配时才迁移到 active
            guard state.phase == .entering, state.activeTermId == termId else { return .ignored }
            let next = TerminalLifecycleState(
                phase: .active, project: state.project, workspace: state.workspace, activeTermId: termId
            )
            state = next
            return .transitioned(next)

        case .attach(let project, let workspace, let termId):
            let next = TerminalLifecycleState(
                phase: .resuming, project: project, workspace: workspace, activeTermId: termId
            )
            state = next
            return .transitioned(next)

        case .attached(let termId):
            // 从 resuming/entering 迁移到 active
            guard state.phase == .resuming || state.phase == .entering,
                  state.activeTermId == termId else { return .ignored }
            let next = TerminalLifecycleState(
                phase: .active, project: state.project, workspace: state.workspace, activeTermId: termId
            )
            state = next
            return .transitioned(next)

        case .resume(let termId):
            guard state.phase == .active || state.phase == .entering else { return .ignored }
            let next = TerminalLifecycleState(
                phase: .resuming, project: state.project, workspace: state.workspace, activeTermId: termId
            )
            state = next
            return .transitioned(next)

        case .resumeCompleted(let termId):
            guard state.phase == .resuming, state.activeTermId == termId else { return .ignored }
            let next = TerminalLifecycleState(
                phase: .active, project: state.project, workspace: state.workspace, activeTermId: termId
            )
            state = next
            return .transitioned(next)

        case .close(let termId):
            // 只关闭匹配的终端，不影响其它终端上下文
            guard state.activeTermId == termId, state.phase != .idle else { return .ignored }
            state = .idle
            return .transitioned(.idle)

        case .disconnect:
            // 断连：active/entering → resuming（保留上下文等待恢复）
            guard state.phase == .active || state.phase == .entering else { return .ignored }
            let next = TerminalLifecycleState(
                phase: .resuming, project: state.project, workspace: state.workspace,
                activeTermId: state.activeTermId
            )
            state = next
            return .transitioned(next)

        case .forceReset:
            let wasIdle = state.phase == .idle
            state = .idle
            return wasIdle ? .ignored : .transitioned(.idle)

        case .restoreFromServer(let project, let workspace, let termId, let phase):
            // 从服务端 term_list 直接恢复到指定相位（无条件覆盖）
            let next = TerminalLifecycleState(
                phase: phase, project: project, workspace: workspace, activeTermId: termId
            )
            state = next
            return .transitioned(next)
        }
    }

    /// 判断当前状态机是否接受来自指定上下文的终端事件。
    /// 只有 active 或 resuming 阶段且上下文匹配时才接受。
    func acceptsEvent(project: String, workspace: String, termId: String) -> Bool {
        guard state.phase == .active || state.phase == .resuming else { return false }
        return state.project == project && state.workspace == workspace && state.activeTermId == termId
    }

    /// 判断当前状态机是否接受指定 termId 的事件。
    func acceptsTermEvent(termId: String) -> Bool {
        guard state.phase == .active || state.phase == .resuming else { return false }
        return state.activeTermId == termId || state.activeTermId == nil
    }
}

// MARK: - 终端 AI 状态（六态枚举）

/// 终端标签中 AI 代理的执行状态（六态）。
/// macOS 与 iOS 共用此定义，跨端消费同一状态语义。
enum TerminalAIStatus: Equatable {
    /// 空闲：无 AI 任务运行，标签栏不展示状态指示器
    case idle
    /// 执行中：AI 正在运行，toolName 为 AI 工具显示名（如 "Codex"、"Opencode"）
    case running(toolName: String?)
    /// 等待输入：AI 需要用户确认或提供输入
    case awaitingInput
    /// 成功完成
    case success
    /// 失败，message 为可选错误摘要
    case failure(message: String?)
    /// 已取消
    case cancelled

    /// 是否需要在终端入口显示状态指示器（空闲时隐藏）
    var isVisible: Bool {
        if case .idle = self { return false }
        return true
    }
}

// MARK: - 终端运行状态归一化

/// 归一化的终端运行状态，双端统一使用
enum TerminalRunningStatus: Equatable {
    /// 终端正在运行
    case running
    /// 终端已停止或关闭
    case stopped
}

// MARK: - 终端展示信息

/// 终端的展示元数据（图标、名称、源命令），双端统一使用
struct TerminalDisplayInfo: Equatable {
    let termId: String
    let project: String
    let workspace: String
    let icon: String
    let name: String
    /// 触发终端创建的源命令（如自定义命令），可为 nil
    let sourceCommand: String?
    var isPinned: Bool

    /// 从 TerminalSessionInfo 恢复展示信息，fallback 到 shell/cwd 派生值
    static func restoreFrom(
        session: TerminalSessionInfo,
        isPinned: Bool = false
    ) -> TerminalDisplayInfo? {
        guard let name = session.name, !name.isEmpty else { return nil }
        return TerminalDisplayInfo(
            termId: session.termId,
            project: session.project,
            workspace: session.workspace,
            icon: session.icon ?? "terminal",
            name: name,
            sourceCommand: nil,
            isPinned: isPinned
        )
    }

    /// 从 TermCreatedResult 恢复展示信息
    static func restoreFrom(
        created: TermCreatedResult,
        isPinned: Bool = false
    ) -> TerminalDisplayInfo? {
        guard let name = created.name, !name.isEmpty else { return nil }
        return TerminalDisplayInfo(
            termId: created.termId,
            project: created.project,
            workspace: created.workspace,
            icon: created.icon ?? "terminal",
            name: name,
            sourceCommand: nil,
            isPinned: isPinned
        )
    }

    /// 从 TermAttachedResult 恢复展示信息
    static func restoreFrom(
        attached: TermAttachedResult,
        isPinned: Bool = false
    ) -> TerminalDisplayInfo? {
        guard let name = attached.name, !name.isEmpty else { return nil }
        return TerminalDisplayInfo(
            termId: attached.termId,
            project: attached.project,
            workspace: attached.workspace,
            icon: attached.icon ?? "terminal",
            name: name,
            sourceCommand: nil,
            isPinned: isPinned
        )
    }
}

// MARK: - 终端语义工具层

enum TerminalSessionSemantics {

    // MARK: - 运行状态归一化

    /// 将后端 status 字符串归一化为 TerminalRunningStatus
    static func runningStatus(from status: String) -> TerminalRunningStatus {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running" ? .running : .stopped
    }

    // MARK: - AI 执行状态映射

    /// 将 AI 会话状态字符串映射为 TerminalAIStatus（六态枚举）。
    /// macOS 与 iOS 共享此映射，不再分平台维护独立实现。
    /// - Parameters:
    ///   - status: 后端 AI 会话状态字符串（如 "running"、"awaiting_input"、"success" 等）
    ///   - errorMessage: 可选错误摘要（failure 时使用）
    ///   - toolName: 优先使用后端工具名，否则回退到 aiToolDisplayName
    ///   - aiToolDisplayName: AI 工具的显示名（fallback）
    static func terminalAIStatus(
        from status: String,
        errorMessage: String?,
        toolName: String?,
        aiToolDisplayName: String
    ) -> TerminalAIStatus {
        let displayName = toolName ?? aiToolDisplayName
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running":
            return .running(toolName: displayName)
        case "awaiting_input":
            return .awaitingInput
        case "success":
            return .success
        case "failure", "error":
            return .failure(message: errorMessage)
        case "cancelled":
            return .cancelled
        default:
            return .idle
        }
    }

    // MARK: - 工作区终端排序

    /// 对指定工作区的终端列表进行排序：
    /// 1. 置顶终端排在前面；
    /// 2. 同优先级内按原始顺序（保持稳定性）。
    /// - 约束：只操作 project/workspace 匹配的终端，不跨工作区混排。
    static func sortedTerminals(
        _ terminals: [TerminalSessionInfo],
        pinnedIds: Set<String>
    ) -> [TerminalSessionInfo] {
        let indexMap = Dictionary(uniqueKeysWithValues: terminals.enumerated().map { ($1.termId, $0) })
        return terminals.sorted { lhs, rhs in
            let lhsPinned = pinnedIds.contains(lhs.termId)
            let rhsPinned = pinnedIds.contains(rhs.termId)
            if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
            return (indexMap[lhs.termId] ?? 0) < (indexMap[rhs.termId] ?? 0)
        }
    }

    /// 过滤 + 排序：从全局活跃列表中取出指定 project/workspace 的运行中终端并排序。
    /// 使用 project/workspace 硬边界，保证多项目多工作区不会串台。
    static func terminalsForWorkspace(
        project: String,
        workspace: String,
        allTerminals: [TerminalSessionInfo],
        pinnedIds: Set<String>
    ) -> [TerminalSessionInfo] {
        let filtered = allTerminals.filter {
            $0.project == project && $0.workspace == workspace && $0.isRunning
        }
        return sortedTerminals(filtered, pinnedIds: pinnedIds)
    }

    // MARK: - 工作区 Open Time

    /// 计算新的 workspaceTerminalOpenTime 字典：保留有活跃终端的工作区，补全新出现的。
    /// 使用 globalWorkspaceKey(project:workspace:) 格式的 key（"project:workspace"）。
    static func updatedWorkspaceOpenTime(
        existing: [String: Date],
        activeTerminals: [TerminalSessionInfo],
        makeKey: (String, String) -> String
    ) -> [String: Date] {
        var activeWorkspaceKeys: Set<String> = []
        var result = existing
        for term in activeTerminals where term.isRunning {
            let key = makeKey(term.project, term.workspace)
            activeWorkspaceKeys.insert(key)
            if result[key] == nil {
                result[key] = Date()
            }
        }
        return result.filter { activeWorkspaceKeys.contains($0.key) }
    }
}

// MARK: - TerminalAIStatus 视觉属性（跨端共享）

extension TerminalAIStatus {
    /// SF Symbol 图标名称（macOS 与 iOS 统一使用）
    var iconName: String {
        switch self {
        case .idle: return "circle.fill"
        case .running: return "bolt.circle.fill"
        case .awaitingInput: return "questionmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    /// 状态颜色（使用 SwiftUI 跨端语义颜色）
    var color: Color {
        switch self {
        case .idle: return .secondary.opacity(0.4)
        case .running: return .blue
        case .awaitingInput: return .orange
        case .success: return .green
        case .failure: return .red
        case .cancelled: return .secondary
        }
    }

    /// 悬浮提示与辅助标签文案（含 AI 工具名或错误摘要）
    var hint: String {
        switch self {
        case .idle: return ""
        case .running(let toolName):
            return toolName.map { "AI 执行中 · \($0)" } ?? "AI 执行中"
        case .awaitingInput:
            return "等待用户输入"
        case .success:
            return "AI 已完成"
        case .failure(let message):
            return message.map { "AI 失败：\($0)" } ?? "AI 失败"
        case .cancelled:
            return "AI 已取消"
        }
    }
}

// MARK: - 终端列表展示阶段

/// 指定工作区的终端列表展示阶段，双端共享判断逻辑。
/// 视图通过此枚举决定呈现 empty / content，不再在 View body 中各自判断 isEmpty。
enum TerminalListDisplayPhase {
    /// 工作区无活跃终端
    case empty
    /// 有终端可展示
    case content(terminals: [TerminalSessionInfo])

    /// 从全局终端列表推导指定工作区的展示阶段。
    static func from(
        project: String,
        workspace: String,
        allTerminals: [TerminalSessionInfo],
        pinnedIds: Set<String>
    ) -> TerminalListDisplayPhase {
        let terminals = TerminalSessionSemantics.terminalsForWorkspace(
            project: project,
            workspace: workspace,
            allTerminals: allTerminals,
            pinnedIds: pinnedIds
        )
        return terminals.isEmpty ? .empty : .content(terminals: terminals)
    }
}

// MARK: - TerminalAIStatus → 共享投影转换

extension TerminalAIStatus {
    /// 将平台层 TerminalAIStatus（含 SwiftUI Color）转换为共享投影模型，
    /// 供 WorkspaceTerminalProjection 在 TidyFlowShared 侧存储。
    func toSharedProjection() -> WorkspaceTerminalAIStatusProjection {
        WorkspaceTerminalAIStatusProjection(
            isVisible: isVisible,
            iconName: iconName,
            hint: hint,
            colorToken: colorToken
        )
    }

    /// 颜色语义标记（供共享投影层使用）
    var colorToken: String {
        switch self {
        case .idle: return "secondary"
        case .running: return "blue"
        case .awaitingInput: return "orange"
        case .success: return "green"
        case .failure: return "red"
        case .cancelled: return "secondary"
        }
    }
}

// MARK: - WorkspaceTerminalAIStatusProjection → SwiftUI Color（平台扩展）

extension WorkspaceTerminalAIStatusProjection {
    /// 将 colorToken 映射为 SwiftUI Color，供视图层使用。
    var color: Color {
        switch colorToken {
        case "blue": return .blue
        case "orange": return .orange
        case "green": return .green
        case "red": return .red
        default: return .secondary
        }
    }
}

// MARK: - 工作区终端事件边界校验器

/// 终端事件工作区隔离校验器。
///
/// 在 reconnect、reclaim、trim 等退化路径下，验证终端事件是否属于当前活跃工作区上下文，
/// 防止跨工作区事件污染状态机。macOS 与 iOS 双端通过同一规则做事件准入判断。
///
/// 设计原则：
/// - 不持有状态，纯函数式设计，无副作用
/// - 按 (project, workspace, termId) 三元组做精确隔离
/// - 宽进策略：termId 不在当前工作区，拒绝（返回 false）
enum WorkspaceEventBoundary {

    /// 校验终端事件是否来自预期的工作区上下文。
    /// - Parameters:
    ///   - project: 事件携带的项目名
    ///   - workspace: 事件携带的工作区名
    ///   - expectedProject: 当前活跃工作区项目名
    ///   - expectedWorkspace: 当前活跃工作区名
    /// - Returns: `true` 表示允许处理该事件，`false` 表示应丢弃
    static func accepts(
        project: String,
        workspace: String,
        expectedProject: String,
        expectedWorkspace: String
    ) -> Bool {
        project == expectedProject && workspace == expectedWorkspace
    }

    /// 校验 termId 是否属于预期工作区（通过生命周期状态机验证）。
    static func accepts(
        termId: String,
        expectedProject: String,
        expectedWorkspace: String,
        lifecycle: TerminalLifecycleStateMachine?
    ) -> Bool {
        guard let lifecycle else { return false }
        let state = lifecycle.state
        guard state.phase != .idle else { return false }
        return state.project == expectedProject && state.workspace == expectedWorkspace
    }

    /// 在 term_list 回调后计算需要 trim 的过期终端集合。
    /// - Parameters:
    ///   - currentDisplayIds: 当前缓存的终端 ID 集合（属于指定工作区）
    ///   - survivingIds: Core 权威的存活终端 ID 集合
    /// - Returns: 应被清除的过期终端 ID 集合
    static func staleTerminals(
        currentDisplayIds: Set<String>,
        survivingIds: Set<String>
    ) -> Set<String> {
        currentDisplayIds.subtracting(survivingIds)
    }
}
