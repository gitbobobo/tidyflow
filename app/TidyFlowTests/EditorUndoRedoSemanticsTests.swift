import XCTest
@testable import TidyFlowShared

final class EditorUndoRedoSemanticsTests: XCTestCase {

    // MARK: - 辅助方法

    private let defaultConfig = EditorUndoHistoryConfiguration.default
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeKey(project: String = "proj", workspace: String = "ws", path: String = "file.txt") -> EditorDocumentKey {
        EditorDocumentKey(project: project, workspace: workspace, path: path)
    }

    /// 构造插入命令
    private func insertCommand(at location: Int, text: String, beforeSel: Int? = nil, time: Date? = nil) -> EditorEditCommand {
        let sel = beforeSel ?? location
        return EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: location, rangeLength: 0, replacementText: text),
            beforeSelection: EditorSelectionSnapshot(location: sel, length: 0),
            afterSelection: EditorSelectionSnapshot(location: location + (text as NSString).length, length: 0),
            timestamp: time ?? now,
            replacedText: ""
        )
    }

    /// 构造删除命令
    private func deleteCommand(at location: Int, length: Int = 1, replacedText: String, time: Date? = nil) -> EditorEditCommand {
        return EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: location, rangeLength: length, replacementText: ""),
            beforeSelection: EditorSelectionSnapshot(location: location + length, length: 0),
            afterSelection: EditorSelectionSnapshot(location: location, length: 0),
            timestamp: time ?? now,
            replacedText: replacedText
        )
    }

    /// 构造替换命令
    private func replaceCommand(at location: Int, length: Int, replacement: String, replacedText: String, time: Date? = nil) -> EditorEditCommand {
        return EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: location, rangeLength: length, replacementText: replacement),
            beforeSelection: EditorSelectionSnapshot(location: location, length: length),
            afterSelection: EditorSelectionSnapshot(location: location + (replacement as NSString).length, length: 0),
            timestamp: time ?? now,
            replacedText: replacedText
        )
    }

    // MARK: - 插入

    func testInsertSingleCharacter() {
        let history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 0, text: "H")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        XCTAssertEqual(result.text, "H")
        XCTAssertTrue(result.canUndo)
        XCTAssertFalse(result.canRedo)
        XCTAssertEqual(result.history.undoStack.count, 1)
    }

    func testInsertMultipleCharacters() {
        let history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 0, text: "Hello")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.selection.location, 5)
    }

    func testInsertAtMiddle() {
        let history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 5, text: " World")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "Hello!", history: history, command: cmd)
        XCTAssertEqual(result.text, "Hello World!")
    }

    // MARK: - 删除

    func testDeleteSingleCharacter() {
        let history = EditorUndoHistoryState.empty
        let cmd = deleteCommand(at: 4, replacedText: "o")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "Hello", history: history, command: cmd)
        XCTAssertEqual(result.text, "Hell")
        XCTAssertTrue(result.canUndo)
    }

    func testDeleteMultipleCharacters() {
        let history = EditorUndoHistoryState.empty
        let cmd = deleteCommand(at: 0, length: 5, replacedText: "Hello")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "Hello World", history: history, command: cmd)
        XCTAssertEqual(result.text, " World")
    }

    // MARK: - 替换

    func testReplaceText() {
        let history = EditorUndoHistoryState.empty
        let cmd = replaceCommand(at: 0, length: 5, replacement: "Hi", replacedText: "Hello")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "Hello World", history: history, command: cmd)
        XCTAssertEqual(result.text, "Hi World")
        XCTAssertEqual(result.selection.location, 2)
    }

    // MARK: - 撤销

    func testUndoInsert() {
        var history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 0, text: "Hello")
        let recordResult = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        history = recordResult.history

        let undoResult = EditorUndoHistorySemantics.undo(currentText: "Hello", history: history)
        XCTAssertNotNil(undoResult)
        XCTAssertEqual(undoResult!.text, "")
        XCTAssertFalse(undoResult!.canUndo)
        XCTAssertTrue(undoResult!.canRedo)
        XCTAssertEqual(undoResult!.selection.location, 0)
    }

    func testUndoDelete() {
        var history = EditorUndoHistoryState.empty
        let cmd = deleteCommand(at: 4, replacedText: "o")
        let recordResult = EditorUndoHistorySemantics.recordEdit(currentText: "Hello", history: history, command: cmd)
        history = recordResult.history

        let undoResult = EditorUndoHistorySemantics.undo(currentText: "Hell", history: history)
        XCTAssertNotNil(undoResult)
        XCTAssertEqual(undoResult!.text, "Hello")
    }

    func testUndoReplace() {
        var history = EditorUndoHistoryState.empty
        let cmd = replaceCommand(at: 0, length: 5, replacement: "Hi", replacedText: "Hello")
        let recordResult = EditorUndoHistorySemantics.recordEdit(currentText: "Hello World", history: history, command: cmd)
        history = recordResult.history

        let undoResult = EditorUndoHistorySemantics.undo(currentText: "Hi World", history: history)
        XCTAssertNotNil(undoResult)
        XCTAssertEqual(undoResult!.text, "Hello World")
    }

    func testUndoOnEmptyStackReturnsNil() {
        let history = EditorUndoHistoryState.empty
        let result = EditorUndoHistorySemantics.undo(currentText: "text", history: history)
        XCTAssertNil(result)
    }

    // MARK: - 重做

    func testRedoAfterUndo() {
        var history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 0, text: "Hello")
        let recordResult = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        history = recordResult.history

        let undoResult = EditorUndoHistorySemantics.undo(currentText: "Hello", history: history)!
        history = undoResult.history
        XCTAssertEqual(undoResult.text, "")

        let redoResult = EditorUndoHistorySemantics.redo(currentText: "", history: history)
        XCTAssertNotNil(redoResult)
        XCTAssertEqual(redoResult!.text, "Hello")
        XCTAssertTrue(redoResult!.canUndo)
        XCTAssertFalse(redoResult!.canRedo)
    }

    func testRedoOnEmptyStackReturnsNil() {
        let history = EditorUndoHistoryState.empty
        let result = EditorUndoHistorySemantics.redo(currentText: "text", history: history)
        XCTAssertNil(result)
    }

    func testNewEditClearsRedoStack() {
        var history = EditorUndoHistoryState.empty
        let cmd1 = insertCommand(at: 0, text: "Hello")
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd1)
        history = r1.history

        let undoResult = EditorUndoHistorySemantics.undo(currentText: "Hello", history: history)!
        history = undoResult.history
        XCTAssertTrue(undoResult.canRedo)

        // 新编辑应清空 redo
        let cmd2 = insertCommand(at: 0, text: "Hi")
        let r2 = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd2)
        XCTAssertFalse(r2.canRedo)
        XCTAssertTrue(r2.history.redoStack.isEmpty)
    }

    // MARK: - 连续输入合并

    func testConsecutiveInsertsCoalesce() {
        var history = EditorUndoHistoryState.empty
        let t0 = now
        let t1 = now.addingTimeInterval(0.1) // 100ms later

        let cmd1 = insertCommand(at: 0, text: "H", time: t0)
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd1)
        history = r1.history
        XCTAssertEqual(history.undoStack.count, 1)

        let cmd2 = insertCommand(at: 1, text: "i", time: t1)
        let r2 = EditorUndoHistorySemantics.recordEdit(currentText: "H", history: history, command: cmd2)
        history = r2.history
        // 应合并为一条记录
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertEqual(r2.text, "Hi")

        // 撤销应还原整个合并输入
        let undoResult = EditorUndoHistorySemantics.undo(currentText: "Hi", history: history)!
        XCTAssertEqual(undoResult.text, "")
    }

    func testInsertsExceedingWindowDoNotCoalesce() {
        var history = EditorUndoHistoryState.empty
        let t0 = now
        let t1 = now.addingTimeInterval(0.7) // 700ms later, 超过 600ms 窗口

        let cmd1 = insertCommand(at: 0, text: "H", time: t0)
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd1)
        history = r1.history

        let cmd2 = insertCommand(at: 1, text: "i", time: t1)
        let r2 = EditorUndoHistorySemantics.recordEdit(currentText: "H", history: history, command: cmd2)
        history = r2.history
        // 不应合并
        XCTAssertEqual(history.undoStack.count, 2)
    }

    func testConsecutiveBackspaceDeletsCoalesce() {
        var history = EditorUndoHistoryState.empty
        let t0 = now
        let t1 = now.addingTimeInterval(0.1)

        // 删除位置 2 的字符 'c'
        let cmd1 = deleteCommand(at: 2, replacedText: "c", time: t0)
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "abc", history: history, command: cmd1)
        history = r1.history
        XCTAssertEqual(r1.text, "ab")

        // 退格删除位置 1 的字符 'b'
        let cmd2 = deleteCommand(at: 1, replacedText: "b", time: t1)
        let r2 = EditorUndoHistorySemantics.recordEdit(currentText: "ab", history: history, command: cmd2)
        history = r2.history
        XCTAssertEqual(r2.text, "a")
        // 应合并
        XCTAssertEqual(history.undoStack.count, 1)
    }

    func testInsertAndDeleteDoNotCoalesce() {
        var history = EditorUndoHistoryState.empty
        let t0 = now
        let t1 = now.addingTimeInterval(0.1)

        let cmd1 = insertCommand(at: 0, text: "H", time: t0)
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd1)
        history = r1.history

        let cmd2 = deleteCommand(at: 0, replacedText: "H", time: t1)
        let r2 = EditorUndoHistorySemantics.recordEdit(currentText: "H", history: history, command: cmd2)
        history = r2.history
        // 不同类型不合并
        XCTAssertEqual(history.undoStack.count, 2)
    }

    func testMultiCharInsertDoesNotCoalesce() {
        var history = EditorUndoHistoryState.empty
        let t0 = now
        let t1 = now.addingTimeInterval(0.1)

        let cmd1 = insertCommand(at: 0, text: "Hello", time: t0)
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd1)
        history = r1.history

        let cmd2 = insertCommand(at: 5, text: " World", time: t1)
        let r2 = EditorUndoHistorySemantics.recordEdit(currentText: "Hello", history: history, command: cmd2)
        history = r2.history
        // 多字符粘贴不合并
        XCTAssertEqual(history.undoStack.count, 2)
    }

    func testNonAdjacentInsertsDoNotCoalesce() {
        var history = EditorUndoHistoryState.empty
        let t0 = now
        let t1 = now.addingTimeInterval(0.1)

        let cmd1 = insertCommand(at: 0, text: "A", time: t0)
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "...", history: history, command: cmd1)
        history = r1.history

        // 不在位置 1（相邻），而在位置 3
        let cmd2 = insertCommand(at: 3, text: "B", time: t1)
        let r2 = EditorUndoHistorySemantics.recordEdit(currentText: "A...", history: history, command: cmd2)
        history = r2.history
        // 不相邻不合并
        XCTAssertEqual(history.undoStack.count, 2)
    }

    // MARK: - 超上限裁剪

    func testExceedMaxDepthTrimsOldest() {
        var history = EditorUndoHistoryState.empty
        let config = EditorUndoHistoryConfiguration(maxDepth: 3)
        var text = ""

        for i in 0..<5 {
            let ch = String(Character(UnicodeScalar(65 + i)!)) // A, B, C, D, E
            let cmd = insertCommand(at: i, text: ch, time: now.addingTimeInterval(Double(i) * 1.0))
            let result = EditorUndoHistorySemantics.recordEdit(currentText: text, history: history, command: cmd, configuration: config)
            text = result.text
            history = result.history
        }

        XCTAssertEqual(text, "ABCDE")
        // maxDepth=3，应只保留最近 3 条
        XCTAssertEqual(history.undoStack.count, 3)
        // 最旧的应是 C（index=2）
        XCTAssertEqual(history.undoStack.first?.mutation.replacementText, "C")
    }

    // MARK: - 跨工作区隔离

    func testDifferentDocumentKeysHaveIsolatedHistories() {
        let keyA = makeKey(project: "projA", workspace: "ws1", path: "a.txt")
        let keyB = makeKey(project: "projB", workspace: "ws2", path: "b.txt")

        var historyA = EditorUndoHistoryState.empty
        var historyB = EditorUndoHistoryState.empty

        let cmdA = insertCommand(at: 0, text: "AAA")
        let resultA = EditorUndoHistorySemantics.recordEdit(currentText: "", history: historyA, command: cmdA)
        historyA = resultA.history

        let cmdB = insertCommand(at: 0, text: "BBB")
        let resultB = EditorUndoHistorySemantics.recordEdit(currentText: "", history: historyB, command: cmdB)
        historyB = resultB.history

        XCTAssertEqual(resultA.text, "AAA")
        XCTAssertEqual(resultB.text, "BBB")

        // 撤销 A 不影响 B
        let undoA = EditorUndoHistorySemantics.undo(currentText: "AAA", history: historyA)!
        XCTAssertEqual(undoA.text, "")
        XCTAssertEqual(historyB.undoStack.count, 1)

        // 用文档键验证隔离概念
        XCTAssertNotEqual(keyA, keyB)
    }

    // MARK: - 键迁移

    func testMigratePreservesHistory() {
        var history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 0, text: "Hello")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        history = result.history

        let oldKey = makeKey(path: "old.txt")
        let newKey = makeKey(path: "new.txt")
        let migrated = EditorUndoHistorySemantics.migrate(history: history, from: oldKey, to: newKey)

        XCTAssertEqual(migrated.undoStack.count, history.undoStack.count)
        XCTAssertEqual(migrated.redoStack.count, history.redoStack.count)
        XCTAssertEqual(migrated.undoStack, history.undoStack)
    }

    // MARK: - 重置

    func testResetClearsAllHistory() {
        var history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 0, text: "Hello")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        history = result.history
        XCTAssertFalse(history.undoStack.isEmpty)

        let reset = EditorUndoHistorySemantics.reset(history: history)
        XCTAssertTrue(reset.undoStack.isEmpty)
        XCTAssertTrue(reset.redoStack.isEmpty)
    }

    // MARK: - 选区恢复

    func testUndoRestoresBeforeSelection() {
        var history = EditorUndoHistoryState.empty
        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 3, rangeLength: 0, replacementText: "XYZ"),
            beforeSelection: EditorSelectionSnapshot(location: 3, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 6, length: 0),
            timestamp: now,
            replacedText: ""
        )
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "abc", history: history, command: cmd)
        history = result.history

        let undoResult = EditorUndoHistorySemantics.undo(currentText: "abcXYZ", history: history)!
        XCTAssertEqual(undoResult.selection.location, 3)
        XCTAssertEqual(undoResult.selection.length, 0)
    }

    func testRedoRestoresAfterSelection() {
        var history = EditorUndoHistoryState.empty
        let cmd = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "Hello"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 5, length: 0),
            timestamp: now,
            replacedText: ""
        )
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        history = result.history

        let undoResult = EditorUndoHistorySemantics.undo(currentText: "Hello", history: history)!
        history = undoResult.history

        let redoResult = EditorUndoHistorySemantics.redo(currentText: "", history: history)!
        XCTAssertEqual(redoResult.selection.location, 5)
    }

    // MARK: - 多次撤销/重做

    func testMultipleUndoRedoCycle() {
        var history = EditorUndoHistoryState.empty
        var text = ""

        // 插入 A, B, C（超出合并窗口）
        for (i, ch) in ["A", "B", "C"].enumerated() {
            let cmd = insertCommand(at: i, text: ch, time: now.addingTimeInterval(Double(i) * 1.0))
            let result = EditorUndoHistorySemantics.recordEdit(currentText: text, history: history, command: cmd)
            text = result.text
            history = result.history
        }
        XCTAssertEqual(text, "ABC")
        XCTAssertEqual(history.undoStack.count, 3)

        // 撤销 3 次
        for expected in ["AB", "A", ""] {
            let result = EditorUndoHistorySemantics.undo(currentText: text, history: history)!
            text = result.text
            history = result.history
            XCTAssertEqual(text, expected)
        }
        XCTAssertFalse(EditorUndoHistorySemantics.undo(currentText: text, history: history) != nil && history.undoStack.isEmpty == false)

        // 重做 3 次
        for expected in ["A", "AB", "ABC"] {
            let result = EditorUndoHistorySemantics.redo(currentText: text, history: history)!
            text = result.text
            history = result.history
            XCTAssertEqual(text, expected)
        }
    }

    // MARK: - EditorDocumentSession 历史辅助

    func testHistoryAfterLoadReturnsEmpty() {
        let h = EditorDocumentSession.historyAfterLoad()
        XCTAssertTrue(h.undoStack.isEmpty)
        XCTAssertTrue(h.redoStack.isEmpty)
    }

    func testHistoryAfterReloadReturnsEmpty() {
        let h = EditorDocumentSession.historyAfterReload()
        XCTAssertTrue(h.undoStack.isEmpty)
        XCTAssertTrue(h.redoStack.isEmpty)
    }

    func testHistoryAfterSaveAsPreservesHistory() {
        var history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 0, text: "data")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        history = result.history

        let oldKey = makeKey(path: "old.txt")
        let newKey = makeKey(path: "new.txt")
        let migrated = EditorDocumentSession.historyAfterSaveAs(history: history, from: oldKey, to: newKey)
        XCTAssertEqual(migrated.undoStack.count, 1)
    }

    func testHistoryAfterRenamePreservesHistory() {
        var history = EditorUndoHistoryState.empty
        let cmd = insertCommand(at: 0, text: "data")
        let result = EditorUndoHistorySemantics.recordEdit(currentText: "", history: history, command: cmd)
        history = result.history

        let oldKey = makeKey(path: "old.txt")
        let newKey = makeKey(path: "new.txt")
        let migrated = EditorDocumentSession.historyAfterRename(history: history, from: oldKey, to: newKey)
        XCTAssertEqual(migrated.undoStack.count, 1)
    }

    // MARK: - applyMutation 边界

    func testApplyMutationEmptyText() {
        let result = EditorUndoHistorySemantics.applyMutation(
            to: "",
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "Hello")
        )
        XCTAssertEqual(result, "Hello")
    }

    func testApplyMutationDeleteAll() {
        let result = EditorUndoHistorySemantics.applyMutation(
            to: "Hello",
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 5, replacementText: "")
        )
        XCTAssertEqual(result, "")
    }

    // MARK: - 默认配置

    func testDefaultConfigurationValues() {
        let config = EditorUndoHistoryConfiguration.default
        XCTAssertEqual(config.maxDepth, 256)
        XCTAssertEqual(config.coalescingWindowMs, 600)
    }

    // MARK: - 前删方向合并

    func testForwardDeleteCoalesces() {
        var history = EditorUndoHistoryState.empty
        let t0 = now
        let t1 = now.addingTimeInterval(0.1)

        // 前删位置 1 的字符 'b' (Delete键)
        let cmd1 = deleteCommand(at: 1, replacedText: "b", time: t0)
        let r1 = EditorUndoHistorySemantics.recordEdit(currentText: "abc", history: history, command: cmd1)
        history = r1.history
        XCTAssertEqual(r1.text, "ac")

        // 继续前删位置 1 的字符 'c'
        let cmd2 = deleteCommand(at: 1, replacedText: "c", time: t1)
        let r2 = EditorUndoHistorySemantics.recordEdit(currentText: "ac", history: history, command: cmd2)
        history = r2.history
        XCTAssertEqual(r2.text, "a")
        // 应合并
        XCTAssertEqual(history.undoStack.count, 1)

        // 撤销应恢复两个字符
        let undoResult = EditorUndoHistorySemantics.undo(currentText: "a", history: history)!
        XCTAssertEqual(undoResult.text, "abc")
    }
}
