import Foundation
import Combine
import TidyFlowShared

struct DiffNavigationContext: Equatable {
    let workspaceKey: String
    let path: String
    let mode: DiffMode
}

/// 编辑器领域状态管理
/// 从 AppState 提取，减少编辑器状态变化对全局视图的影响。
/// 文档缓存统一使用 TidyFlowShared 中的 `EditorDocumentSession`，不再维护本地重复类型。
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

    /// 当前挂起的关闭请求（携带显式文档键/工作区键，不依赖当前 UI 焦点）
    var pendingCloseRequest: DocumentCloseRequest?

    /// 保存后自动关闭的 Tab 信息
    var pendingCloseAfterSave: (workspaceKey: String, tabId: UUID)?

    /// 文档缓存（key: globalWorkspaceKey -> (path -> session)）
    /// 统一使用 EditorDocumentSession 作为文档状态唯一真源。
    @Published var editorDocumentsByWorkspace: [String: [String: EditorDocumentSession]] = [:]

    /// 正在进行的读取请求
    var pendingFileReadRequests: Set<EditorRequestKey> = []
    /// 正在进行的保存请求
    var pendingFileWriteRequests: Set<EditorRequestKey> = []
    /// 最近一次 diff 跳转上下文
    @Published var lastDiffNavigationContext: DiffNavigationContext?

    // MARK: - 按文档记录的查找替换状态

    /// 每个文档独立的查找替换状态，按文档键索引。
    /// 切换标签时保留各自查找条件；面板可见性也按文档记录。
    @Published var findReplaceStateByDocument: [EditorDocumentKey: EditorFindReplaceState] = [:]

    // MARK: - 新建文件状态

    /// 新建文件计数器（用于生成 "Untitled-1", "Untitled-2" 等）
    var untitledFileCounter: Int = 0

    /// 另存为面板是否显示
    @Published var showSaveAsPanel: Bool = false
    /// 待另存为的文件路径
    var pendingSaveAsPath: String?
    /// 待另存为的工作空间 key
    var pendingSaveAsWorkspaceKey: String?

    // MARK: - 回调

    /// 编辑器 Tab 关闭回调：(path)
    var onEditorTabClose: ((String) -> Void)?
    /// 编辑器文件磁盘变化回调：(project, workspace, paths, isDirtyFlags, kind)
    var onEditorFileChanged: ((String, String, [String], [Bool], String) -> Void)?

    /// 编辑器撤销回调（documentKey）
    var onEditorUndo: ((EditorDocumentKey) -> Void)?
    /// 编辑器重做回调（documentKey）
    var onEditorRedo: ((EditorDocumentKey) -> Void)?

    // MARK: - 编辑器状态方法

    /// 保存成功后更新状态
    func handleEditorSaved(path: String, closeAction: (() -> Void)? = nil) {
        editorStatus = "Saved"
        editorStatusIsError = false

        if pendingCloseAfterSave != nil {
            pendingCloseAfterSave = nil
            closeAction?()
        }

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

    /// 请求指定文档的撤销操作
    func requestUndo(documentKey: EditorDocumentKey) {
        onEditorUndo?(documentKey)
    }

    /// 请求指定文档的重做操作
    func requestRedo(documentKey: EditorDocumentKey) {
        onEditorRedo?(documentKey)
    }

    /// 更新指定文档的撤销/重做状态（由编辑器视图回调）
    func updateUndoRedoState(canUndo: Bool, canRedo: Bool, documentKey: EditorDocumentKey) {
        let wsKey = "\(documentKey.project):\(documentKey.workspace)"
        guard var workspaceDocs = editorDocumentsByWorkspace[wsKey],
              var session = workspaceDocs[documentKey.path] else { return }
        session.canUndo = canUndo
        session.canRedo = canRedo
        workspaceDocs[documentKey.path] = session
        editorDocumentsByWorkspace[wsKey] = workspaceDocs
    }

    /// 查询指定文档的撤销能力
    func canUndo(documentKey: EditorDocumentKey) -> Bool {
        let wsKey = "\(documentKey.project):\(documentKey.workspace)"
        return editorDocumentsByWorkspace[wsKey]?[documentKey.path]?.canUndo ?? false
    }

    /// 查询指定文档的重做能力
    func canRedo(documentKey: EditorDocumentKey) -> Bool {
        let wsKey = "\(documentKey.project):\(documentKey.workspace)"
        return editorDocumentsByWorkspace[wsKey]?[documentKey.path]?.canRedo ?? false
    }

    /// 查询当前活跃文档的撤销能力（便捷代理，用于菜单状态等全局 UI）
    func canUndoActiveDocument(workspaceKey: String, path: String) -> Bool {
        editorDocumentsByWorkspace[workspaceKey]?[path]?.canUndo ?? false
    }

    /// 查询当前活跃文档的重做能力
    func canRedoActiveDocument(workspaceKey: String, path: String) -> Bool {
        editorDocumentsByWorkspace[workspaceKey]?[path]?.canRedo ?? false
    }

    /// 释放指定文档的会话状态（关闭 Tab 时调用）
    func releaseDocumentSession(workspaceKey: String, path: String) {
        if let docKey = EditorDocumentKey(globalWorkspaceKey: workspaceKey, path: path) {
            findReplaceStateByDocument.removeValue(forKey: docKey)
        }
    }

    /// 释放指定工作区下所有文档的会话状态（关闭工作区时调用）
    func releaseAllDocumentSessions(workspaceKey: String) {
        let keysToRemove = findReplaceStateByDocument.keys.filter {
            "\($0.project):\($0.workspace)" == workspaceKey
        }
        for key in keysToRemove {
            findReplaceStateByDocument.removeValue(forKey: key)
        }
    }

    // MARK: - 查找替换方法

    /// 获取指定文档的查找替换状态（没有则返回默认状态）
    func findReplaceState(for documentKey: EditorDocumentKey) -> EditorFindReplaceState {
        findReplaceStateByDocument[documentKey] ?? EditorFindReplaceState()
    }

    /// 更新指定文档的查找替换状态
    func updateFindReplaceState(_ state: EditorFindReplaceState, for documentKey: EditorDocumentKey) {
        findReplaceStateByDocument[documentKey] = state
    }

    /// 展示指定文档的查找替换面板
    func presentFindReplace(documentKey: EditorDocumentKey) {
        var state = findReplaceState(for: documentKey)
        state.isVisible = true
        findReplaceStateByDocument[documentKey] = state
    }

    /// 关闭指定文档的查找替换面板
    func dismissFindReplace(documentKey: EditorDocumentKey) {
        var state = findReplaceState(for: documentKey)
        state.isVisible = false
        findReplaceStateByDocument[documentKey] = state
    }

    // MARK: - 工作区级未保存状态查询

    /// 指定工作区内是否存在未保存的文档
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
        return docs.values.filter { $0.isDirty }.map { $0.key.path }
    }

    // MARK: - 新建文件方法

    /// 生成新的未命名文件标题
    func generateUntitledFileName() -> String {
        untitledFileCounter += 1
        return "Untitled-\(untitledFileCounter)"
    }

    /// 重置未命名文件计数器
    func resetUntitledCounter() {
        untitledFileCounter = 0
    }
}
