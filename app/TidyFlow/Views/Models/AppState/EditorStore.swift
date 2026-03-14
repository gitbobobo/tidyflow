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

    // MARK: - 按文档记录的编辑历史状态

    /// 每个文档独立的编辑历史状态，按文档键索引。
    /// 历史状态是运行时状态，不持久化。
    var historyStateByDocument: [EditorDocumentKey: EditorUndoHistoryState] = [:]

    /// 共享编辑历史配置（集中管理，不在各端分叉）
    let historyConfiguration = EditorUndoHistoryConfiguration.default

    // MARK: - 按文档记录的折叠状态

    /// 每个文档独立的代码折叠状态，按文档键索引。
    /// 折叠状态是运行时展示层状态，不持久化，不混入 Core 生命周期模型。
    @Published var foldingStateByDocument: [EditorDocumentKey: EditorCodeFoldingState] = [:]

    // MARK: - 按文档记录的 gutter 状态

    /// 每个文档独立的 gutter 运行时状态，按文档键索引。
    /// gutter 状态是纯展示层运行时状态，与查找替换、折叠状态同级，不持久化。
    @Published var gutterStateByDocument: [EditorDocumentKey: EditorGutterState] = [:]

    // MARK: - 按文档记录的自动补全状态

    /// 每个文档独立的自动补全运行时状态，按文档键索引。
    /// 补全状态与查找/折叠/gutter 同级，是纯展示层运行时状态，不持久化。
    @Published var autocompleteStateByDocument: [EditorDocumentKey: EditorAutocompleteState] = [:]

    // MARK: - 按文档记录的 minimap/viewport 状态

    /// 每个文档独立的视口运行时状态，按文档键索引。
    /// viewport 状态是纯展示层运行时状态，与折叠/gutter 同级，不持久化，不混入 Core 生命周期模型。
    @Published var viewportStateByDocument: [EditorDocumentKey: EditorViewportState] = [:]

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

    // MARK: - 撤销/重做方法（共享历史语义层驱动）

    /// 记录一次编辑命令到指定文档的共享历史栈。
    /// 返回记录后的结果（含新文本和选区），调用方负责回写到视图。
    func recordEdit(
        currentText: String,
        command: EditorEditCommand,
        documentKey: EditorDocumentKey
    ) -> EditorHistoryApplyResult {
        let history = historyStateByDocument[documentKey] ?? .empty
        let result = EditorUndoHistorySemantics.recordEdit(
            currentText: currentText,
            history: history,
            command: command,
            configuration: historyConfiguration
        )
        historyStateByDocument[documentKey] = result.history
        updateUndoRedoState(canUndo: result.canUndo, canRedo: result.canRedo, documentKey: documentKey)
        return result
    }

    /// 执行指定文档的撤销操作。
    /// 返回撤销结果（含恢复的文本和选区），调用方负责回写到视图。
    func undoEdit(documentKey: EditorDocumentKey, currentText: String) -> EditorHistoryApplyResult? {
        let history = historyStateByDocument[documentKey] ?? .empty
        guard let result = EditorUndoHistorySemantics.undo(currentText: currentText, history: history) else { return nil }
        historyStateByDocument[documentKey] = result.history
        updateUndoRedoState(canUndo: result.canUndo, canRedo: result.canRedo, documentKey: documentKey)
        return result
    }

    /// 执行指定文档的重做操作。
    /// 返回重做结果（含新文本和选区），调用方负责回写到视图。
    func redoEdit(documentKey: EditorDocumentKey, currentText: String) -> EditorHistoryApplyResult? {
        let history = historyStateByDocument[documentKey] ?? .empty
        guard let result = EditorUndoHistorySemantics.redo(currentText: currentText, history: history) else { return nil }
        historyStateByDocument[documentKey] = result.history
        updateUndoRedoState(canUndo: result.canUndo, canRedo: result.canRedo, documentKey: documentKey)
        return result
    }

    /// 重置指定文档的编辑历史（加载/重载后调用）
    func resetHistory(documentKey: EditorDocumentKey) {
        historyStateByDocument[documentKey] = EditorDocumentSession.historyAfterLoad()
        updateUndoRedoState(canUndo: false, canRedo: false, documentKey: documentKey)
    }

    /// 迁移文档运行时状态（另存为/重命名时将旧 key 状态移到新 key）
    func migrateDocumentRuntimeState(from oldKey: EditorDocumentKey, to newKey: EditorDocumentKey) {
        // 迁移历史
        if let oldHistory = historyStateByDocument.removeValue(forKey: oldKey) {
            historyStateByDocument[newKey] = EditorDocumentSession.historyAfterSaveAs(
                history: oldHistory, from: oldKey, to: newKey
            )
        }
        // 迁移查找替换状态
        if let fr = findReplaceStateByDocument.removeValue(forKey: oldKey) {
            findReplaceStateByDocument[newKey] = fr
        }
        // 迁移折叠状态
        if let fs = foldingStateByDocument.removeValue(forKey: oldKey) {
            foldingStateByDocument[newKey] = fs
        }
        // 迁移 gutter 状态
        if let gs = gutterStateByDocument.removeValue(forKey: oldKey) {
            gutterStateByDocument[newKey] = gs
        }
        // 迁移补全状态（通常迁移后重置即可）
        autocompleteStateByDocument.removeValue(forKey: oldKey)
        // 迁移 viewport 状态
        if let vs = viewportStateByDocument.removeValue(forKey: oldKey) {
            viewportStateByDocument[newKey] = vs
        }
    }

    /// 请求指定文档的撤销操作（回调到编辑器视图执行实际回放）
    func requestUndo(documentKey: EditorDocumentKey) {
        onEditorUndo?(documentKey)
    }

    /// 请求指定文档的重做操作（回调到编辑器视图执行实际回放）
    func requestRedo(documentKey: EditorDocumentKey) {
        onEditorRedo?(documentKey)
    }

    /// 更新指定文档的撤销/重做状态（由共享历史操作或编辑器视图回调触发）
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
            foldingStateByDocument.removeValue(forKey: docKey)
            gutterStateByDocument.removeValue(forKey: docKey)
            historyStateByDocument.removeValue(forKey: docKey)
            autocompleteStateByDocument.removeValue(forKey: docKey)
            viewportStateByDocument.removeValue(forKey: docKey)
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
        let foldKeysToRemove = foldingStateByDocument.keys.filter {
            "\($0.project):\($0.workspace)" == workspaceKey
        }
        for key in foldKeysToRemove {
            foldingStateByDocument.removeValue(forKey: key)
        }
        let gutterKeysToRemove = gutterStateByDocument.keys.filter {
            "\($0.project):\($0.workspace)" == workspaceKey
        }
        for key in gutterKeysToRemove {
            gutterStateByDocument.removeValue(forKey: key)
        }
        let historyKeysToRemove = historyStateByDocument.keys.filter {
            "\($0.project):\($0.workspace)" == workspaceKey
        }
        for key in historyKeysToRemove {
            historyStateByDocument.removeValue(forKey: key)
        }
        let autocompleteKeysToRemove = autocompleteStateByDocument.keys.filter {
            "\($0.project):\($0.workspace)" == workspaceKey
        }
        for key in autocompleteKeysToRemove {
            autocompleteStateByDocument.removeValue(forKey: key)
        }
        let viewportKeysToRemove = viewportStateByDocument.keys.filter {
            "\($0.project):\($0.workspace)" == workspaceKey
        }
        for key in viewportKeysToRemove {
            viewportStateByDocument.removeValue(forKey: key)
        }
    }

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

    // MARK: - 折叠状态方法

    /// 获取指定文档的折叠状态（没有则返回默认状态）
    func foldingState(for documentKey: EditorDocumentKey) -> EditorCodeFoldingState {
        foldingStateByDocument[documentKey] ?? EditorCodeFoldingState()
    }

    /// 更新指定文档的折叠状态
    func updateFoldingState(_ state: EditorCodeFoldingState, for documentKey: EditorDocumentKey) {
        foldingStateByDocument[documentKey] = state
    }

    /// 释放指定文档的折叠状态
    func releaseFoldingState(for documentKey: EditorDocumentKey) {
        foldingStateByDocument.removeValue(forKey: documentKey)
    }

    /// 释放指定工作区下所有文档的折叠状态
    func releaseAllFoldingStates(workspaceKey: String) {
        let keysToRemove = foldingStateByDocument.keys.filter {
            "\($0.project):\($0.workspace)" == workspaceKey
        }
        for key in keysToRemove {
            foldingStateByDocument.removeValue(forKey: key)
        }
    }

    // MARK: - Gutter 状态方法

    /// 获取指定文档的 gutter 状态（没有则返回默认状态）
    func gutterState(for documentKey: EditorDocumentKey) -> EditorGutterState {
        gutterStateByDocument[documentKey] ?? EditorGutterState()
    }

    /// 更新指定文档的 gutter 状态
    func updateGutterState(_ state: EditorGutterState, for documentKey: EditorDocumentKey) {
        gutterStateByDocument[documentKey] = state
    }

    /// 切换指定文档指定行的断点
    func toggleBreakpoint(line: Int, for documentKey: EditorDocumentKey) {
        var state = gutterState(for: documentKey)
        state.breakpoints.toggle(line: line)
        gutterStateByDocument[documentKey] = state
    }

    /// 更新指定文档的当前行
    func updateCurrentLine(_ line: Int?, for documentKey: EditorDocumentKey) {
        var state = gutterState(for: documentKey)
        state.currentLine = line
        gutterStateByDocument[documentKey] = state
    }

    // MARK: - 自动补全状态方法

    /// 获取指定文档的自动补全状态（没有则返回隐藏状态）
    func autocompleteState(for documentKey: EditorDocumentKey) -> EditorAutocompleteState {
        autocompleteStateByDocument[documentKey] ?? .hidden
    }

    /// 更新指定文档的自动补全状态
    func updateAutocompleteState(_ state: EditorAutocompleteState, for documentKey: EditorDocumentKey) {
        autocompleteStateByDocument[documentKey] = state
    }

    /// 重置指定文档的自动补全状态（隐藏面板）
    func resetAutocompleteState(for documentKey: EditorDocumentKey) {
        autocompleteStateByDocument[documentKey] = .hidden
    }

    /// 接受候选后，通过共享 replacement 规则返回新文本与新选区集合。
    /// 平台桥接层调用此方法获取结果后写回编辑器。
    /// 自动补全只作用于主选区，接受补全后清空附加选区。
    func applyAcceptedAutocomplete(
        _ item: EditorAutocompleteItem,
        for documentKey: EditorDocumentKey,
        currentText: String
    ) -> (text: String, selections: EditorSelectionSet)? {
        let state = autocompleteState(for: documentKey)
        let replacement = EditorAutocompleteEngine.replacement(for: item, state: state)

        let nsText = currentText as NSString
        let range = NSRange(location: replacement.rangeLocation, length: replacement.rangeLength)

        guard range.location >= 0,
              range.location + range.length <= nsText.length else {
            return nil
        }

        let newText = nsText.replacingCharacters(in: range, with: replacement.replacementText)
        let selections = EditorSelectionSet.single(location: replacement.caretLocation, length: 0)

        // 重置补全状态
        resetAutocompleteState(for: documentKey)

        return (text: newText, selections: selections)
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

    // MARK: - Viewport 状态方法

    /// 获取指定文档的视口状态（没有则返回默认状态）
    func viewportState(for documentKey: EditorDocumentKey) -> EditorViewportState {
        viewportStateByDocument[documentKey] ?? EditorViewportState()
    }

    /// 更新指定文档的视口状态
    func updateViewportState(_ state: EditorViewportState, for documentKey: EditorDocumentKey) {
        viewportStateByDocument[documentKey] = state
    }

    /// 释放指定文档的视口状态
    func releaseViewportState(for documentKey: EditorDocumentKey) {
        viewportStateByDocument.removeValue(forKey: documentKey)
    }

    /// 释放指定工作区下所有文档的视口状态
    func releaseAllViewportStates(workspaceKey: String) {
        let keysToRemove = viewportStateByDocument.keys.filter {
            "\($0.project):\($0.workspace)" == workspaceKey
        }
        for key in keysToRemove {
            viewportStateByDocument.removeValue(forKey: key)
        }
    }
}
