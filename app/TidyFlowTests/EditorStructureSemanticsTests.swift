import XCTest
@testable import TidyFlowShared

/// 编辑器结构语义共享层测试矩阵。
///
/// 覆盖：括号语言折叠、Python 缩进折叠、空白行跳过、嵌套折叠、
/// 折叠 ID 稳定性与 reconcile(snapshot:) 清理失效折叠项。
final class EditorStructureSemanticsTests: XCTestCase {

    private let analyzer = EditorStructureAnalyzer()

    // MARK: - Swift 括号折叠

    func testSwiftBraceFolding() {
        let code = """
        func hello() {
            print("hi")
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertEqual(snapshot.language, .swift)
        XCTAssertFalse(snapshot.foldRegions.isEmpty, "应检测到至少一个折叠区域")

        let region = snapshot.foldRegions[0]
        XCTAssertEqual(region.startLine, 0)
        XCTAssertEqual(region.endLine, 2)
        XCTAssertEqual(region.kind, .braces)
    }

    func testSwiftSingleLineBraceNoFold() {
        let code = "let x = { 1 }"
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertTrue(snapshot.foldRegions.isEmpty, "单行大括号不应生成折叠区域")
    }

    func testSwiftNestedFolding() {
        let code = """
        struct Outer {
            func inner() {
                if true {
                    print("nested")
                }
            }
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertGreaterThanOrEqual(snapshot.foldRegions.count, 3, "应检测到嵌套的多层折叠")

        // 验证嵌套深度递增
        let depths = snapshot.foldRegions.map(\.depth).sorted()
        XCTAssertEqual(depths[0], 0)
    }

    // MARK: - Rust 括号折叠

    func testRustBraceFolding() {
        let code = """
        fn main() {
            println!("hello");
        }
        """
        let snapshot = analyzer.analyze(filePath: "main.rs", text: code)
        XCTAssertEqual(snapshot.language, .rust)
        XCTAssertFalse(snapshot.foldRegions.isEmpty)
    }

    // MARK: - JavaScript/TypeScript 括号折叠

    func testJavaScriptFolding() {
        let code = """
        function greet() {
            console.log("hi");
        }
        """
        let snapshot = analyzer.analyze(filePath: "app.js", text: code)
        XCTAssertEqual(snapshot.language, .javascript)
        XCTAssertEqual(snapshot.foldRegions.count, 1)
    }

    func testTypeScriptFolding() {
        let code = """
        interface User {
            name: string;
            age: number;
        }
        """
        let snapshot = analyzer.analyze(filePath: "types.ts", text: code)
        XCTAssertEqual(snapshot.language, .typescript)
        XCTAssertEqual(snapshot.foldRegions.count, 1)
    }

    // MARK: - JSON 折叠

    func testJSONFolding() {
        let code = """
        {
            "name": "test",
            "items": [
                1,
                2
            ]
        }
        """
        let snapshot = analyzer.analyze(filePath: "data.json", text: code)
        XCTAssertEqual(snapshot.language, .json)
        XCTAssertGreaterThanOrEqual(snapshot.foldRegions.count, 2, "应检测到对象和数组的折叠")
    }

    // MARK: - Python 缩进折叠

    func testPythonIndentFolding() {
        let code = """
        def hello():
            print("hi")
            print("world")
        """
        let snapshot = analyzer.analyze(filePath: "main.py", text: code)
        XCTAssertEqual(snapshot.language, .python)
        XCTAssertFalse(snapshot.foldRegions.isEmpty, "应检测到缩进块折叠")

        let region = snapshot.foldRegions[0]
        XCTAssertEqual(region.kind, .indent)
        XCTAssertEqual(region.startLine, 0)
    }

    func testPythonNestedIndentFolding() {
        let code = """
        class MyClass:
            def method(self):
                if True:
                    pass
        """
        let snapshot = analyzer.analyze(filePath: "test.py", text: code)
        XCTAssertGreaterThanOrEqual(snapshot.foldRegions.count, 2, "应检测到嵌套缩进块")
    }

    // MARK: - 空白行处理

    func testBlankLinesAreSkippedInFolding() {
        let code = """
        func test() {
            print("a")

            print("b")
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertFalse(snapshot.foldRegions.isEmpty)

        // 折叠区域应包含中间的空白行
        let region = snapshot.foldRegions[0]
        XCTAssertEqual(region.startLine, 0)
        XCTAssertEqual(region.endLine, 4)
    }

    func testTrailingBlankLinesAreTrimmed() {
        let code = "func test() {\n    print(\"a\")\n\n\n}"
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertFalse(snapshot.foldRegions.isEmpty)

        // endLine 应该是闭括号所在行，不会被裁掉（因为 } 不是空白行）
        let region = snapshot.foldRegions[0]
        XCTAssertEqual(region.endLine, 4)
    }

    // MARK: - Markdown 和 plainText 不折叠

    func testMarkdownReturnsEmpty() {
        let code = "# Title\n\nSome content\n"
        let snapshot = analyzer.analyze(filePath: "README.md", text: code)
        XCTAssertEqual(snapshot.language, .markdown)
        XCTAssertTrue(snapshot.foldRegions.isEmpty)
    }

    func testPlainTextReturnsEmpty() {
        let code = "Hello world\nLine 2\n"
        let snapshot = analyzer.analyze(filePath: "notes.txt", text: code)
        XCTAssertEqual(snapshot.language, .plainText)
        XCTAssertTrue(snapshot.foldRegions.isEmpty)
    }

    // MARK: - 折叠 ID 稳定性

    func testFoldRegionIDStability() {
        let code = """
        func hello() {
            print("hi")
        }
        """
        let snapshot1 = analyzer.analyze(filePath: "test.swift", text: code)
        let snapshot2 = analyzer.analyze(filePath: "test.swift", text: code)

        XCTAssertEqual(snapshot1.foldRegions.count, snapshot2.foldRegions.count)
        for (r1, r2) in zip(snapshot1.foldRegions, snapshot2.foldRegions) {
            XCTAssertEqual(r1.id, r2.id, "相同内容应产生相同的折叠区域 ID")
        }
    }

    // MARK: - EditorCodeFoldingState reconcile

    func testReconcileClearsInvalidRegions() {
        let code1 = """
        func a() {
            print("a")
        }
        func b() {
            print("b")
        }
        """
        let snapshot1 = analyzer.analyze(filePath: "test.swift", text: code1)
        XCTAssertEqual(snapshot1.foldRegions.count, 2)

        // 折叠两个区域
        var state = EditorCodeFoldingState()
        for region in snapshot1.foldRegions {
            state.collapsedRegionIDs.insert(region.id)
        }
        XCTAssertEqual(state.collapsedRegionIDs.count, 2)

        // 修改文本，移除第二个函数
        let code2 = """
        func a() {
            print("a")
        }
        """
        let snapshot2 = analyzer.analyze(filePath: "test.swift", text: code2)

        // reconcile 应清理掉第二个函数的折叠状态
        state.reconcile(snapshot: snapshot2)
        XCTAssertEqual(state.collapsedRegionIDs.count, 1, "reconcile 后应只保留仍存在的区域")
        XCTAssertTrue(state.collapsedRegionIDs.contains(snapshot2.foldRegions[0].id))
    }

    func testReconcilePreservesValidRegions() {
        let code = """
        func hello() {
            print("hi")
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)

        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(snapshot.foldRegions[0].id)

        // 再次 reconcile 同一个快照
        state.reconcile(snapshot: snapshot)
        XCTAssertEqual(state.collapsedRegionIDs.count, 1, "有效区域应保留")
    }

    // MARK: - EditorCodeFoldingState toggle

    func testToggleFoldState() {
        let regionID = EditorFoldRegionID(startLine: 0, endLine: 3, kind: .braces)
        var state = EditorCodeFoldingState()

        state.toggle(regionID)
        XCTAssertTrue(state.collapsedRegionIDs.contains(regionID))

        state.toggle(regionID)
        XCTAssertFalse(state.collapsedRegionIDs.contains(regionID))
    }

    // MARK: - EditorCodeFoldingState expandRegions(containingLine:)

    func testExpandRegionsContainingLine() {
        let code = """
        func outer() {
            func inner() {
                print("deep")
            }
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)

        var state = EditorCodeFoldingState()
        for region in snapshot.foldRegions {
            state.collapsedRegionIDs.insert(region.id)
        }

        // 展开包含第 2 行的所有区域
        state.expandRegions(containingLine: 2, in: snapshot)

        // 第 2 行在 inner 和 outer 内部，两个都应被展开
        XCTAssertTrue(state.collapsedRegionIDs.isEmpty, "包含第 2 行的所有折叠区域都应被展开")
    }

    // MARK: - EditorCodeFoldingProjection.make

    func testProjectionHiddenLineRanges() {
        let code = """
        func hello() {
            print("line1")
            print("line2")
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        guard let region = snapshot.foldRegions.first else {
            XCTFail("应有折叠区域")
            return
        }

        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(region.id)

        let projection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: state)

        XCTAssertFalse(projection.hiddenLineRanges.isEmpty, "应有隐藏行范围")
        // startLine+1 到 endLine 应被隐藏
        let hidden = projection.hiddenLineRanges[0]
        XCTAssertEqual(hidden.lowerBound, region.startLine + 1)
        XCTAssertEqual(hidden.upperBound, region.endLine)
    }

    func testProjectionFoldControls() {
        let code = """
        func a() {
            print("a")
        }
        func b() {
            print("b")
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        let state = EditorCodeFoldingState()

        let projection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: state)

        XCTAssertEqual(projection.foldControls.count, snapshot.foldRegions.count)
        for control in projection.foldControls {
            XCTAssertFalse(control.isCollapsed, "默认所有区域应是展开的")
        }
    }

    func testProjectionIsLineHidden() {
        let code = """
        func test() {
            line1
            line2
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        guard let region = snapshot.foldRegions.first else {
            XCTFail("应有折叠区域")
            return
        }

        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(region.id)
        let projection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: state)

        XCTAssertFalse(projection.isLineHidden(0), "第 0 行（占位行）不应隐藏")
        XCTAssertTrue(projection.isLineHidden(1), "折叠内部行应隐藏")
        XCTAssertTrue(projection.isLineHidden(2), "折叠内部行应隐藏")
    }

    // MARK: - 缩进导线

    func testIndentGuidesGenerated() {
        let code = """
        func test() {
            if true {
                print("deep")
            }
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertFalse(snapshot.indentGuides.isEmpty, "应生成缩进导线")
    }

    func testIndentGuidesFilteredByFolding() {
        let code = """
        func test() {
            print("line1")
            print("line2")
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        guard let region = snapshot.foldRegions.first else { return }

        var state = EditorCodeFoldingState()
        state.collapsedRegionIDs.insert(region.id)

        let projection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: state)

        // 完全在隐藏区域内的导线不应出现在可见导线中
        for guide in projection.visibleIndentGuides {
            let allHidden = (guide.startLine...guide.endLine).allSatisfy { projection.isLineHidden($0) }
            XCTAssertFalse(allHidden, "完全隐藏的导线不应出现在可见列表中")
        }
    }

    // MARK: - 结构分析缓存

    func testAnalyzerCachesResult() {
        let code = """
        func test() {
            print("cached")
        }
        """
        let snapshot1 = analyzer.analyze(filePath: "test.swift", text: code)
        let snapshot2 = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertEqual(snapshot1, snapshot2, "相同输入应返回缓存结果")
    }

    func testAnalyzerInvalidatesOnContentChange() {
        let code1 = "func a() {\n    print(\"a\")\n}"
        let code2 = "func b() {\n    print(\"b\")\n}"

        let snapshot1 = analyzer.analyze(filePath: "test.swift", text: code1)
        let snapshot2 = analyzer.analyze(filePath: "test.swift", text: code2)

        XCTAssertNotEqual(snapshot1.contentFingerprint, snapshot2.contentFingerprint)
    }

    // MARK: - 空文本

    func testEmptyTextReturnsEmptySnapshot() {
        let snapshot = analyzer.analyze(filePath: "test.swift", text: "")
        XCTAssertEqual(snapshot.lineCount, 1) // 空字符串 split 后有 1 个元素
        XCTAssertTrue(snapshot.foldRegions.isEmpty)
    }

    // MARK: - 字符串和注释中的括号不折叠

    func testBracesInStringIgnored() {
        let code = """
        let x = "{ }"
        let y = "}"
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertTrue(snapshot.foldRegions.isEmpty, "字符串内的括号不应生成折叠区域")
    }

    func testBracesInCommentIgnored() {
        let code = """
        // { this is a comment }
        /* { multi
           line } */
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        XCTAssertTrue(snapshot.foldRegions.isEmpty, "注释内的括号不应生成折叠区域")
    }

    // MARK: - Gutter 投影：动态宽度（行号位数）

    func testGutterDigitsFor9Lines() {
        let digits = EditorGutterLayoutMetrics.computeDigits(forMaxLine: 9)
        XCTAssertEqual(digits, 1, "1-9 行应为 1 位")
    }

    func testGutterDigitsFor10Lines() {
        let digits = EditorGutterLayoutMetrics.computeDigits(forMaxLine: 10)
        XCTAssertEqual(digits, 2, "10 行应为 2 位")
    }

    func testGutterDigitsFor99Lines() {
        let digits = EditorGutterLayoutMetrics.computeDigits(forMaxLine: 99)
        XCTAssertEqual(digits, 2, "99 行应为 2 位")
    }

    func testGutterDigitsFor100Lines() {
        let digits = EditorGutterLayoutMetrics.computeDigits(forMaxLine: 100)
        XCTAssertEqual(digits, 3, "100 行应为 3 位")
    }

    func testGutterDigitsFor999Lines() {
        let digits = EditorGutterLayoutMetrics.computeDigits(forMaxLine: 999)
        XCTAssertEqual(digits, 3, "999 行应为 3 位")
    }

    func testGutterDigitsFor1000Lines() {
        let digits = EditorGutterLayoutMetrics.computeDigits(forMaxLine: 1000)
        XCTAssertEqual(digits, 4, "1000 行应为 4 位")
    }

    func testGutterDigitsFor0Lines() {
        let digits = EditorGutterLayoutMetrics.computeDigits(forMaxLine: 0)
        XCTAssertEqual(digits, 1, "0 行应返回最少 1 位")
    }

    // MARK: - Gutter 投影：行项生成

    func testGutterProjectionBasicLineItems() {
        let code = "line1\nline2\nline3"
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        let folding = EditorCodeFoldingProjection.make(snapshot: snapshot, state: EditorCodeFoldingState())
        let gutterState = EditorGutterState()

        let projection = EditorGutterProjectionBuilder.make(snapshot: snapshot, folding: folding, state: gutterState)

        XCTAssertEqual(projection.lineItems.count, 3)
        XCTAssertEqual(projection.lineItems[0].displayLineNumber, "1")
        XCTAssertEqual(projection.lineItems[1].displayLineNumber, "2")
        XCTAssertEqual(projection.lineItems[2].displayLineNumber, "3")
        XCTAssertEqual(projection.lineItems[0].line, 0)
        XCTAssertEqual(projection.lineItems[1].line, 1)
        XCTAssertEqual(projection.lineItems[2].line, 2)
    }

    func testGutterProjectionHiddenLinesOmitted() {
        let code = """
        func test() {
            line1
            line2
        }
        """
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        guard let region = snapshot.foldRegions.first else {
            XCTFail("应有折叠区域")
            return
        }

        var foldState = EditorCodeFoldingState()
        foldState.collapsedRegionIDs.insert(region.id)
        let folding = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)
        let gutterState = EditorGutterState()

        let projection = EditorGutterProjectionBuilder.make(snapshot: snapshot, folding: folding, state: gutterState)

        // 折叠后隐藏行不应生成 item
        let visibleLines = projection.lineItems.map(\.line)
        XCTAssertTrue(visibleLines.contains(0), "折叠起始行应保留")
        XCTAssertFalse(visibleLines.contains(1), "隐藏行不应生成 item")
        XCTAssertFalse(visibleLines.contains(2), "隐藏行不应生成 item")

        // 折叠起始行应标记为 fold placeholder 并携带 foldControl
        let startItem = projection.lineItems.first { $0.line == 0 }
        XCTAssertNotNil(startItem?.foldControl, "折叠起始行应携带 foldControl")
        XCTAssertEqual(startItem?.isFoldPlaceholder, true, "折叠起始行应标记为 fold placeholder")
    }

