import Foundation

// MARK: - 编辑器自动补全共享语义层
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 定义跨 macOS/iOS 共享的编辑器基础代码自动补全类型与引擎。
//
// 设计约束：
// - 共享层只输出候选与替换信息，不持有平台 UI 对象。
// - 全部使用 UTF-16 偏移，与 NSTextView/UITextView 的 NSRange 一致。
// - 候选来源固定为三类：语言关键字、语言静态模板、当前文档标识符索引。
// - 不接入 Core、LSP、跨文件索引或 AI 补全。

// MARK: - 触发方式

/// 补全触发方式
public enum EditorAutocompleteTriggerKind: Equatable, Sendable {
    /// 自动触发（用户输入时满足规则自动弹出）
    case automatic
    /// 手动触发（用户按 Ctrl-Space 或点击按钮）
    case manual
}

// MARK: - 候选类型

/// 补全候选来源类别
public enum EditorAutocompleteItemKind: Equatable, Hashable, Sendable {
    /// 当前文档标识符
    case documentSymbol
    /// 语言关键字
    case languageKeyword
    /// 语言静态模板
    case languageTemplate
}

// MARK: - 候选项

/// 单个补全候选
public struct EditorAutocompleteItem: Equatable, Hashable, Sendable, Identifiable {
    /// 唯一标识
    public let id: String
    /// 显示标题
    public let title: String
    /// 辅助说明（可选）
    public let detail: String?
    /// 插入文本
    public let insertText: String
    /// 候选来源类别
    public let kind: EditorAutocompleteItemKind

    public init(id: String, title: String, detail: String? = nil, insertText: String, kind: EditorAutocompleteItemKind) {
        self.id = id
        self.title = title
        self.detail = detail
        self.insertText = insertText
        self.kind = kind
    }
}

// MARK: - 替换指令

/// 接受候选后的文本替换指令（UTF-16 偏移）
public struct EditorAutocompleteReplacement: Equatable, Sendable {
    /// 替换起始位置（UTF-16 offset）
    public let rangeLocation: Int
    /// 替换长度（UTF-16 offset）
    public let rangeLength: Int
    /// 替换文本
    public let replacementText: String
    /// 替换后光标位置（UTF-16 offset）
    public let caretLocation: Int

    public init(rangeLocation: Int, rangeLength: Int, replacementText: String, caretLocation: Int) {
        self.rangeLocation = rangeLocation
        self.rangeLength = rangeLength
        self.replacementText = replacementText
        self.caretLocation = caretLocation
    }
}

// MARK: - 上下文

/// 补全请求上下文
public struct EditorAutocompleteContext: Equatable, Sendable {
    /// 文件路径（用于语言识别）
    public let filePath: String
    /// 文本全文
    public let text: String
    /// 光标位置（UTF-16 offset）
    public let cursorLocation: Int
    /// 触发方式
    public let triggerKind: EditorAutocompleteTriggerKind

    public init(filePath: String, text: String, cursorLocation: Int, triggerKind: EditorAutocompleteTriggerKind) {
        self.filePath = filePath
        self.text = text
        self.cursorLocation = cursorLocation
        self.triggerKind = triggerKind
    }
}

// MARK: - 补全状态

/// 编辑器补全运行时状态
public struct EditorAutocompleteState: Equatable, Sendable {
    /// 候选面板是否可见
    public var isVisible: Bool
    /// 当前前缀查询
    public var query: String
    /// 当前选中索引
    public var selectedIndex: Int
    /// 当前标识符 token 的替换范围（UTF-16）
    public var replacementRange: NSRange
    /// 过滤后的候选列表
    public var items: [EditorAutocompleteItem]

    public init(
        isVisible: Bool = false,
        query: String = "",
        selectedIndex: Int = 0,
        replacementRange: NSRange = NSRange(location: 0, length: 0),
        items: [EditorAutocompleteItem] = []
    ) {
        self.isVisible = isVisible
        self.query = query
        self.selectedIndex = selectedIndex
        self.replacementRange = replacementRange
        self.items = items
    }

