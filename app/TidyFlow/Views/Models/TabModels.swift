import Foundation

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
    
    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .editor: return "doc.text"
        case .diff: return "arrow.left.arrow.right"
        }
    }
}

enum BottomPanelCategory: String, Codable, CaseIterable {
    case projectConfig
    case terminal
    case edit
    case diff

    var titleKey: String {
        switch self {
        case .projectConfig: return "bottomPanel.category.projectConfig"
        case .terminal: return "bottomPanel.category.terminal"
        case .edit: return "bottomPanel.category.edit"
        case .diff: return "bottomPanel.category.diff"
        }
    }

    var iconName: String {
        switch self {
        case .projectConfig: return "slider.horizontal.3"
        case .terminal: return "terminal"
        case .edit: return "doc.text"
        case .diff: return "arrow.left.arrow.right"
        }
    }

    static func from(tabKind: TabKind) -> BottomPanelCategory {
        switch tabKind {
        case .terminal: return .terminal
        case .editor: return .edit
        case .diff: return .diff
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

    var bottomPanelCategory: BottomPanelCategory {
        BottomPanelCategory.from(tabKind: kind)
    }
}

// Phase C2-1: Diff mode enum for type safety
enum DiffMode: String, Codable {
    case working
    case staged
}

typealias TabSet = [TabModel]

#if os(macOS)
/// 底部面板布局语义，集中维护默认高度、收起阈值与窗口约束。
enum BottomPanelLayoutSemantics {
    static let collapsedTabStripHeight: CGFloat = 28
    static let expandedTabStripHeight: CGFloat = 34
    static let minExpandedTabPanelHeight: CGFloat = 100
    static let defaultExpandedTabPanelHeight: CGFloat = 240
    static let resizeHandleHitAreaHeight: CGFloat = 8
    static let minChatPanelHeight: CGFloat = 220

    static func restoredExpandedHeight(
        currentHeight: CGFloat,
        lastExpandedHeight: CGFloat?
    ) -> CGFloat {
        if currentHeight > 0 {
            return currentHeight
        }
        if let lastExpandedHeight, lastExpandedHeight > 0 {
            return lastExpandedHeight
        }
        return defaultExpandedTabPanelHeight
    }

    static func dragStartPanelHeight(
        isExpanded: Bool,
        currentHeight: CGFloat
    ) -> CGFloat {
        if isExpanded, currentHeight > 0 {
            return currentHeight
        }
        return collapsedTabStripHeight
    }

    static func maxExpandedTabPanelHeight(totalHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - minChatPanelHeight)
    }

    static func effectiveMinExpandedTabPanelHeight(totalHeight: CGFloat) -> CGFloat {
        let maxHeight = maxExpandedTabPanelHeight(totalHeight: totalHeight)
        guard maxHeight > 0 else { return 0 }
        return min(minExpandedTabPanelHeight, maxHeight)
    }

    static func clampedExpandedHeight(_ height: CGFloat, totalHeight: CGFloat) -> CGFloat {
        let maxHeight = maxExpandedTabPanelHeight(totalHeight: totalHeight)
        guard maxHeight > 0 else { return 0 }
        let minHeight = effectiveMinExpandedTabPanelHeight(totalHeight: totalHeight)
        return min(max(height, minHeight), maxHeight)
    }

    static func shouldExpand(candidateHeight: CGFloat, totalHeight: CGFloat) -> Bool {
        candidateHeight >= effectiveMinExpandedTabPanelHeight(totalHeight: totalHeight)
    }
}
#endif
