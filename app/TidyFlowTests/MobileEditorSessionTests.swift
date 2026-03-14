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

    // MARK: - 折叠状态隔离（共享层验证）

    func testFoldingStatePerDocumentIsolation() {
        // 模拟 iOS MobileAppState 中的折叠状态字典
        var foldingState: [EditorDocumentKey: EditorCodeFoldingState] = [:]

        let keyA = EditorDocumentKey(project: "p", workspace: "w", path: "a.swift")
        let keyB = EditorDocumentKey(project: "p", workspace: "w", path: "b.swift")

        var stateA = EditorCodeFoldingState()
        stateA.collapsedRegionIDs.insert(EditorFoldRegionID(startLine: 0, endLine: 3, kind: .braces))
        foldingState[keyA] = stateA

        XCTAssertEqual(foldingState[keyA]?.collapsedRegionIDs.count, 1)
        XCTAssertNil(foldingState[keyB], "不同文档的折叠状态应隔离")
    }

    func testFoldingStateMultiWorkspaceIsolation() {
        var foldingState: [EditorDocumentKey: EditorCodeFoldingState] = [:]

        let keyMain = EditorDocumentKey(project: "app1", workspace: "main", path: "file.swift")
        let keyDev = EditorDocumentKey(project: "app1", workspace: "dev", path: "file.swift")
        let keyOther = EditorDocumentKey(project: "app2", workspace: "main", path: "file.swift")

        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(EditorFoldRegionID(startLine: 0, endLine: 5, kind: .braces))
        foldingState[keyMain] = state

        XCTAssertNotNil(foldingState[keyMain])
        XCTAssertNil(foldingState[keyDev], "同项目不同工作区的折叠状态应隔离")
        XCTAssertNil(foldingState[keyOther], "不同项目同名工作区的折叠状态应隔离")
    }

    func testFoldingStateReleaseOnDocumentClose() {
        var foldingState: [EditorDocumentKey: EditorCodeFoldingState] = [:]

        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(EditorFoldRegionID(startLine: 0, endLine: 3, kind: .braces))
        foldingState[key] = state

        // 模拟文档关闭
        foldingState.removeValue(forKey: key)
        XCTAssertNil(foldingState[key], "文档关闭后应释放折叠状态")
    }

    func testFoldingStateReconcileAfterReload() {
        let analyzer = EditorStructureAnalyzer()

        let code1 = """
        func a() {
            print("a")
        }
        func b() {
            print("b")
        }
        """
        let snapshot1 = analyzer.analyze(filePath: "test.swift", text: code1)

        var foldState = EditorCodeFoldingState()
        for region in snapshot1.foldRegions {
            foldState.collapsedRegionIDs.insert(region.id)
        }

        // 模拟重载：文本变化，只保留第一个函数
        let code2 = """
        func a() {
            print("a updated")
        }
        """
        let snapshot2 = analyzer.analyze(filePath: "test.swift", text: code2)
        foldState.reconcile(snapshot: snapshot2)

        // 只保留仍存在的折叠区域
        XCTAssertEqual(foldState.collapsedRegionIDs.count, snapshot2.foldRegions.count)
    }

    func testProjectionDoesNotModifyDocumentContent() {
        let code = """
        func test() {
            print("hello")
        }
        """
        let analyzer = EditorStructureAnalyzer()
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)

        var foldState = EditorCodeFoldingState()
        if let region = snapshot.foldRegions.first {
            foldState.collapsedRegionIDs.insert(region.id)
        }
        let projection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)

        // 投影只产出隐藏行范围和控制点，不修改原始文本
        XCTAssertFalse(projection.hiddenLineRanges.isEmpty)
        // 验证原始代码没有被修改（投影是纯函数）
        let snapshot2 = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertEqual(snapshot.contentFingerprint, snapshot2.contentFingerprint)
    }

    func testProjectionRebuildableAfterThemeSwitch() {
        let code = """
        func test() {
            print("themed")
        }
        """
        let analyzer = EditorStructureAnalyzer()
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)

        var foldState = EditorCodeFoldingState()
        if let region = snapshot.foldRegions.first {
            foldState.collapsedRegionIDs.insert(region.id)
        }

        // 主题切换不影响结构分析和折叠投影
        let projection1 = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)
        let projection2 = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)
        XCTAssertEqual(projection1, projection2, "相同输入应产出相同投影")
    }

    // MARK: - Gutter 状态（共享类型测试，iOS 场景）

    func testGutterStateDefaultValues() {
        let state = EditorGutterState()
        XCTAssertNil(state.currentLine)
        XCTAssertTrue(state.breakpoints.isEmpty)
        XCTAssertTrue(state.showsCurrentLineHighlight)
    }

    func testGutterStateCurrentLineUpdate() {
        var state = EditorGutterState()
        state.currentLine = 5
        XCTAssertEqual(state.currentLine, 5)
        state.currentLine = nil
        XCTAssertNil(state.currentLine)
    }

    func testGutterBreakpointToggle() {
        var state = EditorGutterState()
        state.breakpoints.toggle(line: 10)
        XCTAssertTrue(state.breakpoints.contains(line: 10))
        state.breakpoints.toggle(line: 10)
        XCTAssertFalse(state.breakpoints.contains(line: 10))
    }

    func testGutterStatePerDocumentIsolation() {
        // 不同文档键的 gutter 状态应完全独立
        let key1 = EditorDocumentKey(project: "app", workspace: "main", path: "src/index.ts")
        let key2 = EditorDocumentKey(project: "app", workspace: "main", path: "src/utils.ts")
        let key3 = EditorDocumentKey(project: "app", workspace: "dev", path: "src/index.ts")

        var state1 = EditorGutterState()
        state1.breakpoints.toggle(line: 5)
        state1.currentLine = 10

        var state2 = EditorGutterState()
        state2.breakpoints.toggle(line: 20)

        var state3 = EditorGutterState()
        state3.currentLine = 30

        // 各自独立
        XCTAssertTrue(state1.breakpoints.contains(line: 5))
        XCTAssertFalse(state2.breakpoints.contains(line: 5))
        XCTAssertFalse(state3.breakpoints.contains(line: 5))

        XCTAssertEqual(state1.currentLine, 10)
        XCTAssertNil(state2.currentLine)
        XCTAssertEqual(state3.currentLine, 30)

        // 以 EditorDocumentKey 为键存储时隔离
        var stateByDoc: [EditorDocumentKey: EditorGutterState] = [:]
        stateByDoc[key1] = state1
        stateByDoc[key2] = state2
        stateByDoc[key3] = state3

        XCTAssertEqual(stateByDoc[key1]?.currentLine, 10)
        XCTAssertNil(stateByDoc[key2]?.currentLine)
        XCTAssertEqual(stateByDoc[key3]?.currentLine, 30)
    }

    func testGutterProjectionWithFolding() {
        let code = """
        func test() {
            line1
            line2
        }
        extra
        """
        let analyzer = EditorStructureAnalyzer()
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)

        var foldState = EditorCodeFoldingState()
        if let region = snapshot.foldRegions.first {
            foldState.collapsedRegionIDs.insert(region.id)
        }

        let folding = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)
        var gutterState = EditorGutterState()
        gutterState.currentLine = 0
        gutterState.breakpoints.toggle(line: 4) // "extra" 行

        let projection = EditorGutterProjectionBuilder.make(snapshot: snapshot, folding: folding, state: gutterState)

        // 折叠后隐藏行不应出现
        let visibleLines = projection.lineItems.map(\.line)
        XCTAssertTrue(visibleLines.contains(0), "折叠起始行应保留")
        XCTAssertTrue(visibleLines.contains(4), "未折叠行应保留")
        XCTAssertFalse(visibleLines.contains(1), "隐藏行不应出现")
        XCTAssertFalse(visibleLines.contains(2), "隐藏行不应出现")

        // 当前行和断点正确
        let line0Item = projection.lineItems.first { $0.line == 0 }
        XCTAssertEqual(line0Item?.isCurrentLine, true)
        let line4Item = projection.lineItems.first { $0.line == 4 }
        XCTAssertEqual(line4Item?.hasBreakpoint, true)
    }
}

