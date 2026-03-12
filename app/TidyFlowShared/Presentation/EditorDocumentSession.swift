import Foundation

// MARK: - 编辑器文档会话共享模型
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 定义跨 macOS/iOS 共享的编辑器文档会话状态类型。
//
// 设计约束：
// - 每个文档会话以 (project, workspace, path) 三元组精确定位，禁止仅按 path 聚合。
// - 撤销/重做状态来自文本编辑器回调，由 EditorStore 记录但不持久化。
// - dirty 状态是文档内容与磁盘基线的偏差，不依赖外部推导。
// - conflictState 来自 Core 磁盘变化通知，只消费不本地推导。

// MARK: - 文档键

/// 编辑器文档唯一标识键，以 (project, workspace, path) 三元组精确定位。
public struct EditorDocumentKey: Hashable, Equatable, Sendable {
    public let project: String
    public let workspace: String
    public let path: String

    public init(project: String, workspace: String, path: String) {
        self.project = project
        self.workspace = workspace
        self.path = path
    }

    /// 字符串表示，用于日志与调试
    public var description: String {
        "\(project):\(workspace):\(path)"
    }
}

// MARK: - 文档加载状态

/// 文档加载状态（与 Core 通信的生命周期状态）
public enum EditorDocumentLoadStatus: Equatable, Sendable {
    /// 尚未发起加载
    case idle
    /// 正在从 Core 加载
    case loading
    /// 已成功加载，内容就绪
    case ready
    /// 加载失败
    case error(String)
}

// MARK: - 文档磁盘冲突状态

/// 文档磁盘冲突状态（来自 Core 磁盘变化通知，只消费不本地推导）
public enum EditorConflictState: Equatable, Sendable {
    /// 无冲突
    case none
    /// 磁盘内容已变更（文件存在但与本地版本不一致）
    case changedOnDisk
    /// 文件已从磁盘删除
    case deletedOnDisk
}

// MARK: - 文档会话状态

/// 编辑器文档会话状态——单个打开文档的完整运行时状态。
///
/// 这是文档状态的唯一真相来源：
/// - `isDirty`：文档内容与磁盘基线的偏差标记，由保存/加载事件重置。
/// - `canUndo/canRedo`：来自文本编辑器回调，只记录当前值，不维护历史栈。
/// - `conflictState`：来自 Core 磁盘变化通知。
/// - `loadStatus`：文档与 Core 通信的生命周期状态。
///
/// Tab 上的 `isDirty` 展示应从此结构投影，而不是作为独立真源。
public struct EditorDocumentSession: Equatable, Sendable {
    /// 文档唯一标识键
    public let key: EditorDocumentKey
    /// 文档内容（供编辑器 binding）
    public var content: String
    /// 磁盘基线内容哈希（保存成功后更新，用于 isDirty 判断）
    public var baselineContentHash: Int
    /// 文档是否有未保存的修改
    public var isDirty: Bool
    /// 当前编辑器是否可撤销（来自文本编辑器回调）
    public var canUndo: Bool
    /// 当前编辑器是否可重做（来自文本编辑器回调）
    public var canRedo: Bool
    /// 上次成功加载的时间
    public var lastLoadedAt: Date
    /// 加载状态
    public var loadStatus: EditorDocumentLoadStatus
    /// 磁盘冲突状态
    public var conflictState: EditorConflictState

    public init(
        key: EditorDocumentKey,
        content: String = "",
        baselineContentHash: Int = 0,
        isDirty: Bool = false,
        canUndo: Bool = false,
        canRedo: Bool = false,
        lastLoadedAt: Date = .distantPast,
        loadStatus: EditorDocumentLoadStatus = .idle,
        conflictState: EditorConflictState = .none
    ) {
        self.key = key
        self.content = content
        self.baselineContentHash = baselineContentHash
        self.isDirty = isDirty
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.lastLoadedAt = lastLoadedAt
        self.loadStatus = loadStatus
        self.conflictState = conflictState
    }

    /// 构建"正在加载"中的初始状态
    public static func loading(key: EditorDocumentKey) -> EditorDocumentSession {
        EditorDocumentSession(key: key, loadStatus: .loading)
    }

    /// 是否需要关闭前询问（有未保存内容，或文件已从磁盘删除）
    public var requiresCloseConfirmation: Bool {
        isDirty || conflictState == .deletedOnDisk
    }
}

// MARK: - 工作区未保存决策

/// 关闭工作区/Tab 时面对未保存文档的用户决策
public enum UnsavedCloseDecision {
    /// 保存后继续关闭
    case saveAndClose
    /// 放弃更改直接关闭
    case discardAndClose
    /// 取消关闭操作
    case cancel
}
