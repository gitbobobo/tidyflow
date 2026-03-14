// SharedTerminalShellDriver.swift
// TidyFlowShared
//
// 跨平台终端多会话壳层驱动：定义共享的纯值类型、状态机和副作用描述。
// 共享层只管理"选中哪个终端、下一步要发什么请求"，
// 不直接依赖 SwiftUI/AppKit/UIKit/WSClient，平台层仅把 effect descriptor 翻译为具体网络请求。
// 终端展示信息、AI 状态、置顶、recoveryPhase 仍由 TerminalSessionStore 和 TerminalSessionSemantics 负责。
//
// ── 职责边界 ──
// 本驱动只负责终端 create/attach/select/close/disconnect/reconcile 语义，
// 不持有、不聚合、不查询任何 AI 运行状态字段。
// 工作区级 AI 展示状态的唯一查询入口是 CoordinatorStateCache，
// 映射为 TerminalAIStatus 的唯一路径是 TerminalSessionSemantics。

import Foundation

// MARK: - SharedTerminalShellContext

/// 终端壳层工作区上下文，标识壳层实例归属。
public struct SharedTerminalShellContext: Equatable, Hashable, Sendable {
    public let projectName: String
    public let workspaceName: String
    public let globalKey: String

    public init(projectName: String, workspaceName: String, globalKey: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.globalKey = globalKey
    }

    public init(projectName: String, workspaceName: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.globalKey = "\(projectName):\(workspaceName)"
    }
}

// MARK: - SharedTerminalShellPhase

/// 壳层级页面相位。
/// `idle`：无活跃终端上下文。
/// `connecting`：create/attach 请求发出但尚未收到确认。
/// `ready`：当前选中终端已 attached 并可交互。
/// `error`：壳层级错误（如 create 失败）。
public enum SharedTerminalShellPhase: String, Equatable, Sendable {
    case idle
    case connecting
    case ready
    case error
}

// MARK: - SharedTerminalSelection

/// 当前工作区选中的终端目标。
public enum SharedTerminalSelection: Equatable, Sendable {
    /// 已绑定真实 termId 的活跃终端
    case active(termId: String)
    /// 尚未收到 term_created 回包的 pending 创建请求
    case pendingCreate(requestId: String, command: String?, icon: String?, name: String?)
    /// 无选中终端
    case none

    public var termId: String? {
        switch self {
        case .active(let termId): return termId
        case .pendingCreate: return nil
        case .none: return nil
        }
    }

    public var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    public var isPendingCreate: Bool {
        if case .pendingCreate = self { return true }
        return false
    }
}

// MARK: - SharedTerminalShellEffect

/// 壳层副作用描述：平台层根据此描述翻译为具体网络请求或 UI 操作。
public enum SharedTerminalShellEffect: Equatable, Sendable {
    case none
    /// 请求创建新终端
    case requestCreate(
        project: String,
        workspace: String,
        command: String?,
        icon: String?,
        name: String?
    )
    /// 请求附着已有终端
    case requestAttach(termId: String)
    /// 请求取消附着
    case requestDetach(termId: String)
    /// 请求关闭终端
    case requestClose(termId: String)
    /// 焦点切换到指定终端（终端视图已存在时使用）
    case focusTerminal(termId: String)
}

// MARK: - SharedTerminalShellInput

/// 壳层输入事件。所有壳层状态迁移必须通过此枚举触发。
public enum SharedTerminalShellInput: Equatable, Sendable {
    /// 打开工作区壳层（进入终端壳层视图，可选指定初始 termId）
    case openWorkspaceShell(initialTermId: String?)
    /// 请求创建新终端
    case createTerminal(command: String?, icon: String?, name: String?)
    /// 请求附着已有终端
    case attachTerminal(termId: String)
    /// 选中指定终端（标签切换）
    case selectTerminal(termId: String)
    /// 关闭指定终端
    case closeTerminal(termId: String)
    /// 服务端确认终端已创建
    case serverTermCreated(termId: String)
    /// 服务端确认终端已附着
    case serverTermAttached(termId: String)
    /// 服务端通知终端已关闭
    case serverTermClosed(termId: String)
    /// 用 term_list 同步工作区活跃终端列表
    case reconcileLiveTerminals(liveTermIds: [String])
    /// 连接断开
    case disconnect
    /// 清除错误
    case clearError
    /// 设置错误消息
    case setError(message: String)
}

// MARK: - SharedTerminalShellWorkspaceState

/// 单个工作区的壳层状态。
public struct SharedTerminalShellWorkspaceState: Equatable, Sendable {
    /// 当前选中终端
    public var selection: SharedTerminalSelection
    /// 壳层相位
    public var phase: SharedTerminalShellPhase
    /// 上一次选中的终端 ID（工作区切回时恢复）
    public var lastSelectedTermId: String?
    /// 最近错误消息
    public var lastError: String?

