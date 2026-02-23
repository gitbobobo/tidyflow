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
    /// 编辑器 WebView 是否就绪
    @Published var editorWebReady: Bool = false

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

    // MARK: - 回调

    /// 编辑器 Tab 关闭回调：(path)
    var onEditorTabClose: ((String) -> Void)?
    /// 编辑器文件磁盘变化回调：(project, workspace, paths, isDirtyFlags, kind)
    var onEditorFileChanged: ((String, String, [String], [Bool], String) -> Void)?

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
}
