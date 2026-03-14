import Foundation
import TidyFlowShared

// MARK: - 文档格式化命令与回调处理

extension AppState {

    /// 格式化当前激活的文档
    func formatCurrentDocument() {
        guard let globalKey = currentGlobalWorkspaceKey,
              let path = activeEditorPath,
              let session = getEditorDocument(globalWorkspaceKey: globalKey, path: path),
              session.loadStatus == .ready,
              !session.formattingState.isFormatting else { return }

        // 构建请求上下文
        let request = EditorFormattingRequestBuilder.buildDocumentRequest(session: session)

        // 标记格式化开始
        updateDocumentFormattingStarted(globalWorkspaceKey: globalKey, path: path)

        // 更新编辑器状态栏
        editorStatus = NSLocalizedString("editor.formatting", comment: "")
        editorStatusIsError = false

        // 发送 WS 请求
        wsClient.requestFileFormatExecute(context: request)
    }

    // MARK: - WS 回调处理

    /// 处理 Core 返回的格式化能力查询结果
    func handleFormatCapabilitiesResult(_ result: FileFormatCapabilitiesResult) {
        let globalKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        guard var workspaceDocs = editorDocumentsByWorkspace[globalKey],
              var session = workspaceDocs[result.path] else { return }
        session.updateFormattingCapabilities(result.capabilities)
        workspaceDocs[result.path] = session
        editorDocumentsByWorkspace[globalKey] = workspaceDocs
    }

    /// 处理 Core 返回的格式化结果
    func handleFormatResult(_ result: FileFormatResult) {
        let globalKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        guard var workspaceDocs = editorDocumentsByWorkspace[globalKey],
              var session = workspaceDocs[result.path] else { return }

        let docKey = session.key
        let formattingResult = result.toFormattingResult()
        let history = editorStore.historyStateByDocument[docKey] ?? .empty

        if let applyResult = EditorFormattingResultApplier.applyFormatResult(
            result: formattingResult,
            currentText: session.content,
            currentSelections: session.selectionSet,
            history: history
        ) {
            session.content = applyResult.text
            session.selectionSet = applyResult.selections
            session.isDirty = EditorDocumentSession.contentHash(applyResult.text) != session.baselineContentHash
            session.canUndo = applyResult.canUndo
            session.canRedo = applyResult.canRedo
            editorStore.historyStateByDocument[docKey] = applyResult.history
            editorStore.updateUndoRedoState(canUndo: applyResult.canUndo, canRedo: applyResult.canRedo, documentKey: docKey)
        }

        session.markFormattingCompleted()
        workspaceDocs[result.path] = session
        editorDocumentsByWorkspace[globalKey] = workspaceDocs

        // 更新编辑器状态栏
        editorStatus = NSLocalizedString("editor.formatted", comment: "")
        editorStatusIsError = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.editorStatus == NSLocalizedString("editor.formatted", comment: "") {
                self?.editorStatus = ""
            }
        }
    }

    /// 处理 Core 返回的格式化错误
    func handleFormatError(_ result: FileFormatErrorResult) {
        let globalKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        guard var workspaceDocs = editorDocumentsByWorkspace[globalKey],
              var session = workspaceDocs[result.path] else { return }

        let formattingError = result.toFormattingError()
        session.markFormattingFailed(error: formattingError)
        workspaceDocs[result.path] = session
        editorDocumentsByWorkspace[globalKey] = workspaceDocs

        // 更新编辑器状态栏
        editorStatus = formattingError.message ?? NSLocalizedString("editor.formatFailed", comment: "")
        editorStatusIsError = true
    }

    // MARK: - 内部辅助

    /// 标记文档格式化开始（更新会话状态）
    private func updateDocumentFormattingStarted(globalWorkspaceKey: String, path: String) {
        guard var workspaceDocs = editorDocumentsByWorkspace[globalWorkspaceKey],
              var session = workspaceDocs[path] else { return }
        session.markFormattingStarted()
        workspaceDocs[path] = session
        editorDocumentsByWorkspace[globalWorkspaceKey] = workspaceDocs
    }
}
