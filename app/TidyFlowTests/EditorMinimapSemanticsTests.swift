import XCTest
@testable import TidyFlowShared

/// 编辑器 minimap 共享语义层测试矩阵。
///
/// 覆盖：主导角色聚合、强调度计算、折叠行压缩、viewport clamp、
/// 显示阈值判定、多工作区隔离、点击跳转目标行映射。
final class EditorMinimapSemanticsTests: XCTestCase {

    private let highlighter = EditorSyntaxHighlighter()
    private let structureAnalyzer = EditorStructureAnalyzer()

    // MARK: - 辅助方法

    /// 构建完整的 minimap 投影
    private func buildProjection(
        text: String,
        filePath: String = "test.swift",
        viewportState: EditorViewportState? = nil,
        collapsedRegionIDs: Set<EditorFoldRegionID> = []
    ) -> EditorMinimapProjection {
        let syntaxSnapshot = highlighter.highlight(
            filePath: filePath,
            text: text,
            theme: .systemLight
        )
        let structSnapshot = structureAnalyzer.analyze(filePath: filePath, text: text)
        var foldState = EditorCodeFoldingState()
        foldState.collapsedRegionIDs = collapsedRegionIDs
        foldState.reconcile(snapshot: structSnapshot)
        let foldingProjection = EditorCodeFoldingProjection.make(snapshot: structSnapshot, state: foldState)

        let lineCount = text.components(separatedBy: "\n").count
        let vp = viewportState ?? EditorViewportState(
            firstVisibleLine: 0,
            lastVisibleLine: min(39, lineCount - 1),
            viewportLineSpan: 40,
            lineCount: lineCount
        )

        return EditorMinimapProjectionBuilder.make(
            text: text,
            filePath: filePath,
            syntaxSnapshot: syntaxSnapshot,
            structureSnapshot: structSnapshot,
            foldingProjection: foldingProjection,
            viewportState: vp
        )
    }

    /// 生成指定行数的测试文本
    private func generateLongText(lineCount: Int) -> String {
        (0..<lineCount).map { i in
            if i % 5 == 0 { return "func test\(i)() {" }
            if i % 5 == 4 { return "}" }
            return "    let x\(i) = \(i) // line \(i)"
        }.joined(separator: "\n")
    }

    // MARK: - 主导角色聚合

    func testDominantRoleForKeywordLine() {
        let code = "func hello() {\n    print(\"hi\")\n}"
        let projection = buildProjection(text: code)
        // 第一行包含 func 关键字和 hello 函数名，主导角色取 UTF-16 覆盖最多者
        let firstLine = projection.snapshot.lineDescriptors[0]
        XCTAssertTrue(
            [.keyword, .function].contains(firstLine.dominantRole),
            "func hello() 行主导角色应为 keyword 或 function"
        )
    }

    func testDominantRoleForCommentLine() {
        let code = "// 这是一行注释\nlet x = 1"
        let projection = buildProjection(text: code)
        let firstLine = projection.snapshot.lineDescriptors[0]
        XCTAssertEqual(firstLine.dominantRole, .comment, "注释行主导角色应为 comment")
    }

    func testDominantRoleForStringLine() {
        let code = "let msg = \"hello world this is a long string literal\""
        let projection = buildProjection(text: code)
        // 字符串占大部分的行，主导角色可能为 string 或 keyword
        let firstLine = projection.snapshot.lineDescriptors[0]
        XCTAssertTrue(
            [.string, .keyword, .plain].contains(firstLine.dominantRole),
            "字符串行主导角色应为合理的语义角色"
        )
    }

    func testDominantRoleFallbackPlainForEmptyLine() {
        let code = "let x = 1\n\nlet y = 2"
        let projection = buildProjection(text: code)
        // 空行应回退为 .plain
        let emptyLine = projection.snapshot.lineDescriptors[1]
        XCTAssertEqual(emptyLine.dominantRole, .plain, "空行主导角色应回退为 plain")
    }

    // MARK: - 强调度计算

