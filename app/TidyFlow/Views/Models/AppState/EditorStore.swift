import Foundation
import Combine

struct EditorRequestKey: Hashable {
    let project: String
    let workspace: String
    let path: String
}

enum EditorDocumentLoadStatus: Equatable {
    case idle
    case loading
    case ready
    case error(String)
}

enum EditorConflictState: Equatable {
    case none
    case changedOnDisk
    case deletedOnDisk
}

struct EditorDocumentState: Equatable {
    let path: String
    var content: String
    var originalContentHash: Int
    var isDirty: Bool
    var lastLoadedAt: Date
    var status: EditorDocumentLoadStatus
    var conflictState: EditorConflictState

    static func loading(path: String) -> EditorDocumentState {
        EditorDocumentState(
            path: path,
            content: "",
            originalContentHash: 0,
            isDirty: false,
            lastLoadedAt: .distantPast,
            status: .loading,
            conflictState: .none
        )
    }
}

struct DiffNavigationContext: Equatable {
    let workspaceKey: String
    let path: String
    let mode: DiffMode
}

/// 编辑器领域状态管理
/// 从 AppState 提取，减少编辑器状态变化对全局视图的影响
class EditorStore: ObservableObject {
    /// 上次操作的编辑器文件路径
    @Published var lastEditorPath: String?

    /// 编辑器状态栏文本
    @Published var editorStatus: String = ""

    /// 编辑器状态是否为错误
    @Published var editorStatusIsError: Bool = false

    /// 待执行的编辑器行跳转 (path, line, highlightMs)
    @Published var pendingEditorReveal: (path: String, line: Int, highlightMs: Int)?

    /// 未保存更改确认对话框
    @Published var showUnsavedChangesAlert: Bool = false

    /// 待关闭的 Tab ID（未保存确认流程中）
    var pendingCloseTabId: UUID?
    /// 待关闭的工作空间 key
    var pendingCloseWorkspaceKey: String?
    /// 保存后自动关闭的 Tab 信息
    var pendingCloseAfterSave: (workspaceKey: String, tabId: UUID)?

    /// 文档缓存（key: globalWorkspaceKey -> (path -> state)）
    @Published var editorDocumentsByWorkspace: [String: [String: EditorDocumentState]] = [:]

    /// 正在进行的读取请求
    var pendingFileReadRequests: Set<EditorRequestKey> = []
    /// 正在进行的保存请求
    var pendingFileWriteRequests: Set<EditorRequestKey> = []
    /// 最近一次 diff 跳转上下文
    @Published var lastDiffNavigationContext: DiffNavigationContext?

    // MARK: - 撤销/重做状态

    /// 当前活跃编辑器是否可撤销（最近一次 updateUndoRedoState 的值）
    @Published var canUndo: Bool = false
    /// 当前活跃编辑器是否可重做（最近一次 updateUndoRedoState 的值）
    @Published var canRedo: Bool = false

    /// 按文档键记录的撤销/重做能力（key: globalWorkspaceKey:path）。
    /// 用于在多文档场景中判断特定文档的历史状态，不作为 UI 驱动主来源。
    private var documentUndoRedoState: [String: (canUndo: Bool, canRedo: Bool)] = [:]

    // MARK: - 新建文件状态

    /// 新建文件计数器（用于生成 "Untitled-1", "Untitled-2" 等）
    var untitledFileCounter: Int = 0

    /// 另存为面板是否显示
    @Published var showSaveAsPanel: Bool = false
    /// 查找替换面板是否显示
    @Published var showFindReplacePanel: Bool = false
    /// 待另存为的文件路径
    var pendingSaveAsPath: String?
    /// 待另存为的工作空间 key
    var pendingSaveAsWorkspaceKey: String?

    // MARK: - 回调

    /// 编辑器 Tab 关闭回调：(path)
    var onEditorTabClose: ((String) -> Void)?
    /// 编辑器文件磁盘变化回调：(project, workspace, paths, isDirtyFlags, kind)
    var onEditorFileChanged: ((String, String, [String], [Bool], String) -> Void)?

