import XCTest
@testable import TidyFlowShared

/// 共享文档会话测试：覆盖多项目同名工作区隔离、dirty/baseline 更新、
/// 磁盘冲突状态、关闭保护决策和新建未命名文件保存后的键迁移。
final class EditorDocumentSessionTests: XCTestCase {

    // MARK: - EditorDocumentKey 隔离

    func testDocumentKeysFromDifferentProjectsAreNotEqual() {
        let keyA = EditorDocumentKey(project: "projectA", workspace: "main", path: "src/index.ts")
        let keyB = EditorDocumentKey(project: "projectB", workspace: "main", path: "src/index.ts")
        XCTAssertNotEqual(keyA, keyB)
    }

    func testDocumentKeysFromDifferentWorkspacesAreNotEqual() {
        let keyA = EditorDocumentKey(project: "proj", workspace: "dev", path: "README.md")
        let keyB = EditorDocumentKey(project: "proj", workspace: "staging", path: "README.md")
        XCTAssertNotEqual(keyA, keyB)
    }

    func testDocumentKeyFromGlobalWorkspaceKey() {
        let key = EditorDocumentKey(globalWorkspaceKey: "myProject:devBranch", path: "lib/utils.swift")
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.project, "myProject")
        XCTAssertEqual(key?.workspace, "devBranch")
        XCTAssertEqual(key?.path, "lib/utils.swift")
    }

    func testDocumentKeyFromInvalidGlobalWorkspaceKeyReturnsNil() {
        let key = EditorDocumentKey(globalWorkspaceKey: "noColonHere", path: "file.txt")
        XCTAssertNil(key)
    }

    func testDocumentKeyDescription() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "a/b.txt")
        XCTAssertEqual(key.description, "p:w:a/b.txt")
    }

    // MARK: - EditorDocumentSession baseline/dirty

    func testNewSessionIsNotDirty() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue)
        XCTAssertFalse(session.isDirty)
    }

    func testSessionBecomesDirtyWhenContentChanges() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue)
        session.content = "hello world"
        session.isDirty = session.content.hashValue != session.baselineContentHash
        XCTAssertTrue(session.isDirty)
    }

    func testBaselineUpdateClearsDirty() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key, content: "modified", baselineContentHash: "original".hashValue, isDirty: true)
        // 模拟保存成功：更新 baseline
        session.baselineContentHash = session.content.hashValue
        session.isDirty = false
        XCTAssertFalse(session.isDirty)
    }

    // MARK: - 加载状态

    func testLoadingFactoryMethod() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession.loading(key: key)
        XCTAssertEqual(session.loadStatus, .loading)
        XCTAssertEqual(session.content, "")
        XCTAssertFalse(session.isDirty)
    }

    // MARK: - 冲突状态

    func testConflictStateChangedOnDisk() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue)
        session.conflictState = .changedOnDisk
        XCTAssertEqual(session.conflictState, .changedOnDisk)
    }

    func testConflictStateDeletedOnDisk() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue)
        session.conflictState = .deletedOnDisk
        XCTAssertEqual(session.conflictState, .deletedOnDisk)
    }

    // MARK: - 关闭保护决策

    func testCleanDocumentDoesNotRequireCloseConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue)
        XCTAssertFalse(session.requiresCloseConfirmation)
    }

    func testDirtyDocumentRequiresCloseConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "modified", baselineContentHash: "original".hashValue, isDirty: true)
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    func testDeletedOnDiskDocumentRequiresCloseConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue, conflictState: .deletedOnDisk)
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    func testCleanDeletedOnDiskDocumentRequiresCloseConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue, isDirty: false, conflictState: .deletedOnDisk)
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    // MARK: - UnsavedCloseDecision

    func testUnsavedCloseDecisionEquality() {
        XCTAssertEqual(UnsavedCloseDecision.saveAndClose, UnsavedCloseDecision.saveAndClose)
        XCTAssertNotEqual(UnsavedCloseDecision.saveAndClose, UnsavedCloseDecision.cancel)
    }

    // MARK: - EditorFindReplaceState

    func testFindReplaceStateDefaults() {
        let state = EditorFindReplaceState()
        XCTAssertEqual(state.findText, "")
        XCTAssertEqual(state.replaceText, "")
        XCTAssertFalse(state.isCaseSensitive)
        XCTAssertFalse(state.useRegex)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.regexError)
    }

    func testFindReplaceStateEquality() {
        let stateA = EditorFindReplaceState(findText: "hello", isVisible: true)
        let stateB = EditorFindReplaceState(findText: "hello", isVisible: true)
        XCTAssertEqual(stateA, stateB)
    }

    // MARK: - DocumentCloseRequest

    func testDocumentCloseRequestSingleTab() {
        let docKey = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let tabId = UUID()
        let request = DocumentCloseRequest(documentKey: docKey, workspaceKey: "p:w", tabId: tabId, scope: .singleTab)
        XCTAssertEqual(request.scope, .singleTab)
        XCTAssertEqual(request.documentKey, docKey)
        XCTAssertEqual(request.tabId, tabId)
    }

    func testDocumentCloseRequestWorkspace() {
        let request = DocumentCloseRequest(documentKey: nil, workspaceKey: "p:w", tabId: nil, scope: .workspace)
        XCTAssertEqual(request.scope, .workspace)
        XCTAssertNil(request.documentKey)
        XCTAssertNil(request.tabId)
    }

    // MARK: - EditorSessionCommand

    func testEditorSessionCommandEquality() {
        XCTAssertEqual(EditorSessionCommand.undo, EditorSessionCommand.undo)
        XCTAssertNotEqual(EditorSessionCommand.undo, EditorSessionCommand.redo)
    }

    // MARK: - 新建未命名文件保存后的键迁移

    func testUntitledFileKeyMigrationAfterSave() {
        let untitledKey = EditorDocumentKey(project: "p", workspace: "w", path: "Untitled-1")
        let savedKey = EditorDocumentKey(project: "p", workspace: "w", path: "src/new_file.swift")

        var session = EditorDocumentSession(key: untitledKey, content: "// new file", isDirty: true, loadStatus: .ready)
        // 模拟另存为：使用新键创建新会话
        let migratedSession = EditorDocumentSession(
            key: savedKey,
            content: session.content,
            baselineContentHash: session.content.hashValue,
            isDirty: false,
            lastLoadedAt: Date(),
            loadStatus: .ready,
            conflictState: .none
        )

        XCTAssertNotEqual(untitledKey, savedKey)
        XCTAssertFalse(migratedSession.isDirty)
        XCTAssertEqual(migratedSession.key.path, "src/new_file.swift")
        // 可变量消除编译警告
        session.isDirty = false
    }

    // MARK: - 共享状态变换辅助 API

    func testApplyLoadSuccessSetsCorrectState() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession.loading(key: key)
        session.applyLoadSuccess(content: "hello world")
        XCTAssertEqual(session.content, "hello world")
        XCTAssertEqual(session.loadStatus, .ready)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.conflictState, .none)
        XCTAssertEqual(session.baselineContentHash, EditorDocumentSession.contentHash("hello world"))
    }

    func testApplyContentEditMakesDirty() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")
        session.applyContentEdit("modified")
        XCTAssertEqual(session.content, "modified")
        XCTAssertTrue(session.isDirty)
    }

    func testApplyContentEditClearsChangedOnDisk() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")
        session.conflictState = .changedOnDisk
        session.applyContentEdit("modified")
        XCTAssertEqual(session.conflictState, .none)
    }

    func testApplyContentEditPreservesDeletedOnDisk() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")
        session.conflictState = .deletedOnDisk
        session.applyContentEdit("modified")
        XCTAssertEqual(session.conflictState, .deletedOnDisk)
    }

    func testApplyContentEditWithSameContentNotDirty() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "same")
        session.applyContentEdit("same")
        XCTAssertFalse(session.isDirty)
    }

    func testApplySaveSuccessClearsDirtyAndConflict() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")
        session.applyContentEdit("modified")
        XCTAssertTrue(session.isDirty)
        session.applySaveSuccess()
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.conflictState, .none)
        XCTAssertEqual(session.baselineContentHash, EditorDocumentSession.contentHash("modified"))
    }

    func testApplyDiskChange() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "hello")
        session.applyDiskChange(kind: .changedOnDisk)
        XCTAssertEqual(session.conflictState, .changedOnDisk)
        session.applyDiskChange(kind: .deletedOnDisk)
        XCTAssertEqual(session.conflictState, .deletedOnDisk)
    }

    // MARK: - EditorRequestKey

    func testEditorRequestKeyEquality() {
        let a = EditorRequestKey(project: "p", workspace: "w", path: "f.txt")
        let b = EditorRequestKey(project: "p", workspace: "w", path: "f.txt")
        let c = EditorRequestKey(project: "p", workspace: "w2", path: "f.txt")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