    /// 空状态（隐藏面板）
    public static let hidden = EditorAutocompleteState()
}

// MARK: - 补全引擎常量

/// 补全引擎配置常量
public enum EditorAutocompleteConstants {
    /// 自动触发所需的最小前缀长度
    public static let autoTriggerMinPrefixLength = 2
    /// 候选结果数量上限
    public static let maxResultCount = 24
}

// MARK: - 语言关键字与模板目录

/// 语言关键字与静态模板目录，复用 EditorSyntaxHighlighter 的关键字集合。
public enum EditorAutocompleteKeywordCatalog {

    /// 返回指定语言的关键字列表
    public static func keywords(for language: EditorSyntaxLanguage) -> [String] {
        switch language {
        case .swift:
            return [
                "actor", "associatedtype", "async", "await", "break", "case", "catch", "class",
                "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
                "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if",
                "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating",
                "nil", "nonisolated", "open", "operator", "override", "precedencegroup", "private",
                "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self",
                "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
                "true", "try", "typealias", "var", "weak", "where", "while",
            ]
        case .rust:
            return [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn",
                "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
                "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                "self", "Self", "static", "struct", "super", "trait", "true", "type",
                "unsafe", "use", "where", "while", "yield",
            ]
        case .javascript:
            return [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends",
                "false", "finally", "for", "from", "function", "if", "import", "in",
                "instanceof", "let", "new", "null", "of", "return", "static", "super",
                "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
                "void", "while", "with", "yield",
            ]
        case .typescript:
            return [
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
        case .python:
            return [
                "False", "None", "True", "and", "as", "assert", "async", "await",
                "break", "class", "continue", "def", "del", "elif", "else", "except",
                "finally", "for", "from", "global", "if", "import", "in", "is",
                "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
                "while", "with", "yield",
            ]
        case .json:
            return ["true", "false", "null"]
        case .markdown, .plainText:
            return []
        }
    }

    /// 返回指定语言的静态模板列表（仅纯文本插入，无占位符）
    public static func templates(for language: EditorSyntaxLanguage) -> [(title: String, insertText: String, detail: String)] {
        switch language {
        case .swift:
            return [
                ("guard let ... else { return }", "guard let  else { return }", "guard 提前返回"),
                ("if let ... {}", "if let  {\n    \n}", "可选绑定"),
                ("switch ... {}", "switch  {\ncase :\n    break\ndefault:\n    break\n}", "模式匹配"),
                ("for ... in ... {}", "for  in  {\n    \n}", "遍历循环"),
            ]
        case .rust:
            return [
                ("match ... {}", "match  {\n    _ => {},\n}", "模式匹配"),
                ("if let ... {}", "if let  =  {\n    \n}", "可选解构"),
                ("for ... in ... {}", "for  in  {\n    \n}", "迭代循环"),
                ("impl ... {}", "impl  {\n    \n}", "实现块"),
            ]
        case .javascript, .typescript:
            return [
                ("function ...() {}", "function () {\n    \n}", "函数声明"),
                ("if (...) {}", "if () {\n    \n}", "条件分支"),
                ("for (...) {}", "for (let i = 0; i < ; i++) {\n    \n}", "for 循环"),
                ("try ... catch {}", "try {\n    \n} catch (error) {\n    \n}", "异常捕获"),
                ("async function ...() {}", "async function () {\n    \n}", "异步函数"),
            ]
        case .python:
            return [
                ("def ...():", "def ():\n    ", "函数定义"),
                ("class ...(...):", "class ():\n    ", "类定义"),
                ("if ...:", "if :\n    ", "条件分支"),
                ("for ... in ...:", "for  in :\n    ", "遍历循环"),
                ("try ... except:", "try:\n    \nexcept  as e:\n    ", "异常捕获"),
                ("with ... as ...:", "with  as :\n    ", "上下文管理"),
            ]
        case .json, .markdown, .plainText:
            return []
        }
    }
}

// MARK: - 文档标识符索引

/// 当前文档标识符提取与缓存
public final class EditorDocumentIdentifierIndex {
    /// 缓存键
    private var cachedFingerprint: Int?
    private var cachedFilePath: String?
    private var cachedLanguage: EditorSyntaxLanguage?
    /// 缓存的标识符列表（按在文档中出现的先后排列，去重后）
    private var cachedIdentifiers: [DocumentIdentifier] = []

