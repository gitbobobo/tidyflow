import Foundation

// MARK: - 编辑器括号/引号匹配语义共享层
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 提供跨 macOS/iOS 共享的编辑器光标邻域括号/引号配对检测能力。
//
// 设计约束：
// - 共享层只输出 UTF-16 范围和状态枚举，不持有平台 rect、颜色或覆盖层。
// - 匹配是当前文本 + 当前光标位置的瞬时投影，不进入 EditorStore 或 MobileAppState。
// - 匹配语义与折叠分析保持独立，不把两者强绑定为同一模型。
// - 扫描逻辑复用 EditorStructureAnalyzer 的注释/字符串跳过思路，但拥有自己的独立扫描函数。

// MARK: - 匹配状态

/// 当前光标位置的括号/引号匹配状态
public enum EditorPairMatchState: String, Equatable, Hashable, Sendable {
    /// 光标附近没有受支持的分隔符，或语言不支持匹配
    case inactive
    /// 找到了合法的配对
    case matched
    /// 找到了活动分隔符但没有合法配对
    case mismatched
}

// MARK: - 高亮角色

/// 匹配高亮中每个标记的角色
public enum EditorPairHighlightRole: String, Equatable, Hashable, Sendable {
    /// 光标邻域的活动分隔符
    case activeDelimiter
    /// 活动分隔符的配对目标
    case pairedDelimiter
    /// 不匹配时的活动分隔符
    case mismatchDelimiter
}

// MARK: - 高亮标记

/// 单个需要高亮的字符范围
public struct EditorPairHighlight: Equatable, Sendable {
    /// UTF-16 起始偏移量
    public let location: Int
    /// UTF-16 长度（通常为 1）
    public let length: Int
    /// 高亮角色
    public let role: EditorPairHighlightRole

    public init(location: Int, length: Int, role: EditorPairHighlightRole) {
        self.location = location
        self.length = length
        self.role = role
    }

    /// 便捷 NSRange 访问
    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

// MARK: - 匹配快照

/// 一次匹配计算的不可变结果
public struct EditorPairMatchSnapshot: Equatable, Sendable {
    /// 文本内容指纹
    public let contentFingerprint: Int
    /// 识别到的语言
    public let language: EditorSyntaxLanguage
    /// 光标的 UTF-16 偏移量
    public let selectionLocation: Int
    /// 匹配状态
    public let state: EditorPairMatchState
    /// 需要高亮的标记列表（matched 时有 2 个，mismatched 时有 1 个，inactive 时为空）
    public let highlights: [EditorPairHighlight]

    public init(
        contentFingerprint: Int,
        language: EditorSyntaxLanguage,
        selectionLocation: Int,
        state: EditorPairMatchState,
        highlights: [EditorPairHighlight]
    ) {
        self.contentFingerprint = contentFingerprint
        self.language = language
        self.selectionLocation = selectionLocation
        self.state = state
        self.highlights = highlights
    }

    /// inactive 快照工厂
    public static func inactive(
        contentFingerprint: Int,
        language: EditorSyntaxLanguage,
        selectionLocation: Int
    ) -> EditorPairMatchSnapshot {
        EditorPairMatchSnapshot(
            contentFingerprint: contentFingerprint,
            language: language,
            selectionLocation: selectionLocation,
            state: .inactive,
            highlights: []
        )
    }
}

// MARK: - 匹配器

/// 编辑器括号/引号匹配器。
///
/// 给定文件路径、文本和选区信息，输出匹配快照。
/// 规则：
/// - 仅在选区长度为 0（折叠选区）时启用。
/// - 优先检查光标左侧字符，其次检查右侧字符。
/// - 支持 (), [], {}, "", '', ``。
/// - JSON 仅支持双引号。
/// - markdown/plainText 直接返回 inactive。
public enum EditorPairMatcher {

