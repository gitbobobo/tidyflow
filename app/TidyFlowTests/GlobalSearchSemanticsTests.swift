import XCTest
@testable import TidyFlow
import TidyFlowShared

/// 全局搜索共享语义层单元测试
/// 覆盖：状态模型、预览高亮片段、结果分组构建、缓存键隔离
final class GlobalSearchSemanticsTests: XCTestCase {

    // MARK: - GlobalSearchState 基础

    func testEmptyStateIsCorrect() {
        let state = GlobalSearchState.empty()
        XCTAssertTrue(state.query.isEmpty)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.sections.isEmpty)
        XCTAssertFalse(state.hasResults)
        XCTAssertEqual(state.totalMatches, 0)
        XCTAssertFalse(state.truncated)
        XCTAssertNil(state.error)
    }

    func testQueryNotEmpty() {
        let query = GlobalSearchQuery(text: "hello", caseSensitive: false)
        XCTAssertFalse(query.isEmpty)
        XCTAssertEqual(query.text, "hello")
    }

    func testEmptyQueryIsEmpty() {
        let query = GlobalSearchQuery(text: "", caseSensitive: false)
        XCTAssertTrue(query.isEmpty)
    }

    func testWhitespaceOnlyQueryIsEmpty() {
        let query = GlobalSearchQuery(text: "   ", caseSensitive: false)
        XCTAssertTrue(query.isEmpty)
    }

    // MARK: - GlobalSearchPreviewFormatter

    func testHighlightedSegmentsBasic() {
        let preview = "Hello world test"
        let ranges: [FileContentSearchMatchRange] = [
            FileContentSearchMatchRange(start: 6, end: 11) // "world"
        ]
        let segments = GlobalSearchPreviewFormatter.highlightedSegments(
            preview: preview,
            matchRanges: ranges
        )
        XCTAssertEqual(segments.count, 3) // "Hello ", "world", " test"
        XCTAssertFalse(segments[0].isHighlighted)
        XCTAssertTrue(segments[1].isHighlighted)
        XCTAssertEqual(segments[1].text, "world")
        XCTAssertFalse(segments[2].isHighlighted)
    }

    func testHighlightedSegmentsAtStart() {
        let preview = "Hello world"
        let ranges = [FileContentSearchMatchRange(start: 0, end: 5)]
        let segments = GlobalSearchPreviewFormatter.highlightedSegments(
            preview: preview,
            matchRanges: ranges
        )
        XCTAssertTrue(segments[0].isHighlighted)
        XCTAssertEqual(segments[0].text, "Hello")
    }

    func testHighlightedSegmentsNoRanges() {
        let preview = "Hello world"
        let segments = GlobalSearchPreviewFormatter.highlightedSegments(
            preview: preview,
            matchRanges: []
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments[0].isHighlighted)
        XCTAssertEqual(segments[0].text, "Hello world")
    }

    // MARK: - GlobalSearchResultBuilder

    func testBuildSectionsGroupsByFile() {
        let result = FileContentSearchResult(
            project: "proj",
            workspace: "ws",
            query: "test",
            scope: "proj:ws",
            items: [
                FileContentSearchItem(
                    path: "src/main.rs", line: 1, column: 0,
                    preview: "test line 1",
                    matchRanges: [FileContentSearchMatchRange(start: 0, end: 4)],
                    beforeContext: [], afterContext: []
                ),
                FileContentSearchItem(
                    path: "src/main.rs", line: 5, column: 0,
                    preview: "test line 5",
                    matchRanges: [FileContentSearchMatchRange(start: 0, end: 4)],
                    beforeContext: [], afterContext: []
                ),
                FileContentSearchItem(
                    path: "src/lib.rs", line: 3, column: 0,
                    preview: "test lib",
                    matchRanges: [FileContentSearchMatchRange(start: 0, end: 4)],
                    beforeContext: [], afterContext: []
                ),
            ],
            totalMatches: 3,
            truncated: false,
            searchDurationMs: 10
        )
        let sections = GlobalSearchResultBuilder.buildSections(from: result)
        XCTAssertEqual(sections.count, 2) // main.rs 和 lib.rs
        let mainSection = sections.first { $0.fileName == "main.rs" }
        XCTAssertNotNil(mainSection)
        XCTAssertEqual(mainSection?.matchCount, 2)
        XCTAssertEqual(mainSection?.matches.count, 2)
    }

    func testBuildSectionsEmptyResult() {
        let result = FileContentSearchResult(
            project: "proj",
            workspace: "ws",
            query: "nothing",
            scope: "proj:ws",
            items: [],
            totalMatches: 0,
            truncated: false,
            searchDurationMs: 1
        )
        let sections = GlobalSearchResultBuilder.buildSections(from: result)
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - 缓存键隔离

    func testGlobalKeyIsolation() {
        let key1 = WorkspaceKeySemantics.globalKey(project: "proj1", workspace: "default")
        let key2 = WorkspaceKeySemantics.globalKey(project: "proj2", workspace: "default")
        XCTAssertNotEqual(key1, key2, "不同项目的同名工作区必须有不同的全局键")
    }

    func testGlobalKeyFormat() {
        let key = WorkspaceKeySemantics.globalKey(project: "myProject", workspace: "dev")
        XCTAssertEqual(key, "myProject:dev")
    }
}