    func testEmphasisClampedRange() {
        let code = "    x\n" + String(repeating: "a", count: 80)
        let projection = buildProjection(text: code)
        for line in projection.snapshot.lineDescriptors {
            XCTAssertGreaterThanOrEqual(line.emphasis, 0.15, "强调度不应小于 0.15")
            XCTAssertLessThanOrEqual(line.emphasis, 1.0, "强调度不应大于 1.0")
        }
    }

    func testEmptyLineHasMinimumEmphasis() {
        let code = "let x = 1\n\nlet y = 2"
        let projection = buildProjection(text: code)
        let emptyLine = projection.snapshot.lineDescriptors[1]
        XCTAssertEqual(emptyLine.emphasis, 0.15, "空行强调度应为最小值 0.15")
    }

    // MARK: - 折叠行压缩

    func testFoldedLinesExcludedFromMinimap() {
        let code = """
        func hello() {
            let a = 1
            let b = 2
            let c = 3
        }
        let outside = true
        """
        let structSnapshot = structureAnalyzer.analyze(filePath: "test.swift", text: code)
        guard let foldRegion = structSnapshot.foldRegions.first else {
            XCTFail("应检测到折叠区域")
            return
        }

        // 无折叠时应有 6 个可见行描述符
        let unfoldedProjection = buildProjection(text: code)
        XCTAssertEqual(unfoldedProjection.snapshot.visibleLineCount, 6, "未折叠应有 6 个可见行")

        // 折叠后，被隐藏的行应被排除
        let foldedProjection = buildProjection(
            text: code,
            collapsedRegionIDs: [foldRegion.id]
        )
        XCTAssertLessThan(
            foldedProjection.snapshot.visibleLineCount,
            unfoldedProjection.snapshot.visibleLineCount,
            "折叠后可见行数应减少"
        )

        // 折叠占位行应保留
        let foldPlaceholders = foldedProjection.snapshot.lineDescriptors.filter { $0.isFoldPlaceholder }
        XCTAssertFalse(foldPlaceholders.isEmpty, "折叠后应保留至少一个折叠占位行")
    }

    func testFoldedRegionPreservesFoldStartLine() {
        let code = """
        struct Outer {
            func inner() {
                print("body")
            }
        }
        """
        let structSnapshot = structureAnalyzer.analyze(filePath: "test.swift", text: code)
        guard let outerFold = structSnapshot.foldRegions.first(where: { $0.startLine == 0 }) else {
            XCTFail("应检测到 Outer 折叠区域")
            return
        }

        let projection = buildProjection(
            text: code,
            collapsedRegionIDs: [outerFold.id]
        )

        // 折叠起始行（line 0）应保留并标记为占位
        let startLine = projection.snapshot.lineDescriptors.first { $0.sourceLine == outerFold.startLine }
        XCTAssertNotNil(startLine, "折叠起始行应保留在 minimap 中")
        XCTAssertTrue(startLine?.isFoldPlaceholder ?? false, "折叠起始行应标记为占位行")
    }

    // MARK: - Viewport Clamp

    func testViewportClampForShortDocument() {
        let code = "line1\nline2\nline3"
        let vp = EditorViewportState(
            firstVisibleLine: 0,
            lastVisibleLine: 2,
            viewportLineSpan: 40,
            lineCount: 3
        )
        let projection = buildProjection(text: code, viewportState: vp)
        // 超短文档 viewport 应 clamp 到合理范围
        let vpProj = projection.viewportProjection
        XCTAssertGreaterThanOrEqual(vpProj.topRatio, 0.0, "topRatio 不应小于 0")
        XCTAssertLessThanOrEqual(vpProj.bottomRatio, 1.0, "bottomRatio 不应大于 1")
        XCTAssertGreaterThanOrEqual(vpProj.effectiveHeightRatio, vpProj.minimumHeightRatio, "高度不应小于最小值")
    }