    /// 编辑器撤销回调
    var onEditorUndo: (() -> Void)?
    /// 编辑器重做回调
    var onEditorRedo: (() -> Void)?

    // MARK: - 编辑器状态方法

    /// 保存成功后更新状态
    func handleEditorSaved(path: String, closeAction: (() -> Void)? = nil) {
        editorStatus = "Saved"
        editorStatusIsError = false

        // 如果有待关闭的 Tab（保存后关闭流程），执行关闭
        if pendingCloseAfterSave != nil {
            pendingCloseAfterSave = nil
            closeAction?()
        }

        // 3 秒后清除状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.editorStatus == "Saved" {
                self?.editorStatus = ""
            }
        }
    }

    /// 保存失败后更新状态
    func handleEditorSaveError(path: String, message: String) {
        editorStatus = "Error: \(message)"
        editorStatusIsError = true
        pendingCloseAfterSave = nil
    }

    /// 开始保存流程
    func beginSave(path: String) {
        lastEditorPath = path
        editorStatus = "Saving..."
        editorStatusIsError = false
    }

    // MARK: - 撤销/重做方法

    /// 请求撤销操作
    func requestUndo() {
        onEditorUndo?()
    }

    /// 请求重做操作
    func requestRedo() {
        onEditorRedo?()
    }

    /// 更新撤销/重做状态（由编辑器视图调用）
    func updateUndoRedoState(canUndo: Bool, canRedo: Bool) {
        self.canUndo = canUndo
        self.canRedo = canRedo
    }

    /// 更新指定文档的撤销/重做状态（多文档场景，按 workspaceKey:path 记录）
    func updateUndoRedoState(canUndo: Bool, canRedo: Bool, workspaceKey: String, path: String) {
        self.canUndo = canUndo
        self.canRedo = canRedo
        let docKey = "\(workspaceKey):\(path)"
        documentUndoRedoState[docKey] = (canUndo: canUndo, canRedo: canRedo)
    }

    /// 查询指定文档的撤销能力（关闭文档后释放记录）
    func canUndo(workspaceKey: String, path: String) -> Bool {
        documentUndoRedoState["\(workspaceKey):\(path)"]?.canUndo ?? false
    }

    /// 查询指定文档的重做能力
    func canRedo(workspaceKey: String, path: String) -> Bool {
        documentUndoRedoState["\(workspaceKey):\(path)"]?.canRedo ?? false
    }

    /// 释放指定文档的撤销/重做历史记录（关闭 Tab 或强制重载时调用）
    func releaseDocumentUndoHistory(workspaceKey: String, path: String) {
        documentUndoRedoState.removeValue(forKey: "\(workspaceKey):\(path)")
    }

    /// 释放指定工作区下所有文档的撤销/重做历史记录（关闭工作区时调用）
    func releaseAllDocumentUndoHistory(workspaceKey: String) {
        let prefix = "\(workspaceKey):"
        documentUndoRedoState = documentUndoRedoState.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - 工作区级未保存状态查询

    /// 指定工作区内是否存在未保存的文档（工作区级关闭保护入口）
    func hasDirtyDocuments(workspaceKey: String) -> Bool {
        guard let docs = editorDocumentsByWorkspace[workspaceKey] else { return false }
        return docs.values.contains { $0.isDirty }
    }

    /// 指定工作区内未保存文档数量
    func dirtyDocumentCount(workspaceKey: String) -> Int {
        guard let docs = editorDocumentsByWorkspace[workspaceKey] else { return 0 }
        return docs.values.filter { $0.isDirty }.count
    }

    /// 指定工作区内所有未保存文档的路径列表
    func dirtyDocumentPaths(workspaceKey: String) -> [String] {
        guard let docs = editorDocumentsByWorkspace[workspaceKey] else { return [] }
        return docs.values.filter { $0.isDirty }.map { $0.path }
    }

    // MARK: - 新建文件方法

    /// 生成新的未命名文件标题
    func generateUntitledFileName() -> String {
        untitledFileCounter += 1
        return "Untitled-\(untitledFileCounter)"
    }

    /// 重置未命名文件计数器（新项目/工作空间时）
    func resetUntitledCounter() {
        untitledFileCounter = 0
    }
}
