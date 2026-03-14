import Foundation

// MARK: - 编辑器文档会话共享模型
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 定义跨 macOS/iOS 共享的编辑器文档会话状态类型。
//
// 设计约束：
// - 每个文档会话以 (project, workspace, path) 三元组精确定位，禁止仅按 path 聚合。
// - 撤销/重做能力来自共享编辑历史语义层（EditorUndoRedoSemantics），
//   由平台状态容器按 EditorDocumentKey 维护历史状态并投影 canUndo/canRedo。
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
/// - `canUndo/canRedo`：来自共享编辑历史语义层的当前能力投影。
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
    /// 当前编辑器是否可撤销（来自共享编辑历史语义层）
    public var canUndo: Bool
    /// 当前编辑器是否可重做（来自共享编辑历史语义层）
    public var canRedo: Bool
    /// 当前文档选区集合（共享状态，文档唯一真相源）
    public var selectionSet: EditorSelectionSet
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
        selectionSet: EditorSelectionSet = .zero,
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
        self.selectionSet = selectionSet
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
public enum UnsavedCloseDecision: Equatable, Sendable {
    /// 保存后继续关闭
    case saveAndClose
    /// 放弃更改直接关闭
    case discardAndClose
    /// 取消关闭操作
    case cancel
}

// MARK: - 查找替换会话状态

/// 每个文档独立的查找替换运行时状态，纯值类型，不依赖 UI 框架。
public struct EditorFindReplaceState: Equatable, Sendable {
    /// 查找文本
    public var findText: String
    /// 替换文本
    public var replaceText: String
    /// 是否大小写敏感（默认不敏感）
    public var isCaseSensitive: Bool
    /// 是否启用正则表达式（默认不启用）
    public var useRegex: Bool
    /// 查找替换面板是否可见
    public var isVisible: Bool
    /// 正则表达式编译错误（非空时表示当前正则无效，不执行查找/替换）
    public var regexError: String?

    public init(
        findText: String = "",
        replaceText: String = "",
        isCaseSensitive: Bool = false,
        useRegex: Bool = false,
        isVisible: Bool = false,
        regexError: String? = nil
    ) {
        self.findText = findText
        self.replaceText = replaceText
        self.isCaseSensitive = isCaseSensitive
        self.useRegex = useRegex
        self.isVisible = isVisible
        self.regexError = regexError
    }
}

// MARK: - 关闭保护请求

/// 待确认的关闭操作，记录具体文档键或工作区键，不依赖当前 UI 焦点。
public struct DocumentCloseRequest: Equatable, Sendable {
    /// 目标文档键（单文档关闭时非 nil）
    public let documentKey: EditorDocumentKey?
    /// 目标工作区全局键
    public let workspaceKey: String
    /// 目标 Tab ID（单文档关闭时非 nil）
    public let tabId: UUID?
    /// 关闭范围
    public let scope: CloseScope

    public enum CloseScope: Equatable, Sendable {
        /// 单个 Tab 关闭
        case singleTab
        /// 工作区级关闭
        case workspace
    }

    public init(documentKey: EditorDocumentKey?, workspaceKey: String, tabId: UUID?, scope: CloseScope) {
        self.documentKey = documentKey
        self.workspaceKey = workspaceKey
        self.tabId = tabId
        self.scope = scope
    }
}

// MARK: - EditorDocumentKey 扩展

extension EditorDocumentKey {
    /// 从 globalWorkspaceKey（格式 "project:workspace"）和 path 构建文档键。
    /// 解析失败返回 nil。
    public init?(globalWorkspaceKey: String, path: String) {
        let parts = globalWorkspaceKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        self.init(project: parts[0], workspace: parts[1], path: path)
    }
}

// MARK: - 编辑器请求键

/// 编辑器文件读写请求的去重键（project + workspace + path）。
/// 用于追踪进行中的读取/保存请求，防止重复请求和响应误归属。
public struct EditorRequestKey: Hashable, Sendable {
    public let project: String
    public let workspace: String
    public let path: String