    func testGutterProjectionCurrentLine() {
        let code = "a\nb\nc"
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        let folding = EditorCodeFoldingProjection.make(snapshot: snapshot, state: EditorCodeFoldingState())
        let gutterState = EditorGutterState(currentLine: 1)

        let projection = EditorGutterProjectionBuilder.make(snapshot: snapshot, folding: folding, state: gutterState)

        XCTAssertFalse(projection.lineItems[0].isCurrentLine)
        XCTAssertTrue(projection.lineItems[1].isCurrentLine, "第 1 行（0-based）应标为当前行")
        XCTAssertFalse(projection.lineItems[2].isCurrentLine)
    }

    func testGutterProjectionCurrentLineHighlightDisabled() {
        let code = "a\nb\nc"
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        let folding = EditorCodeFoldingProjection.make(snapshot: snapshot, state: EditorCodeFoldingState())
        let gutterState = EditorGutterState(currentLine: 1, showsCurrentLineHighlight: false)

        let projection = EditorGutterProjectionBuilder.make(snapshot: snapshot, folding: folding, state: gutterState)

        // 高亮关闭时所有行都不应标为当前行
        for item in projection.lineItems {
            XCTAssertFalse(item.isCurrentLine)
        }
    }

    func testGutterProjectionBreakpoints() {
        let code = "a\nb\nc"
        let snapshot = analyzer.analyze(filePath: "test.swift", text: code)
        let folding = EditorCodeFoldingProjection.make(snapshot: snapshot, state: EditorCodeFoldingState())
        var breakpoints = EditorBreakpointSet()
        breakpoints.toggle(line: 0)
        breakpoints.toggle(line: 2)
        let gutterState = EditorGutterState(breakpoints: breakpoints)

        let projection = EditorGutterProjectionBuilder.make(snapshot: snapshot, folding: folding, state: gutterState)

        XCTAssertTrue(projection.lineItems[0].hasBreakpoint)
        XCTAssertFalse(projection.lineItems[1].hasBreakpoint)
        XCTAssertTrue(projection.lineItems[2].hasBreakpoint)
    }

