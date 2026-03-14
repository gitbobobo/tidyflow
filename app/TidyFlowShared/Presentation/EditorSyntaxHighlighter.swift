import Foundation

// MARK: - 编辑器语法高亮共享领域层
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 提供跨 macOS/iOS 共享的编辑器语法高亮引擎、语言识别、主题语义和结果模型。
//
// 设计约束：
// - 共享层只输出语义角色与范围，不持有平台颜色或字体对象。
// - 语言识别复用与 AICodeCompletionLanguage 相同的扩展名映射规则，但使用独立枚举。
// - 高亮结果以内容指纹为边界，平台层应用前必须校验版本匹配。
// - 高亮失败时稳定降级为纯文本，不阻断编辑。

// MARK: - 编辑器语言枚举

/// 编辑器语法语言枚举，独立于 AI 代码补全语义。
/// 编辑器高亮和 AI 补全是不同领域，语言集合和回退策略可能独立演进。
public enum EditorSyntaxLanguage: String, Equatable, Hashable, Sendable, CaseIterable {
    case swift
    case rust
    case javascript
    case typescript
    case python
    case json
    case markdown
    case plainText

    /// 从文件扩展名推断编辑器语言。
    /// 扩展名映射规则与 `AICodeCompletionLanguage.from(fileExtension:)` 对齐，
    /// 避免仓库内出现第二套互相漂移的规则。
    public static func from(fileExtension ext: String) -> EditorSyntaxLanguage {
        switch ext.lowercased() {
        case "swift":
            return .swift
        case "rs":
            return .rust
        case "js", "jsx", "mjs", "cjs":
            return .javascript
        case "ts", "tsx", "mts", "cts":
            return .typescript
        case "py", "pyw":
            return .python
        case "json", "jsonc", "geojson":
            return .json
        case "md", "markdown":
            return .markdown
        default:
            return .plainText
        }
    }

    /// 从文件路径推断编辑器语言。
    public static func from(filePath: String) -> EditorSyntaxLanguage {
        let ext = (filePath as NSString).pathExtension
        return from(fileExtension: ext)
    }
}

// MARK: - 语义角色

/// 编辑器语法语义角色，表达 token 的语义意图。
/// 平台层把这些角色映射为具体颜色和字体属性。
public enum EditorSyntaxRole: String, Equatable, Hashable, Sendable, CaseIterable {
    /// 默认文本（无特殊语义）
    case plain
    /// 语言关键字（if, let, func, class, ...）
    case keyword
    /// 类型名（String, Int, Self, ...）
    case type
    /// 字符串字面量
    case string
    /// 数字字面量
    case number
    /// 注释（行注释和块注释）
    case comment
    /// 预处理指令 / 属性（#if, @objc, #[derive], ...）
    case attribute
    /// 函数/方法调用
    case function
    /// 操作符与标点
    case punctuation
}

// MARK: - 主题标识

/// 编辑器语法主题标识。
/// 共享层定义语义角色到样式意图的映射；平台层按此标识选择颜色集。
public enum EditorSyntaxTheme: String, Equatable, Hashable, Sendable, CaseIterable {
    /// 系统浅色主题
    case systemLight
    /// 系统深色主题
    case systemDark
}

// MARK: - 高亮运行片段

/// 高亮运行片段：一段连续的文本范围及其语义角色。
/// 使用 UTF-16 偏移量，与 NSTextStorage / UITextView 的 NSRange 直接对齐。
public struct EditorSyntaxRun: Equatable, Sendable {
    /// UTF-16 起始偏移量
    public let location: Int
    /// UTF-16 长度
    public let length: Int
    /// 语义角色
    public let role: EditorSyntaxRole

    public init(location: Int, length: Int, role: EditorSyntaxRole) {
        self.location = location
        self.length = length
        self.role = role
    }

    /// 转换为 NSRange（便捷属性）
    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

// MARK: - 高亮快照

/// 高亮快照：一次完整高亮计算的不可变结果。
/// 平台层应用前必须校验 `contentFingerprint` 与当前文本匹配。
public struct EditorSyntaxSnapshot: Equatable, Sendable {
    /// 文本内容的指纹（用于版本校验）
    public let contentFingerprint: Int
    /// 识别到的语言
    public let language: EditorSyntaxLanguage
    /// 使用的主题标识
    public let theme: EditorSyntaxTheme
    /// 高亮运行片段列表（按 location 升序排列）
    public let runs: [EditorSyntaxRun]