    /// 计算匹配快照
    ///
    /// - Parameters:
    ///   - filePath: 文件路径（用于语言识别）
    ///   - text: 完整文本内容
    ///   - selectionLocation: 选区起始 UTF-16 偏移量
    ///   - selectionLength: 选区长度（UTF-16）
    /// - Returns: 匹配快照
    public static func match(
        filePath: String,
        text: String,
        selectionLocation: Int,
        selectionLength: Int = 0
    ) -> EditorPairMatchSnapshot {
        let language = EditorSyntaxLanguage.from(filePath: filePath)
        let fingerprint = EditorSyntaxFingerprint.compute(text)

        // 不支持匹配的语言
        guard language != .markdown, language != .plainText else {
            return .inactive(contentFingerprint: fingerprint, language: language, selectionLocation: selectionLocation)
        }

        // 选区非折叠时不启用
        guard selectionLength == 0 else {
            return .inactive(contentFingerprint: fingerprint, language: language, selectionLocation: selectionLocation)
        }

        let utf16 = text.utf16
        let utf16Count = utf16.count

        // 尝试找到活动分隔符：优先左侧，其次右侧
        var activeOffset: Int? = nil
        var activeChar: Character? = nil

        // 检查左侧字符
        if selectionLocation > 0 && selectionLocation <= utf16Count {
            let leftOffset = selectionLocation - 1
            if let ch = characterAt(utf16Offset: leftOffset, in: text),
               isSupportedDelimiter(ch, language: language) {
                activeOffset = leftOffset
                activeChar = ch
            }
        }

        // 如果左侧没有，检查右侧字符
        if activeOffset == nil, selectionLocation < utf16Count {
            if let ch = characterAt(utf16Offset: selectionLocation, in: text),
               isSupportedDelimiter(ch, language: language) {
                activeOffset = selectionLocation
                activeChar = ch
            }
        }

        // 没有活动分隔符
        guard let offset = activeOffset, let ch = activeChar else {
            return .inactive(contentFingerprint: fingerprint, language: language, selectionLocation: selectionLocation)
        }

        // 检查活动分隔符是否处于有效上下文（不在注释或不相关的字符串内）
        let context = contextAt(utf16Offset: offset, in: text, language: language)
        if context == .lineComment || context == .blockComment {
            return .inactive(contentFingerprint: fingerprint, language: language, selectionLocation: selectionLocation)
        }

        // 执行配对扫描
        if isBracket(ch) {
            // 括号在字符串上下文中不参与匹配
            if context == .string {
                return .inactive(contentFingerprint: fingerprint, language: language, selectionLocation: selectionLocation)
            }
            return matchBracket(ch: ch, offset: offset, text: text, language: language, fingerprint: fingerprint, selectionLocation: selectionLocation)
        } else {
            // 引号匹配
            return matchQuote(ch: ch, offset: offset, text: text, language: language, fingerprint: fingerprint, selectionLocation: selectionLocation)
        }
    }

    // MARK: - 分隔符分类

    private static let openBrackets: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let closeBrackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    private static let quoteChars: Set<Character> = ["\"", "'", "`"]

    private static func isSupportedDelimiter(_ ch: Character, language: EditorSyntaxLanguage) -> Bool {
        if openBrackets[ch] != nil || closeBrackets[ch] != nil { return true }
        if ch == "\"" { return true }
        if ch == "'" || ch == "`" {
            return language != .json
        }
        return false
    }

    private static func isBracket(_ ch: Character) -> Bool {
        openBrackets[ch] != nil || closeBrackets[ch] != nil
    }

    // MARK: - UTF-16 字符访问

    private static func characterAt(utf16Offset: Int, in text: String) -> Character? {
        let utf16 = text.utf16
        guard utf16Offset >= 0, utf16Offset < utf16.count else { return nil }
        let idx = utf16.index(utf16.startIndex, offsetBy: utf16Offset)
        // 单个 UTF-16 code unit 对应的字符
        guard let scalar = Unicode.Scalar(utf16[idx]) else { return nil }
        return Character(scalar)
    }

    // MARK: - 上下文检测

    /// 扫描上下文：当前偏移处的字符是否在注释或字符串中
    enum ScanContext {
        case code
        case lineComment
        case blockComment
        case string
    }