    /// 文档标识符（含出现位置信息）
    public struct DocumentIdentifier: Equatable, Sendable {
        /// 标识符文本
        public let text: String
        /// 最后一次出现的 UTF-16 位置
        public let lastLocation: Int
    }

    private static let identifierRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*", options: [])
    }()

    public init() {}

    /// 提取当前文档中的标识符（去重、过滤短标识符和关键字）
    public func identifiers(
        text: String,
        filePath: String,
        language: EditorSyntaxLanguage,
        contentFingerprint: Int
    ) -> [DocumentIdentifier] {
        // 缓存命中
        if cachedFingerprint == contentFingerprint,
           cachedFilePath == filePath,
           cachedLanguage == language {
            return cachedIdentifiers
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let keywords = Set(EditorAutocompleteKeywordCatalog.keywords(for: language))

        var seen = Set<String>()
        var results: [DocumentIdentifier] = []

        let matches = Self.identifierRegex.matches(in: text, options: [], range: fullRange)
        for match in matches {
            let range = match.range
            let ident = nsText.substring(with: range)

            // 过滤规则
            if ident.count < 2 { continue }
            if keywords.contains(ident) { continue }

            if seen.contains(ident) {
                // 更新最后出现位置
                if let idx = results.firstIndex(where: { $0.text == ident }) {
                    results[idx] = DocumentIdentifier(text: ident, lastLocation: range.location)
                }
            } else {
                seen.insert(ident)
                results.append(DocumentIdentifier(text: ident, lastLocation: range.location))
            }
        }

        // 更新缓存
        cachedFingerprint = contentFingerprint
        cachedFilePath = filePath
        cachedLanguage = language
        cachedIdentifiers = results
        return results
    }

    /// 清除缓存
    public func invalidate() {
        cachedFingerprint = nil
        cachedFilePath = nil
        cachedLanguage = nil
        cachedIdentifiers = []
    }
}

// MARK: - 补全引擎

/// 编辑器基础补全引擎。
///
/// 输入上下文，输出稳定的补全状态。
/// 候选来源：语言关键字 + 语言模板 + 当前文档标识符。
/// 不依赖 Core、LSP、AI 或跨文件索引。
public final class EditorAutocompleteEngine {
    private let identifierIndex = EditorDocumentIdentifierIndex()

    public init() {}

    // MARK: - 主入口

