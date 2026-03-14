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

    // MARK: - Gutter 状态

    func testGutterStateDefaultValues() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        let state = store.gutterState(for: docKey)
        XCTAssertNil(state.currentLine)
        XCTAssertTrue(state.breakpoints.isEmpty)
        XCTAssertTrue(state.showsCurrentLineHighlight)
    }

    func testUpdateCurrentLine() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        store.updateCurrentLine(5, for: docKey)
        XCTAssertEqual(store.gutterState(for: docKey).currentLine, 5)

        store.updateCurrentLine(nil, for: docKey)
        XCTAssertNil(store.gutterState(for: docKey).currentLine)
    }

    func testToggleBreakpoint() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        store.toggleBreakpoint(line: 10, for: docKey)
        XCTAssertTrue(store.gutterState(for: docKey).breakpoints.contains(line: 10))

        store.toggleBreakpoint(line: 10, for: docKey)
        XCTAssertFalse(store.gutterState(for: docKey).breakpoints.contains(line: 10))
    }

    func testGutterStatePerDocumentIsolation() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.swift")
        let docB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.swift")

        store.toggleBreakpoint(line: 5, for: docA)

        XCTAssertTrue(store.gutterState(for: docA).breakpoints.contains(line: 5))
        XCTAssertFalse(store.gutterState(for: docB).breakpoints.contains(line: 5),
                       "不同文档的断点应隔离")
    }

    func testGutterStateIsolatedBetweenWorkspaces() {
        let store = makeStore()
        let docMain = EditorDocumentKey(project: "proj", workspace: "main", path: "file.swift")
        let docDev = EditorDocumentKey(project: "proj", workspace: "dev", path: "file.swift")

        store.toggleBreakpoint(line: 3, for: docMain)
        store.updateCurrentLine(10, for: docMain)

        XCTAssertTrue(store.gutterState(for: docMain).breakpoints.contains(line: 3))
        XCTAssertFalse(store.gutterState(for: docDev).breakpoints.contains(line: 3),
                       "同名路径在不同工作区的 gutter 状态应隔离")
        XCTAssertNil(store.gutterState(for: docDev).currentLine)
    }

    func testGutterStateIsolatedBetweenProjects() {
        let store = makeStore()
        let docProj1 = EditorDocumentKey(project: "proj1", workspace: "main", path: "file.swift")
        let docProj2 = EditorDocumentKey(project: "proj2", workspace: "main", path: "file.swift")

        store.toggleBreakpoint(line: 7, for: docProj1)

        XCTAssertTrue(store.gutterState(for: docProj1).breakpoints.contains(line: 7))
        XCTAssertFalse(store.gutterState(for: docProj2).breakpoints.contains(line: 7),
                       "同名路径在不同项目的 gutter 状态应隔离")
    }

    func testReleaseDocumentClearsGutterState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        store.toggleBreakpoint(line: 5, for: docKey)
        store.updateCurrentLine(10, for: docKey)

        store.releaseDocumentSession(workspaceKey: "proj:main", path: "f.swift")

        XCTAssertTrue(store.gutterState(for: docKey).breakpoints.isEmpty,
                      "关闭文档后 gutter 状态应被释放")
        XCTAssertNil(store.gutterState(for: docKey).currentLine)
    }

    func testReleaseAllDocumentSessionsClearsGutterState() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.swift")
        let docB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.swift")
        let docC = EditorDocumentKey(project: "proj", workspace: "dev", path: "c.swift")

        store.toggleBreakpoint(line: 1, for: docA)
        store.toggleBreakpoint(line: 2, for: docB)
        store.toggleBreakpoint(line: 3, for: docC)

        store.releaseAllDocumentSessions(workspaceKey: "proj:main")

        XCTAssertTrue(store.gutterState(for: docA).breakpoints.isEmpty)
        XCTAssertTrue(store.gutterState(for: docB).breakpoints.isEmpty)
        XCTAssertFalse(store.gutterState(for: docC).breakpoints.isEmpty,
                       "不同工作区的 gutter 状态不受影响")
    }

    // MARK: - 共享编辑历史

    func testRecordEditCreatesHistoryAndUpdatesUndoRedoState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = ["f.txt": makeSession(path: "f.txt")]

        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "Hi"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 2, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let result = store.recordEdit(currentText: "", command: cmd, documentKey: docKey)
        XCTAssertEqual(result.text, "Hi")
        XCTAssertTrue(store.canUndo(documentKey: docKey))
        XCTAssertFalse(store.canRedo(documentKey: docKey))
    }

    func testUndoEditRestoresTextAndState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = ["f.txt": makeSession(path: "f.txt")]

        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "Hi"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 2, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        _ = store.recordEdit(currentText: "", command: cmd, documentKey: docKey)

        let undoResult = store.undoEdit(documentKey: docKey, currentText: "Hi")
        XCTAssertNotNil(undoResult)
        XCTAssertEqual(undoResult?.text, "")
        XCTAssertFalse(store.canUndo(documentKey: docKey))
        XCTAssertTrue(store.canRedo(documentKey: docKey))
    }

    func testRedoEditRestoresTextAndState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = ["f.txt": makeSession(path: "f.txt")]

        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "Hi"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 2, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        _ = store.recordEdit(currentText: "", command: cmd, documentKey: docKey)
        _ = store.undoEdit(documentKey: docKey, currentText: "Hi")

        let redoResult = store.redoEdit(documentKey: docKey, currentText: "")
        XCTAssertNotNil(redoResult)
        XCTAssertEqual(redoResult?.text, "Hi")
        XCTAssertTrue(store.canUndo(documentKey: docKey))
        XCTAssertFalse(store.canRedo(documentKey: docKey))
    }

    func testResetHistoryClearsUndoRedoState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = ["f.txt": makeSession(path: "f.txt")]

        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "Hi"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 2, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        _ = store.recordEdit(currentText: "", command: cmd, documentKey: docKey)
        XCTAssertTrue(store.canUndo(documentKey: docKey))

        store.resetHistory(documentKey: docKey)
        XCTAssertFalse(store.canUndo(documentKey: docKey))
        XCTAssertFalse(store.canRedo(documentKey: docKey))
    }

    func testMigrateDocumentRuntimeStateMovesHistory() {
        let store = makeStore()
        let oldKey = EditorDocumentKey(project: "proj", workspace: "main", path: "old.txt")
        let newKey = EditorDocumentKey(project: "proj", workspace: "main", path: "new.txt")
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = [
            "old.txt": makeSession(path: "old.txt"),
            "new.txt": makeSession(path: "new.txt"),
        ]

        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "X"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 1, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        _ = store.recordEdit(currentText: "", command: cmd, documentKey: oldKey)

        // 添加查找替换状态验证迁移
        store.findReplaceStateByDocument[oldKey] = EditorFindReplaceState(findText: "test")

        store.migrateDocumentRuntimeState(from: oldKey, to: newKey)

        // 旧 key 上的历史应被移除
        XCTAssertNil(store.historyStateByDocument[oldKey])
        // 新 key 上应有历史
        XCTAssertNotNil(store.historyStateByDocument[newKey])
        XCTAssertEqual(store.historyStateByDocument[newKey]?.undoStack.count, 1)
        // 查找替换状态也应迁移
        XCTAssertNil(store.findReplaceStateByDocument[oldKey])
        XCTAssertNotNil(store.findReplaceStateByDocument[newKey])
    }

    func testMultiWorkspaceHistoryIsolation() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "projA", workspace: "ws1", path: "a.txt")
        let docB = EditorDocumentKey(project: "projB", workspace: "ws2", path: "b.txt")
        store.editorDocumentsByWorkspace["projA:ws1"] = ["a.txt": makeSession(project: "projA", workspace: "ws1", path: "a.txt")]
        store.editorDocumentsByWorkspace["projB:ws2"] = ["b.txt": makeSession(project: "projB", workspace: "ws2", path: "b.txt")]

        let cmdA = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "A"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 1, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        _ = store.recordEdit(currentText: "", command: cmdA, documentKey: docA)

        // A 有历史，B 没有
        XCTAssertTrue(store.canUndo(documentKey: docA))
        XCTAssertFalse(store.canUndo(documentKey: docB))

        // 撤销 A 不影响 B
        _ = store.undoEdit(documentKey: docA, currentText: "A")
        XCTAssertFalse(store.canUndo(documentKey: docA))
        XCTAssertFalse(store.canUndo(documentKey: docB))
    }

    func testReleaseDocumentSessionClearsHistoryState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.txt")
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = ["f.txt": makeSession(path: "f.txt")]

        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "X"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 1, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        _ = store.recordEdit(currentText: "", command: cmd, documentKey: docKey)
        XCTAssertNotNil(store.historyStateByDocument[docKey])

        store.releaseDocumentSession(workspaceKey: wsKey, path: "f.txt")
        XCTAssertNil(store.historyStateByDocument[docKey])
    }

    func testReleaseAllDocumentSessionsClearsWorkspaceHistoryState() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.txt")
        let docB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.txt")
        let docC = EditorDocumentKey(project: "proj", workspace: "dev", path: "c.txt")

        store.historyStateByDocument[docA] = EditorUndoHistoryState(undoStack: [], redoStack: [])
        store.historyStateByDocument[docB] = EditorUndoHistoryState(undoStack: [], redoStack: [])
        store.historyStateByDocument[docC] = EditorUndoHistoryState(undoStack: [], redoStack: [])

        store.releaseAllDocumentSessions(workspaceKey: "proj:main")

        XCTAssertNil(store.historyStateByDocument[docA])
        XCTAssertNil(store.historyStateByDocument[docB])
        XCTAssertNotNil(store.historyStateByDocument[docC], "不同工作区的历史不受影响")
    }

    // MARK: - 补全状态

    func testAutocompleteStateDefaultHidden() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        let state = store.autocompleteState(for: docKey)
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.items.isEmpty)
    }

    func testUpdateAutocompleteStatePersists() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        let state = EditorAutocompleteState(
            isVisible: true,
            query: "gu",
            selectedIndex: 0,
            replacementRange: NSRange(location: 4, length: 2),
            items: [
                EditorAutocompleteItem(id: "kw-guard", title: "guard", insertText: "guard", kind: .languageKeyword),
            ]
        )
        store.updateAutocompleteState(state, for: docKey)
        let retrieved = store.autocompleteState(for: docKey)
        XCTAssertTrue(retrieved.isVisible)
        XCTAssertEqual(retrieved.query, "gu")
        XCTAssertEqual(retrieved.items.count, 1)
    }

    func testResetAutocompleteState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        store.updateAutocompleteState(
            EditorAutocompleteState(isVisible: true, query: "test", items: [
                EditorAutocompleteItem(id: "t", title: "test", insertText: "test", kind: .languageKeyword),
            ]),
            for: docKey
        )
        store.resetAutocompleteState(for: docKey)
        let state = store.autocompleteState(for: docKey)
        XCTAssertFalse(state.isVisible)
    }

    func testAutocompleteStatePerDocumentIsolation() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.swift")
        let docB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.swift")

        store.updateAutocompleteState(
            EditorAutocompleteState(isVisible: true, query: "alpha", items: [
                EditorAutocompleteItem(id: "a", title: "alpha", insertText: "alpha", kind: .documentSymbol),
            ]),
            for: docA
        )

        XCTAssertTrue(store.autocompleteState(for: docA).isVisible)
        XCTAssertFalse(store.autocompleteState(for: docB).isVisible,
                        "不同文档的补全状态应隔离")
    }

    func testAutocompleteStateIsolatedBetweenWorkspaces() {
        let store = makeStore()
        let docMain = EditorDocumentKey(project: "proj", workspace: "main", path: "file.swift")
        let docDev = EditorDocumentKey(project: "proj", workspace: "dev", path: "file.swift")

        store.updateAutocompleteState(
            EditorAutocompleteState(isVisible: true, query: "test"),
            for: docMain
        )

        XCTAssertTrue(store.autocompleteState(for: docMain).isVisible)
        XCTAssertFalse(store.autocompleteState(for: docDev).isVisible,
                        "同名路径在不同工作区的补全状态应隔离")
    }

    func testReleaseDocumentClearsAutocompleteState() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")
        store.updateAutocompleteState(
            EditorAutocompleteState(isVisible: true, query: "test"),
            for: docKey
        )

        store.releaseDocumentSession(workspaceKey: "proj:main", path: "f.swift")
        XCTAssertFalse(store.autocompleteState(for: docKey).isVisible,
                        "关闭文档后补全状态应被释放")
    }

    func testReleaseAllDocumentSessionsClearsAutocompleteState() {
        let store = makeStore()
        let docA = EditorDocumentKey(project: "proj", workspace: "main", path: "a.swift")
        let docB = EditorDocumentKey(project: "proj", workspace: "main", path: "b.swift")
        let docC = EditorDocumentKey(project: "proj", workspace: "dev", path: "c.swift")

        for docKey in [docA, docB, docC] {
            store.updateAutocompleteState(
                EditorAutocompleteState(isVisible: true, query: "test"),
                for: docKey
            )
        }

        store.releaseAllDocumentSessions(workspaceKey: "proj:main")

        XCTAssertFalse(store.autocompleteState(for: docA).isVisible)
        XCTAssertFalse(store.autocompleteState(for: docB).isVisible)
        XCTAssertTrue(store.autocompleteState(for: docC).isVisible,
                       "不同工作区的补全状态不受影响")
    }

    func testApplyAcceptedAutocomplete() {
        let store = makeStore()
        let docKey = EditorDocumentKey(project: "proj", workspace: "main", path: "f.swift")

        // 设置补全状态
        let state = EditorAutocompleteState(
            isVisible: true,
            query: "gu",
            selectedIndex: 0,
            replacementRange: NSRange(location: 4, length: 2),
            items: [
                EditorAutocompleteItem(id: "kw-guard", title: "guard", insertText: "guard", kind: .languageKeyword),
            ]
        )
        store.updateAutocompleteState(state, for: docKey)

        let result = store.applyAcceptedAutocomplete(
            state.items[0],
            for: docKey,
            currentText: "let gu = 1"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "let guard = 1")
        XCTAssertEqual(result?.selection.location, 9) // "let guard".count
    }

    func testMigrateDocumentRuntimeStateClearsAutocomplete() {
        let store = makeStore()
        let oldKey = EditorDocumentKey(project: "proj", workspace: "main", path: "old.txt")
        let newKey = EditorDocumentKey(project: "proj", workspace: "main", path: "new.txt")
        let wsKey = "proj:main"
        store.editorDocumentsByWorkspace[wsKey] = [
            "old.txt": makeSession(path: "old.txt"),
            "new.txt": makeSession(path: "new.txt"),
        ]

        store.updateAutocompleteState(
            EditorAutocompleteState(isVisible: true, query: "test"),
            for: oldKey
        )

        store.migrateDocumentRuntimeState(from: oldKey, to: newKey)

        // 迁移后旧 key 和新 key 的补全状态都应为空（补全不迁移，直接清除）
        XCTAssertFalse(store.autocompleteState(for: oldKey).isVisible)
    }
}
#endif
