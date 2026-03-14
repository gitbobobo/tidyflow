import XCTest
@testable import TidyFlow
@testable import TidyFlowShared

#if os(macOS)

/// EditorStore 测试：覆盖按文档记录 undo/redo 能力、文档关闭后释放状态、
/// 按工作区聚合 dirty 文档。
final class EditorStoreTests: XCTestCase {

    private func makeStore() -> EditorStore {
        EditorStore()
    }

    private func makeSession(
        project: String = "proj",
        workspace: String = "main",
        path: String = "file.txt",
        content: String = "hello",
        isDirty: Bool = false,
        loadStatus: EditorDocumentLoadStatus = .ready
    ) -> EditorDocumentSession {
        let key = EditorDocumentKey(project: project, workspace: workspace, path: path)
        return EditorDocumentSession(
            key: key,
            content: content,
            baselineContentHash: isDirty ? 0 : content.hashValue,
            isDirty: isDirty,
            loadStatus: loadStatus
        )
    }

    // MARK: - 撤销/重做状态

    func testUpdateUndoRedoStateForDocument() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = [
            "f.txt": makeSession(path: "f.txt")
        ]

        store.updateUndoRedoState(canUndo: true, canRedo: false, documentKey: docKey)

        XCTAssertTrue(store.canUndo(documentKey: docKey))
        XCTAssertFalse(store.canRedo(documentKey: docKey))
    }

    func testCanUndoReturnsFalseForUnknownDocument() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "unknown.txt")
        XCTAssertFalse(store.canUndo(documentKey: docKey))
        XCTAssertFalse(store.canRedo(documentKey: docKey))
    }

    // MARK: - 文档关闭后释放状态

    func testReleaseDocumentSessionClearsFindReplaceState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        store.findReplaceStateByDocument[docKey] = EditorFindReplaceState(findText: "test", isVisible: true)

        store.releaseDocumentSession(workspaceKey: "proj:main", path: "f.txt")

        XCTAssertNil(store.findReplaceStateByDocument[docKey])
    }

    func testReleaseAllDocumentSessionsClearsWorkspaceSessions() {
        let store = makeStore()
        let docKeyA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.txt")
        let docKeyB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.txt")
        let docKeyC = EditorDocumentKey(project: "proj", workspace: "dev", path: "c.txt")

        store.findReplaceStateByDocument[docKeyA] = EditorFindReplaceState(findText: "a")
        store.findReplaceStateByDocument[docKeyB] = EditorFindReplaceState(findText: "b")
        store.findReplaceStateByDocument[docKeyC] = EditorFindReplaceState(findText: "c")

        store.releaseAllDocumentSessions(workspaceKey: "proj:main")

        XCTAssertNil(store.findReplaceStateByDocument[docKeyA])
        XCTAssertNil(store.findReplaceStateByDocument[docKeyB])
        // 不同工作区的会话不受影响
        XCTAssertNotNil(store.findReplaceStateByDocument[docKeyC])
    }

    // MARK: - 按工作区聚合 dirty 文档

    func testHasDirtyDocumentsReturnsTrueWhenDirtyExists() {
        let store = makeStore()
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = [
            "a.txt": makeSession(path: "a.txt", isDirty: false),
            "b.txt": makeSession(path: "b.txt", isDirty: true),
        ]
        XCTAssertTrue(store.hasDirtyDocuments(workspaceKey: wsKey))
    }

    func testHasDirtyDocumentsReturnsFalseWhenAllClean() {
        let store = makeStore()
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = [
            "a.txt": makeSession(path: "a.txt", isDirty: false),
            "b.txt": makeSession(path: "b.txt", isDirty: false),
        ]
        XCTAssertFalse(store.hasDirtyDocuments(workspaceKey: wsKey))
    }

    func testDirtyDocumentCount() {
        let store = makeStore()
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = [
            "a.txt": makeSession(path: "a.txt", isDirty: true),
            "b.txt": makeSession(path: "b.txt", isDirty: true),
            "c.txt": makeSession(path: "c.txt", isDirty: false),
        ]
        XCTAssertEqual(store.dirtyDocumentCount(workspaceKey: wsKey), 2)
    }

    func testDirtyDocumentPaths() {
        let store = makeStore()
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = [
            "a.txt": makeSession(path: "a.txt", isDirty: true),
            "b.txt": makeSession(path: "b.txt", isDirty: false),
        ]
        let paths = store.dirtyDocumentPaths(workspaceKey: wsKey)
        XCTAssertEqual(paths, ["a.txt"])
    }

    func testDirtyDocumentsIsolatedBetweenWorkspaces() {
        let store = makeStore()
        store.editorDocumentsByWorkspace["proj:main"] = [
            "a.txt": makeSession(workspace: "main", path: "a.txt", isDirty: true),
        ]
        store.editorDocumentsByWorkspace["proj:dev"] = [
            "a.txt": makeSession(workspace: "dev", path: "a.txt", isDirty: false),
        ]
        XCTAssertTrue(store.hasDirtyDocuments(workspaceKey: "proj:main"))
        XCTAssertFalse(store.hasDirtyDocuments(workspaceKey: "proj:dev"))
    }

    // MARK: - 查找替换

    func testFindReplaceStateDefaultsForUnknownDocument() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        let state = store.findReplaceState(for: docKey)
        XCTAssertEqual(state, EditorFindReplaceState())
    }

    func testPresentFindReplaceSetsVisible() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        store.presentFindReplace(documentKey: docKey)
        XCTAssertTrue(store.findReplaceState(for: docKey).isVisible)
    }

    func testDismissFindReplaceClearsVisible() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        store.presentFindReplace(documentKey: docKey)
        store.dismissFindReplace(documentKey: docKey)
        XCTAssertFalse(store.findReplaceState(for: docKey).isVisible)
    }

    func testFindReplaceStatePerDocumentIsolation() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.txt")
        let docB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.txt")

        store.updateFindReplaceState(EditorFindReplaceState(findText: "alpha", isVisible: true), for: docA)
        store.updateFindReplaceState(EditorFindReplaceState(findText: "beta", isVisible: false), for: docB)

        XCTAssertEqual(store.findReplaceState(for: docA).findText, "alpha")
        XCTAssertTrue(store.findReplaceState(for: docA).isVisible)
        XCTAssertEqual(store.findReplaceState(for: docB).findText, "beta")
        XCTAssertFalse(store.findReplaceState(for: docB).isVisible)
    }

    // MARK: - 新建文件

    func testGenerateUntitledFileName() {
        let store = makeStore()
        XCTAssertEqual(store.generateUntitledFileName(), "Untitled-1")
        XCTAssertEqual(store.generateUntitledFileName(), "Untitled-2")
    }

    func testResetUntitledCounter() {
        let store = makeStore()
        _ = store.generateUntitledFileName()
        store.resetUntitledCounter()
        XCTAssertEqual(store.generateUntitledFileName(), "Untitled-1")
    }

    // MARK: - 折叠状态

    func testFoldingStateDefaultsForUnknownDocument() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        let state = store.foldingState(for: docKey)
        XCTAssertEqual(state, EditorCodeFoldingState())
        XCTAssertTrue(state.collapsedRegionIDs.isEmpty)
    }

    func testUpdateFoldingStatePersists() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(EditorFoldRegionID(startLine: 0, endLine: 3, kind: .braces))
        store.updateFoldingState(state, for: docKey)

        let retrieved = store.foldingState(for: docKey)
        XCTAssertEqual(retrieved.collapsedRegionIDs.count, 1)
    }

    func testReleaseFoldingStateOnDocumentClose() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(EditorFoldRegionID(startLine: 0, endLine: 3, kind: .braces))
        store.updateFoldingState(state, for: docKey)

        store.releaseDocumentSession(workspaceKey: "proj:main", path: "f.swift")

        XCTAssertTrue(store.foldingState(for: docKey).collapsedRegionIDs.isEmpty)
    }

    func testReleaseAllDocumentSessionsClearsFoldingState() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.swift")
        let docB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.swift")
        let docC = EditorDocumentKey(project: "proj", workspace: "dev", path: "c.swift")

        let regionID = EditorFoldRegionID(startLine: 0, endLine: 3, kind: .braces)
        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(regionID)

        store.updateFoldingState(state, for: docA)
        store.updateFoldingState(state, for: docB)
        store.updateFoldingState(state, for: docC)

        store.releaseAllDocumentSessions(workspaceKey: "proj:main")

        XCTAssertTrue(store.foldingState(for: docA).collapsedRegionIDs.isEmpty)
        XCTAssertTrue(store.foldingState(for: docB).collapsedRegionIDs.isEmpty)
        // 不同工作区不受影响
        XCTAssertFalse(store.foldingState(for: docC).collapsedRegionIDs.isEmpty)
    }

    func testFoldingStatePerDocumentIsolation() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.swift")
        let docB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.swift")

        var stateA = EditorCodeFoldingState()
        stateA.collapsedRegionIDs.insert(EditorFoldRegionID(startLine: 0, endLine: 5, kind: .braces))
        store.updateFoldingState(stateA, for: docA)

        XCTAssertEqual(store.foldingState(for: docA).collapsedRegionIDs.count, 1)
        XCTAssertEqual(store.foldingState(for: docB).collapsedRegionIDs.count, 0)
    }

    func testFoldingStateIsolatedBetweenWorkspaces() {
        let store = makeStore()
        let docMain = EditorDocumentKey(project: "proj", workspace: "main", path: "file.swift")
        let docDev = EditorDocumentKey(project: "proj", workspace: "dev", path: "file.swift")

        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(EditorFoldRegionID(startLine: 0, endLine: 3, kind: .braces))
        store.updateFoldingState(state, for: docMain)

        XCTAssertFalse(store.foldingState(for: docMain).collapsedRegionIDs.isEmpty)
        XCTAssertTrue(store.foldingState(for: docDev).collapsedRegionIDs.isEmpty,
                       "同名路径在不同工作区的折叠状态应隔离")
    }

    func testFoldingStateIsolatedBetweenProjects() {
        let store = makeStore()
        let docProj1 = EditorDocumentKey(project: "proj1", workspace: "main", path: "file.swift")
        let docProj2 = EditorDocumentKey(project: "proj2", workspace: "main", path: "file.swift")

        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(EditorFoldRegionID(startLine: 0, endLine: 3, kind: .braces))
        store.updateFoldingState(state, for: docProj1)

        XCTAssertFalse(store.foldingState(for: docProj1).collapsedRegionIDs.isEmpty)
        XCTAssertTrue(store.foldingState(for: docProj2).collapsedRegionIDs.isEmpty,
                       "同名路径在不同项目的折叠状态应隔离")
    }
}
#endif
