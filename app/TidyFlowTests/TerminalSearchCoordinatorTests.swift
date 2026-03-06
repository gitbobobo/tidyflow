import XCTest
@testable import TidyFlow

// TerminalSearchEngine 是在 MacSwiftTermTerminalView.swift 内定义的纯逻辑结构，
// 通过 @testable import TidyFlow 可直接访问。

final class TerminalSearchCoordinatorTests: XCTestCase {

    // MARK: - 初始状态

    func testInitialStateIsEmpty() {
        let engine = TerminalSearchEngine()
        XCTAssertEqual(engine.query, "")
        XCTAssertFalse(engine.caseSensitive)
        XCTAssertFalse(engine.useRegex)
        XCTAssertEqual(engine.matchCount, 0)
        XCTAssertEqual(engine.currentMatchIndex, -1)
        XCTAssertNil(engine.currentMatch)
    }

    // MARK: - 基础搜索

    func testSearchFindsMatchInSingleLine() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["hello world"], query: "world", caseSensitive: false, useRegex: false)
        XCTAssertEqual(engine.matchCount, 1)
        XCTAssertEqual(engine.currentMatchIndex, 0)
        let match = engine.currentMatch
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.row, 0)
        XCTAssertEqual(match?.startCol, 6)
        XCTAssertEqual(match?.endCol, 11)
    }

    func testSearchFindsMultipleMatchesAcrossLines() {
        var engine = TerminalSearchEngine()
        let lines = ["foo bar", "baz foo", "nothing"]
        engine.search(in: lines, query: "foo", caseSensitive: false, useRegex: false)
        XCTAssertEqual(engine.matchCount, 2)
        XCTAssertEqual(engine.results[0].row, 0)
        XCTAssertEqual(engine.results[1].row, 1)
    }

    func testEmptyQueryClearsResults() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["hello"], query: "hello", caseSensitive: false, useRegex: false)
        XCTAssertEqual(engine.matchCount, 1)
        engine.search(in: ["hello"], query: "", caseSensitive: false, useRegex: false)
        XCTAssertEqual(engine.matchCount, 0)
        XCTAssertEqual(engine.currentMatchIndex, -1)
    }

    // MARK: - 大小写敏感选项

    func testCaseSensitiveSearchDistinguishesCase() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["Hello World"], query: "hello", caseSensitive: true, useRegex: false)
        XCTAssertEqual(engine.matchCount, 0, "大小写敏感时不应匹配大写 Hello")

        engine.search(in: ["Hello World"], query: "Hello", caseSensitive: true, useRegex: false)
        XCTAssertEqual(engine.matchCount, 1)
    }

    func testCaseInsensitiveSearchIgnoresCase() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["Hello World"], query: "hello", caseSensitive: false, useRegex: false)
        XCTAssertEqual(engine.matchCount, 1)
    }

    // MARK: - 正则表达式选项

    func testRegexSearchMatchesPattern() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["error: 42", "info: ok"], query: "error: \\d+", caseSensitive: false, useRegex: true)
        XCTAssertEqual(engine.matchCount, 1)
        XCTAssertEqual(engine.currentMatch?.row, 0)
    }

    func testRegexSearchWithInvalidPatternReturnsZeroMatches() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["test"], query: "[invalid(", caseSensitive: false, useRegex: true)
        XCTAssertEqual(engine.matchCount, 0)
    }

    func testRegexCaseInsensitiveOption() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["ERROR: something"], query: "error", caseSensitive: false, useRegex: true)
        XCTAssertEqual(engine.matchCount, 1)

        engine.search(in: ["ERROR: something"], query: "error", caseSensitive: true, useRegex: true)
        XCTAssertEqual(engine.matchCount, 0)
    }

    // MARK: - 导航：循环行为

    func testNavigateNextCyclesThroughResults() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["a b a"], query: "a", caseSensitive: false, useRegex: false)
        XCTAssertEqual(engine.matchCount, 2)
        XCTAssertEqual(engine.currentMatchIndex, 0)

        engine.next()
        XCTAssertEqual(engine.currentMatchIndex, 1)

        // 从最后一个循环到第一个
        engine.next()
        XCTAssertEqual(engine.currentMatchIndex, 0)
    }

    func testNavigatePreviousCyclesBackward() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["a b a"], query: "a", caseSensitive: false, useRegex: false)
        XCTAssertEqual(engine.currentMatchIndex, 0)

        // 从第一个向前循环到最后一个
        engine.previous()
        XCTAssertEqual(engine.currentMatchIndex, 1)

        engine.previous()
        XCTAssertEqual(engine.currentMatchIndex, 0)
    }

    func testNavigateOnEmptyResultsIsNoop() {
        var engine = TerminalSearchEngine()
        engine.next()
        XCTAssertEqual(engine.currentMatchIndex, -1)
        engine.previous()
        XCTAssertEqual(engine.currentMatchIndex, -1)
    }

    // MARK: - 清除搜索

    func testClearResetsAllState() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["hello"], query: "hello", caseSensitive: true, useRegex: true)
        XCTAssertEqual(engine.matchCount, 1)

        engine.clear()
        XCTAssertEqual(engine.query, "")
        XCTAssertEqual(engine.matchCount, 0)
        XCTAssertEqual(engine.currentMatchIndex, -1)
        XCTAssertNil(engine.currentMatch)
    }

    // MARK: - 匹配边界验证

    func testMatchPositionsAreCorrect() {
        var engine = TerminalSearchEngine()
        engine.search(in: ["abcabc"], query: "bc", caseSensitive: false, useRegex: false)
        XCTAssertEqual(engine.matchCount, 2)
        XCTAssertEqual(engine.results[0].startCol, 1)
        XCTAssertEqual(engine.results[0].endCol, 3)
        XCTAssertEqual(engine.results[1].startCol, 4)
        XCTAssertEqual(engine.results[1].endCol, 6)
    }
}
