import XCTest
@testable import TidyFlowShared

/// 编辑器语法高亮共享层测试矩阵。
///
/// 覆盖：语言识别、词法规则（每种首批语言）、未知扩展名回退、
/// 主题语义角色、高亮快照缓存与版本失效、多工作区隔离。
final class EditorSyntaxHighlighterTests: XCTestCase {

    // MARK: - 语言识别

    func testLanguageDetection_Swift() {
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "/src/main.swift"), .swift)
    }

    func testLanguageDetection_Rust() {
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "/src/lib.rs"), .rust)
    }

    func testLanguageDetection_JavaScript() {
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "app.js"), .javascript)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "component.jsx"), .javascript)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "utils.mjs"), .javascript)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "config.cjs"), .javascript)
    }

    func testLanguageDetection_TypeScript() {
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "index.ts"), .typescript)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "App.tsx"), .typescript)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "module.mts"), .typescript)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "lib.cts"), .typescript)
    }

    func testLanguageDetection_Python() {
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "main.py"), .python)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "gui.pyw"), .python)
    }

    func testLanguageDetection_JSON() {
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "config.json"), .json)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "tsconfig.jsonc"), .json)
    }

    func testLanguageDetection_Markdown() {
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "README.md"), .markdown)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "docs.markdown"), .markdown)
    }

    func testLanguageDetection_UnknownFallback() {
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "Makefile"), .plainText)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "data.csv"), .plainText)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: "image.png"), .plainText)
        XCTAssertEqual(EditorSyntaxLanguage.from(filePath: ""), .plainText)
    }

    func testLanguageDetection_FromExtension() {
        XCTAssertEqual(EditorSyntaxLanguage.from(fileExtension: "SWIFT"), .swift)
        XCTAssertEqual(EditorSyntaxLanguage.from(fileExtension: "Rs"), .rust)
        XCTAssertEqual(EditorSyntaxLanguage.from(fileExtension: ""), .plainText)
    }

    // MARK: - Swift 词法规则

    func testSwift_Keywords() {
        let code = "let x = 42\nfunc hello() { return }"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .swift)
        let keywords = runs.filter { $0.role == .keyword }
        let keywordTexts = keywords.map { (code as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }
        XCTAssertTrue(keywordTexts.contains("let"), "应识别 let 为关键字")
        XCTAssertTrue(keywordTexts.contains("func"), "应识别 func 为关键字")
        XCTAssertTrue(keywordTexts.contains("return"), "应识别 return 为关键字")
    }

    func testSwift_Strings() {
        let code = #"let msg = "hello world""#
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .swift)
        let strings = runs.filter { $0.role == .string }
        XCTAssertFalse(strings.isEmpty, "应识别字符串字面量")
        let stringText = (code as NSString).substring(with: NSRange(location: strings[0].location, length: strings[0].length))
        XCTAssertEqual(stringText, #""hello world""#)
    }

    func testSwift_Comments() {
        let code = "// 这是注释\nlet x = 1"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .swift)
        let comments = runs.filter { $0.role == .comment }
        XCTAssertFalse(comments.isEmpty, "应识别行注释")
    }

    func testSwift_Numbers() {
        let code = "let a = 42\nlet b = 3.14\nlet c = 0xFF"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .swift)
        let numbers = runs.filter { $0.role == .number }
        XCTAssertGreaterThanOrEqual(numbers.count, 3, "应识别整数、浮点数和十六进制")
    }

    func testSwift_Attributes() {
        let code = "@objc func test() {}"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .swift)
        let attrs = runs.filter { $0.role == .attribute }
        XCTAssertFalse(attrs.isEmpty, "应识别 @objc 属性")
    }

    // MARK: - Rust 词法规则

    func testRust_Keywords() {
        let code = "fn main() {\n    let mut x = 5;\n}"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .rust)
        let keywords = runs.filter { $0.role == .keyword }
        let texts = keywords.map { (code as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }
        XCTAssertTrue(texts.contains("fn"), "应识别 fn 为关键字")
        XCTAssertTrue(texts.contains("let"), "应识别 let 为关键字")
        XCTAssertTrue(texts.contains("mut"), "应识别 mut 为关键字")
    }

    func testRust_Strings() {
        let code = #"let s = "hello";"#
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .rust)
        let strings = runs.filter { $0.role == .string }
        XCTAssertFalse(strings.isEmpty, "应识别 Rust 字符串字面量")
    }

    func testRust_Comments() {
        let code = "// Rust 注释\nlet x = 1;"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .rust)
        let comments = runs.filter { $0.role == .comment }
        XCTAssertFalse(comments.isEmpty, "应识别 Rust 行注释")
    }

    func testRust_Attributes() {
        let code = "#[derive(Debug)]\nstruct Foo;"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .rust)
        let attrs = runs.filter { $0.role == .attribute }
        XCTAssertFalse(attrs.isEmpty, "应识别 #[derive] 属性")
    }

    // MARK: - JavaScript 词法规则

    func testJavaScript_Keywords() {
        let code = "const x = () => { return null; };"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .javascript)
        let keywords = runs.filter { $0.role == .keyword }
        let texts = keywords.map { (code as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }
        XCTAssertTrue(texts.contains("const"), "应识别 const 为关键字")
        XCTAssertTrue(texts.contains("return"), "应识别 return 为关键字")
        XCTAssertTrue(texts.contains("null"), "应识别 null 为关键字")
    }

    func testJavaScript_TemplateStrings() {
        let code = "const msg = `hello ${name}`;"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .javascript)
        let strings = runs.filter { $0.role == .string }
        XCTAssertFalse(strings.isEmpty, "应识别模板字符串")
    }

    func testJavaScript_Comments() {
        let code = "/* block */\n// line\nconst x = 1;"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .javascript)
        let comments = runs.filter { $0.role == .comment }
        XCTAssertGreaterThanOrEqual(comments.count, 2, "应识别块注释和行注释")
    }

    // MARK: - TypeScript 词法规则

    func testTypeScript_Keywords() {
        let code = "interface Foo {\n    readonly name: string;\n}"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .typescript)
        let keywords = runs.filter { $0.role == .keyword }
        let texts = keywords.map { (code as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }
        XCTAssertTrue(texts.contains("interface"), "应识别 interface 为关键字")
        XCTAssertTrue(texts.contains("readonly"), "应识别 readonly 为关键字")
        XCTAssertTrue(texts.contains("string"), "应识别 string 为关键字")
    }

    func testTypeScript_Decorators() {
        let code = "@Component\nclass Foo {}"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .typescript)
        let attrs = runs.filter { $0.role == .attribute }
        XCTAssertFalse(attrs.isEmpty, "应识别 TypeScript 装饰器")
    }

    // MARK: - Python 词法规则

    func testPython_Keywords() {
        let code = "def hello():\n    if True:\n        return None"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .python)
        let keywords = runs.filter { $0.role == .keyword }
        let texts = keywords.map { (code as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }
        XCTAssertTrue(texts.contains("def"), "应识别 def 为关键字")
        XCTAssertTrue(texts.contains("if"), "应识别 if 为关键字")
        XCTAssertTrue(texts.contains("True"), "应识别 True 为关键字")
        XCTAssertTrue(texts.contains("return"), "应识别 return 为关键字")
        XCTAssertTrue(texts.contains("None"), "应识别 None 为关键字")
    }

    func testPython_Comments() {
        let code = "# Python 注释\nx = 1"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .python)
        let comments = runs.filter { $0.role == .comment }
        XCTAssertFalse(comments.isEmpty, "应识别 Python 注释")
    }

    func testPython_Strings() {
        let code = #"msg = "hello""#
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .python)
        let strings = runs.filter { $0.role == .string }
        XCTAssertFalse(strings.isEmpty, "应识别 Python 字符串")
    }

    func testPython_Decorators() {
        let code = "@staticmethod\ndef foo(): pass"
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .python)
        let attrs = runs.filter { $0.role == .attribute }
        XCTAssertFalse(attrs.isEmpty, "应识别 Python 装饰器")
    }

    // MARK: - 纯文本回退

    func testPlainText_NoRuns() {
        let runs = try! EditorSyntaxLexer.tokenize(text: "hello world", language: .plainText)
        XCTAssertTrue(runs.isEmpty, "纯文本不应产生任何高亮 run")
    }

    // MARK: - 主题语义角色覆盖

    func testThemeRoles_AllCasesPresent() {
        // 验证所有语义角色都被主题枚举覆盖
        XCTAssertEqual(EditorSyntaxRole.allCases.count, 9)
        XCTAssertEqual(EditorSyntaxTheme.allCases.count, 2)
    }

    // MARK: - 高亮快照与缓存

    func testHighlighter_CacheHit() {
        let highlighter = EditorSyntaxHighlighter()
        let text = "let x = 42"
        let snap1 = highlighter.highlight(filePath: "test.swift", text: text, theme: .systemDark)
        let snap2 = highlighter.highlight(filePath: "test.swift", text: text, theme: .systemDark)
        // 缓存命中应返回相同结果
        XCTAssertEqual(snap1, snap2)
        XCTAssertEqual(snap1.contentFingerprint, snap2.contentFingerprint)
    }

    func testHighlighter_CacheInvalidation_ContentChange() {
        let highlighter = EditorSyntaxHighlighter()
        let snap1 = highlighter.highlight(filePath: "test.swift", text: "let x = 1", theme: .systemDark)
        let snap2 = highlighter.highlight(filePath: "test.swift", text: "let x = 2", theme: .systemDark)
        // 内容变化应重新计算
        XCTAssertNotEqual(snap1.contentFingerprint, snap2.contentFingerprint)
    }

    func testHighlighter_CacheInvalidation_ThemeChange() {
        let highlighter = EditorSyntaxHighlighter()
        let text = "let x = 42"
        let snap1 = highlighter.highlight(filePath: "test.swift", text: text, theme: .systemDark)
        let snap2 = highlighter.highlight(filePath: "test.swift", text: text, theme: .systemLight)
        // 主题变化应重新计算
        XCTAssertNotEqual(snap1.theme, snap2.theme)
    }

    func testHighlighter_CacheInvalidation_FilePathChange() {
        let highlighter = EditorSyntaxHighlighter()
        let text = "let x = 42"
        let snap1 = highlighter.highlight(filePath: "test.swift", text: text, theme: .systemDark)
        let snap2 = highlighter.highlight(filePath: "test.rs", text: text, theme: .systemDark)
        // 文件路径变化（语言变化）应重新计算
        XCTAssertNotEqual(snap1.language, snap2.language)
    }

    func testHighlighter_ExplicitInvalidate() {
        let highlighter = EditorSyntaxHighlighter()
        let text = "let x = 42"
        _ = highlighter.highlight(filePath: "test.swift", text: text, theme: .systemDark)
        highlighter.invalidateCache()
        // invalidateCache 后应不崩溃、正常工作
        let snap = highlighter.highlight(filePath: "test.swift", text: text, theme: .systemDark)
        XCTAssertFalse(snap.runs.isEmpty)
    }

    // MARK: - 版本指纹

    func testFingerprint_SameContent() {
        let f1 = EditorSyntaxFingerprint.compute("hello")
        let f2 = EditorSyntaxFingerprint.compute("hello")
        XCTAssertEqual(f1, f2)
    }

    func testFingerprint_DifferentContent() {
        let f1 = EditorSyntaxFingerprint.compute("hello")
        let f2 = EditorSyntaxFingerprint.compute("world")
        XCTAssertNotEqual(f1, f2)
    }

    // MARK: - 高亮降级

    func testPlainTextSnapshot() {
        let snap = EditorSyntaxSnapshot.plainText(contentFingerprint: 123, theme: .systemDark)
        XCTAssertEqual(snap.language, .plainText)
        XCTAssertTrue(snap.runs.isEmpty)
        XCTAssertEqual(snap.contentFingerprint, 123)
    }

    func testHighlighter_EmptyText() {
        let highlighter = EditorSyntaxHighlighter()
        let snap = highlighter.highlight(filePath: "test.swift", text: "", theme: .systemDark)
        XCTAssertTrue(snap.runs.isEmpty, "空文本不应产生高亮 run")
    }

    // MARK: - 多工作区隔离

    func testMultiWorkspace_DifferentHighlighters() {
        // 每个编辑器协调器持有独立的 EditorSyntaxHighlighter 实例
        // 验证两个独立实例不会串用缓存
        let h1 = EditorSyntaxHighlighter()
        let h2 = EditorSyntaxHighlighter()
        let text = "let x = 42"
        let snap1 = h1.highlight(filePath: "ws1/test.swift", text: text, theme: .systemDark)
        let snap2 = h2.highlight(filePath: "ws2/test.swift", text: text, theme: .systemDark)
        // 两个独立实例应各自独立工作
        XCTAssertEqual(snap1.runs.count, snap2.runs.count)
    }

    func testMultiWorkspace_SamePathDifferentContent() {
        // 同路径不同内容（不同工作区的同名文件）
        let h1 = EditorSyntaxHighlighter()
        let h2 = EditorSyntaxHighlighter()
        let snap1 = h1.highlight(filePath: "test.swift", text: "let x = 1", theme: .systemDark)
        let snap2 = h2.highlight(filePath: "test.swift", text: "var y = 2", theme: .systemDark)
        XCTAssertNotEqual(snap1.contentFingerprint, snap2.contentFingerprint)
    }

    // MARK: - 旧版本丢弃

    func testOldVersionDiscard() {
        // 模拟旧高亮结果不应覆盖新文本版本
        let highlighter = EditorSyntaxHighlighter()
        let oldText = "let old = 1"
        let newText = "let new = 2"
        let oldSnap = highlighter.highlight(filePath: "test.swift", text: oldText, theme: .systemDark)
        let newFingerprint = EditorSyntaxFingerprint.compute(newText)
        // 旧快照的 fingerprint 与新文本不匹配，应被丢弃
        XCTAssertNotEqual(oldSnap.contentFingerprint, newFingerprint,
                          "旧快照的 fingerprint 应与新文本不同，平台层据此丢弃旧结果")
    }

    // MARK: - EditorSyntaxRun NSRange 转换

    func testRunNSRange() {
        let run = EditorSyntaxRun(location: 5, length: 3, role: .keyword)
        XCTAssertEqual(run.nsRange, NSRange(location: 5, length: 3))
    }

    // MARK: - 高亮 run 不重叠

    func testRuns_NoOverlap() {
        let code = """
        // comment
        let x = "hello"
        func foo() { return 42 }
        """
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .swift)
        // 验证 runs 无重叠
        let sortedRuns = runs.sorted { $0.location < $1.location }
        for i in 1..<sortedRuns.count {
            let prev = sortedRuns[i - 1]
            let curr = sortedRuns[i]
            XCTAssertLessThanOrEqual(prev.location + prev.length, curr.location,
                                     "Run \(i-1) [\(prev.location)..\(prev.location+prev.length)) 与 Run \(i) [\(curr.location)..\(curr.location+curr.length)) 重叠")
        }
    }

    // MARK: - 各语言至少有代表性样例

    func testJSON_BasicHighlighting() {
        let code = #"{"key": "value", "num": 42, "bool": true}"#
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .json)
        XCTAssertFalse(runs.isEmpty, "JSON 应有高亮 run")
        let strings = runs.filter { $0.role == .string }
        XCTAssertFalse(strings.isEmpty, "JSON 应识别字符串值")
    }

    func testMarkdown_BasicHighlighting() {
        let code = "# Title\n\nSome **bold** text and `code`."
        let runs = try! EditorSyntaxLexer.tokenize(text: code, language: .markdown)
        XCTAssertFalse(runs.isEmpty, "Markdown 应有高亮 run")
    }
}
