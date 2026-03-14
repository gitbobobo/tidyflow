import XCTest
@testable import TidyFlowShared

/// 多选区语义层的纯逻辑测试。
/// 覆盖：归一化、批量替换、撤销/重做选区恢复、自动补全主选区语义。
final class EditorMultiSelectionSemanticsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - EditorSelectionSet 归一化

    func testNormalizeSortsAndMergesOverlapping() {
        // 三个选区：[10,5] [0,3] [12,6]，其中 [10,5] 和 [12,6] 重叠（10..15 与 12..18）
        let set = EditorSelectionSet(regions: [
            EditorSelectionRegion(location: 10, length: 5, isPrimary: true),
            EditorSelectionRegion(location: 0, length: 3, isPrimary: false),
            EditorSelectionRegion(location: 12, length: 6, isPrimary: false),
        ]).normalized()

        // 排序后: [0,3], 合并 [10,5]+[12,6] → [10,8]
        XCTAssertEqual(set.count, 2)
        XCTAssertEqual(set.regions[0].location, 0)
        XCTAssertEqual(set.regions[0].length, 3)
        XCTAssertEqual(set.regions[1].location, 10)
        XCTAssertEqual(set.regions[1].length, 8) // max(15, 18) - 10
        // 主选区标记被保留到合并结果
        XCTAssertTrue(set.regions[1].isPrimary)
    }

    func testNormalizeMergesAdjacentRegions() {
        // [5,3] 和 [8,2] 相邻（5..8 和 8..10）
        let set = EditorSelectionSet(regions: [
            EditorSelectionRegion(location: 5, length: 3, isPrimary: true),
            EditorSelectionRegion(location: 8, length: 2, isPrimary: false),
        ]).normalized()

        XCTAssertEqual(set.count, 1)
        XCTAssertEqual(set.regions[0].location, 5)
        XCTAssertEqual(set.regions[0].length, 5)
        XCTAssertTrue(set.regions[0].isPrimary)
    }

    func testNormalizeKeepsDisjointRegions() {
        let set = EditorSelectionSet(regions: [
            EditorSelectionRegion(location: 20, length: 3, isPrimary: false),
            EditorSelectionRegion(location: 0, length: 2, isPrimary: true),
            EditorSelectionRegion(location: 10, length: 2, isPrimary: false),
        ]).normalized()

        XCTAssertEqual(set.count, 3)
        XCTAssertEqual(set.regions[0].location, 0)
        XCTAssertEqual(set.regions[1].location, 10)
        XCTAssertEqual(set.regions[2].location, 20)
    }

    func testSingleSelectionIsAlreadyNormalized() {
        let set = EditorSelectionSet.single(location: 5, length: 3)
        let normalized = set.normalized()
        XCTAssertEqual(normalized, set)
    }

    func testClampedToUTF16Length() {
        let set = EditorSelectionSet(regions: [
            EditorSelectionRegion(location: 8, length: 10, isPrimary: true),
            EditorSelectionRegion(location: 0, length: 3, isPrimary: false),
        ]).clamped(toUTF16Length: 12)

        XCTAssertEqual(set.regions[0].location, 8)
        XCTAssertEqual(set.regions[0].length, 4) // clamped: min(18, 12) - 8 = 4
        XCTAssertEqual(set.regions[1].location, 0)
        XCTAssertEqual(set.regions[1].length, 3) // 未变
    }

    func testInitEnsuresPrimaryExists() {
        // 没有指定 isPrimary 的选区，构造器应自动将第一个设为 primary
        let set = EditorSelectionSet(regions: [
            EditorSelectionRegion(location: 5, length: 2, isPrimary: false),
            EditorSelectionRegion(location: 10, length: 2, isPrimary: false),
        ])
        XCTAssertTrue(set.regions[0].isPrimary)
    }

    // MARK: - 批量替换（多选区插入/删除/替换 + 撤销/重做）

    func testBatchInsertAndUndoRedo() {
        // 文本: "AABBCC"（6 个字符）
        // 在位置 4 和 2 各插入 "X"
        let text = "AABBCC"
        let command = EditorEditCommand(
            mutations: [
                EditorTextMutation(rangeLocation: 4, rangeLength: 0, replacementText: "X"),
                EditorTextMutation(rangeLocation: 2, rangeLength: 0, replacementText: "X"),
            ],
            beforeSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 2, length: 0, isPrimary: true),
                EditorSelectionRegion(location: 4, length: 0, isPrimary: false),
            ]),
            afterSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 3, length: 0, isPrimary: true),
                EditorSelectionRegion(location: 6, length: 0, isPrimary: false),
            ]),
            timestamp: now,
            replacedTexts: ["", ""]
        )

        // 记录编辑
        let result = EditorUndoHistorySemantics.recordEdit(
            currentText: text,
            history: .empty,
            command: command
        )
        // mutations 按降序排列（4 先于 2），"AABBCC" → "AABBXCC" → "AAXBBXCC"
        XCTAssertEqual(result.text, "AAXBBXCC")
        XCTAssertTrue(result.canUndo)

        // 撤销：回到 "AABBCC"
        let undoResult = EditorUndoHistorySemantics.undo(
            currentText: result.text,
            history: result.history
        )
        XCTAssertNotNil(undoResult)
        XCTAssertEqual(undoResult!.text, text)
        XCTAssertEqual(undoResult!.selections, command.beforeSelections)

        // 重做：回到 "AAXBBXCC"
        let redoResult = EditorUndoHistorySemantics.redo(
            currentText: undoResult!.text,
            history: undoResult!.history
        )
        XCTAssertNotNil(redoResult)
        XCTAssertEqual(redoResult!.text, "AAXBBXCC")
        XCTAssertEqual(redoResult!.selections, command.afterSelections)
    }

    func testBatchReplaceAndUndo() {
        // 文本: "foo bar foo"
        // 同时替换两个 "foo" 为 "baz"
        let text = "foo bar foo"
        let command = EditorEditCommand(
            mutations: [
                EditorTextMutation(rangeLocation: 8, rangeLength: 3, replacementText: "baz"),
                EditorTextMutation(rangeLocation: 0, rangeLength: 3, replacementText: "baz"),
            ],
            beforeSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 0, length: 3, isPrimary: true),
                EditorSelectionRegion(location: 8, length: 3, isPrimary: false),
            ]),
            afterSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 3, length: 0, isPrimary: true),
                EditorSelectionRegion(location: 11, length: 0, isPrimary: false),
            ]),
            timestamp: now,
            replacedTexts: ["foo", "foo"]
        )

        let result = EditorUndoHistorySemantics.recordEdit(
            currentText: text,
            history: .empty,
            command: command
        )
        XCTAssertEqual(result.text, "baz bar baz")

        let undoResult = EditorUndoHistorySemantics.undo(
            currentText: result.text,
            history: result.history
        )!
        XCTAssertEqual(undoResult.text, "foo bar foo")
    }

    func testBatchDeleteAndUndo() {
        // 文本: "abcXdefXghi"
        // 删除位置 7 和 3 的 "X"
        let text = "abcXdefXghi"
        let command = EditorEditCommand(
            mutations: [
                EditorTextMutation(rangeLocation: 7, rangeLength: 1, replacementText: ""),
                EditorTextMutation(rangeLocation: 3, rangeLength: 1, replacementText: ""),
            ],
            beforeSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 4, length: 0, isPrimary: true),
                EditorSelectionRegion(location: 8, length: 0, isPrimary: false),
            ]),
            afterSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 3, length: 0, isPrimary: true),
                EditorSelectionRegion(location: 6, length: 0, isPrimary: false),
            ]),
            timestamp: now,
            replacedTexts: ["X", "X"]
        )

        let result = EditorUndoHistorySemantics.recordEdit(
            currentText: text,
            history: .empty,
            command: command
        )
        XCTAssertEqual(result.text, "abcdefghi")

        let undoResult = EditorUndoHistorySemantics.undo(
            currentText: result.text,
            history: result.history
        )!
        XCTAssertEqual(undoResult.text, text)
    }

    // MARK: - 批量命令不参与合并

    func testBatchCommandsAreNotCoalesced() {
        let text = "abcdef"
        let cmd1 = EditorEditCommand(
            mutations: [
                EditorTextMutation(rangeLocation: 3, rangeLength: 0, replacementText: "X"),
                EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "X"),
            ],
            beforeSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 0, length: 0, isPrimary: true),
                EditorSelectionRegion(location: 3, length: 0, isPrimary: false),
            ]),
            afterSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 1, length: 0, isPrimary: true),
                EditorSelectionRegion(location: 5, length: 0, isPrimary: false),
            ]),
            timestamp: now,
            replacedTexts: ["", ""]
        )

        let result1 = EditorUndoHistorySemantics.recordEdit(
            currentText: text, history: .empty, command: cmd1
        )

        // 紧接着第二条批量命令
        let cmd2 = EditorEditCommand(
            mutations: [
                EditorTextMutation(rangeLocation: 5, rangeLength: 0, replacementText: "Y"),
                EditorTextMutation(rangeLocation: 1, rangeLength: 0, replacementText: "Y"),
            ],
            beforeSelections: result1.selections,
            afterSelections: EditorSelectionSet(regions: [
                EditorSelectionRegion(location: 2, length: 0, isPrimary: true),
                EditorSelectionRegion(location: 7, length: 0, isPrimary: false),
            ]),
            timestamp: Date(timeIntervalSince1970: 1_000_000.1),
            replacedTexts: ["", ""]
        )

        let result2 = EditorUndoHistorySemantics.recordEdit(
            currentText: result1.text, history: result1.history, command: cmd2
        )

        // undo 栈应有 2 条记录（批量命令不合并）
        XCTAssertEqual(result2.history.undoStack.count, 2)
    }

    // MARK: - 自动补全主选区语义

    func testAutocompleteAcceptReturnsSinglePrimarySelection() {
        // 验证 accept() 返回的选区集合仅含主选区
        let engine = EditorAutocompleteEngine()
        let item = EditorAutocompleteItem(
            id: "test-forEach",
            title: "forEach",
            insertText: "forEach",
            kind: .languageKeyword
        )
        let state = EditorAutocompleteState(
            isVisible: true,
            query: "fo",
            selectedIndex: 0,
            replacementRange: NSRange(location: 7, length: 2),
            items: [item]
        )
        let text = "let x = fo"

        if let accepted = engine.accept(item: item, state: state, currentText: text) {
            XCTAssertTrue(accepted.selections.isSingleSelection)
            XCTAssertTrue(accepted.selections.primarySelection.isPrimary)
            let expectedCaret = 7 + ("forEach" as NSString).length
            XCTAssertEqual(accepted.selections.primarySelection.location, expectedCaret)
            XCTAssertEqual(accepted.selections.primarySelection.length, 0)
        } else {
            XCTFail("accept() 不应返回 nil")
        }
    }

    // MARK: - EditorSelectionRegion 基本属性

    func testSelectionRegionEndLocation() {
        let region = EditorSelectionRegion(location: 10, length: 5, isPrimary: true)
        XCTAssertEqual(region.endLocation, 15)
    }

    func testSelectionRegionSnapshotBridge() {
        let region = EditorSelectionRegion(location: 7, length: 3, isPrimary: false)
        let snap = region.snapshot
        XCTAssertEqual(snap.location, 7)
        XCTAssertEqual(snap.length, 3)
    }

    // MARK: - EditorSelectionSet 工厂方法

    func testSingleFactory() {
        let set = EditorSelectionSet.single(location: 42, length: 5)
        XCTAssertEqual(set.count, 1)
        XCTAssertTrue(set.isSingleSelection)
        XCTAssertEqual(set.primarySelection.location, 42)
        XCTAssertEqual(set.primarySelection.length, 5)
        XCTAssertTrue(set.additionalSelections.isEmpty)
    }

    func testZeroFactory() {
        let set = EditorSelectionSet.zero
        XCTAssertEqual(set.primarySelection.location, 0)
        XCTAssertEqual(set.primarySelection.length, 0)
    }

    func testSingleFromSnapshot() {
        let snap = EditorSelectionSnapshot(location: 3, length: 7)
        let set = EditorSelectionSet.single(snap)
        XCTAssertEqual(set.primarySelection.location, 3)
        XCTAssertEqual(set.primarySelection.length, 7)
    }

    // MARK: - 撤销/重做选区集合完整恢复

    func testUndoRedoRestoresFullSelectionSet() {
        let text = "hello world"
        let beforeSel = EditorSelectionSet(regions: [
            EditorSelectionRegion(location: 0, length: 5, isPrimary: true),
            EditorSelectionRegion(location: 6, length: 5, isPrimary: false),
        ])
        let afterSel = EditorSelectionSet(regions: [
            EditorSelectionRegion(location: 3, length: 0, isPrimary: true),
            EditorSelectionRegion(location: 6, length: 0, isPrimary: false),
        ])

        let command = EditorEditCommand(
            mutations: [
                EditorTextMutation(rangeLocation: 6, rangeLength: 5, replacementText: ""),
                EditorTextMutation(rangeLocation: 0, rangeLength: 5, replacementText: "abc"),
            ],
            beforeSelections: beforeSel,
            afterSelections: afterSel,
            timestamp: now,
            replacedTexts: ["world", "hello"]
        )

        let recordResult = EditorUndoHistorySemantics.recordEdit(
            currentText: text, history: .empty, command: command
        )
        XCTAssertEqual(recordResult.selections, afterSel)

        let undoResult = EditorUndoHistorySemantics.undo(
            currentText: recordResult.text, history: recordResult.history
        )!
        XCTAssertEqual(undoResult.selections, beforeSel)

        let redoResult = EditorUndoHistorySemantics.redo(
            currentText: undoResult.text, history: undoResult.history
        )!
        XCTAssertEqual(redoResult.selections, afterSel)
    }

    // MARK: - compat 访问器

    func testCompatSelectionAccessor() {
        let command = EditorEditCommand(
            mutation: EditorTextMutation(rangeLocation: 0, rangeLength: 0, replacementText: "a"),
            beforeSelection: EditorSelectionSnapshot(location: 0, length: 0),
            afterSelection: EditorSelectionSnapshot(location: 1, length: 0),
            timestamp: now,
            replacedText: ""
        )

        let result = EditorUndoHistorySemantics.recordEdit(
            currentText: "", history: .empty, command: command
        )

        // compat: result.selection 应等于 primarySnapshot
        XCTAssertEqual(result.selection.location, result.selections.primarySnapshot.location)
        XCTAssertEqual(result.selection.length, result.selections.primarySnapshot.length)
    }
}