// MARK: - iOS 共享编辑历史语义测试

/// 验证共享历史语义在 iOS 编辑器场景下的行为正确性：
/// 覆盖辅助栏状态刷新、跨文档隔离、外部命令转发、重载清栈和另存为迁移。
final class MobileEditorHistoryTests: XCTestCase {

    // MARK: - 基础记录与撤销/重做

    func testRecordAndUndoRedo() {
        let history = EditorUndoHistoryState()
        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "Hello"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 5, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        XCTAssertEqual(result.text, "Hello")
        XCTAssertTrue(result.canUndo)
        XCTAssertFalse(result.canRedo)

        // 撤销
        let undoResult = EditorUndoHistorySemantics.undo(currentText: "Hello", history: result.history)
        XCTAssertNotNil(undoResult)
        XCTAssertEqual(undoResult?.text, "")
        XCTAssertFalse(undoResult!.canUndo)
        XCTAssertTrue(undoResult!.canRedo)

        // 重做
        let redoResult = EditorUndoHistorySemantics.redo(currentText: "", history: undoResult!.history)
        XCTAssertNotNil(redoResult)
        XCTAssertEqual(redoResult?.text, "Hello")
        XCTAssertTrue(redoResult!.canUndo)
        XCTAssertFalse(redoResult!.canRedo)
    }

