import XCTest
@testable import TidyFlowShared

/// 编辑器查找替换语义测试：验证共享引擎 EditorFindReplaceEngine 的纯值 API。
/// 覆盖大小写不敏感查找、正则查找、非法正则、替换当前、全部替换、
/// 匹配索引钳制、高亮目标行解析与切换文档隔离。
final class EditorFindReplaceSemanticsTests: XCTestCase {

    // MARK: - 大小写不敏感查找

    func testCaseInsensitiveFindMatchesBothCases() {
        let text = "Hello hello HELLO"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "hello", isCaseSensitive: false)
        XCTAssertEqual(result.ranges.count, 3)
        XCTAssertNil(result.regexError)
    }

    func testCaseSensitiveFindMatchesExactCase() {
        let text = "Hello hello HELLO"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "hello", isCaseSensitive: true)
        XCTAssertEqual(result.ranges.count, 1)
    }

    // MARK: - 正则查找

    func testRegexFindMatchesPattern() {
        let text = "foo123 bar456 baz"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "[a-z]+\\d+", useRegex: true)
        XCTAssertEqual(result.ranges.count, 2)
        XCTAssertNil(result.regexError)
    }

    func testRegexFindCaseInsensitive() {
        let text = "ABC abc Abc"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "abc", isCaseSensitive: false, useRegex: true)
        XCTAssertEqual(result.ranges.count, 3)
    }

    func testRegexFindCaseSensitive() {
        let text = "ABC abc Abc"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "abc", isCaseSensitive: true, useRegex: true)
        XCTAssertEqual(result.ranges.count, 1)
    }

    // MARK: - 非法正则

    func testInvalidRegexReturnsError() {
        let text = "hello world"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "[invalid", useRegex: true)
        XCTAssertTrue(result.ranges.isEmpty)
        XCTAssertNotNil(result.regexError)
    }

    func testInvalidRegexDoesNotCrash() {
        let text = "hello world"
        for pattern in ["(", "(?<", "[", "*", "+?+"] {
            let result = EditorFindReplaceEngine.findMatches(in: text, findText: pattern, useRegex: true)
            // 要么有错误，要么匹配数正常（部分正则如 * 在 NSRegularExpression 中可能不会抛异常）
            _ = result.regexError
        }
    }

    // MARK: - 替换当前（通过共享引擎）

    func testReplaceCurrentAtIndex() {
        let text = "aaa bbb aaa"
        let state = EditorFindReplaceState(findText: "aaa", replaceText: "ccc")
        let findResult = EditorFindReplaceEngine.findMatches(in: text, state: state)
        XCTAssertEqual(findResult.ranges.count, 2)

        let result = EditorFindReplaceEngine.replaceCurrent(
            in: text, matchRanges: findResult.ranges, currentIndex: 0, replaceText: "ccc", state: state
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "ccc bbb aaa")
    }

    func testReplaceCurrentWithInvalidIndexReturnsNil() {
        let text = "aaa bbb"
        let state = EditorFindReplaceState(findText: "aaa", replaceText: "ccc")
        let findResult = EditorFindReplaceEngine.findMatches(in: text, state: state)
        let result = EditorFindReplaceEngine.replaceCurrent(
            in: text, matchRanges: findResult.ranges, currentIndex: 5, replaceText: "ccc", state: state
        )
        XCTAssertNil(result)
    }

    func testReplaceCurrentWithRegexErrorReturnsNil() {
        let text = "aaa"
        var state = EditorFindReplaceState(findText: "aaa", replaceText: "ccc")
        state.regexError = "some error"
        let findResult = EditorFindReplaceEngine.findMatches(in: text, findText: "aaa")
        let result = EditorFindReplaceEngine.replaceCurrent(
            in: text, matchRanges: findResult.ranges, currentIndex: 0, replaceText: "ccc", state: state
        )
        XCTAssertNil(result)
    }

    // MARK: - 全部替换（通过共享引擎）

    func testReplaceAllOccurrences() {
        let text = "aaa bbb aaa"
        let state = EditorFindReplaceState(findText: "aaa", replaceText: "ccc")
        let findResult = EditorFindReplaceEngine.findMatches(in: text, state: state)

        let result = EditorFindReplaceEngine.replaceAll(
            in: text, matchRanges: findResult.ranges, replaceText: "ccc", state: state
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "ccc bbb ccc")
    }

    func testReplaceAllWithDifferentLengthReplacement() {
        let text = "ab ab ab"
        let state = EditorFindReplaceState(findText: "ab", replaceText: "xyz")
        let findResult = EditorFindReplaceEngine.findMatches(in: text, state: state)

        let result = EditorFindReplaceEngine.replaceAll(
            in: text, matchRanges: findResult.ranges, replaceText: "xyz", state: state
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "xyz xyz xyz")
    }

    func testReplaceAllEmptyMatchesReturnsNil() {
        let text = "aaa"
        let state = EditorFindReplaceState(findText: "zzz", replaceText: "ccc")
        let result = EditorFindReplaceEngine.replaceAll(
            in: text, matchRanges: [], replaceText: "ccc", state: state
        )
        XCTAssertNil(result)
    }

    // MARK: - 空查找文本

    func testEmptyFindTextReturnsNoMatches() {
        let text = "hello world"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "")
        XCTAssertTrue(result.ranges.isEmpty)
        XCTAssertNil(result.regexError)
    }

    // MARK: - 匹配索引钳制

    func testClampMatchIndexWithKeepSelection() {
        XCTAssertEqual(EditorFindReplaceEngine.clampMatchIndex(currentIndex: 5, matchCount: 3, keepSelection: true), 2)
        XCTAssertEqual(EditorFindReplaceEngine.clampMatchIndex(currentIndex: 1, matchCount: 3, keepSelection: true), 1)
        XCTAssertEqual(EditorFindReplaceEngine.clampMatchIndex(currentIndex: -1, matchCount: 3, keepSelection: true), 0)
    }

    func testClampMatchIndexWithoutKeepSelection() {
        XCTAssertEqual(EditorFindReplaceEngine.clampMatchIndex(currentIndex: 5, matchCount: 3, keepSelection: false), 0)
        XCTAssertEqual(EditorFindReplaceEngine.clampMatchIndex(currentIndex: -1, matchCount: 0, keepSelection: false), -1)
    }

    func testMatchIndexClampedAfterReplace() {
        let text = "aaa bbb aaa ccc aaa"
        let state = EditorFindReplaceState(findText: "aaa", replaceText: "xxx")
        let findResult = EditorFindReplaceEngine.findMatches(in: text, state: state)
        XCTAssertEqual(findResult.ranges.count, 3)

        let result = EditorFindReplaceEngine.replaceCurrent(
            in: text, matchRanges: findResult.ranges, currentIndex: 1, replaceText: "xxx", state: state
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.newRanges.count, 2)
        XCTAssertTrue(result!.currentMatchIndex >= 0 && result!.currentMatchIndex < result!.newRanges.count)
    }

    // MARK: - 导航索引

    func testNextMatchIndexWrapsAround() {
        XCTAssertEqual(EditorFindReplaceEngine.nextMatchIndex(currentIndex: 2, matchCount: 3), 0)
        XCTAssertEqual(EditorFindReplaceEngine.nextMatchIndex(currentIndex: 0, matchCount: 3), 1)
        XCTAssertEqual(EditorFindReplaceEngine.nextMatchIndex(currentIndex: -1, matchCount: 3), 0)
        XCTAssertEqual(EditorFindReplaceEngine.nextMatchIndex(currentIndex: 0, matchCount: 0), -1)
    }

    func testPreviousMatchIndexWrapsAround() {
        XCTAssertEqual(EditorFindReplaceEngine.previousMatchIndex(currentIndex: 0, matchCount: 3), 2)
        XCTAssertEqual(EditorFindReplaceEngine.previousMatchIndex(currentIndex: 2, matchCount: 3), 1)
        XCTAssertEqual(EditorFindReplaceEngine.previousMatchIndex(currentIndex: -1, matchCount: 3), 0)
        XCTAssertEqual(EditorFindReplaceEngine.previousMatchIndex(currentIndex: 0, matchCount: 0), -1)
    }

    // MARK: - 高亮目标行

    func testTargetLineForCurrentMatch() {
        let text = "line1\nline2\nline3"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "line3")
        XCTAssertEqual(result.ranges.count, 1)
        let line = EditorFindReplaceEngine.targetLineForCurrentMatch(in: text, matchRanges: result.ranges, currentIndex: 0)
        XCTAssertEqual(line, 3)
    }

    func testTargetLineForFirstLine() {
        let text = "hello\nworld"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "hello")
        let line = EditorFindReplaceEngine.targetLineForCurrentMatch(in: text, matchRanges: result.ranges, currentIndex: 0)
        XCTAssertEqual(line, 1)
    }

    func testTargetLineForInvalidIndexReturnsNil() {
        let text = "hello"
        let result = EditorFindReplaceEngine.findMatches(in: text, findText: "hello")
        let line = EditorFindReplaceEngine.targetLineForCurrentMatch(in: text, matchRanges: result.ranges, currentIndex: 5)
        XCTAssertNil(line)
    }

    // MARK: - 匹配状态文本

    func testMatchStatusText() {
        XCTAssertEqual(EditorFindReplaceEngine.matchStatusText(currentIndex: 0, matchCount: 5), "1/5")
        XCTAssertEqual(EditorFindReplaceEngine.matchStatusText(currentIndex: 4, matchCount: 5), "5/5")
        XCTAssertEqual(EditorFindReplaceEngine.matchStatusText(currentIndex: -1, matchCount: 0), "0/0")
        XCTAssertEqual(EditorFindReplaceEngine.matchStatusText(currentIndex: -1, matchCount: 3), "0/0")
    }

    // MARK: - 使用 State 对象查找

    func testFindMatchesWithState() {
        let text = "Hello hello HELLO"
        let state = EditorFindReplaceState(findText: "hello", isCaseSensitive: false)
        let result = EditorFindReplaceEngine.findMatches(in: text, state: state)
        XCTAssertEqual(result.ranges.count, 3)
    }

    // MARK: - 切换文档隔离（通过 EditorFindReplaceState）

    func testFindReplaceStatesAreIsolatedPerDocument() {
        let stateA = EditorFindReplaceState(findText: "alpha", isCaseSensitive: true)
        let stateB = EditorFindReplaceState(findText: "beta", useRegex: true)
        XCTAssertNotEqual(stateA, stateB)
        XCTAssertEqual(stateA.findText, "alpha")
        XCTAssertTrue(stateA.isCaseSensitive)
        XCTAssertEqual(stateB.findText, "beta")
        XCTAssertTrue(stateB.useRegex)
    }
}