    public init(project: String, workspace: String, path: String) {
        self.project = project
        self.workspace = workspace
        self.path = path
    }
}

// MARK: - 共享文档会话状态变换辅助 API
//
// 这些方法封装文档生命周期中的典型状态变换，
// macOS 与 iOS 共用同一套规则，避免各端各写 baseline/hash/dirty 推导逻辑。

extension EditorDocumentSession {

    /// 内容哈希计算（与 macOS AppState+FileOps 中的 contentHash 保持一致）
    public static func contentHash(_ content: String) -> Int {
        content.hashValue
    }

    /// 文档加载成功后的状态更新。
    ///
    /// 写入 content、baselineContentHash、lastLoadedAt、loadStatus = .ready、isDirty = false、conflictState = .none。
    public mutating func applyLoadSuccess(content: String, at date: Date = Date()) {
        self.content = content
        self.baselineContentHash = Self.contentHash(content)
        self.isDirty = false
        self.selectionSet = .zero
        self.lastLoadedAt = date
        self.loadStatus = .ready
        self.conflictState = .none
    }

    /// 文本编辑后的状态更新。
    ///
    /// 只更新 content、重新计算 isDirty，并在非磁盘删除状态下清除冲突标记。
    public mutating func applyContentEdit(_ newContent: String) {
        self.content = newContent
        self.isDirty = Self.contentHash(newContent) != self.baselineContentHash
        // 编辑操作清除 changedOnDisk 冲突（用户已知悉并继续编辑），
        // 但保留 deletedOnDisk（文件已不存在，用户需要明确处理）。
        if self.conflictState == .changedOnDisk {
            self.conflictState = .none
        }
    }

    /// 保存成功后的状态更新。
    ///
    /// 用当前文本刷新 baseline/hash，清掉 dirty 和冲突。
    public mutating func applySaveSuccess(at date: Date = Date()) {
        self.baselineContentHash = Self.contentHash(self.content)
        self.isDirty = false
        self.lastLoadedAt = date
        self.loadStatus = .ready
        self.conflictState = .none
    }

    /// 磁盘变化通知后的状态更新。
    ///
    /// 只更新 conflictState，不自行推导额外状态。
    public mutating func applyDiskChange(kind: EditorConflictState) {
        self.conflictState = kind
    }
}

// MARK: - 编辑历史生命周期辅助

extension EditorDocumentSession {

    /// 加载成功后重置关联历史。
    /// 调用方应在 applyLoadSuccess 后调用此方法获取清空的历史状态。
    public static func historyAfterLoad() -> EditorUndoHistoryState {
        return EditorUndoHistorySemantics.reset(history: .empty)
    }

    /// 磁盘重载后重置关联历史。
    /// 语义与 historyAfterLoad 一致——重载等价于重新加载。
    public static func historyAfterReload() -> EditorUndoHistoryState {
        return EditorUndoHistorySemantics.reset(history: .empty)
    }

    /// 另存为后迁移历史。
    /// 历史内容不变，调用方负责在状态容器中将旧 key 移到新 key。
    public static func historyAfterSaveAs(
        history: EditorUndoHistoryState,
        from oldKey: EditorDocumentKey,
        to newKey: EditorDocumentKey
    ) -> EditorUndoHistoryState {
        return EditorUndoHistorySemantics.migrate(history: history, from: oldKey, to: newKey)
    }

    /// 文件重命名后迁移历史。
    /// 与另存为语义一致。
    public static func historyAfterRename(
        history: EditorUndoHistoryState,
        from oldKey: EditorDocumentKey,
        to newKey: EditorDocumentKey
    ) -> EditorUndoHistoryState {
        return EditorUndoHistorySemantics.migrate(history: history, from: oldKey, to: newKey)
    }
}

// MARK: - 编辑器会话级命令

/// 编辑器会话级命令枚举，统一命令分发入口。
public enum EditorSessionCommand: Equatable, Sendable {
    case undo
    case redo
    case save
    case saveAs
    case presentFindReplace
    case dismissFindReplace
}