    func testViewportClampForEmptyDocument() {
        let code = ""
        let vp = EditorViewportState(
            firstVisibleLine: 0,
            lastVisibleLine: 0,
            viewportLineSpan: 40,
            lineCount: 1
        )
        let projection = buildProjection(text: code, viewportState: vp)
        let vpProj = projection.viewportProjection
        XCTAssertGreaterThanOrEqual(vpProj.topRatio, 0.0)
        XCTAssertLessThanOrEqual(vpProj.bottomRatio, 1.0)
    }

    func testViewportClampForOutOfBoundsVisibleRange() {
        let code = "line1\nline2\nline3\nline4\nline5"
        let vp = EditorViewportState(
            firstVisibleLine: 10, // 越界
            lastVisibleLine: 20, // 越界
            viewportLineSpan: 11,
            lineCount: 5
        )
        let projection = buildProjection(text: code, viewportState: vp)
        let vpProj = projection.viewportProjection
        XCTAssertGreaterThanOrEqual(vpProj.topRatio, 0.0, "越界 viewport topRatio 应 clamp")
        XCTAssertLessThanOrEqual(vpProj.bottomRatio, 1.0, "越界 viewport bottomRatio 应 clamp")
    }

    // MARK: - 显示阈值判定

    func testShouldNotDisplayForShortDocument() {
        // 少于 80 行的文档不应显示 minimap
        let code = (0..<30).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        let vp = EditorViewportState(
            firstVisibleLine: 0,
            lastVisibleLine: 29,
            viewportLineSpan: 30,
            lineCount: 30
        )
        let projection = buildProjection(text: code, viewportState: vp)
        XCTAssertFalse(projection.shouldDisplay, "短文档（30行、viewport 30行）不应显示 minimap")
    }

    func testShouldDisplayForLongDocument() {
        // 100 行文档，viewport 40 行，应显示 minimap
        let code = generateLongText(lineCount: 100)
        let vp = EditorViewportState(
            firstVisibleLine: 0,
            lastVisibleLine: 39,
            viewportLineSpan: 40,
            lineCount: 100
        )
        let projection = buildProjection(text: code, viewportState: vp)
        XCTAssertTrue(projection.shouldDisplay, "长文档（100行、viewport 40行）应显示 minimap")
    }

    func testShouldNotDisplayWhenViewportCoversAll() {
        // 行数 >= 80 但 viewport 覆盖全部时不应显示
        // lineCount >= max(80, viewportLineSpan * 2) → viewportLineSpan = 80，需要 lineCount >= 160
        // 当 lineCount=85, viewportLineSpan=80: max(80, 160)=160 > 85，不显示
        let code = (0..<85).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        let vp = EditorViewportState(
            firstVisibleLine: 0,
            lastVisibleLine: 79,
            viewportLineSpan: 80,
            lineCount: 85
        )
        let projection = buildProjection(text: code, viewportState: vp)
        XCTAssertFalse(projection.shouldDisplay, "viewport 几乎覆盖全部时不应显示 minimap")
    }

    // MARK: - 点击跳转目标行映射

    func testTargetSourceLineFromRatio() {
        let code = generateLongText(lineCount: 100)
        let projection = buildProjection(text: code)

        // 顶部
        let topIdx = EditorMinimapProjectionBuilder.visibleLineIndex(fromRatio: 0.0, in: projection.snapshot)
        let topLine = EditorMinimapProjectionBuilder.targetSourceLine(fromVisibleLineIndex: topIdx, in: projection.snapshot)
        XCTAssertEqual(topLine, 0, "比例 0.0 应映射到第一行")

        // 底部
        let bottomIdx = EditorMinimapProjectionBuilder.visibleLineIndex(fromRatio: 1.0, in: projection.snapshot)
        let bottomLine = EditorMinimapProjectionBuilder.targetSourceLine(fromVisibleLineIndex: bottomIdx, in: projection.snapshot)
        XCTAssertNotNil(bottomLine, "比例 1.0 应映射到有效行")
        if let line = bottomLine {
            XCTAssertEqual(line, 99, "比例 1.0 应映射到最后一行")
        }
    }

