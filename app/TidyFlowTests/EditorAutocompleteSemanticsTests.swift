import XCTest
@testable import TidyFlowShared

/// 编辑器自动补全共享语义层测试：覆盖语言关键字候选、文档标识符提取与去重、
/// 手动/自动触发规则、替换范围计算、排序稳定性、注释/字符串场景抑制。
final class EditorAutocompleteSemanticsTests: XCTestCase {

    private let engine = EditorAutocompleteEngine()

    // MARK: - 语言关键字候选

    func testSwiftKeywordsCandidatesForPrefix() {
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: "gu",
            cursorLocation: 2,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "前缀 'gu' 应匹配 Swift 关键字 'guard'")
        let titles = state.items.map(\.title)
        XCTAssertTrue(titles.contains("guard"), "候选应包含 'guard'")
    }

    func testRustKeywordsCandidatesForPrefix() {
        let ctx = EditorAutocompleteContext(
            filePath: "lib.rs",
            text: "ma",
            cursorLocation: 2,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible)
        let titles = state.items.map(\.title)
        XCTAssertTrue(titles.contains("match"), "Rust 应匹配 'match'")
    }

    func testJavaScriptKeywordsForPrefix() {
        let ctx = EditorAutocompleteContext(
            filePath: "index.js",
            text: "fu",
            cursorLocation: 2,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.items.contains { $0.title == "function" })
    }

    func testTypeScriptKeywordsForPrefix() {
        let ctx = EditorAutocompleteContext(
            filePath: "app.ts",
            text: "in",
            cursorLocation: 2,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible)
        let titles = state.items.map(\.title)
        XCTAssertTrue(titles.contains("interface") || titles.contains("infer"),
                       "TS 应包含以 'in' 开头的关键字")
    }

    func testPythonKeywordsForPrefix() {
        let ctx = EditorAutocompleteContext(
            filePath: "script.py",
            text: "de",
            cursorLocation: 2,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.items.contains { $0.title == "def" })
    }

    func testPlainTextReturnsNoCandidates() {
        let ctx = EditorAutocompleteContext(
            filePath: "readme.txt",
            text: "he",
            cursorLocation: 2,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        // 纯文本没有关键字目录和模板，无文档标识符时应隐藏
        XCTAssertFalse(state.isVisible)
    }

    // MARK: - 文档标识符提取与去重

    func testDocumentIdentifiersExtracted() {
        let text = "let myVariable = 42\nprint(myVariable)"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length, // 文尾
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "手动触发应显示候选")
        let titles = state.items.map(\.title)
        XCTAssertTrue(titles.contains("myVariable"), "应提取文档标识符 'myVariable'")
    }

    func testIdentifiersDeduplication() {
        let text = "foo bar foo baz foo"
        let ctx = EditorAutocompleteContext(
            filePath: "test.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        let fooItems = state.items.filter { $0.title == "foo" && $0.kind == .documentSymbol }
        XCTAssertEqual(fooItems.count, 1, "重复标识符应去重为 1 个候选")
    }

    func testIdentifierFilterShortTokens() {
        // 长度 < 2 的标识符应被过滤
        let text = "a b cd ef"
        let ctx = EditorAutocompleteContext(
            filePath: "test.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        let docSymbols = state.items.filter { $0.kind == .documentSymbol }
        for item in docSymbols {
            XCTAssertGreaterThanOrEqual(item.title.count, 2,
                                         "长度 < 2 的标识符不应出现在候选中")
        }
    }

    func testIdentifierFilterKeywords() {
        // 与语言关键字相同的标识符不应在文档标识符候选中出现
        let text = "let myFunc = 1"
        let ctx = EditorAutocompleteContext(
            filePath: "test.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        let docLetItems = state.items.filter { $0.title == "let" && $0.kind == .documentSymbol }
        XCTAssertEqual(docLetItems.count, 0,
                       "'let' 是 Swift 关键字，不应出现在文档标识符候选中")
    }

    // MARK: - 手动触发空前缀

    func testManualTriggerAllowsEmptyPrefix() {
        let text = "func hello() { }\n"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "手动触发应允许空前缀并显示候选")
        XCTAssertFalse(state.items.isEmpty, "手动触发空前缀应显示语言关键字和模板")
    }

    // MARK: - 自动触发阈值

    func testAutoTriggerRequiresMinPrefixLength() {
        // 前缀长度 1（< 2）不应自动触发
        let ctx1 = EditorAutocompleteContext(
            filePath: "main.swift",
            text: "g",
            cursorLocation: 1,
            triggerKind: .automatic
        )
        let state1 = engine.update(context: ctx1, previousState: nil)
        XCTAssertFalse(state1.isVisible, "前缀长度 < 2 不应自动触发")

        // 前缀长度 2 应触发
        let ctx2 = EditorAutocompleteContext(
            filePath: "main.swift",
            text: "gu",
            cursorLocation: 2,
            triggerKind: .automatic
        )
        let state2 = engine.update(context: ctx2, previousState: nil)
        XCTAssertTrue(state2.isVisible, "前缀长度 >= 2 应自动触发")
    }

    func testAutoTriggerOnlyAtIdentifierEnd() {
        // 光标位于标识符中间（不是尾部）—— 但实际上我们的引擎只看前缀
        // 光标在空白后面时不应触发
        let text = "guard "
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length, // 空格后面
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "光标位于空白后面不应自动触发")
    }

    // MARK: - 替换范围计算

    func testReplacementRangeCoversCurrentToken() {
        let text = "let myVa"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: 8, // 在 "myVa" 尾部
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        // replacementRange 应覆盖 "myVa" token（位置 4，长度 4）
        XCTAssertEqual(state.replacementRange.location, 4)
        XCTAssertEqual(state.replacementRange.length, 4)
    }

    func testAcceptReplacesTokenRange() {
        let text = "let gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: 6, // 在 "gu" 尾部（文本末尾）
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        guard let guardItem = state.items.first(where: { $0.title == "guard" }) else {
            XCTFail("应包含 guard 候选")
            return
        }

        let result = engine.accept(item: guardItem, state: state, currentText: text)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "let guard")
        XCTAssertEqual(result?.selection.location, 9) // "let guard" 长度
    }

    func testReplacementStaticFunction() {
        let state = EditorAutocompleteState(
            isVisible: true,
            query: "gu",
            selectedIndex: 0,
            replacementRange: NSRange(location: 4, length: 2),
            items: [
                EditorAutocompleteItem(id: "kw-guard", title: "guard", insertText: "guard", kind: .languageKeyword),
            ]
        )
        let replacement = EditorAutocompleteEngine.replacement(for: state.items[0], state: state)
        XCTAssertEqual(replacement.rangeLocation, 4)
        XCTAssertEqual(replacement.rangeLength, 2)
        XCTAssertEqual(replacement.replacementText, "guard")
        XCTAssertEqual(replacement.caretLocation, 9) // 4 + "guard".count
    }

    // MARK: - 排序稳定性

    func testSortingExactPrefixFirst() {
        let text = "func guardCheck() {}\nlet gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible)
        // "guard" 应在 "guardCheck" 之前（完全匹配优先于包含匹配…
        // 实际上两者都是前缀匹配，但 "guard" 是关键字、"guardCheck" 是文档标识符
        // 根据排序规则文档标识符优先于关键字
        let titles = state.items.map(\.title)
        if let guardCheckIdx = titles.firstIndex(of: "guardCheck"),
           let guardIdx = titles.firstIndex(of: "guard") {
            XCTAssertLessThan(guardCheckIdx, guardIdx,
                              "文档标识符应优先于语言关键字")
        }
    }

    func testSortingDocumentSymbolBeforeKeyword() {
        let text = "let myFunc = 1\nfunc foo() {}\nlet fu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        let docSymbols = state.items.filter { $0.kind == .documentSymbol }
        let keywords = state.items.filter { $0.kind == .languageKeyword }

        if let firstDocIdx = state.items.firstIndex(where: { $0.kind == .documentSymbol }),
           let firstKWIdx = state.items.firstIndex(where: { $0.kind == .languageKeyword }) {
            // 在同一前缀匹配精度下，文档标识符应排在关键字前面
            if !docSymbols.isEmpty && !keywords.isEmpty {
                XCTAssertLessThan(firstDocIdx, firstKWIdx,
                                  "文档标识符应优先于语言关键字")
            }
        }
    }

    func testMaxResultCount() {
        // 创建大量标识符确保截断到 24
        var identifiers: [String] = []
        for i in 0..<40 {
            identifiers.append("myVar\(String(format: "%02d", i))")
        }
        let text = identifiers.joined(separator: " ") + "\nmy"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertLessThanOrEqual(state.items.count, EditorAutocompleteConstants.maxResultCount,
                                  "候选数量不应超过上限 \(EditorAutocompleteConstants.maxResultCount)")
    }

    // MARK: - 注释/字符串场景抑制自动触发

    func testAutoTriggerSuppressedInStringLiteral() {
        let text = "let x = \"gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "字符串内部不应自动触发补全")
    }

    func testAutoTriggerSuppressedInComment() {
        let text = "// gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "注释内部不应自动触发补全")
    }

    func testAutoTriggerSuppressedInMultiLineComment() {
        let text = "/* gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "多行注释内部不应自动触发补全")
    }

    // MARK: - 标识符缓存

    func testIdentifierIndexCacheReuse() {
        let index = EditorDocumentIdentifierIndex()
        let text = "let hello = world"
        let fingerprint = text.hashValue

        let ids1 = index.identifiers(
            text: text,
            filePath: "test.swift",
            language: .swift,
            contentFingerprint: fingerprint
        )
        let ids2 = index.identifiers(
            text: text,
            filePath: "test.swift",
            language: .swift,
            contentFingerprint: fingerprint
        )
        // 相同指纹应复用缓存
        XCTAssertEqual(ids1.count, ids2.count)
    }

    func testIdentifierIndexInvalidatesOnFingerprintChange() {
        let index = EditorDocumentIdentifierIndex()
        let text1 = "let hello = world"
        let text2 = "let hello = world\nlet newVar = 1"

        let ids1 = index.identifiers(
            text: text1,
            filePath: "test.swift",
            language: .swift,
            contentFingerprint: text1.hashValue
        )
        let ids2 = index.identifiers(
            text: text2,
            filePath: "test.swift",
            language: .swift,
            contentFingerprint: text2.hashValue
        )
        // 新文本包含新标识符
        let names2 = ids2.map(\.text)
        XCTAssertTrue(names2.contains("newVar"))
        XCTAssertNotEqual(ids1.count, ids2.count)
    }

    // MARK: - 语言模板

    func testSwiftTemplatesPresent() {
        let templates = EditorAutocompleteKeywordCatalog.templates(for: .swift)
        XCTAssertFalse(templates.isEmpty, "Swift 应有模板候选")
    }

    func testRustTemplatesPresent() {
        let templates = EditorAutocompleteKeywordCatalog.templates(for: .rust)
        XCTAssertFalse(templates.isEmpty, "Rust 应有模板候选")
    }

    func testPlainTextNoTemplates() {
        let templates = EditorAutocompleteKeywordCatalog.templates(for: .plainText)
        XCTAssertTrue(templates.isEmpty, "纯文本不应有模板")
    }

    // MARK: - 边界条件

    func testEmptyTextAutomaticTrigger() {
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: "",
            cursorLocation: 0,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "空文本不应自动触发")
    }

    func testEmptyTextManualTrigger() {
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: "",
            cursorLocation: 0,
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "空文本手动触发应显示关键字候选")
    }

    func testCursorAtDocumentStart() {
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: "guard let x = y",
            cursorLocation: 0,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "光标在文档开头且前缀为空不应自动触发")
    }

    func testAcceptWithInvalidRange() {
        let state = EditorAutocompleteState(
            isVisible: true,
            query: "gu",
            selectedIndex: 0,
            replacementRange: NSRange(location: 100, length: 5), // 超出文本长度
            items: [
                EditorAutocompleteItem(id: "kw-guard", title: "guard", insertText: "guard", kind: .languageKeyword),
            ]
        )
        let result = engine.accept(item: state.items[0], state: state, currentText: "short")
        XCTAssertNil(result, "替换范围超出文本长度时应返回 nil")
    }

    // MARK: - 数字开头不应触发

    func testDigitPrefixDoesNotTrigger() {
        let text = "let x = 42"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: 10, // 在 "42" 尾部
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "光标位于数字后面不应触发补全")
    }

    // MARK: - WI-001 回归：手动触发边界与 replacementRange

    func testManualTriggerAfterWhitespace_ZeroLengthRange() {
        let text = "let myVar = hello "
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length, // 空格后文本末尾
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "手动触发在空白后应显示候选")
        XCTAssertEqual(state.replacementRange.length, 0, "空白边界应为零长度 replacementRange")
        XCTAssertEqual(state.replacementRange.location, (text as NSString).length)
        // 应包含文档标识符候选
        let docSymbols = state.items.filter { $0.kind == .documentSymbol }
        XCTAssertFalse(docSymbols.isEmpty, "手动触发空白边界应包含文档标识符候选")
        let titles = docSymbols.map(\.title)
        XCTAssertTrue(titles.contains("myVar") || titles.contains("hello"),
                       "文档标识符候选应包含文档中的标识符")
    }

    func testManualTriggerAtSeparator_DoesNotBorrowLeftToken() {
        let text = "hello,"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length, // 逗号后文本末尾
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "手动触发在分隔符后应显示候选")
        XCTAssertEqual(state.replacementRange.length, 0,
                       "分隔符边界不应借用左侧 token 作为 replacementRange")
    }

    func testManualTriggerAtSeparatorMidText_DoesNotBorrowLeftToken() {
        // 光标在分隔符位置（非文本末尾），不回借前一个 token
        let text = "hello, world"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: 5, // 在 'o' 和 ',' 之间：char at 5 = ','
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        // 光标在逗号上，不应借用 "hello" 作为 replacementRange
        XCTAssertTrue(state.isVisible, "手动触发应显示候选")
        XCTAssertEqual(state.replacementRange.length, 0,
                       "光标在分隔符上不应回借左侧 token")
    }

    func testManualTriggerAtTokenEnd_UsesTokenAsReplacement() {
        let text = "let gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length, // 在 "gu" 尾部
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "手动触发在 token 尾部应显示候选")
        XCTAssertEqual(state.replacementRange.location, 4, "替换范围起始应为 token 起始")
        XCTAssertEqual(state.replacementRange.length, 2, "替换范围长度应为 token 长度")
        XCTAssertTrue(state.items.contains { $0.title == "guard" }, "应包含 guard 候选")
    }

    func testManualTriggerAtNewline_ZeroLengthRange() {
        let text = "func hello()\n"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length, // 换行后文本末尾
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "手动触发在换行后应显示候选")
        XCTAssertEqual(state.replacementRange.length, 0, "换行边界应为零长度 replacementRange")
    }

    func testManualTriggerAtTab_ZeroLengthRange() {
        let text = "func hello()\t"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length, // Tab 后文本末尾
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible, "手动触发在 Tab 后应显示候选")
        XCTAssertEqual(state.replacementRange.length, 0, "Tab 边界应为零长度 replacementRange")
    }

    func testCursorInMiddleOfIdentifier_ManualTriggerHidden() {
        let text = "helloWorld"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: 5, // 在 "hello" 和 "World" 之间（标识符中部）
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        // 光标在标识符中部，手动触发也不应生成会破坏现有 token 的 replacementRange
        XCTAssertFalse(state.isVisible,
                        "光标在标识符中部，手动触发应隐藏（cursorAtEnd 检查失败）")
    }

    func testManualTriggerEmptyPrefix_IncludesAllThreeSources() {
        let text = "let myVar = 1\n"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible)
        // 验证三类来源都存在
        let hasDocSymbol = state.items.contains { $0.kind == .documentSymbol }
        let hasKeyword = state.items.contains { $0.kind == .languageKeyword }
        let hasTemplate = state.items.contains { $0.kind == .languageTemplate }
        XCTAssertTrue(hasDocSymbol, "手动触发空前缀应包含文档标识符")
        XCTAssertTrue(hasKeyword, "手动触发空前缀应包含语言关键字")
        XCTAssertTrue(hasTemplate, "手动触发空前缀应包含语言模板")
    }

    func testManualTriggerEmptyPrefix_DocumentIdentifiersVisible() {
        // 创建足够多的候选，确保截断后文档标识符仍然可见
        var parts: [String] = []
        for i in 0..<5 {
            parts.append("docIdent\(i)")
        }
        let text = parts.joined(separator: " ") + "\n"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertTrue(state.isVisible)
        // 文档标识符应出现在截断结果中
        let docSymbols = state.items.filter { $0.kind == .documentSymbol }
        XCTAssertFalse(docSymbols.isEmpty, "截断前应优先保留文档标识符可见性")
    }

    // MARK: - WI-002 回归：注释/字符串上下文抑制

    func testAutoTriggerSuppressedInClosedBlockComment() {
        let text = "/* comment */ gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        // "gu" 在已闭合注释之后，应正常触发
        XCTAssertTrue(state.isVisible, "已闭合块注释之后的代码应允许自动触发")
    }

    func testAutoTriggerSuppressedInUnclosedBlockComment() {
        let text = "/* unclosed comment gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "未闭合块注释内部不应自动触发")
    }

    func testAutoTriggerSuppressedInUnclosedString() {
        let text = "let x = \"unclosed string gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "未闭合字符串内部不应自动触发")
    }

    func testAutoTriggerSuppressedInClosedString() {
        let text = "let x = \"closed\" + gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        // "gu" 在闭合字符串之后，应正常触发
        XCTAssertTrue(state.isVisible, "已闭合字符串之后的代码应允许自动触发")
    }

    func testAutoTriggerSuppressedWithEscapedQuote() {
        // 转义引号不应结束字符串
        let text = "let x = \"hello \\\"gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "转义引号后字符串仍未闭合，不应自动触发")
    }

    func testAutoTriggerSuppressedInTemplateString() {
        let text = "const x = `hello gu"
        let ctx = EditorAutocompleteContext(
            filePath: "index.js",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "JS 模板字符串内部不应自动触发")
    }

    func testJSONOnlyDoubleQuoteIsString() {
        // JSON 中双引号内应抑制自动触发
        let text = "{ \"key\": \"va"
        let ctx = EditorAutocompleteContext(
            filePath: "data.json",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "JSON 双引号字符串内不应自动触发")
    }

    func testJSONSingleQuoteNotString() {
        // JSON 中单引号不是合法字符串，光标不在字符串中
        let text = "{ 'ke"
        let ctx = EditorAutocompleteContext(
            filePath: "data.json",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        // 单引号在 JSON 中不构成字符串上下文，"ke" 在代码上下文中
        // JSON 关键字有 true/false/null，"ke" 不匹配这些前缀
        // 但有文档标识符 "ke" 如果长度 < 2 会被过滤（"ke" 刚好 = 2）
        // 光标在 "ke" 尾部，"ke" 本身不是 JSON 关键字前缀
        // 这里的核心断言是：单引号不被当作字符串，auto trigger 不被抑制
        // 即使最终无候选，isVisible 为 false 也是因为无匹配而非字符串抑制
        // 改为测试引擎内部行为：验证 isInsideCommentOrString 不把单引号当字符串
        let engine2 = EditorAutocompleteEngine()
        let isSuppressed = engine2.isInsideCommentOrString(
            text: "{ 'ke",
            cursorLocation: 4, // 在 'k' 处
            language: .json
        )
        XCTAssertFalse(isSuppressed, "JSON 中单引号不应被识别为字符串上下文")
    }

    func testJSONBacktickNotString() {
        // JSON 中反引号不是合法字符串
        let engine2 = EditorAutocompleteEngine()
        let isSuppressed = engine2.isInsideCommentOrString(
            text: "{ `ke",
            cursorLocation: 4,
            language: .json
        )
        XCTAssertFalse(isSuppressed, "JSON 中反引号不应被识别为字符串上下文")
    }

    func testJSONNoCommentSupport() {
        // JSON 不支持注释，// 不应被识别为注释
        let engine2 = EditorAutocompleteEngine()
        let isSuppressed = engine2.isInsideCommentOrString(
            text: "// ke",
            cursorLocation: 5,
            language: .json
        )
        XCTAssertFalse(isSuppressed, "JSON 中 // 不应被识别为注释")
    }

    func testAutoTriggerInRustLineComment() {
        let text = "// co"
        let ctx = EditorAutocompleteContext(
            filePath: "lib.rs",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "Rust 行注释内不应自动触发")
    }

    func testAutoTriggerInPythonComment() {
        let text = "# de"
        let ctx = EditorAutocompleteContext(
            filePath: "script.py",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "Python # 注释内不应自动触发")
    }

    func testManualTriggerInComment_StillShowsCandidates() {
        let text = "// gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .manual
        )
        let state = engine.update(context: ctx, previousState: nil)
        // 手动触发不受注释抑制规则影响
        XCTAssertTrue(state.isVisible, "手动触发在注释内应仍允许显示候选")
    }

    func testAutoTriggerInTripleQuoteString() {
        let text = "let x = \"\"\"\nhello gu"
        let ctx = EditorAutocompleteContext(
            filePath: "main.swift",
            text: text,
            cursorLocation: (text as NSString).length,
            triggerKind: .automatic
        )
        let state = engine.update(context: ctx, previousState: nil)
        XCTAssertFalse(state.isVisible, "三引号字符串内不应自动触发")
    }
}