    // MARK: - 断点集合

    func testBreakpointSetToggle() {
        var bps = EditorBreakpointSet()
        XCTAssertTrue(bps.isEmpty)

        bps.toggle(line: 5)
        XCTAssertTrue(bps.contains(line: 5))
        XCTAssertEqual(bps.count, 1)

        bps.toggle(line: 5)
        XCTAssertFalse(bps.contains(line: 5))
        XCTAssertTrue(bps.isEmpty)
    }

    func testBreakpointSetRemoveAll() {
        var bps = EditorBreakpointSet()
        bps.toggle(line: 0)
        bps.toggle(line: 10)
        bps.toggle(line: 100)
        XCTAssertEqual(bps.count, 3)

        bps.removeAll()
        XCTAssertTrue(bps.isEmpty)
    }

    func testBreakpointSetIsolation() {
        var bps1 = EditorBreakpointSet()
        var bps2 = EditorBreakpointSet()
        bps1.toggle(line: 1)
        bps2.toggle(line: 2)

        XCTAssertTrue(bps1.contains(line: 1))
        XCTAssertFalse(bps1.contains(line: 2))
        XCTAssertFalse(bps2.contains(line: 1))
        XCTAssertTrue(bps2.contains(line: 2))
    }

    // MARK: - Gutter 投影：宽度指标

    func testGutterLayoutMetrics() {
        // 生成一个 100 行文档
        let lines = (0..<100).map { "line\($0)" }.joined(separator: "\n")
        let snapshot = analyzer.analyze(filePath: "test.swift", text: lines)
        let folding = EditorCodeFoldingProjection.make(snapshot: snapshot, state: EditorCodeFoldingState())
        let gutterState = EditorGutterState()

        let projection = EditorGutterProjectionBuilder.make(snapshot: snapshot, folding: folding, state: gutterState)

        XCTAssertEqual(projection.layoutMetrics.lineNumberDigits, 3, "100 行文档最大显示 100，需 3 位")
        XCTAssertEqual(projection.layoutMetrics.leadingAccessorySlots, 2, "应有断点位和折叠按钮位")
    }
}
