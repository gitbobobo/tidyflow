import XCTest
@testable import TidyFlowShared

/// 编辑器括号/引号匹配语义共享层测试。
///
/// 覆盖：嵌套括号、跨行括号、字符串中的假括号、注释中的假括号、
/// 转义引号、JSON 单引号禁用和选区非折叠场景。
final class EditorPairMatchSemanticsTests: XCTestCase {

    // MARK: - 基础括号匹配

    /// 光标位于 `(` 后时应找到对应 `)`
    func testBracketPairMatchedAroundCaret() {
        // "foo(bar)"
        // 光标在 ( 后面，即位置 4（0-based UTF-16: f=0, o=1, o=2, (=3, b=4...）
        // 左侧字符是 (，偏移 3
        let text = "foo(bar)"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.state, .matched)
        XCTAssertEqual(snap.highlights.count, 2)

        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 3, "活动分隔符应为 ( 位于偏移 3")
        XCTAssertEqual(paired?.location, 7, "配对分隔符应为 ) 位于偏移 7")
    }

    /// 光标位于 `)` 前时应找到对应 `(`
    func testCloseBracketMatchesOpenBracket() {
        let text = "foo(bar)"
        // 光标位于偏移 7，左侧字符是 r(偏移6)，右侧字符是 )(偏移7)
        // 左侧 r 不是分隔符，检查右侧 ) 偏移 7
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 7)
        XCTAssertEqual(snap.state, .matched)

        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 7)
        XCTAssertEqual(paired?.location, 3)
    }

    // MARK: - 嵌套括号

    /// 嵌套括号应匹配当前层的合法配对
    func testNestedBracketPairUsesNearestValidPair() {
        let text = "a(b[c]d)"
        // 光标在偏移 2，左侧 ( 偏移1，应匹配 ) 偏移7
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 2)
        XCTAssertEqual(snap.state, .matched)

        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 1)
        XCTAssertEqual(paired?.location, 7)
    }

    func testNestedInnerBracket() {
        let text = "a(b[c]d)"
        // 光标在偏移 4，左侧 [ 偏移3，应匹配 ] 偏移5
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.state, .matched)

        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 3)
        XCTAssertEqual(paired?.location, 5)
    }

    // MARK: - 跨行括号

    func testCrossLineBracketMatching() {
        let text = "func foo() {\n    bar()\n}"
        // f(0) u(1) n(2) c(3) (4) f(5) o(6) o(7) ((8) )(9) (10) {(11) \n(12)
        // 光标在 12，左侧是 { 偏移 11
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 12)
        XCTAssertEqual(snap.state, .matched)

        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 11)
        // } 在最后一个字符
        let closeBraceOffset = (text as NSString).length - 1
        XCTAssertEqual(paired?.location, closeBraceOffset)
    }

    // MARK: - 注释中的假括号

    /// 行注释中的括号不参与匹配
    func testCommentContentDoesNotParticipateInMatching() {
        let text = "// (foo)"
        // 光标在偏移 4，左侧 ( 偏移3 位于行注释中
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.state, .inactive, "注释内的括号应返回 inactive")
    }

    /// 块注释中的括号不参与匹配
    func testBlockCommentBracketsInactive() {
        let text = "/* (foo) */"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.state, .inactive)
    }

    /// 扫描跳过注释中的括号
    func testScanSkipsCommentBrackets() {
        // 开括号在代码中，注释中有假的闭括号，真闭括号在注释后
        let text = "foo(// )\nbar)"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.state, .matched)

        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        let closingOffset = (text as NSString).range(of: "bar)").location + 3
        XCTAssertEqual(paired?.location, closingOffset)
    }

    // MARK: - 字符串中的假括号

    /// 字符串内的括号不参与匹配
    func testStringContentDoesNotParticipateInBracketMatching() {
        let text = "let s = \"(hello)\""
        // 光标在 ( 后面，( 偏移 9，位于字符串中
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 10)
        XCTAssertEqual(snap.state, .inactive, "字符串中的括号应返回 inactive")
    }

    /// 扫描跳过字符串中的假括号
    func testScanSkipsStringBrackets() {
        let text = "foo(\")\", bar)"
        // ( 偏移3 在代码中，字符串 ")" 中的 ) 应被跳过，真 ) 在最后
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.state, .matched)

        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        let closingOffset = (text as NSString).length - 1
        XCTAssertEqual(paired?.location, closingOffset)
    }

    // MARK: - 引号匹配

    func testDoubleQuoteMatching() {
        let text = "let s = \"hello\""
        // 光标在偏移 9，左侧 " 偏移 8
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 9)
        XCTAssertEqual(snap.state, .matched)

        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 8)
        XCTAssertEqual(paired?.location, 14)
    }

    func testSingleQuoteMatchingInSwift() {
        // Swift 中 ' 可用于字符字面量或者普通场景
        let text = "let c = 'a'"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 9)
        XCTAssertEqual(snap.state, .matched)
    }

    // MARK: - 转义引号

    /// 转义引号不会提前结束字符串配对
    func testEscapedQuoteDoesNotTerminateStringPair() {
        let text = "let s = \"he\\\"llo\""
        // 实际文本: l(0) e(1) t(2) (3) s(4) (5) =(6) (7) "(8) h(9) e(10) \(11) "(12) l(13) l(14) o(15) "(16)
        // 第一个 " 偏移 8，\" 中的 " 偏移 12 被转义不是真引号
        // 闭合 " 偏移 16
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 9)
        XCTAssertEqual(snap.state, .matched)

        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 8)
        XCTAssertEqual(paired?.location, 16)
    }

    // MARK: - JSON 限制

    /// JSON 中单引号不参与匹配
    func testJSONSingleQuoteReturnsInactive() {
        let text = "{'key': 'value'}"
        // 光标在偏移 2，左侧 ' 偏移1
        let snap = EditorPairMatcher.match(filePath: "test.json", text: text, selectionLocation: 2)
        // JSON 中 ' 不是受支持的分隔符
        // 左侧 ' 不受支持，右侧 k 也不是分隔符
        XCTAssertNotEqual(snap.state, .matched, "JSON 中单引号不应产生匹配")
    }

    /// JSON 中双引号正常工作
    func testJSONDoubleQuoteWorks() {
        let text = "{\"key\": \"value\"}"
        // { 偏移0，光标偏移1，左侧是 { 偏移0
        let snap = EditorPairMatcher.match(filePath: "test.json", text: text, selectionLocation: 1)
        XCTAssertEqual(snap.state, .matched)
    }

    /// JSON 中反引号返回 inactive
    func testJSONBacktickReturnsInactive() {
        let text = "{`key`: `value`}"
        let snap = EditorPairMatcher.match(filePath: "test.json", text: text, selectionLocation: 2)
        // ` 在 JSON 中不受支持
        XCTAssertNotEqual(snap.state, .matched)
    }

    // MARK: - 选区非折叠

    /// 选区长度大于 0 时应返回 inactive
    func testNonCollapsedSelectionDisablesPairHighlight() {
        let text = "foo(bar)"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4, selectionLength: 3)
        XCTAssertEqual(snap.state, .inactive, "选区非折叠时应返回 inactive")
    }

    // MARK: - Markdown 和 PlainText

    func testMarkdownReturnsInactive() {
        let text = "# Hello (world)"
        let snap = EditorPairMatcher.match(filePath: "readme.md", text: text, selectionLocation: 9)
        XCTAssertEqual(snap.state, .inactive, "Markdown 应直接返回 inactive")
    }

    func testPlainTextReturnsInactive() {
        let text = "hello (world)"
        let snap = EditorPairMatcher.match(filePath: "notes.txt", text: text, selectionLocation: 7)
        XCTAssertEqual(snap.state, .inactive, "PlainText 应直接返回 inactive")
    }

    // MARK: - 不匹配场景

    func testUnmatchedOpenBracket() {
        let text = "foo("
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.state, .mismatched)
        XCTAssertEqual(snap.highlights.count, 1)
        XCTAssertEqual(snap.highlights[0].role, .mismatchDelimiter)
    }

    func testUnmatchedCloseBracket() {
        let text = ")bar"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 0)
        // 右侧 ) 偏移0
        XCTAssertEqual(snap.state, .mismatched)
    }

    // MARK: - 方括号和花括号

    func testSquareBracketMatching() {
        let text = "arr[0]"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.state, .matched)
        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 3)
        XCTAssertEqual(paired?.location, 5)
    }

    func testCurlyBraceMatching() {
        let text = "if true { x }"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 9)
        XCTAssertEqual(snap.state, .matched)
    }

    // MARK: - 边界场景

    func testEmptyText() {
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: "", selectionLocation: 0)
        XCTAssertEqual(snap.state, .inactive)
    }

    func testCursorAtEnd() {
        let text = "foo()"
        // 光标在末尾偏移5，左侧 ) 偏移4
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 5)
        XCTAssertEqual(snap.state, .matched)
        let active = snap.highlights.first { $0.role == .activeDelimiter }
        XCTAssertEqual(active?.location, 4)
    }

    func testCursorAtStart() {
        let text = "(bar)"
        // 光标在偏移0，左侧无，右侧 ( 偏移0
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 0)
        XCTAssertEqual(snap.state, .matched)
        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 0)
        XCTAssertEqual(paired?.location, 4)
    }

    // MARK: - 无活动分隔符

    func testNoDelimiterNearCursor() {
        let text = "hello world"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 5)
        XCTAssertEqual(snap.state, .inactive)
        XCTAssertTrue(snap.highlights.isEmpty)
    }

    // MARK: - 快照字段验证

    func testSnapshotContainsCorrectMetadata() {
        let text = "foo(bar)"
        let snap = EditorPairMatcher.match(filePath: "test.swift", text: text, selectionLocation: 4)
        XCTAssertEqual(snap.language, .swift)
        XCTAssertEqual(snap.selectionLocation, 4)
        XCTAssertEqual(snap.contentFingerprint, EditorSyntaxFingerprint.compute(text))
    }

    // MARK: - 反引号匹配

    func testBacktickMatchingInJavaScript() {
        let text = "const s = `hello`"
        // 光标偏移 12，左侧 ` 偏移 10? 不对。
        // c=0,o=1,n=2,s=3,t=4, =5,s=6, =7,==8, =9,`=10,h=11,...
        // 光标在偏移 11，左侧 ` 偏移 10
        let snap = EditorPairMatcher.match(filePath: "test.js", text: text, selectionLocation: 11)
        XCTAssertEqual(snap.state, .matched)

        let active = snap.highlights.first { $0.role == .activeDelimiter }
        let paired = snap.highlights.first { $0.role == .pairedDelimiter }
        XCTAssertEqual(active?.location, 10)
        XCTAssertEqual(paired?.location, 16)
    }

    // MARK: - 多语言支持

    func testRustBracketMatching() {
        let text = "fn main() {}"
        let snap = EditorPairMatcher.match(filePath: "main.rs", text: text, selectionLocation: 11)
        XCTAssertEqual(snap.state, .matched)
        XCTAssertEqual(snap.language, .rust)
    }

    func testTypeScriptBracketMatching() {
        let text = "const f = () => {}"
        let snap = EditorPairMatcher.match(filePath: "app.ts", text: text, selectionLocation: 17)
        XCTAssertEqual(snap.state, .matched)
        XCTAssertEqual(snap.language, .typescript)
    }

    func testPythonBracketMatching() {
        let text = "print(\"hello\")"
        let snap = EditorPairMatcher.match(filePath: "main.py", text: text, selectionLocation: 6)
        XCTAssertEqual(snap.state, .matched)
        XCTAssertEqual(snap.language, .python)
    }
}