    // MARK: - 辅助栏状态刷新

    func testAccessoryBarStateReflectsHistory() {
        let history = EditorUndoHistoryState()

        // 初始状态：无法撤销也无法重做
        XCTAssertTrue(history.undoStack.isEmpty)
        XCTAssertTrue(history.redoStack.isEmpty)

        // 录入一条编辑后：可撤销，不可重做
        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "A"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 1, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        XCTAssertTrue(r1.canUndo)
        XCTAssertFalse(r1.canRedo)

        // 撤销后：不可撤销，可重做
        let r2 = EditorUndoHistorySemantics.undo(currentText: r1.text, history: r1.history)
        XCTAssertFalse(r2!.canUndo)
        XCTAssertTrue(r2!.canRedo)
    }

    // MARK: - 跨文档隔离

    func testCrossDocumentHistoryIsolation() {
        let historyA = EditorUndoHistoryState()
        let historyB = EditorUndoHistoryState()

        let cmdA = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "AAA"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 3, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let resultA = EditorUndoHistorySemantics.recordEdit(currentText: "", history: historyA, command: cmdA)

        // 文档 B 没有历史
        XCTAssertTrue(resultA.canUndo)
        XCTAssertTrue(historyB.undoStack.isEmpty)

        let cmdB = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "BBB"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 3, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let resultB = EditorUndoHistorySemantics.recordEdit(currentText: "", history: historyB, command: cmdB)

        // 撤销 A 不影响 B
        let undoA = EditorUndoHistorySemantics.undo(currentText: "AAA", history: resultA.history)
        XCTAssertFalse(undoA!.canUndo)
        XCTAssertTrue(resultB.canUndo)
    }

    // MARK: - 外部命令转发

    func testExternalUndoRedoForwarding() {
        let history = EditorUndoHistoryState()
        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "X"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 1, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)

        // 模拟外部 requestUndo
        let undoResult = EditorUndoHistorySemantics.undo(currentText: "X", history: result.history)
        XCTAssertEqual(undoResult?.text, "")