    public init(
        contentFingerprint: Int,
        language: EditorSyntaxLanguage,
        theme: EditorSyntaxTheme,
        runs: [EditorSyntaxRun]
    ) {
        self.contentFingerprint = contentFingerprint
        self.language = language
        self.theme = theme
        self.runs = runs
    }

    /// 纯文本回退快照（无高亮 token）
    public static func plainText(
        contentFingerprint: Int,
        theme: EditorSyntaxTheme
    ) -> EditorSyntaxSnapshot {
        EditorSyntaxSnapshot(
            contentFingerprint: contentFingerprint,
            language: .plainText,
            theme: theme,
            runs: []
        )
    }
}

// MARK: - 内容指纹计算

/// 内容指纹计算（与 EditorDocumentSession.contentHash 语义一致）
public enum EditorSyntaxFingerprint {
    public static func compute(_ text: String) -> Int {
        text.hashValue
    }
}

// MARK: - 共享高亮引擎

/// 编辑器语法高亮引擎。
///
/// 输入：文件路径、文本内容和主题。
/// 输出：稳定的高亮快照。
///
/// 设计要点：
/// - 内置最小缓存策略（单条目），内容/语言/主题均不变时复用结果。
/// - 词法规则完全内置，不引入 Tree-sitter、LSP 或跨语言依赖。
/// - 高亮失败稳定降级为纯文本。
public final class EditorSyntaxHighlighter: @unchecked Sendable {
    /// 缓存的最近一次高亮结果
    private var cachedSnapshot: EditorSyntaxSnapshot?
    /// 缓存对应的文件路径（用于多文档区分）
    private var cachedFilePath: String?

    private let lock = NSLock()

    public init() {}

    /// 计算语法高亮。
    ///
    /// - Parameters:
    ///   - filePath: 文件路径（用于语言识别）
    ///   - text: 文本内容
    ///   - theme: 目标主题
    /// - Returns: 高亮快照
    public func highlight(filePath: String, text: String, theme: EditorSyntaxTheme) -> EditorSyntaxSnapshot {
        let fingerprint = EditorSyntaxFingerprint.compute(text)
        let language = EditorSyntaxLanguage.from(filePath: filePath)

        lock.lock()
        // 缓存命中检查
        if let cached = cachedSnapshot,
           cached.contentFingerprint == fingerprint,
           cached.language == language,
           cached.theme == theme,
           cachedFilePath == filePath {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // 计算高亮
        let snapshot: EditorSyntaxSnapshot
        do {
            let runs = try EditorSyntaxLexer.tokenize(text: text, language: language)
            snapshot = EditorSyntaxSnapshot(
                contentFingerprint: fingerprint,
                language: language,
                theme: theme,
                runs: runs
            )
        } catch {
            // 高亮失败稳定降级为纯文本
            snapshot = .plainText(contentFingerprint: fingerprint, theme: theme)
        }

        // 更新缓存
        lock.lock()
        cachedSnapshot = snapshot
        cachedFilePath = filePath
        lock.unlock()

        return snapshot
    }

    /// 使缓存失效（用于测试或强制刷新）
    public func invalidateCache() {
        lock.lock()
        cachedSnapshot = nil
        cachedFilePath = nil
        lock.unlock()
    }
}

// MARK: - 词法分析器

/// 内置词法分析器，基于简单的正则/状态机实现词法高亮。
/// 不追求语法树精度，目标是稳定、可维护的词法级别高亮。
public enum EditorSyntaxLexer {

    /// 对文本进行词法分析，返回高亮运行片段列表。
    /// - Throws: 理论上不应抛出异常；catch 块作为防御性降级入口。
    public static func tokenize(text: String, language: EditorSyntaxLanguage) throws -> [EditorSyntaxRun] {
        guard language != .plainText else { return [] }

        let rules = lexerRules(for: language)
        guard !rules.isEmpty else { return [] }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var runs: [EditorSyntaxRun] = []
        // 追踪已着色区域，避免重叠
        var colored = IndexSet()

        for rule in rules {
            guard let regex = rule.regex else { continue }
            let matches = regex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                let group = rule.captureGroup < match.numberOfRanges ? rule.captureGroup : 0
                let range = match.range(at: group)
                guard range.location != NSNotFound, range.length > 0 else { continue }

                // 检查是否与已着色区域重叠
                let rangeSet = IndexSet(integersIn: range.location..<(range.location + range.length))
                if !colored.intersection(rangeSet).isEmpty { continue }

                runs.append(EditorSyntaxRun(location: range.location, length: range.length, role: rule.role))
                colored.formUnion(rangeSet)
            }
        }

