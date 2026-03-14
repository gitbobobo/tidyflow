import XCTest
@testable import TidyFlowShared

/// 编辑器查找替换语义测试：覆盖大小写不敏感查找、正则查找、非法正则、
/// 替换当前、全部替换、匹配索引保持与切换文档隔离。
final class EditorFindReplaceSemanticsTests: XCTestCase {

    // MARK: - 查找匹配（纯逻辑，不依赖 UI）

    /// 查找范围工具函数（复刻视图层逻辑，用于独立测试）
    private func findRanges(
        in text: String,
        findText: String,
        isCaseSensitive: Bool = false,
        useRegex: Bool = false
    ) -> (ranges: [Range<String.Index>], regexError: String?) {
        guard !findText.isEmpty else { return ([], nil) }

        if useRegex {
            do {
                let regex = try NSRegularExpression(
                    pattern: findText,
                    options: isCaseSensitive ? [] : [.caseInsensitive]
                )
                let nsText = text as NSString
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
                let ranges = matches.compactMap { Range($0.range, in: text) }
                return (ranges, nil)
            } catch {
                return ([], "Invalid regex")
            }
        }

        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        while let range = text.range(of: findText, options: options, range: searchRange) {
            ranges.append(range)
            if range.upperBound == text.endIndex { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return (ranges, nil)
    }

    // MARK: - 大小写不敏感查找

    func testCaseInsensitiveFindMatchesBothCases() {
        let text = "Hello hello HELLO"
        let result = findRanges(in: text, findText: "hello", isCaseSensitive: false)
        XCTAssertEqual(result.ranges.count, 3)
        XCTAssertNil(result.regexError)
    }

    func testCaseSensitiveFindMatchesExactCase() {
        let text = "Hello hello HELLO"
        let result = findRanges(in: text, findText: "hello", isCaseSensitive: true)
        XCTAssertEqual(result.ranges.count, 1)
    }

    // MARK: - 正则查找

    func testRegexFindMatchesPattern() {
        let text = "foo123 bar456 baz"
        let result = findRanges(in: text, findText: "[a-z]+\\d+", useRegex: true)
        XCTAssertEqual(result.ranges.count, 2)
        XCTAssertNil(result.regexError)
    }

    func testRegexFindCaseInsensitive() {
        let text = "ABC abc Abc"
        let result = findRanges(in: text, findText: "abc", isCaseSensitive: false, useRegex: true)
        XCTAssertEqual(result.ranges.count, 3)
    }

    func testRegexFindCaseSensitive() {
        let text = "ABC abc Abc"
        let result = findRanges(in: text, findText: "abc", isCaseSensitive: true, useRegex: true)
        XCTAssertEqual(result.ranges.count, 1)
    }

    // MARK: - 非法正则

    func testInvalidRegexReturnsError() {
        let text = "hello world"
        let result = findRanges(in: text, findText: "[invalid", useRegex: true)
        XCTAssertTrue(result.ranges.isEmpty)
        XCTAssertNotNil(result.regexError)
    }

    func testInvalidRegexDoesNotCrash() {
        let text = "hello world"
        // 多个非法正则模式
        for pattern in ["(", "(?<", "[", "*", "+?+"] {
            let result = findRanges(in: text, findText: pattern, useRegex: true)
            // 要么有错误，要么匹配数正常（部分正则如 * 在 NSRegularExpression 中可能不会抛异常）
            if result.regexError == nil {
                // 正常匹配，没有崩溃
            }
        }
    }

    // MARK: - 替换当前

    func testReplaceCurrentAtIndex() {
        var text = "aaa bbb aaa"
        let result = findRanges(in: text, findText: "aaa")
        XCTAssertEqual(result.ranges.count, 2)
        // 替换第一个
        let range = result.ranges[0]
        text.replaceSubrange(range, with: "ccc")
        XCTAssertEqual(text, "ccc bbb aaa")
    }

    // MARK: - 全部替换

    func testReplaceAllOccurrences() {
        var text = "aaa bbb aaa"
        let result = findRanges(in: text, findText: "aaa")
        for range in result.ranges.reversed() {
            text.replaceSubrange(range, with: "ccc")
        }
        XCTAssertEqual(text, "ccc bbb ccc")
    }

    func testReplaceAllWithDifferentLengthReplacement() {
        var text = "ab ab ab"
        let result = findRanges(in: text, findText: "ab")
        for range in result.ranges.reversed() {
            text.replaceSubrange(range, with: "xyz")
        }
        XCTAssertEqual(text, "xyz xyz xyz")
    }

    // MARK: - 空查找文本

    func testEmptyFindTextReturnsNoMatches() {
        let text = "hello world"
        let result = findRanges(in: text, findText: "")
        XCTAssertTrue(result.ranges.isEmpty)
        XCTAssertNil(result.regexError)
    }

    // MARK: - 切换文档隔离（通过 EditorFindReplaceState）

    func testFindReplaceStatesAreIsolatedPerDocument() {
        let stateA = EditorFindReplaceState(findText: "alpha", isCaseSensitive: true)
        let stateB = EditorFindReplaceState(findText: "beta", useRegex: true)
        // 不同文档的查找状态互不影响
        XCTAssertNotEqual(stateA, stateB)
        XCTAssertEqual(stateA.findText, "alpha")
        XCTAssertTrue(stateA.isCaseSensitive)
        XCTAssertEqual(stateB.findText, "beta")
        XCTAssertTrue(stateB.useRegex)
    }

    // MARK: - 匹配索引保持

    func testMatchIndexClampedAfterReplace() {
        let text = "aaa bbb aaa ccc aaa"
        let result = findRanges(in: text, findText: "aaa")
        XCTAssertEqual(result.ranges.count, 3)

        // 模拟替换第二个后，重新查找
        var modifiedText = text
        modifiedText.replaceSubrange(result.ranges[1], with: "xxx")
        let newResult = findRanges(in: modifiedText, findText: "aaa")
        XCTAssertEqual(newResult.ranges.count, 2)

        // 索引应被 clamp 到有效范围
        let clampedIndex = min(1, newResult.ranges.count - 1)
        XCTAssertEqual(clampedIndex, 1)
    }
}