    public init(
        selection: SharedTerminalSelection = .none,
        phase: SharedTerminalShellPhase = .idle,
        lastSelectedTermId: String? = nil,
        lastError: String? = nil
    ) {
        self.selection = selection
        self.phase = phase
        self.lastSelectedTermId = lastSelectedTermId
        self.lastError = lastError
    }

    public static let empty = SharedTerminalShellWorkspaceState()
}

// MARK: - SharedTerminalShellState

/// 所有工作区的壳层状态集合。按工作区 globalKey 隔离。
public struct SharedTerminalShellState: Equatable, Sendable {
    public var workspaceStates: [String: SharedTerminalShellWorkspaceState]

    public init(workspaceStates: [String: SharedTerminalShellWorkspaceState] = [:]) {
        self.workspaceStates = workspaceStates
    }

    /// 获取指定工作区状态（不存在时返回空状态）
    public func state(for globalKey: String) -> SharedTerminalShellWorkspaceState {
        workspaceStates[globalKey] ?? .empty
    }

    /// 原地修改指定工作区状态
    public mutating func update(
        globalKey: String,
        _ transform: (inout SharedTerminalShellWorkspaceState) -> Void
    ) {
        var ws = workspaceStates[globalKey] ?? .empty
        transform(&ws)
        workspaceStates[globalKey] = ws
    }
}

// MARK: - SharedTerminalShellDriver

/// 跨平台终端壳层驱动器：纯函数入口，不持有平台可变状态。
/// 每次输入产出 (新状态, 副作用)，平台层负责翻译副作用。
public enum SharedTerminalShellDriver {