    /// 根据上下文计算补全状态
    public func update(context: EditorAutocompleteContext, previousState: EditorAutocompleteState?) -> EditorAutocompleteState {
        let language = EditorSyntaxLanguage.from(filePath: context.filePath)
        let nsText = context.text as NSString

        // 计算光标所在的标识符 token
        guard let tokenInfo = currentIdentifierToken(in: nsText, at: context.cursorLocation) else {
            // 光标不在标识符位置
            if context.triggerKind == .manual {
                let fingerprint = EditorSyntaxFingerprint.compute(context.text)
                let identifiers = identifierIndex.identifiers(
                    text: context.text,
                    filePath: context.filePath,
                    language: language,
                    contentFingerprint: fingerprint
                )
                // 手动触发在非标识符位置：展示关键字、模板和文档标识符
                let items = buildCandidatesForManualTriggerNoPrefix(
                    language: language,
                    identifiers: identifiers,
                    cursorLocation: context.cursorLocation
                )
                if items.isEmpty {
                    return .hidden
                }
                return EditorAutocompleteState(
                    isVisible: true,
                    query: "",
                    selectedIndex: 0,
                    replacementRange: NSRange(location: context.cursorLocation, length: 0),
                    items: items
                )
            }
            return .hidden
        }

        let prefix = tokenInfo.prefix
        let tokenRange = tokenInfo.range

        // 检查光标是否在标识符尾部
        let cursorAtEnd = context.cursorLocation == tokenRange.location + tokenRange.length
        guard cursorAtEnd else {
            return .hidden
        }

        // 检查是否在注释或字符串内部（自动触发时抑制）
        if context.triggerKind == .automatic {
            if isInsideCommentOrString(text: context.text, cursorLocation: context.cursorLocation, language: language) {
                return .hidden
            }
        }

        // 自动触发前缀长度检查
        if context.triggerKind == .automatic && prefix.count < EditorAutocompleteConstants.autoTriggerMinPrefixLength {
            return .hidden
        }

        // 生成候选
        let fingerprint = EditorSyntaxFingerprint.compute(context.text)
        let identifiers = identifierIndex.identifiers(
            text: context.text,
            filePath: context.filePath,
            language: language,
            contentFingerprint: fingerprint
        )

        var candidates = buildCandidates(
            prefix: prefix,
            language: language,
            identifiers: identifiers,
            cursorLocation: context.cursorLocation,
            includeExactDocumentIdentifierMatch: context.triggerKind == .manual
        )

        if candidates.isEmpty {
            return EditorAutocompleteState(
                isVisible: false,
                query: prefix,
                selectedIndex: 0,
                replacementRange: tokenRange,
                items: []
            )
        }

        // 排序
        candidates = sortCandidates(candidates, prefix: prefix, cursorLocation: context.cursorLocation)

        // 截断
        if candidates.count > EditorAutocompleteConstants.maxResultCount {
            candidates = Array(candidates.prefix(EditorAutocompleteConstants.maxResultCount))
        }

        return EditorAutocompleteState(
            isVisible: true,
            query: prefix,
            selectedIndex: 0,
            replacementRange: tokenRange,
            items: candidates
        )
    }

    /// 接受候选项，返回替换后的新文本和新选区
    public func accept(
        item: EditorAutocompleteItem,
        state: EditorAutocompleteState,
        currentText: String
    ) -> (text: String, selection: EditorSelectionSnapshot)? {
        let nsText = currentText as NSString
        let range = state.replacementRange

        // 安全检查
        guard range.location >= 0,
              range.location + range.length <= nsText.length else {
            return nil
        }

        let newText = nsText.replacingCharacters(in: range, with: item.insertText)
        let caretLocation = range.location + (item.insertText as NSString).length

        return (
            text: newText,
            selection: EditorSelectionSnapshot(location: caretLocation, length: 0)
        )
    }

    /// 计算接受候选后的替换指令（纯函数，不修改状态）
    public static func replacement(
        for item: EditorAutocompleteItem,
        state: EditorAutocompleteState
    ) -> EditorAutocompleteReplacement {
        let caretLocation = state.replacementRange.location + (item.insertText as NSString).length
        return EditorAutocompleteReplacement(
            rangeLocation: state.replacementRange.location,
            rangeLength: state.replacementRange.length,
            replacementText: item.insertText,
            caretLocation: caretLocation
        )
    }

    // MARK: - 标识符 token 解析

    /// 光标所在标识符 token 的信息
    struct IdentifierTokenInfo {
        let prefix: String
        let range: NSRange
    }

