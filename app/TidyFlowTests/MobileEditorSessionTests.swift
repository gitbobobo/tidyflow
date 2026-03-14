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