        // 按 location 排序
        runs.sort { $0.location < $1.location }
        return runs
    }

    // MARK: - 词法规则定义

    struct LexerRule {
        let role: EditorSyntaxRole
        let pattern: String
        let captureGroup: Int
        let options: NSRegularExpression.Options

        var regex: NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: options)
        }

        init(role: EditorSyntaxRole, pattern: String, captureGroup: Int = 0, options: NSRegularExpression.Options = []) {
            self.role = role
            self.pattern = pattern
            self.captureGroup = captureGroup
            self.options = options
        }
    }

    // MARK: - 语言规则分发

    static func lexerRules(for language: EditorSyntaxLanguage) -> [LexerRule] {
        switch language {
        case .swift: return swiftRules
        case .rust: return rustRules
        case .javascript: return javascriptRules
        case .typescript: return typescriptRules
        case .python: return pythonRules
        case .json: return jsonRules
        case .markdown: return markdownRules
        case .plainText: return []
        }
    }

    // MARK: - 通用辅助模式

    /// 双引号字符串（支持转义）
    private static let doubleQuoteString = #"\"(?:[^\"\\]|\\.)*\""#
    /// 单引号字符串（支持转义）
    private static let singleQuoteString = #"'(?:[^'\\]|\\.)*'"#
    /// 反引号模板字符串（简化版，不解析内嵌表达式）
    private static let backtickString = #"`(?:[^`\\]|\\.)*`"#
    /// 数字字面量（整数、浮点、十六进制、二进制、八进制）
    private static let numberLiteral = #"\b(?:0[xX][0-9a-fA-F][0-9a-fA-F_]*|0[oO][0-7][0-7_]*|0[bB][01][01_]*|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9][0-9_]*)?)\b"#

    // MARK: - Swift 规则

    static let swiftRules: [LexerRule] = {
        // 注释优先（避免被关键字规则误匹配）
        let blockComment = LexerRule(role: .comment, pattern: #"/\*[\s\S]*?\*/"#, options: [.dotMatchesLineSeparators])
        let lineComment = LexerRule(role: .comment, pattern: #"//[^\n]*"#)

        // 多行字符串
        let multiLineString = LexerRule(role: .string, pattern: #"\"\"\"[\s\S]*?\"\"\""#, options: [.dotMatchesLineSeparators])
        let stringLiteral = LexerRule(role: .string, pattern: doubleQuoteString)

        // 属性/预处理
        let attribute = LexerRule(role: .attribute, pattern: #"@\w+"#)
        let preprocessor = LexerRule(role: .attribute, pattern: #"#(?:if|elseif|else|endif|sourceLocation|warning|error|available|unavailable|selector|keyPath|colorLiteral|fileLiteral|imageLiteral|line|file|function|column|dsohandle)\b"#)

        // 关键字
        let keywords = [
            "actor", "associatedtype", "async", "await", "break", "case", "catch", "class",
            "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
            "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if",
            "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating",
            "nil", "nonisolated", "open", "operator", "override", "precedencegroup", "private",
            "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self",
            "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
            "true", "try", "typealias", "var", "weak", "where", "while",
        ]
        let keywordPattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        let keyword = LexerRule(role: .keyword, pattern: keywordPattern)

        // 内置类型
        let types = [
            "Any", "AnyObject", "Array", "Bool", "Character", "Dictionary", "Double",
            "Float", "Int", "Int8", "Int16", "Int32", "Int64", "Never", "Optional",
            "Result", "Set", "String", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Void",
        ]
        let typePattern = "\\b(?:" + types.joined(separator: "|") + ")\\b"
        let typeRule = LexerRule(role: .type, pattern: typePattern)

        // 大写字母开头的标识符也视为类型（启发式）
        let upperType = LexerRule(role: .type, pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)

        // 数字
        let number = LexerRule(role: .number, pattern: numberLiteral)

        // 函数调用（标识符后跟左括号）
        let functionCall = LexerRule(role: .function, pattern: #"\b([a-zA-Z_]\w*)\s*(?=\()"#, captureGroup: 1)

        // 操作符/标点
        let punctuationRule = LexerRule(role: .punctuation, pattern: #"[{}()\[\];:,.\-><=!&|^~?+\-*/%@#]"#)

        // 规则优先级：注释 > 多行字符串 > 字符串 > 属性 > 关键字 > 类型 > 数字 > 函数 > 操作符
        return [
            blockComment, lineComment,
            multiLineString, stringLiteral,
            attribute, preprocessor,
            keyword,
            typeRule,
            number,
            functionCall,
            upperType,
            punctuationRule,
        ]
    }()

    // MARK: - Rust 规则

    static let rustRules: [LexerRule] = {
        let blockComment = LexerRule(role: .comment, pattern: #"/\*[\s\S]*?\*/"#, options: [.dotMatchesLineSeparators])
        let lineComment = LexerRule(role: .comment, pattern: #"//[^\n]*"#)

        let rawString = LexerRule(role: .string, pattern: ##"r#*"[\s\S]*?"#*"##, options: [.dotMatchesLineSeparators])
        let stringLiteral = LexerRule(role: .string, pattern: doubleQuoteString)
        let charLiteral = LexerRule(role: .string, pattern: #"'(?:[^'\\]|\\.)+'"#)

        let attribute = LexerRule(role: .attribute, pattern: #"#!?\[[^\]]*\]"#)

        let keywords = [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
            "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "true", "type",
            "unsafe", "use", "where", "while", "yield",
        ]
        let keywordPattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        let keyword = LexerRule(role: .keyword, pattern: keywordPattern)

        let types = [
            "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128",
            "isize", "str", "u8", "u16", "u32", "u64", "u128", "usize",
            "Box", "Option", "Result", "String", "Vec", "HashMap", "HashSet",
        ]
        let typePattern = "\\b(?:" + types.joined(separator: "|") + ")\\b"
        let typeRule = LexerRule(role: .type, pattern: typePattern)
        let upperType = LexerRule(role: .type, pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)

        let number = LexerRule(role: .number, pattern: numberLiteral)
        let functionCall = LexerRule(role: .function, pattern: #"\b([a-zA-Z_]\w*)\s*(?=[!]?\()"#, captureGroup: 1)
        let macroCall = LexerRule(role: .function, pattern: #"\b([a-zA-Z_]\w*)!"#, captureGroup: 1)
        let punctuationRule = LexerRule(role: .punctuation, pattern: #"[{}()\[\];:,.\-><=!&|^~?+\-*/%@#]"#)

        return [
            blockComment, lineComment,
            rawString, stringLiteral, charLiteral,
            attribute,
            keyword,
            typeRule,
            number,
            functionCall, macroCall,
            upperType,
            punctuationRule,
        ]
    }()

    // MARK: - JavaScript 规则

    static let javascriptRules: [LexerRule] = {
        let blockComment = LexerRule(role: .comment, pattern: #"/\*[\s\S]*?\*/"#, options: [.dotMatchesLineSeparators])
        let lineComment = LexerRule(role: .comment, pattern: #"//[^\n]*"#)

        let templateString = LexerRule(role: .string, pattern: backtickString)
        let stringDouble = LexerRule(role: .string, pattern: doubleQuoteString)
        let stringSingle = LexerRule(role: .string, pattern: singleQuoteString)

        let keywords = [
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "debugger", "default", "delete", "do", "else", "export", "extends",
            "false", "finally", "for", "from", "function", "if", "import", "in",
            "instanceof", "let", "new", "null", "of", "return", "static", "super",
            "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
            "void", "while", "with", "yield",
        ]
        let keywordPattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        let keyword = LexerRule(role: .keyword, pattern: keywordPattern)

        let types = [
            "Array", "Boolean", "Date", "Error", "Function", "Map", "Number",
            "Object", "Promise", "RegExp", "Set", "String", "Symbol", "WeakMap",
            "WeakSet",
        ]
        let typePattern = "\\b(?:" + types.joined(separator: "|") + ")\\b"
        let typeRule = LexerRule(role: .type, pattern: typePattern)
        let upperType = LexerRule(role: .type, pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)

        let number = LexerRule(role: .number, pattern: numberLiteral)
        let functionCall = LexerRule(role: .function, pattern: #"\b([a-zA-Z_$]\w*)\s*(?=\()"#, captureGroup: 1)
        let punctuationRule = LexerRule(role: .punctuation, pattern: #"[{}()\[\];:,.\-><=!&|^~?+\-*/%]"#)

        return [
            blockComment, lineComment,
            templateString, stringDouble, stringSingle,
            keyword,
            typeRule,
            number,
            functionCall,
            upperType,
            punctuationRule,
        ]
    }()

    // MARK: - TypeScript 规则

    static let typescriptRules: [LexerRule] = {
        let blockComment = LexerRule(role: .comment, pattern: #"/\*[\s\S]*?\*/"#, options: [.dotMatchesLineSeparators])
        let lineComment = LexerRule(role: .comment, pattern: #"//[^\n]*"#)

        let templateString = LexerRule(role: .string, pattern: backtickString)
        let stringDouble = LexerRule(role: .string, pattern: doubleQuoteString)
        let stringSingle = LexerRule(role: .string, pattern: singleQuoteString)

        // TypeScript 关键字 = JavaScript 关键字 + TS 专属
        let keywords = [
            "abstract", "any", "as", "asserts", "async", "await", "bigint", "boolean",
            "break", "case", "catch", "class", "const", "continue", "debugger",
            "declare", "default", "delete", "do", "else", "enum", "export", "extends",
            "false", "finally", "for", "from", "function", "get", "if", "implements",
            "import", "in", "infer", "instanceof", "interface", "is", "keyof", "let",
            "module", "namespace", "never", "new", "null", "number", "object", "of",
            "override", "package", "private", "protected", "public", "readonly",
            "return", "require", "set", "static", "string", "super", "switch",
            "symbol", "this", "throw", "true", "try", "type", "typeof", "undefined",
            "unique", "unknown", "var", "void", "while", "with", "yield",
        ]
        let keywordPattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        let keyword = LexerRule(role: .keyword, pattern: keywordPattern)

        let decorator = LexerRule(role: .attribute, pattern: #"@\w+"#)

        let types = [
            "Array", "Boolean", "Date", "Error", "Function", "Map", "Number",
            "Object", "Promise", "Record", "RegExp", "Set", "String", "Symbol",
            "Partial", "Required", "Readonly", "Pick", "Omit", "Exclude", "Extract",
            "ReturnType",
        ]
        let typePattern = "\\b(?:" + types.joined(separator: "|") + ")\\b"
        let typeRule = LexerRule(role: .type, pattern: typePattern)
        let upperType = LexerRule(role: .type, pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)

        let number = LexerRule(role: .number, pattern: numberLiteral)
        let functionCall = LexerRule(role: .function, pattern: #"\b([a-zA-Z_$]\w*)\s*(?=\()"#, captureGroup: 1)
        let punctuationRule = LexerRule(role: .punctuation, pattern: #"[{}()\[\];:,.\-><=!&|^~?+\-*/%]"#)

        return [
            blockComment, lineComment,
            templateString, stringDouble, stringSingle,
            decorator,
            keyword,
            typeRule,
            number,
            functionCall,
            upperType,
            punctuationRule,
        ]
    }()

    // MARK: - Python 规则

    static let pythonRules: [LexerRule] = {
        let lineComment = LexerRule(role: .comment, pattern: #"#[^\n]*"#)

        // 三引号字符串（文档字符串）
        let tripleDoubleString = LexerRule(role: .string, pattern: #"\"\"\"[\s\S]*?\"\"\""#, options: [.dotMatchesLineSeparators])
        let tripleSingleString = LexerRule(role: .string, pattern: #"'''[\s\S]*?'''"#, options: [.dotMatchesLineSeparators])
        let stringDouble = LexerRule(role: .string, pattern: doubleQuoteString)
        let stringSingle = LexerRule(role: .string, pattern: singleQuoteString)
        // f-string 前缀
        let fStringDouble = LexerRule(role: .string, pattern: #"[fFbBrRuU]{1,2}\"(?:[^\"\\]|\\.)*\""#)
        let fStringSingle = LexerRule(role: .string, pattern: #"[fFbBrRuU]{1,2}'(?:[^'\\]|\\.)*'"#)

        let decorator = LexerRule(role: .attribute, pattern: #"@\w[\w.]*"#)

        let keywords = [
            "False", "None", "True", "and", "as", "assert", "async", "await",
            "break", "class", "continue", "def", "del", "elif", "else", "except",
            "finally", "for", "from", "global", "if", "import", "in", "is",
            "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
            "while", "with", "yield",
        ]
        let keywordPattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        let keyword = LexerRule(role: .keyword, pattern: keywordPattern)

        let types = [
            "int", "float", "complex", "str", "bytes", "bytearray", "bool",
            "list", "tuple", "dict", "set", "frozenset", "type", "object",
            "range", "memoryview",
        ]
        let typePattern = "\\b(?:" + types.joined(separator: "|") + ")\\b"
        let typeRule = LexerRule(role: .type, pattern: typePattern)
        let upperType = LexerRule(role: .type, pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)

        let builtinFunc = [
            "print", "len", "range", "enumerate", "zip", "map", "filter",
            "sorted", "reversed", "isinstance", "issubclass", "hasattr",
            "getattr", "setattr", "delattr", "super", "property", "staticmethod",
            "classmethod", "abs", "all", "any", "bin", "hex", "oct", "ord",
            "chr", "repr", "input", "open", "iter", "next",
        ]
        let builtinPattern = "\\b(?:" + builtinFunc.joined(separator: "|") + ")\\b"
        let builtinRule = LexerRule(role: .function, pattern: builtinPattern)

        let number = LexerRule(role: .number, pattern: numberLiteral)
        let functionCall = LexerRule(role: .function, pattern: #"\b([a-zA-Z_]\w*)\s*(?=\()"#, captureGroup: 1)
        let punctuationRule = LexerRule(role: .punctuation, pattern: #"[{}()\[\];:,.\-><=!&|^~?+\-*/%@]"#)

        return [
            lineComment,
            tripleDoubleString, tripleSingleString,
            fStringDouble, fStringSingle,
            stringDouble, stringSingle,
            decorator,
            keyword,
            typeRule,
            builtinRule,
            number,
            functionCall,
            upperType,
            punctuationRule,
        ]
    }()

    // MARK: - JSON 规则

    static let jsonRules: [LexerRule] = {
        let lineComment = LexerRule(role: .comment, pattern: #"//[^\n]*"#)
        let blockComment = LexerRule(role: .comment, pattern: #"/\*[\s\S]*?\*/"#, options: [.dotMatchesLineSeparators])
        // JSON 键（双引号后跟冒号）
        let key = LexerRule(role: .keyword, pattern: #"\"(?:[^\"\\]|\\.)*\"\s*(?=:)"#)
        let stringLiteral = LexerRule(role: .string, pattern: doubleQuoteString)
        let number = LexerRule(role: .number, pattern: numberLiteral)
        let boolNull = LexerRule(role: .keyword, pattern: #"\b(?:true|false|null)\b"#)
        let punctuationRule = LexerRule(role: .punctuation, pattern: #"[{}()\[\]:,]"#)

        return [
            lineComment, blockComment,
            key,
            stringLiteral,
            number,
            boolNull,
            punctuationRule,
        ]
    }()

    // MARK: - Markdown 规则

    static let markdownRules: [LexerRule] = {
        // 代码块
        let codeBlock = LexerRule(role: .string, pattern: #"```[\s\S]*?```"#, options: [.dotMatchesLineSeparators])
        let inlineCode = LexerRule(role: .string, pattern: #"`[^`\n]+`"#)
        // 标题
        let heading = LexerRule(role: .keyword, pattern: #"^#{1,6}\s+[^\n]*"#, options: [.anchorsMatchLines])
        // 粗体
        let bold = LexerRule(role: .type, pattern: #"\*\*[^*]+\*\*"#)
        // 斜体
        let italic = LexerRule(role: .attribute, pattern: #"\*[^*\n]+\*"#)
        // 链接
        let link = LexerRule(role: .function, pattern: #"\[([^\]]+)\]\([^\)]+\)"#)
        // 列表标记
        let listMarker = LexerRule(role: .punctuation, pattern: #"^[\t ]*(?:[-*+]|\d+\.)\s"#, options: [.anchorsMatchLines])

        return [
            codeBlock, inlineCode,
            heading,
            bold, italic,
            link,
            listMarker,
        ]
    }()
}