    private static func contextAt(utf16Offset: Int, in text: String, language: EditorSyntaxLanguage) -> ScanContext {
        let utf16 = text.utf16
        guard !utf16.isEmpty else { return .code }

        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var stringDelimiter: UInt16 = 0
        var i = utf16.startIndex

        let targetIndex = utf16.index(utf16.startIndex, offsetBy: min(utf16Offset, utf16.count - 1))

        while i <= targetIndex {
            let cu = utf16[i]

            if inString {
                if cu == 0x5C /* \ */ {
                    // 跳过转义
                    let next = utf16.index(after: i)
                    if next < utf16.endIndex {
                        if next <= targetIndex {
                            i = utf16.index(after: next)
                            continue
                        } else {
                            // 转义的下一个字符在目标之后，当前仍在字符串中
                            break
                        }
                    }
                }
                if cu == stringDelimiter {
                    inString = false
                }
                if i == targetIndex {
                    return .string
                }
                i = utf16.index(after: i)
                continue
            }

            if inBlockComment {
                if cu == 0x2A /* * */ {
                    let next = utf16.index(after: i)
                    if next < utf16.endIndex, utf16[next] == 0x2F /* / */ {
                        if i == targetIndex || next == targetIndex {
                            return .blockComment
                        }
                        inBlockComment = false
                        i = utf16.index(after: next)
                        continue
                    }
                }
                if i == targetIndex {
                    return .blockComment
                }
                i = utf16.index(after: i)
                continue
            }

            if inLineComment {
                if cu == 0x0A /* \n */ {
                    inLineComment = false
                } else if i == targetIndex {
                    return .lineComment
                }
                i = utf16.index(after: i)
                continue
            }

            // 检测注释开始
            if cu == 0x2F /* / */ {
                let next = utf16.index(after: i)
                if next < utf16.endIndex {
                    let ncu = utf16[next]
                    if ncu == 0x2F /* / */ {
                        if i == targetIndex || next == targetIndex {
                            return .lineComment
                        }
                        inLineComment = true
                        i = utf16.index(after: next)
                        continue
                    }
                    if ncu == 0x2A /* * */ {
                        if i == targetIndex || next == targetIndex {
                            return .blockComment
                        }
                        inBlockComment = true
                        i = utf16.index(after: next)
                        continue
                    }
                }
            }

            // 检测字符串开始
            if cu == 0x22 /* " */ || cu == 0x27 /* ' */ || cu == 0x60 /* ` */ {
                if language == .json && cu != 0x22 {
                    if i == targetIndex { return .code }
                    i = utf16.index(after: i)
                    continue
                }
                inString = true
                stringDelimiter = cu
                if i == targetIndex {
                    return .string
                }
                i = utf16.index(after: i)
                continue
            }

            if i == targetIndex {
                return .code
            }
            i = utf16.index(after: i)
        }

        if inString { return .string }
        if inBlockComment { return .blockComment }
        if inLineComment { return .lineComment }
        return .code
    }

    // MARK: - 括号匹配

    private static func matchBracket(
        ch: Character,
        offset: Int,
        text: String,
        language: EditorSyntaxLanguage,
        fingerprint: Int,
        selectionLocation: Int
    ) -> EditorPairMatchSnapshot {
        let utf16 = text.utf16
        let utf16Count = utf16.count

        if let closingChar = openBrackets[ch] {
            // 开括号：向右扫描找闭括号
            if let pairedOffset = scanForward(
                from: offset + 1,
                openChar: ch,
                closeChar: closingChar,
                text: text,
                language: language
            ) {
                return EditorPairMatchSnapshot(
                    contentFingerprint: fingerprint,
                    language: language,
                    selectionLocation: selectionLocation,
                    state: .matched,
                    highlights: [
                        EditorPairHighlight(location: offset, length: 1, role: .activeDelimiter),
                        EditorPairHighlight(location: pairedOffset, length: 1, role: .pairedDelimiter),
                    ]
                )
            }
        } else if let openingChar = closeBrackets[ch] {
            // 闭括号：向左扫描找开括号
            if let pairedOffset = scanBackward(
                from: offset - 1,
                openChar: openingChar,
                closeChar: ch,
                text: text,
                language: language
            ) {
                return EditorPairMatchSnapshot(
                    contentFingerprint: fingerprint,
                    language: language,
                    selectionLocation: selectionLocation,
                    state: .matched,
                    highlights: [
                        EditorPairHighlight(location: offset, length: 1, role: .activeDelimiter),
                        EditorPairHighlight(location: pairedOffset, length: 1, role: .pairedDelimiter),
                    ]
                )
            }
        }

        // 没找到配对
        return EditorPairMatchSnapshot(
            contentFingerprint: fingerprint,
            language: language,
            selectionLocation: selectionLocation,
            state: .mismatched,
            highlights: [
                EditorPairHighlight(location: offset, length: 1, role: .mismatchDelimiter),
            ]
        )
    }

