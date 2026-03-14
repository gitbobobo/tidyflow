import XCTest
@testable import TidyFlowShared

/// iOS 编辑器会话状态测试：覆盖文档打开/保存、dirty 重置、
/// 脏文档返回确认、多工作区隔离、查找面板状态隔离和磁盘冲突状态流转。
///
/// 这些测试不依赖 MobileAppState（因为它是 iOS target 私有类型），
/// 而是验证共享 EditorDocumentSession 在 iOS 编辑器场景下的行为正确性。
final class MobileEditorSessionTests: XCTestCase {

    // MARK: - 文档打开（模拟 openEditorDocument 路径）

    func testDocumentOpenCreatesLoadingSession() {
        let key = EditorDocumentKey(project: "myApp", workspace: "main", path: "src/index.ts")
        let session = EditorDocumentSession.loading(key: key)
        XCTAssertEqual(session.loadStatus, .loading)
        XCTAssertEqual(session.content, "")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.conflictState, .none)
    }

    func testDocumentLoadSuccessTransitionsToReady() {
        let key = EditorDocumentKey(project: "myApp", workspace: "main", path: "src/index.ts")
        var session = EditorDocumentSession.loading(key: key)
        session.applyLoadSuccess(content: "const x = 1;")
        XCTAssertEqual(session.loadStatus, .ready)
        XCTAssertEqual(session.content, "const x = 1;")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.baselineContentHash, EditorDocumentSession.contentHash("const x = 1;"))
    }

    // MARK: - 保存与 dirty 重置

    func testSaveSuccessResetsDirty() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")

        // 编辑使文档变脏
        session.applyContentEdit("modified content")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.content, "modified content")

        // 保存成功
        session.applySaveSuccess()
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.baselineContentHash, EditorDocumentSession.contentHash("modified content"))
    }

    func testSaveErrorDoesNotAffectSession() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")
        session.applyContentEdit("modified")

        // 保存失败时不调用 applySaveSuccess，session 保持 dirty
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.content, "modified")
    }

    // MARK: - 脏文档返回确认

    func testCleanDocumentDoesNotRequireConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "clean")
        XCTAssertFalse(session.requiresCloseConfirmation)
    }

    func testDirtyDocumentRequiresConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "clean")
        session.applyContentEdit("dirty")
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    func testDeletedOnDiskDocumentRequiresConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "hello")
        session.applyDiskChange(kind: .deletedOnDisk)
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    func testSavedDocumentDoesNotRequireConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")
        session.applyContentEdit("modified")
        XCTAssertTrue(session.requiresCloseConfirmation)
        session.applySaveSuccess()
        XCTAssertFalse(session.requiresCloseConfirmation)
    }

    // MARK: - 多工作区隔离

    func testMultiWorkspaceDocumentIsolation() {
        let keyA = EditorDocumentKey(project: "app1", workspace: "dev", path: "README.md")
        let keyB = EditorDocumentKey(project: "app2", workspace: "dev", path: "README.md")
        let keyC = EditorDocumentKey(project: "app1", workspace: "staging", path: "README.md")

        // 同名工作区不同项目
        XCTAssertNotEqual(keyA, keyB)
        // 同项目不同工作区
        XCTAssertNotEqual(keyA, keyC)

        // 模拟独立文档缓存
        var cacheA: [String: [String: EditorDocumentSession]] = [:]
        var sessionA = EditorDocumentSession(key: keyA)
        sessionA.applyLoadSuccess(content: "content A")
        cacheA["app1:dev"] = ["README.md": sessionA]

        var sessionB = EditorDocumentSession(key: keyB)
        sessionB.applyLoadSuccess(content: "content B")
        cacheA["app2:dev"] = ["README.md": sessionB]

        // 互不污染
        XCTAssertEqual(cacheA["app1:dev"]?["README.md"]?.content, "content A")
        XCTAssertEqual(cacheA["app2:dev"]?["README.md"]?.content, "content B")
    }

    // MARK: - 查找面板状态隔离

    func testFindReplaceStateIsolationPerDocument() {
        var stateStore: [EditorDocumentKey: EditorFindReplaceState] = [:]

        let keyA = EditorDocumentKey(project: "p", workspace: "w", path: "a.swift")
        let keyB = EditorDocumentKey(project: "p", workspace: "w", path: "b.swift")

        // 文档 A 打开查找面板
        stateStore[keyA] = EditorFindReplaceState(findText: "func", isVisible: true)
        // 文档 B 没有查找面板
        stateStore[keyB] = EditorFindReplaceState()

        XCTAssertTrue(stateStore[keyA]?.isVisible ?? false)
        XCTAssertFalse(stateStore[keyB]?.isVisible ?? true)
        XCTAssertEqual(stateStore[keyA]?.findText, "func")
        XCTAssertEqual(stateStore[keyB]?.findText, "")
    }

    // MARK: - 磁盘冲突状态流转

    func testChangedOnDiskConflictFlow() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")

        // 收到磁盘变化通知
        session.applyDiskChange(kind: .changedOnDisk)
        XCTAssertEqual(session.conflictState, .changedOnDisk)

        // 用户继续编辑——清除 changedOnDisk
        session.applyContentEdit("user edit")
        XCTAssertEqual(session.conflictState, .none)
        XCTAssertTrue(session.isDirty)
    }

    func testDeletedOnDiskConflictPreservedDuringEdit() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")

        // 文件被删除
        session.applyDiskChange(kind: .deletedOnDisk)
        XCTAssertEqual(session.conflictState, .deletedOnDisk)

        // 用户继续编辑——deletedOnDisk 保留
        session.applyContentEdit("still editing")
        XCTAssertEqual(session.conflictState, .deletedOnDisk)
    }

    func testReloadClearsConflict() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: "original")
        session.applyDiskChange(kind: .changedOnDisk)

        // 模拟重新加载
        session.applyLoadSuccess(content: "new content from disk")
        XCTAssertEqual(session.conflictState, .none)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.content, "new content from disk")
    }

    // MARK: - UnsavedCloseDecision 语义

    func testUnsavedCloseDecisionValues() {
        XCTAssertEqual(UnsavedCloseDecision.saveAndClose, .saveAndClose)
        XCTAssertEqual(UnsavedCloseDecision.discardAndClose, .discardAndClose)
        XCTAssertEqual(UnsavedCloseDecision.cancel, .cancel)
        XCTAssertNotEqual(UnsavedCloseDecision.saveAndClose, .cancel)
    }
}