    /// 解析光标位置的标识符 token
    func currentIdentifierToken(in nsText: NSString, at cursorLocation: Int) -> IdentifierTokenInfo? {
        guard cursorLocation >= 0, cursorLocation <= nsText.length else { return nil }
        guard nsText.length > 0 else { return nil }

        var probe = cursorLocation
        if probe == nsText.length {
            guard probe > 0, isIdentifierContinue(nsText.character(at: probe - 1)) else { return nil }
            probe -= 1
        } else if !isIdentifierContinue(nsText.character(at: probe)) {
            guard probe > 0, isIdentifierContinue(nsText.character(at: probe - 1)) else { return nil }
            probe -= 1
        }

        // 向前扫描标识符字符
        var start = probe
        while start > 0 {
            let ch = nsText.character(at: start - 1)
            if isIdentifierContinue(ch) {
                start -= 1
            } else {
                break
            }
        }

        // 向后扫描标识符字符（token 尾部）
        var end = probe + 1
        while end < nsText.length {
            let ch = nsText.character(at: end)
            if isIdentifierContinue(ch) {
                end += 1
            } else {
                break
            }
        }

        let tokenLength = end - start
        guard tokenLength > 0 else { return nil }

        // 检查首字符是否合法
        let firstChar = nsText.character(at: start)
        guard isIdentifierStart(firstChar) else { return nil }

        let prefix = nsText.substring(with: NSRange(location: start, length: cursorLocation - start))
        let range = NSRange(location: start, length: tokenLength)
        return IdentifierTokenInfo(prefix: prefix, range: range)
    }

    // MARK: - 字符判断

    private func isIdentifierStart(_ ch: unichar) -> Bool {
        // [A-Za-z_]
        (ch >= 0x41 && ch <= 0x5A) || // A-Z
        (ch >= 0x61 && ch <= 0x7A) || // a-z
        ch == 0x5F // _
    }

    private func isIdentifierContinue(_ ch: unichar) -> Bool {
        // [A-Za-z0-9_]
        isIdentifierStart(ch) || (ch >= 0x30 && ch <= 0x39) // 0-9
    }

    private func isIdentifierChar(_ ch: unichar, isFirst: Bool) -> Bool {
        if isFirst {
            return isIdentifierStart(ch)
        }
        return isIdentifierContinue(ch)
    }

    // MARK: - 注释/字符串检测

    /// 判断光标位置是否在注释或字符串内部（基于高亮运行片段）
    func isInsideCommentOrString(text: String, cursorLocation: Int, language: EditorSyntaxLanguage) -> Bool {
        // 使用词法分析来检查光标处的语义角色
        guard language != .plainText else { return false }
        guard let runs = try? EditorSyntaxLexer.tokenize(text: text, language: language) else { return false }

        for run in runs {
            let runEnd = run.location + run.length
            if cursorLocation > run.location && cursorLocation <= runEnd {
                if run.role == .comment || run.role == .string {
                    return true
                }
            }
        }
        return isInsideUnterminatedCommentOrString(text: text, cursorLocation: cursorLocation, language: language)
    }

    // MARK: - 候选构建

    /// 构建候选列表（前缀过滤）
    private func buildCandidates(
        prefix: String,
        language: EditorSyntaxLanguage,
        identifiers: [EditorDocumentIdentifierIndex.DocumentIdentifier],
        cursorLocation: Int,
        includeExactDocumentIdentifierMatch: Bool
    ) -> [EditorAutocompleteItem] {
        let lowerPrefix = prefix.lowercased()
        var items: [EditorAutocompleteItem] = []
        var seen = Set<String>()

        // 文档标识符
        for ident in identifiers {
            let lower = ident.text.lowercased()
            guard lower.hasPrefix(lowerPrefix) else { continue }
            // 排除与前缀完全相同的候选（避免补全自身）
            if !includeExactDocumentIdentifierMatch {
                guard ident.text != prefix else { continue }
            }
            guard !seen.contains(ident.text) else { continue }
            seen.insert(ident.text)
            items.append(EditorAutocompleteItem(
                id: "doc:\(ident.text)",
                title: ident.text,
                detail: nil,
                insertText: ident.text,
                kind: .documentSymbol
            ))
        }

        // 语言关键字
        let keywords = EditorAutocompleteKeywordCatalog.keywords(for: language)
        for kw in keywords {
            let lower = kw.lowercased()
            guard lower.hasPrefix(lowerPrefix) else { continue }
            guard kw != prefix else { continue }
            guard !seen.contains(kw) else { continue }
            seen.insert(kw)
            items.append(EditorAutocompleteItem(
                id: "kw:\(kw)",
                title: kw,
                detail: "keyword",
                insertText: kw,
                kind: .languageKeyword
            ))
        }

        // 语言模板
        let templates = EditorAutocompleteKeywordCatalog.templates(for: language)
        for tpl in templates {
            let lower = tpl.title.lowercased()
            guard lower.hasPrefix(lowerPrefix) || tpl.insertText.lowercased().hasPrefix(lowerPrefix) else { continue }
            let tplId = "tpl:\(tpl.title)"
            guard !seen.contains(tplId) else { continue }
            seen.insert(tplId)
            items.append(EditorAutocompleteItem(
                id: tplId,
                title: tpl.title,
                detail: tpl.detail,
                insertText: tpl.insertText,
                kind: .languageTemplate
            ))
        }

        return items
    }