    /// 向前扫描查找配对闭括号（跳过注释和字符串）
    private static func scanForward(
        from start: Int,
        openChar: Character,
        closeChar: Character,
        text: String,
        language: EditorSyntaxLanguage
    ) -> Int? {
        let utf16 = text.utf16
        let utf16Count = utf16.count
        guard start < utf16Count else { return nil }

        let openCU = openChar.asciiValue.map { UInt16($0) } ?? 0
        let closeCU = closeChar.asciiValue.map { UInt16($0) } ?? 0

        var depth = 1
        var inString = false
        var stringDelimiter: UInt16 = 0
        var inLineComment = false
        var inBlockComment = false

        var i = utf16.index(utf16.startIndex, offsetBy: start)

        while i < utf16.endIndex {
            let cu = utf16[i]

            // 字符串内
            if inString {
                if cu == 0x5C /* \ */ {
                    let next = utf16.index(after: i)
                    if next < utf16.endIndex {
                        i = utf16.index(after: next)
                        continue
                    }
                }
                if cu == stringDelimiter {
                    inString = false
                }
                i = utf16.index(after: i)
                continue
            }

            // 块注释内
            if inBlockComment {
                if cu == 0x2A /* * */ {
                    let next = utf16.index(after: i)
                    if next < utf16.endIndex, utf16[next] == 0x2F /* / */ {
                        inBlockComment = false
                        i = utf16.index(after: next)
                        continue
                    }
                }
                i = utf16.index(after: i)
                continue
            }

            // 行注释
            if inLineComment {
                if cu == 0x0A /* \n */ {
                    inLineComment = false
                }
                i = utf16.index(after: i)
                continue
            }

            // 检测注释开始
            if cu == 0x2F /* / */ {
                let next = utf16.index(after: i)
                if next < utf16.endIndex {
                    let ncu = utf16[next]
                    if ncu == 0x2F {
                        inLineComment = true
                        i = utf16.index(after: next)
                        continue
                    }
                    if ncu == 0x2A {
                        inBlockComment = true
                        i = utf16.index(after: next)
                        continue
                    }
                }
            }

            // 检测字符串开始
            if cu == 0x22 || cu == 0x27 || cu == 0x60 {
                if language == .json && cu != 0x22 {
                    i = utf16.index(after: i)
                    continue
                }
                inString = true
                stringDelimiter = cu
                i = utf16.index(after: i)
                continue
            }

            // 匹配括号
            if cu == openCU {
                depth += 1
            } else if cu == closeCU {
                depth -= 1
                if depth == 0 {
                    return utf16.distance(from: utf16.startIndex, to: i)
                }
            }

            i = utf16.index(after: i)
        }

        return nil
    }

    /// 向后扫描查找配对开括号
    private static func scanBackward(
        from start: Int,
        openChar: Character,
        closeChar: Character,
        text: String,
        language: EditorSyntaxLanguage
    ) -> Int? {
        let utf16 = text.utf16
        guard start >= 0, !utf16.isEmpty else { return nil }

        // 向后扫描比较复杂，需要反方向遍历并跟踪上下文。
        // 策略：从头到 start 做一次正向扫描，构建有效括号位置栈。
        let openCU = openChar.asciiValue.map { UInt16($0) } ?? 0
        let closeCU = closeChar.asciiValue.map { UInt16($0) } ?? 0

        var stack: [Int] = [] // 存储未关闭的开括号 UTF-16 偏移
        var inString = false
        var stringDelimiter: UInt16 = 0
        var inLineComment = false
        var inBlockComment = false

        let endIndex = utf16.index(utf16.startIndex, offsetBy: min(start + 1, utf16.count))
        var i = utf16.startIndex

        while i < endIndex {
            let cu = utf16[i]

            if inString {
                if cu == 0x5C /* \ */ {
                    let next = utf16.index(after: i)
                    if next < endIndex {
                        i = utf16.index(after: next)
                        continue
                    }
                }
                if cu == stringDelimiter {
                    inString = false
                }
                i = utf16.index(after: i)
                continue
            }

            if inBlockComment {
                if cu == 0x2A /* * */ {
                    let next = utf16.index(after: i)
                    if next < endIndex, utf16[next] == 0x2F {
                        inBlockComment = false
                        i = utf16.index(after: next)
                        continue
                    }
                }
                i = utf16.index(after: i)
                continue
            }

            if inLineComment {
                if cu == 0x0A {
                    inLineComment = false
                }
                i = utf16.index(after: i)
                continue
            }

            if cu == 0x2F {
                let next = utf16.index(after: i)
                if next < endIndex {
                    let ncu = utf16[next]
                    if ncu == 0x2F {
                        inLineComment = true
                        i = utf16.index(after: next)
                        continue
                    }
                    if ncu == 0x2A {
                        inBlockComment = true
                        i = utf16.index(after: next)
                        continue
                    }
                }
            }

            if cu == 0x22 || cu == 0x27 || cu == 0x60 {
                if language == .json && cu != 0x22 {
                    i = utf16.index(after: i)
                    continue
                }
                inString = true
                stringDelimiter = cu
                i = utf16.index(after: i)
                continue
            }

            let currentOffset = utf16.distance(from: utf16.startIndex, to: i)
            if cu == openCU {
                stack.append(currentOffset)
            } else if cu == closeCU {
                if !stack.isEmpty {
                    stack.removeLast()
                }
            }

            i = utf16.index(after: i)
        }

        // 栈顶就是与当前闭括号配对的开括号
        return stack.last
    }

