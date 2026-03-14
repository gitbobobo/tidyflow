import XCTest
@testable import TidyFlowShared

/// 编辑器未保存保护测试：覆盖单 Tab 关闭、工作区关闭、保存后关闭、取消关闭、
/// 磁盘删除 dirty 文档、外部修改 dirty 文档与未命名文件另存为。
final class EditorUnsavedProtectionTests: XCTestCase {

    // MARK: - requiresCloseConfirmation 语义

    func testCleanDocumentNoConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue, isDirty: false)
        XCTAssertFalse(session.requiresCloseConfirmation)
    }

    func testDirtyDocumentRequiresConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "modified", isDirty: true)
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    func testDeletedOnDiskRequiresConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue, isDirty: false, conflictState: .deletedOnDisk)
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    func testDirtyAndDeletedOnDiskRequiresConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "modified", isDirty: true, conflictState: .deletedOnDisk)
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    func testChangedOnDiskCleanDocumentNoConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "hello", baselineContentHash: "hello".hashValue, isDirty: false, conflictState: .changedOnDisk)
        // changedOnDisk + clean = 不需要确认（Core 负责重载 clean 文档）
        XCTAssertFalse(session.requiresCloseConfirmation)
    }

    func testChangedOnDiskDirtyDocumentRequiresConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let session = EditorDocumentSession(key: key, content: "modified", isDirty: true, conflictState: .changedOnDisk)
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    // MARK: - DocumentCloseRequest 语义

    func testSingleTabCloseRequest() {
        let docKey = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let tabId = UUID()
        let request = DocumentCloseRequest(documentKey: docKey, workspaceKey: "p:w", tabId: tabId, scope: .singleTab)
        XCTAssertEqual(request.scope, .singleTab)
        XCTAssertEqual(request.workspaceKey, "p:w")
        XCTAssertNotNil(request.tabId)
        XCTAssertNotNil(request.documentKey)
    }

    func testWorkspaceCloseRequest() {
        let request = DocumentCloseRequest(documentKey: nil, workspaceKey: "p:w", tabId: nil, scope: .workspace)
        XCTAssertEqual(request.scope, .workspace)
        XCTAssertNil(request.documentKey)
        XCTAssertNil(request.tabId)
    }

    func testCloseRequestEquality() {
        let docKey = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        let tabId = UUID()
        let requestA = DocumentCloseRequest(documentKey: docKey, workspaceKey: "p:w", tabId: tabId, scope: .singleTab)
        let requestB = DocumentCloseRequest(documentKey: docKey, workspaceKey: "p:w", tabId: tabId, scope: .singleTab)
        XCTAssertEqual(requestA, requestB)
    }

    // MARK: - UnsavedCloseDecision 语义

    func testSaveAndCloseDecision() {
        let decision = UnsavedCloseDecision.saveAndClose
        XCTAssertEqual(decision, .saveAndClose)
        XCTAssertNotEqual(decision, .discardAndClose)
    }

    func testDiscardAndCloseDecision() {
        let decision = UnsavedCloseDecision.discardAndClose
        XCTAssertEqual(decision, .discardAndClose)
        XCTAssertNotEqual(decision, .cancel)
    }

    func testCancelDecision() {
        let decision = UnsavedCloseDecision.cancel
        XCTAssertEqual(decision, .cancel)
        XCTAssertNotEqual(decision, .saveAndClose)
    }

    // MARK: - 保存后关闭流程（状态转换）

    func testSaveResetsBaselineAndClearsDirty() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key, content: "modified content", isDirty: true, loadStatus: .ready)

        // 模拟保存成功
        session.baselineContentHash = session.content.hashValue
        session.isDirty = false
        session.conflictState = .none

        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.requiresCloseConfirmation)
    }

    // MARK: - 磁盘删除 dirty 文档

    func testDiskDeletedDirtyDocumentStillRequiresConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key, content: "local changes", isDirty: true, loadStatus: .ready)
        // 模拟磁盘删除通知
        session.conflictState = .deletedOnDisk
        // dirty + deletedOnDisk → 必须确认
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    func testDiskDeletedCleanDocumentStillRequiresConfirmation() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key, content: "content", baselineContentHash: "content".hashValue, isDirty: false, loadStatus: .ready)
        // 模拟磁盘删除通知
        session.conflictState = .deletedOnDisk
        // clean + deletedOnDisk → 需要确认（计划规定删除的 dirty 文档继续要求确认）
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    // MARK: - 外部修改 dirty 文档

    func testExternalModificationOfDirtyDocumentSetsConflict() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.txt")
        var session = EditorDocumentSession(key: key, content: "local changes", isDirty: true, loadStatus: .ready)
        // 模拟外部修改通知
        session.conflictState = .changedOnDisk
        XCTAssertEqual(session.conflictState, .changedOnDisk)
        XCTAssertTrue(session.isDirty)
        // dirty + changedOnDisk → 需要确认（用户应选择重载或覆盖）
        XCTAssertTrue(session.requiresCloseConfirmation)
    }

    // MARK: - 未命名文件另存为

    func testUntitledFileSaveAsMigratesKey() {
        let untitledKey = EditorDocumentKey(project: "p", workspace: "w", path: "Untitled-1")
        let savedKey = EditorDocumentKey(project: "p", workspace: "w", path: "src/new.swift")

        let untitledSession = EditorDocumentSession(
            key: untitledKey,
            content: "new code",
            isDirty: true,
            loadStatus: .ready
        )

        // 另存为后创建新会话
        let savedSession = EditorDocumentSession(
            key: savedKey,
            content: untitledSession.content,
            baselineContentHash: untitledSession.content.hashValue,
            isDirty: false,
            lastLoadedAt: Date(),
            loadStatus: .ready,
            conflictState: .none
        )

        XCTAssertEqual(savedSession.key.path, "src/new.swift")
        XCTAssertFalse(savedSession.isDirty)
        XCTAssertFalse(savedSession.requiresCloseConfirmation)
    }

    // MARK: - 多工作区隔离

    func testMultipleWorkspacesWithSameFilePathAreIndependent() {
        let keyMain = EditorDocumentKey(project: "proj", workspace: "main", path: "config.json")
        let keyDev = EditorDocumentKey(project: "proj", workspace: "dev", path: "config.json")

        let sessionMain = EditorDocumentSession(key: keyMain, content: "main content", isDirty: true, loadStatus: .ready)
        let sessionDev = EditorDocumentSession(key: keyDev, content: "dev content", isDirty: false, loadStatus: .ready)

        XCTAssertTrue(sessionMain.requiresCloseConfirmation)
        XCTAssertFalse(sessionDev.requiresCloseConfirmation)
        XCTAssertNotEqual(keyMain, keyDev)
    }
}