    /// 构建手动触发无前缀时的候选
    private func buildCandidatesForManualTriggerNoPrefix(
        language: EditorSyntaxLanguage,
        identifiers: [EditorDocumentIdentifierIndex.DocumentIdentifier],
        cursorLocation: Int
    ) -> [EditorAutocompleteItem] {
        var items: [EditorAutocompleteItem] = []
        var seen = Set<String>()

        for ident in identifiers {
            guard !seen.contains(ident.text) else { continue }
            seen.insert(ident.text)
            items.append(EditorAutocompleteItem(
                id: "doc:\(ident.text)",
                title: ident.text,
                insertText: ident.text,
                kind: .documentSymbol
            ))
        }

        let keywords = EditorAutocompleteKeywordCatalog.keywords(for: language)
        for kw in keywords {
            guard !seen.contains(kw) else { continue }
            seen.insert(kw)
            items.append(EditorAutocompleteItem(
                id: "kw:\(kw)",
                title: kw,
                detail: "keyword",
                insertText: kw,
                kind: .languageKeyword
            ))
        }

        let templates = EditorAutocompleteKeywordCatalog.templates(for: language)
        for tpl in templates {
            let tplId = "tpl:\(tpl.title)"
            guard !seen.contains(tplId) else { continue }
            seen.insert(tplId)
            items.append(EditorAutocompleteItem(
                id: tplId,
                title: tpl.title,
                detail: tpl.detail,
                insertText: tpl.insertText,
                kind: .languageTemplate
            ))
        }

        items = sortCandidates(items, prefix: "", cursorLocation: cursorLocation)

        // 截断
        if items.count > EditorAutocompleteConstants.maxResultCount {
            items = Array(items.prefix(EditorAutocompleteConstants.maxResultCount))
        }

        return items
    }

    // MARK: - 排序

