import Foundation

/// 终端标签中 AI 代理的执行状态（六态）
/// 用于在标签栏为每个终端 tab 独立展示 AI 任务进度
enum TerminalAIStatus: Equatable {
    /// 空闲：无 AI 任务运行
    case idle
    /// 执行中：AI 正在运行，toolName 为 AI 工具显示名（如 "Codex"、"Copilot"）
    case running(toolName: String?)
    /// 等待输入：AI 需要用户确认或提供输入
    case awaitingInput
    /// 成功完成
    case success
    /// 失败，message 为可选错误摘要
    case failure(message: String?)
    /// 已取消
    case cancelled

    /// 是否需要在标签栏显示状态指示器（空闲时隐藏）
    var isVisible: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// 二值连接状态，保留用于向后兼容（如 GitCacheState 回调）。
/// 新代码应使用 `ConnectionPhase`（见 ConnectionSemantics.swift），它表达完整的连接阶段语义。
enum ConnectionState {
    case connected
    case disconnected
}

// Phase C1-1: Terminal state for native binding
enum TerminalState: Equatable {
    case idle
    case connecting
    case ready(sessionId: String)
    case error(message: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

enum TabKind: String, Codable {
    case terminal
    case editor
    case diff
    case settings
    
    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .editor: return "doc.text"
        case .diff: return "arrow.left.arrow.right"
        case .settings: return "gearshape"
        }
    }
}

/// 工作空间级主内容页面（不进入 Tab 列表）
enum WorkspaceSpecialPage: String, Codable {
    case aiChat
    case evolution
    case evidence
}

struct TabModel: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let kind: TabKind
    let workspaceKey: String
    var payload: String  // 使用 var 以便执行后清空自定义命令

    // Phase C1-2: Terminal session ID (only for terminal tabs)
    // Stored separately from payload to maintain Codable compatibility
    var terminalSessionId: String?

    // Phase C2-1: Diff mode (only for diff tabs)
    // "working" = unstaged changes, "staged" = staged changes
    var diffMode: String?

    // Phase C2-2b: Diff view mode (only for diff tabs)
    // "unified" = single column, "split" = side-by-side
    var diffViewMode: String?

    // 终端快捷命令配置的图标（仅通过快捷命令创建的终端 tab 使用，用于 Tab 栏显示）
    var commandIcon: String? = nil

    // 终端标签固定状态（固定后不会被“关闭其他/关闭右侧”批量关闭）
    var isPinned: Bool = false

    // 编辑器 dirty 状态（文件有未保存更改）
    var isDirty: Bool = false
}

// Phase C2-1: Diff mode enum for type safety
enum DiffMode: String, Codable {
    case working
    case staged
}

typealias TabSet = [TabModel]