    // MARK: - 引号匹配

    private static func matchQuote(
        ch: Character,
        offset: Int,
        text: String,
        language: EditorSyntaxLanguage,
        fingerprint: Int,
        selectionLocation: Int
    ) -> EditorPairMatchSnapshot {
        // 找到当前引号所在的配对（从行首或文件头开始扫描）
        let utf16 = text.utf16
        let utf16Count = utf16.count
        let quoteCU = ch.asciiValue.map { UInt16($0) } ?? 0

        // 收集所有有效的（非转义、非注释中的）同类引号位置
        var quotePositions: [Int] = []
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var stringDelimiter: UInt16 = 0

        var i = utf16.startIndex
        while i < utf16.endIndex {
            let cu = utf16[i]
            let currentOffset = utf16.distance(from: utf16.startIndex, to: i)

            if inBlockComment {
                if cu == 0x2A {
                    let next = utf16.index(after: i)
                    if next < utf16.endIndex, utf16[next] == 0x2F {
                        inBlockComment = false
                        i = utf16.index(after: next)
                        continue
                    }
                }
                i = utf16.index(after: i)
                continue
            }

            if inLineComment {
                if cu == 0x0A {
                    inLineComment = false
                }
                i = utf16.index(after: i)
                continue
            }

            // 字符串内部（非目标引号类型的字符串）
            if inString && stringDelimiter != quoteCU {
                if cu == 0x5C {
                    let next = utf16.index(after: i)
                    if next < utf16.endIndex {
                        i = utf16.index(after: next)
                        continue
                    }
                }
                if cu == stringDelimiter {
                    inString = false
                }
                i = utf16.index(after: i)
                continue
            }

            // 在目标引号类型的字符串内
            if inString && stringDelimiter == quoteCU {
                if cu == 0x5C {
                    let next = utf16.index(after: i)
                    if next < utf16.endIndex {
                        i = utf16.index(after: next)
                        continue
                    }
                }
                if cu == quoteCU {
                    // 这是闭合引号
                    quotePositions.append(currentOffset)
                    inString = false
                }
                i = utf16.index(after: i)
                continue
            }

            // 代码上下文
            if cu == 0x2F {
                let next = utf16.index(after: i)
                if next < utf16.endIndex {
                    let ncu = utf16[next]
                    if ncu == 0x2F {
                        inLineComment = true
                        i = utf16.index(after: next)
                        continue
                    }
                    if ncu == 0x2A {
                        inBlockComment = true
                        i = utf16.index(after: next)
                        continue
                    }
                }
            }

            // 遇到引号
            if cu == 0x22 || cu == 0x27 || cu == 0x60 {
                if language == .json && cu != 0x22 {
                    i = utf16.index(after: i)
                    continue
                }
                if cu == quoteCU {
                    quotePositions.append(currentOffset)
                }
                inString = true
                stringDelimiter = cu
                i = utf16.index(after: i)
                continue
            }

            i = utf16.index(after: i)
        }

        // 找到 offset 在 quotePositions 中的位置
        guard let posIndex = quotePositions.firstIndex(of: offset) else {
            return .inactive(contentFingerprint: fingerprint, language: language, selectionLocation: selectionLocation)
        }

        // 引号是成对出现的：(0,1), (2,3), (4,5)...
        let pairIndex: Int
        if posIndex % 2 == 0 {
            // 开引号，配对是下一个
            pairIndex = posIndex + 1
        } else {
            // 闭引号，配对是上一个
            pairIndex = posIndex - 1
        }

        guard pairIndex >= 0, pairIndex < quotePositions.count else {
            return EditorPairMatchSnapshot(
                contentFingerprint: fingerprint,
                language: language,
                selectionLocation: selectionLocation,
                state: .mismatched,
                highlights: [
                    EditorPairHighlight(location: offset, length: 1, role: .mismatchDelimiter),
                ]
            )
        }

        let pairedOffset = quotePositions[pairIndex]
        return EditorPairMatchSnapshot(
            contentFingerprint: fingerprint,
            language: language,
            selectionLocation: selectionLocation,
            state: .matched,
            highlights: [
                EditorPairHighlight(location: offset, length: 1, role: .activeDelimiter),
                EditorPairHighlight(location: pairedOffset, length: 1, role: .pairedDelimiter),
            ]
        )
    }
}
