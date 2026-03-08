import Foundation

// MARK: - 终端会话共享语义层
//
// 跨平台共享的终端语义工具层，提供统一的终端运行状态归一化、
// AI 会话状态到 TerminalAIStatus 的映射、终端展示信息恢复与同工作区排序规则。
// macOS 与 iOS 通过此层共享规则，不再各自维护同义私有实现。
// 所有键均显式带上 project/workspace/termId 边界，禁止将单项目假设编码进状态派生逻辑。

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

    #if os(macOS)
    /// 将 AI 会话状态字符串映射为 TerminalAIStatus（六态枚举）。
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
    #endif

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