    /// 稳定排序规则：
    /// 1. 前缀完全匹配优先于前缀包含
    /// 2. documentSymbol 优先于 languageKeyword 优先于 languageTemplate
    /// 3. 文档标识符中距光标最近的优先
    /// 4. 标题字典序
    private func sortCandidates(
        _ candidates: [EditorAutocompleteItem],
        prefix: String,
        cursorLocation: Int
    ) -> [EditorAutocompleteItem] {
        return candidates.sorted { a, b in
            let aExact = a.title.hasPrefix(prefix)
            let bExact = b.title.hasPrefix(prefix)
            if aExact != bExact { return aExact }

            let aKindOrder = kindSortOrder(a.kind)
            let bKindOrder = kindSortOrder(b.kind)
            if aKindOrder != bKindOrder { return aKindOrder < bKindOrder }

            // 标题字典序
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private func kindSortOrder(_ kind: EditorAutocompleteItemKind) -> Int {
        switch kind {
        case .documentSymbol: return 0
        case .languageKeyword: return 1
        case .languageTemplate: return 2
        }
    }

    private func isInsideUnterminatedCommentOrString(
        text: String,
        cursorLocation: Int,
        language: EditorSyntaxLanguage
    ) -> Bool {
        let nsText = text as NSString
        let limit = min(max(cursorLocation, 0), nsText.length)
        var offset = 0
        var inLineComment = false
        var blockCommentDepth = 0
        var stringDelimiter: String?

        while offset < limit {
            if inLineComment {
                if matchesToken("\n", in: nsText, at: offset) {
                    inLineComment = false
                }
                offset += 1
                continue
            }

            if blockCommentDepth > 0 {
                if supportsNestedBlockComments(for: language),
                   matchesToken("/*", in: nsText, at: offset) {
                    blockCommentDepth += 1
                    offset += 2
                    continue
                }
                if matchesToken("*/", in: nsText, at: offset) {
                    blockCommentDepth -= 1
                    offset += 2
                    continue
                }
                offset += 1
                continue
            }

            if let delimiter = stringDelimiter {
                if matchesToken(delimiter, in: nsText, at: offset),
                   delimiter.count > 1 || !isEscaped(in: nsText, at: offset) {
                    offset += delimiter.utf16.count
                    stringDelimiter = nil
                    continue
                }
                offset += 1
                continue
            }

            if let lineCommentToken = lineCommentToken(for: language),
               matchesToken(lineCommentToken, in: nsText, at: offset) {
                inLineComment = true
                offset += lineCommentToken.utf16.count
                continue
            }

            if supportsBlockComments(for: language), matchesToken("/*", in: nsText, at: offset) {
                blockCommentDepth = 1
                offset += 2
                continue
            }

            if let delimiter = startingStringDelimiter(in: nsText, at: offset, language: language) {
                stringDelimiter = delimiter
                offset += delimiter.utf16.count
                continue
            }

            offset += 1
        }

        return inLineComment || blockCommentDepth > 0 || stringDelimiter != nil
    }

    private func lineCommentToken(for language: EditorSyntaxLanguage) -> String? {
        switch language {
        case .swift, .rust, .javascript, .typescript, .json:
            return "//"
        case .python:
            return "#"
        case .markdown, .plainText:
            return nil
        }
    }

    private func supportsBlockComments(for language: EditorSyntaxLanguage) -> Bool {
        switch language {
        case .swift, .rust, .javascript, .typescript, .json:
            return true
        case .python, .markdown, .plainText:
            return false
        }
    }

    private func supportsNestedBlockComments(for language: EditorSyntaxLanguage) -> Bool {
        language == .swift
    }

    private func startingStringDelimiter(
        in nsText: NSString,
        at offset: Int,
        language: EditorSyntaxLanguage
    ) -> String? {
        let delimiters: [String]
        switch language {
        case .swift:
            delimiters = ["\"\"\"", "\""]
        case .rust:
            delimiters = ["\"", "'"]
        case .javascript, .typescript:
            delimiters = ["`", "\"", "'"]
        case .python:
            delimiters = ["\"\"\"", "'''", "\"", "'"]
        case .json:
            delimiters = ["\""]
        case .markdown:
            delimiters = ["```", "`"]
        case .plainText:
            delimiters = []
        }

        for delimiter in delimiters {
            if matchesToken(delimiter, in: nsText, at: offset) {
                return delimiter
            }
        }
        return nil
    }

    private func matchesToken(_ token: String, in nsText: NSString, at offset: Int) -> Bool {
        let length = token.utf16.count
        guard offset >= 0, offset + length <= nsText.length else { return false }
        return nsText.substring(with: NSRange(location: offset, length: length)) == token
    }

    private func isEscaped(in nsText: NSString, at offset: Int) -> Bool {
        guard offset > 0 else { return false }

        var slashCount = 0
        var index = offset - 1
        while index >= 0, nsText.character(at: index) == 0x5C {
            slashCount += 1
            if index == 0 {
                break
            }
            index -= 1
        }

        return slashCount % 2 == 1
    }
}