    /// 计算输入驱动的状态迁移和副作用。
    /// - Parameters:
    ///   - state: 当前工作区壳层状态
    ///   - input: 壳层输入事件
    ///   - context: 工作区上下文
    ///   - liveTermIds: 当前工作区所有活跃终端 ID 列表（用于选择回退逻辑）
    /// - Returns: (新状态, 副作用)
    public static func reduce(
        state: SharedTerminalShellWorkspaceState,
        input: SharedTerminalShellInput,
        context: SharedTerminalShellContext,
        liveTermIds: [String]
    ) -> (SharedTerminalShellWorkspaceState, SharedTerminalShellEffect) {
        var next = state
        let effect: SharedTerminalShellEffect

        switch input {
        case .openWorkspaceShell(let initialTermId):
            if let termId = initialTermId, liveTermIds.contains(termId) {
                // 指定了 termId 且存在：选中并 attach
                next.selection = .active(termId: termId)
                next.phase = .connecting
                next.lastSelectedTermId = termId
                effect = .requestAttach(termId: termId)
            } else if let lastId = state.lastSelectedTermId, liveTermIds.contains(lastId) {
                // 恢复上次选中终端
                next.selection = .active(termId: lastId)
                next.phase = .connecting
                effect = .requestAttach(termId: lastId)
            } else if !liveTermIds.isEmpty {
                // 有活跃终端但无记忆：选中第一个
                let first = liveTermIds[0]
                next.selection = .active(termId: first)
                next.phase = .connecting
                next.lastSelectedTermId = first
                effect = .requestAttach(termId: first)
            } else {
                // 无活跃终端：自动创建
                let requestId = UUID().uuidString
                next.selection = .pendingCreate(requestId: requestId, command: nil, icon: nil, name: nil)
                next.phase = .connecting
                effect = .requestCreate(
                    project: context.projectName,
                    workspace: context.workspaceName,
                    command: nil,
                    icon: nil,
                    name: nil
                )
            }

        case .createTerminal(let command, let icon, let name):
            let requestId = UUID().uuidString
            next.selection = .pendingCreate(requestId: requestId, command: command, icon: icon, name: name)
            next.phase = .connecting
            next.lastError = nil
            effect = .requestCreate(
                project: context.projectName,
                workspace: context.workspaceName,
                command: command,
                icon: icon,
                name: name
            )

        case .attachTerminal(let termId):
            next.selection = .active(termId: termId)
            next.phase = .connecting
            next.lastSelectedTermId = termId
            next.lastError = nil
            effect = .requestAttach(termId: termId)

        case .selectTerminal(let termId):
            let oldTermId = state.selection.termId
            // 选中同一个终端：无操作
            guard termId != oldTermId else {
                effect = .none
                break
            }
            // 先 detach 旧终端
            var detachEffect: SharedTerminalShellEffect = .none
            if let old = oldTermId {
                detachEffect = .requestDetach(termId: old)
            }
            next.selection = .active(termId: termId)
            next.phase = .connecting
            next.lastSelectedTermId = termId
            // 如果需要 detach 旧终端，返回 detach；attach 由平台层在 detach 后发起
            // 这里简化：只返回 attach，detach 由平台在切换时处理
            if oldTermId != nil {
                effect = detachEffect
            } else {
                effect = .requestAttach(termId: termId)
            }

        case .closeTerminal(let termId):
            effect = .requestClose(termId: termId)
            // 如果关闭的是当前选中终端，需要选择新终端
            if state.selection.termId == termId {
                let fallback = Self.selectFallback(
                    closingTermId: termId,
                    liveTermIds: liveTermIds
                )
                if let newId = fallback {
                    next.selection = .active(termId: newId)
                    next.phase = .connecting
                    next.lastSelectedTermId = newId
                } else {
                    next.selection = .none
                    next.phase = .idle
                }
            }

        case .serverTermCreated(let termId):
            // 绑定 pending create 到真实 termId
            if case .pendingCreate = state.selection {
                next.selection = .active(termId: termId)
                next.phase = .connecting
                next.lastSelectedTermId = termId
                // 创建完成后自动 attach
                effect = .requestAttach(termId: termId)
            } else {
                // 不是当前 pending 的创建：忽略
                effect = .none
            }

        case .serverTermAttached(let termId):
            if state.selection.termId == termId {
                next.phase = .ready
                next.lastError = nil
                effect = .focusTerminal(termId: termId)
            } else {
                effect = .none
            }

        case .serverTermClosed(let termId):
            // 清理当前选中（如果匹配）
            if state.selection.termId == termId {
                let survivingIds = liveTermIds.filter { $0 != termId }
                let fallback = Self.selectFallbackFromList(
                    closingTermId: termId,
                    orderedTermIds: liveTermIds
                )
                if let newId = fallback {
                    next.selection = .active(termId: newId)
                    next.phase = .connecting
                    next.lastSelectedTermId = newId
                    effect = .requestAttach(termId: newId)
                } else {
                    next.selection = .none
                    next.phase = .idle
                    next.lastSelectedTermId = nil
                    effect = .none
                }
            } else {
                effect = .none
            }
            // 清理 lastSelectedTermId 如果被关闭
            if next.lastSelectedTermId == termId, next.selection.termId != termId {
                next.lastSelectedTermId = next.selection.termId
            }

        case .reconcileLiveTerminals(let newLiveTermIds):
            let liveSet = Set(newLiveTermIds)
            // 清理不存在的选中项
            if let selectedId = state.selection.termId, !liveSet.contains(selectedId) {
                // 当前选中终端已不存在
                let fallback = newLiveTermIds.first
                if let newId = fallback {
                    next.selection = .active(termId: newId)
                    next.lastSelectedTermId = newId
                    next.phase = .connecting
                    effect = .requestAttach(termId: newId)
                } else {
                    next.selection = .none
                    next.phase = .idle
                    next.lastSelectedTermId = nil
                    effect = .none
                }
            } else if case .pendingCreate = state.selection {
                // pending create 仍然有效（等待 term_created）
                effect = .none
            } else {
                effect = .none
            }
            // 清理 lastSelectedTermId
            if let lastId = next.lastSelectedTermId, !liveSet.contains(lastId) {
                next.lastSelectedTermId = next.selection.termId
            }

        case .disconnect:
            if state.selection.termId != nil {
                next.phase = .connecting
            }
            next.lastError = nil
            effect = .none

        case .clearError:
            next.lastError = nil
            if next.phase == .error {
                next.phase = next.selection.isNone ? .idle : .ready
            }
            effect = .none

        case .setError(let message):
            next.lastError = message
            next.phase = .error
            effect = .none
        }

        return (next, effect)
    }

    // MARK: - 终端选择回退逻辑

    /// 关闭终端后的回退选择：右侧优先、左侧回退、否则 nil（空态）。
    public static func selectFallback(
        closingTermId: String,
        liveTermIds: [String]
    ) -> String? {
        return selectFallbackFromList(closingTermId: closingTermId, orderedTermIds: liveTermIds)
    }

    /// 从有序列表中选择回退目标。
    public static func selectFallbackFromList(
        closingTermId: String,
        orderedTermIds: [String]
    ) -> String? {
        guard let idx = orderedTermIds.firstIndex(of: closingTermId) else {
            return orderedTermIds.first
        }
        let surviving = orderedTermIds.filter { $0 != closingTermId }
        guard !surviving.isEmpty else { return nil }
        // 右侧优先
        let rightIdx = orderedTermIds.index(after: idx)
        if rightIdx < orderedTermIds.endIndex {
            let rightId = orderedTermIds[rightIdx]
            if rightId != closingTermId { return rightId }
        }
        // 左侧回退
        if idx > orderedTermIds.startIndex {
            let leftIdx = orderedTermIds.index(before: idx)
            let leftId = orderedTermIds[leftIdx]
            if leftId != closingTermId { return leftId }
        }
        // 其他存活终端
        return surviving.first
    }
}