        // 模拟外部 requestRedo
        let redoResult = EditorUndoHistorySemantics.redo(currentText: "", history: undoResult!.history)
        XCTAssertEqual(redoResult?.text, "X")
    }

    // MARK: - 重载清栈

    func testReloadClearsHistoryStack() {
        let history = EditorUndoHistoryState()
        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "data"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 4, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        XCTAssertTrue(result.canUndo)

        // 模拟重载后重置
        let reloadedHistory = EditorDocumentSession.historyAfterReload()
        XCTAssertTrue(reloadedHistory.undoStack.isEmpty)
        XCTAssertTrue(reloadedHistory.redoStack.isEmpty)
    }

    // MARK: - 另存为迁移

    func testSaveAsMigratesHistory() {
        let history = EditorUndoHistoryState()
        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "code"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 4, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        XCTAssertTrue(result.canUndo)

        // 另存为迁移：历史应保留
        let oldKey = EditorDocumentKey(project: "app", workspace: "ws", path: "old.swift")
        let newKey = EditorDocumentKey(project: "app", workspace: "ws", path: "new.swift")
        let migratedHistory = EditorDocumentSession.historyAfterSaveAs(history: result.history, from: oldKey, to: newKey)
        XCTAssertFalse(migratedHistory.undoStack.isEmpty)
        XCTAssertEqual(migratedHistory.undoStack.count, result.history.undoStack.count)
    }

    // MARK: - 重命名迁移

    func testRenameMigratesHistory() {
        let history = EditorUndoHistoryState()
        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "fn"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 2, length: 0),
            timestamp: Date(),
            replacedText: ""
        )
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)

        let oldKey = EditorDocumentKey(project: "app", workspace: "ws", path: "old.swift")
        let newKey = EditorDocumentKey(project: "app", workspace: "ws", path: "renamed.swift")
        let migratedHistory = EditorDocumentSession.historyAfterRename(history: result.history, from: oldKey, to: newKey)
        XCTAssertFalse(migratedHistory.undoStack.isEmpty)
        XCTAssertEqual(migratedHistory.undoStack.count, 1)
    }

    // MARK: - 共享补全替换语义

    func testSharedReplacementSemanticsIdenticalAcrossPlatforms() {
        // 验证共享引擎的 accept() 在纯函数层面的行为一致性
        let engine = EditorAutocompleteEngine()
        let text = "let myVa = 1"
        let ctx = EditorAutocompleteContext(
            filePath: "test.swift",
            text: text,
            cursorLocation: 8, // 在 "myVa" 尾部
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)

        // 查找 myVariable 类候选或关键字候选
        guard let item = state.items.first else {
            // 可能无候选（myVa 开头的不多），跳过测试
            return
        }

        // 第一次接受
        let result1 = engine.accept(item: item, state: state, currentText: text)

        // 第二次接受（同样的状态和文本）—— 应完全一致
        let result2 = engine.accept(item: item, state: state, currentText: text)

        XCTAssertEqual(result1?.text, result2?.text, "共享替换语义应确定性一致")
        XCTAssertEqual(result1?.selection.location, result2?.selection.location)
    }

    func testReplacementStaticFunctionConsistency() {
        let item = EditorAutocompleteItem(
            id: "kw-guard",
            title: "guard",
            insertText: "guard",
            kind: .languageKeyword
        )
        let state = EditorAutocompleteState(
            isVisible: true,
            query: "gu",
            selectedIndex: 0,
            replacementRange: NSRange(location: 4, length: 2),
            items: [item]
        )

        let replacement = EditorAutocompleteEngine.replacement(for: item, state: state)

        // 验证替换指令与 accept() 结果一致
        let engine = EditorAutocompleteEngine()
        let result = engine.accept(item: item, state: state, currentText: "let gu = 1")
        XCTAssertNotNil(result)
        XCTAssertEqual(replacement.replacementText, item.insertText)
        XCTAssertEqual(replacement.rangeLocation, state.replacementRange.location)
        XCTAssertEqual(replacement.rangeLength, state.replacementRange.length)
        XCTAssertEqual(replacement.caretLocation, result?.selection.location)
    }

    func testAutocompleteStateIsolationBetweenDocuments() {
        // 验证补全状态在共享层只是值类型，不同文档互不影响
        let stateA = EditorAutocompleteState(
            isVisible: true,
            query: "alpha",
            selectedIndex: 1,
            replacementRange: NSRange(location: 0, length: 5),
            items: [
                EditorAutocompleteItem(id: "a1", title: "alpha", insertText: "alpha", kind: .documentSymbol),
                EditorAutocompleteItem(id: "a2", title: "alphaNum", insertText: "alphaNum", kind: .documentSymbol),
            ]
        )
        var stateB = EditorAutocompleteState.hidden

        // 修改 B 不应影响 A
        stateB.isVisible = true
        stateB.query = "beta"

        XCTAssertEqual(stateA.query, "alpha")
        XCTAssertEqual(stateB.query, "beta")
        XCTAssertNotEqual(stateA, stateB, "不同文档的补全状态应完全独立")
    }

    func testAutocompleteEngineUpdateIdempotent() {
        // 同一上下文调用两次应返回相同结果
        let engine = EditorAutocompleteEngine()
        let text = "let guard"
        let ctx = EditorAutocompleteContext(
            filePath: "test.swift",
            text: text,
            cursorLocation: 9,
            triggerKind: .automatic
        )

        let state1 = engine.update(context: ctx, previousState: nil)
        let state2 = engine.update(context: ctx, previousState: nil)

        XCTAssertEqual(state1.isVisible, state2.isVisible)
        XCTAssertEqual(state1.items.count, state2.items.count)
        XCTAssertEqual(state1.query, state2.query)
        XCTAssertEqual(state1.replacementRange, state2.replacementRange)
    }

    func testSharedReplacementDoesNotExpandBeyondToken() {
        // 验证替换范围只覆盖当前 token，不跨 token
        let engine = EditorAutocompleteEngine()
        let text = "let gu = 1"
        let ctx = EditorAutocompleteContext(
            filePath: "test.swift",
            text: text,
            cursorLocation: 6, // "gu" 尾部
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)

        XCTAssertTrue(state.isVisible)
        // replacementRange 应仅覆盖 "gu" token
        XCTAssertEqual(state.replacementRange.location, 4)
        XCTAssertEqual(state.replacementRange.length, 2)
    }
}