    func testTargetSourceLineWithFoldedRegion() {
        let code = """
        func a() {
            let x = 1
            let y = 2
        }
        func b() {
            let z = 3
        }
        """
        let structSnapshot = structureAnalyzer.analyze(filePath: "test.swift", text: code)
        guard let firstFold = structSnapshot.foldRegions.first(where: { $0.startLine == 0 }) else {
            XCTFail("应检测到 a() 的折叠区域")
            return
        }

        let projection = buildProjection(
            text: code,
            collapsedRegionIDs: [firstFold.id]
        )

        // 折叠后，minimap 底部附近应映射到 func b 相关行
        let lastIdx = projection.snapshot.visibleLineCount - 1
        let lastLine = EditorMinimapProjectionBuilder.targetSourceLine(
            fromVisibleLineIndex: lastIdx,
            in: projection.snapshot
        )
        XCTAssertNotNil(lastLine, "折叠后最后一个可见行应有有效源行号")
    }

    func testOutOfBoundsVisibleLineIndexReturnsNil() {
        let code = "line1\nline2"
        let projection = buildProjection(text: code)
        let result = EditorMinimapProjectionBuilder.targetSourceLine(
            fromVisibleLineIndex: 999,
            in: projection.snapshot
        )
        XCTAssertNil(result, "越界可见行索引应返回 nil")
    }

    func testNegativeVisibleLineIndexReturnsNil() {
        let code = "line1\nline2"
        let projection = buildProjection(text: code)
        let result = EditorMinimapProjectionBuilder.targetSourceLine(
            fromVisibleLineIndex: -1,
            in: projection.snapshot
        )
        XCTAssertNil(result, "负数可见行索引应返回 nil")
    }

    // MARK: - EditorViewportState 基础

    func testViewportStateInit() {
        let vp = EditorViewportState(
            firstVisibleLine: 10,
            lastVisibleLine: 50,
            viewportLineSpan: 41,
            lineCount: 200
        )
        XCTAssertEqual(vp.firstVisibleLine, 10)
        XCTAssertEqual(vp.lastVisibleLine, 50)
        XCTAssertEqual(vp.viewportLineSpan, 41)
        XCTAssertEqual(vp.lineCount, 200)
    }

    // MARK: - 源行号索引连续性

    func testSourceLineIndexIsContiguousWithoutFolding() {
        let code = "line0\nline1\nline2\nline3\nline4"
        let projection = buildProjection(text: code)
        for (idx, descriptor) in projection.snapshot.lineDescriptors.enumerated() {
            XCTAssertEqual(descriptor.sourceLine, idx, "无折叠时源行号应与可见行索引一致")
            XCTAssertEqual(descriptor.visibleLineIndex, idx, "无折叠时可见行索引应连续")
        }
    }

    // MARK: - 空快照

    func testEmptySnapshotProperties() {
        let empty = EditorMinimapSnapshot.empty
        XCTAssertEqual(empty.totalLineCount, 0)
        XCTAssertEqual(empty.visibleLineCount, 0)
        XCTAssertTrue(empty.lineDescriptors.isEmpty)
    }

    // MARK: - ViewportProjection 有效比例

    func testEffectiveHeightRatioNotLessThanMinimum() {
        let vpProj = EditorMinimapViewportProjection(
            topRatio: 0.5,
            bottomRatio: 0.501, // 非常小的高度
            minimumHeightRatio: 0.02
        )
        XCTAssertGreaterThanOrEqual(
            vpProj.effectiveHeightRatio,
            0.02,
            "有效高度应不小于最小比例"
        )
    }

    func testFullViewportProjectionCoversEntireRange() {
        let full = EditorMinimapViewportProjection.full
        XCTAssertEqual(full.topRatio, 0.0)
        XCTAssertEqual(full.bottomRatio, 1.0)
        XCTAssertEqual(full.effectiveHeightRatio, 1.0, accuracy: 0.001)
    }
}
