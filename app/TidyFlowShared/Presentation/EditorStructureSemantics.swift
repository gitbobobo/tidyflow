import Foundation

// MARK: - 编辑器结构语义共享层
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 提供跨 macOS/iOS 共享的编辑器代码折叠、缩进导线和结构分析能力。
//
// 设计约束：
// - 共享层只输出语义行号、列号和折叠关系，不持有平台 rect、颜色或命中区域。
// - 结构分析采用轻量级行扫描与内容指纹缓存，不引入 Tree-sitter/LSP。
// - 平台层只允许读取 EditorCodeFoldingProjection，不得再自行推导隐藏行范围。
// - 折叠是展示层行为，不改写文档内容。

// MARK: - 折叠区域类型

/// 折叠区域的种类
public enum EditorFoldRegionKind: String, Equatable, Hashable, Sendable {
    /// 大括号/方括号/圆括号块（Swift, Rust, JS, TS, JSON）
    case braces
    /// 缩进块（Python）
    case indent
}

// MARK: - 折叠区域 ID

/// 折叠区域的稳定标识键，基于 startLine/endLine/kind 生成。
/// 文本轻微编辑后若同一位置仍存在相同结构，ID 保持不变。
public struct EditorFoldRegionID: Hashable, Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int
    public let kind: EditorFoldRegionKind

    public init(startLine: Int, endLine: Int, kind: EditorFoldRegionKind) {
        self.startLine = startLine
        self.endLine = endLine
        self.kind = kind
    }
}

// MARK: - 折叠区域

/// 描述一个可折叠代码区块。
public struct EditorFoldRegion: Equatable, Sendable {
    /// 稳定标识键
    public let id: EditorFoldRegionID
    /// 折叠种类
    public let kind: EditorFoldRegionKind
    /// 起始行（0-based）
    public let startLine: Int
    /// 结束行（0-based，含此行）
    public let endLine: Int
    /// 嵌套深度（0 表示顶层）
    public let depth: Int
    /// 折叠后用作占位显示的行号（通常是 startLine）
    public let placeholderLine: Int

    public init(startLine: Int, endLine: Int, kind: EditorFoldRegionKind, depth: Int) {
        self.id = EditorFoldRegionID(startLine: startLine, endLine: endLine, kind: kind)
        self.kind = kind
        self.startLine = startLine
        self.endLine = endLine
        self.depth = depth
        self.placeholderLine = startLine
    }
}

// MARK: - 缩进导线段

/// 描述一条缩进引导线的可见段。
public struct EditorIndentGuideSegment: Equatable, Sendable {
    /// 起始行（0-based）
    public let startLine: Int
    /// 结束行（0-based，含此行）
    public let endLine: Int
    /// 缩进深度（从 0 开始）
    public let depth: Int
    /// 引导线所在列号（字符级，0-based）
    public let column: Int
    /// 是否被折叠截断
    public let trimmedByFold: Bool

    public init(startLine: Int, endLine: Int, depth: Int, column: Int, trimmedByFold: Bool = false) {
        self.startLine = startLine
        self.endLine = endLine
        self.depth = depth
        self.column = column
        self.trimmedByFold = trimmedByFold
    }
}

// MARK: - 结构分析快照

/// 一次完整结构分析的不可变结果。
public struct EditorStructureSnapshot: Equatable, Sendable {
    /// 文本内容的指纹（用于版本校验）
    public let contentFingerprint: Int
    /// 识别到的语言
    public let language: EditorSyntaxLanguage
    /// 总行数
    public let lineCount: Int
    /// 可折叠区域列表（按 startLine 升序）
    public let foldRegions: [EditorFoldRegion]
    /// 每行的缩进层级（索引为行号）
    public let lineIndentLevels: [Int]
    /// 缩进导线段列表
    public let indentGuides: [EditorIndentGuideSegment]

    public init(
        contentFingerprint: Int,
        language: EditorSyntaxLanguage,
        lineCount: Int,
        foldRegions: [EditorFoldRegion],
        lineIndentLevels: [Int],
        indentGuides: [EditorIndentGuideSegment]
    ) {
        self.contentFingerprint = contentFingerprint
        self.language = language
        self.lineCount = lineCount
        self.foldRegions = foldRegions
        self.lineIndentLevels = lineIndentLevels
        self.indentGuides = indentGuides
    }

    /// 空快照（不支持折叠的语言使用）
    public static func empty(contentFingerprint: Int, language: EditorSyntaxLanguage, lineCount: Int) -> EditorStructureSnapshot {
        EditorStructureSnapshot(
            contentFingerprint: contentFingerprint,
            language: language,
            lineCount: lineCount,
            foldRegions: [],
            lineIndentLevels: Array(repeating: 0, count: lineCount),
            indentGuides: []
        )
    }
}

// MARK: - 折叠状态

/// 每个文档的运行时折叠状态。
/// 只记录当前已折叠的区域 ID 集合和最近一次匹配的内容指纹。
public struct EditorCodeFoldingState: Equatable, Sendable {
    /// 当前已折叠的区域 ID 集合
    public var collapsedRegionIDs: Set<EditorFoldRegionID>
    /// 最近一次 reconcile 时使用的内容指纹
    public var contentFingerprint: Int

    public init(collapsedRegionIDs: Set<EditorFoldRegionID> = [], contentFingerprint: Int = 0) {
        self.collapsedRegionIDs = collapsedRegionIDs
        self.contentFingerprint = contentFingerprint
    }

    /// 与新快照对账：清理快照中已不存在的折叠区域，保留仍然有效的。
    public mutating func reconcile(snapshot: EditorStructureSnapshot) {
        let validIDs = Set(snapshot.foldRegions.map(\.id))
        collapsedRegionIDs = collapsedRegionIDs.intersection(validIDs)
        contentFingerprint = snapshot.contentFingerprint
    }

    /// 切换指定区域的折叠状态
    public mutating func toggle(_ regionID: EditorFoldRegionID) {
        if collapsedRegionIDs.contains(regionID) {
            collapsedRegionIDs.remove(regionID)
        } else {
            collapsedRegionIDs.insert(regionID)
        }
    }

    /// 展开指定区域（如果它当前是折叠的）
    public mutating func expand(_ regionID: EditorFoldRegionID) {
        collapsedRegionIDs.remove(regionID)
    }

    /// 展开包含指定行的所有折叠区域
    public mutating func expandRegions(containingLine line: Int, in snapshot: EditorStructureSnapshot) {
        let toExpand = snapshot.foldRegions.filter { region in
            collapsedRegionIDs.contains(region.id) &&
            line >= region.startLine && line <= region.endLine
        }
        for region in toExpand {
            collapsedRegionIDs.remove(region.id)
        }
    }
}

// MARK: - 折叠控制点

/// 折叠控制点信息（供平台层渲染折叠按钮）
public struct EditorFoldControl: Equatable, Sendable {
    /// 对应的折叠区域
    public let region: EditorFoldRegion
    /// 当前是否已折叠
    public let isCollapsed: Bool

    public init(region: EditorFoldRegion, isCollapsed: Bool) {
        self.region = region
        self.isCollapsed = isCollapsed
    }
}

// MARK: - 折叠投影

/// 基于 snapshot + state 产出的平台消费对象。
/// 平台层只需要读取此投影来决定渲染行为。
public struct EditorCodeFoldingProjection: Equatable, Sendable {
    /// 应隐藏的行范围列表（每个元素是 [startLine, endLine] 的闭区间）
    public let hiddenLineRanges: [ClosedRange<Int>]
    /// 折叠控制点列表（供渲染折叠按钮）
    public let foldControls: [EditorFoldControl]
    /// 当前可见的缩进导线段
    public let visibleIndentGuides: [EditorIndentGuideSegment]

    public init(
        hiddenLineRanges: [ClosedRange<Int>],
        foldControls: [EditorFoldControl],
        visibleIndentGuides: [EditorIndentGuideSegment]
    ) {
        self.hiddenLineRanges = hiddenLineRanges
        self.foldControls = foldControls
        self.visibleIndentGuides = visibleIndentGuides
    }

    /// 空投影（无折叠状态时使用）
    public static let empty = EditorCodeFoldingProjection(
        hiddenLineRanges: [],
        foldControls: [],
        visibleIndentGuides: []
    )

    /// 从快照和折叠状态生成投影
    public static func make(snapshot: EditorStructureSnapshot, state: EditorCodeFoldingState) -> EditorCodeFoldingProjection {
        // 生成折叠控制点
        let foldControls = snapshot.foldRegions.map { region in
            EditorFoldControl(
                region: region,
                isCollapsed: state.collapsedRegionIDs.contains(region.id)
            )
        }

        // 计算隐藏行范围
        var hiddenLineRanges: [ClosedRange<Int>] = []
        let collapsedRegions = snapshot.foldRegions.filter { state.collapsedRegionIDs.contains($0.id) }

        // 按 startLine 排序，合并重叠的隐藏范围
        let sortedCollapsed = collapsedRegions.sorted { $0.startLine < $1.startLine }
        for region in sortedCollapsed {
            // 隐藏区域是 startLine+1 到 endLine（startLine 本身保留为占位行）
            guard region.endLine > region.startLine else { continue }
            let newRange = (region.startLine + 1)...region.endLine
            if let last = hiddenLineRanges.last, last.upperBound >= newRange.lowerBound - 1 {
                // 合并重叠或相邻的范围
                hiddenLineRanges[hiddenLineRanges.count - 1] = last.lowerBound...max(last.upperBound, newRange.upperBound)
            } else {
                hiddenLineRanges.append(newRange)
            }
        }

        // 构建隐藏行集合用于过滤缩进导线
        var hiddenLines = Set<Int>()
        for range in hiddenLineRanges {
            for line in range {
                hiddenLines.insert(line)
            }
        }

        // 过滤缩进导线：移除完全在隐藏区域内的导线，裁剪部分隐藏的导线
        var visibleGuides: [EditorIndentGuideSegment] = []
        for guide in snapshot.indentGuides {
            // 检查是否完全隐藏
            let allHidden = (guide.startLine...guide.endLine).allSatisfy { hiddenLines.contains($0) }
            if allHidden { continue }

            // 检查是否需要裁剪
            let visibleLines = (guide.startLine...guide.endLine).filter { !hiddenLines.contains($0) }
            guard let firstVisible = visibleLines.first, let lastVisible = visibleLines.last else { continue }

            if firstVisible == guide.startLine && lastVisible == guide.endLine {
                visibleGuides.append(guide)
            } else {
                visibleGuides.append(EditorIndentGuideSegment(
                    startLine: firstVisible,
                    endLine: lastVisible,
                    depth: guide.depth,
                    column: guide.column,
                    trimmedByFold: true
                ))
            }
        }

        return EditorCodeFoldingProjection(
            hiddenLineRanges: hiddenLineRanges,
            foldControls: foldControls,
            visibleIndentGuides: visibleGuides
        )
    }

    /// 判断指定行是否在隐藏范围内
    public func isLineHidden(_ line: Int) -> Bool {
        hiddenLineRanges.contains { $0.contains(line) }
    }
}

// MARK: - 结构分析器

/// 编辑器结构分析器。
///
/// 采用轻量级行扫描策略分析代码结构：
/// - Swift/Rust/JavaScript/TypeScript/JSON：以 `{}`/`[]`/`()` 为块边界
/// - Python：以缩进层级为块边界
/// - Markdown/plainText：不支持折叠，返回空结果
///
/// 内置单条目缓存，内容指纹不变时复用上次分析结果。
public final class EditorStructureAnalyzer: @unchecked Sendable {
    private var cachedSnapshot: EditorStructureSnapshot?
    private var cachedFilePath: String?
    private let lock = NSLock()

    public init() {}

    /// 分析文本结构。
    ///
    /// - Parameters:
    ///   - filePath: 文件路径（用于语言识别）
    ///   - text: 文本内容
    ///   - tabWidth: Tab 宽度（用于缩进计算，默认 4）
    /// - Returns: 结构分析快照
    public func analyze(filePath: String, text: String, tabWidth: Int = 4) -> EditorStructureSnapshot {
        let fingerprint = EditorSyntaxFingerprint.compute(text)
        let language = EditorSyntaxLanguage.from(filePath: filePath)

        lock.lock()
        if let cached = cachedSnapshot,
           cached.contentFingerprint == fingerprint,
           cached.language == language,
           cachedFilePath == filePath {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let lines = text.components(separatedBy: "\n")
        let lineCount = lines.count

        let snapshot: EditorStructureSnapshot
        switch language {
        case .swift, .rust, .javascript, .typescript, .json:
            snapshot = analyzeBracketLanguage(lines: lines, lineCount: lineCount, language: language, fingerprint: fingerprint, tabWidth: tabWidth)
        case .python:
            snapshot = analyzePythonLanguage(lines: lines, lineCount: lineCount, fingerprint: fingerprint, tabWidth: tabWidth)
        case .markdown, .plainText:
            snapshot = .empty(contentFingerprint: fingerprint, language: language, lineCount: lineCount)
        }

        lock.lock()
        cachedSnapshot = snapshot
        cachedFilePath = filePath
        lock.unlock()

        return snapshot
    }

    /// 清除缓存
    public func invalidateCache() {
        lock.lock()
        cachedSnapshot = nil
        cachedFilePath = nil
        lock.unlock()
    }

    // MARK: - 括号语言分析

    /// 分析括号类语言（Swift/Rust/JS/TS/JSON）的代码结构
    private func analyzeBracketLanguage(
        lines: [String],
        lineCount: Int,
        language: EditorSyntaxLanguage,
        fingerprint: Int,
        tabWidth: Int
    ) -> EditorStructureSnapshot {
        var indentLevels = [Int](repeating: 0, count: lineCount)
        var foldRegions: [EditorFoldRegion] = []

        // 栈：记录未关闭的开括号行号和深度
        struct BracketOpen {
            let line: Int
            let char: Character
            let depth: Int
        }
        var stack: [BracketOpen] = []
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var stringDelimiter: Character = "\""

        for (lineIndex, line) in lines.enumerated() {
            // 计算缩进层级
            indentLevels[lineIndex] = computeIndentLevel(line: line, tabWidth: tabWidth)

            let chars = Array(line)
            var i = 0
            // 行开始时重置行注释状态
            inLineComment = false

            while i < chars.count {
                let ch = chars[i]

                // 字符串内部
                if inString {
                    if ch == "\\" && i + 1 < chars.count {
                        i += 2 // 跳过转义
                        continue
                    }
                    if ch == stringDelimiter {
                        inString = false
                    }
                    i += 1
                    continue
                }

                // 块注释内部
                if inBlockComment {
                    if ch == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                        inBlockComment = false
                        i += 2
                        continue
                    }
                    i += 1
                    continue
                }

                // 行注释
                if inLineComment {
                    break
                }

                // 检测注释开始
                if ch == "/" && i + 1 < chars.count {
                    if chars[i + 1] == "/" {
                        inLineComment = true
                        break
                    }
                    if chars[i + 1] == "*" {
                        inBlockComment = true
                        i += 2
                        continue
                    }
                }

                // 检测字符串开始
                if ch == "\"" || ch == "'" || ch == "`" {
                    // JSON 只用双引号；其他语言支持单引号和反引号
                    if language == .json && ch != "\"" {
                        i += 1
                        continue
                    }
                    inString = true
                    stringDelimiter = ch
                    i += 1
                    continue
                }

                // 检测开括号
                if ch == "{" || ch == "[" || ch == "(" {
                    stack.append(BracketOpen(line: lineIndex, char: ch, depth: stack.count))
                }
                // 检测闭括号
                else if ch == "}" || ch == "]" || ch == ")" {
                    let expected: Character
                    switch ch {
                    case "}": expected = "{"
                    case "]": expected = "["
                    case ")": expected = "("
                    default: expected = ch
                    }
                    if let last = stack.last, last.char == expected {
                        let open = stack.removeLast()
                        // 只为跨多行的块生成折叠区域
                        if lineIndex > open.line {
                            // 裁剪结束行：去掉尾部空白行
                            let trimmedEnd = trimTrailingBlankLines(from: open.line + 1, to: lineIndex, lines: lines)
                            if trimmedEnd > open.line {
                                foldRegions.append(EditorFoldRegion(
                                    startLine: open.line,
                                    endLine: trimmedEnd,
                                    kind: .braces,
                                    depth: open.depth
                                ))
                            }
                        }
                    }
                }

                i += 1
            }
        }

        // 按 startLine 排序
        foldRegions.sort { $0.startLine < $1.startLine }

        // 生成缩进导线
        let guides = buildIndentGuides(indentLevels: indentLevels, lines: lines, tabWidth: tabWidth)

        return EditorStructureSnapshot(
            contentFingerprint: fingerprint,
            language: language,
            lineCount: lineCount,
            foldRegions: foldRegions,
            lineIndentLevels: indentLevels,
            indentGuides: guides
        )
    }

    // MARK: - Python 缩进分析

    /// 分析 Python 缩进语言的代码结构
    private func analyzePythonLanguage(
        lines: [String],
        lineCount: Int,
        fingerprint: Int,
        tabWidth: Int
    ) -> EditorStructureSnapshot {
        var indentLevels = [Int](repeating: 0, count: lineCount)
        var foldRegions: [EditorFoldRegion] = []

        // 计算每行的缩进层级
        for (i, line) in lines.enumerated() {
            indentLevels[i] = computeIndentLevel(line: line, tabWidth: tabWidth)
        }

        // 标记非空行
        let isNonBlank = lines.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // 使用栈来识别缩进块
        // Python 缩进块：某行的缩进层级高于前一个非空行时，前一行是折叠起点
        struct IndentBlock {
            let startLine: Int
            let indentLevel: Int
            let depth: Int
        }
        var stack: [IndentBlock] = []

        // 找到第一个非空行来建立基准
        var lastNonBlankLine = -1
        var lastNonBlankIndent = 0

        for i in 0..<lineCount {
            guard isNonBlank[i] else { continue }

            let currentIndent = indentLevels[i]

            if lastNonBlankLine >= 0 {
                if currentIndent > lastNonBlankIndent {
                    // 缩进增加：上一个非空行是块起点
                    stack.append(IndentBlock(
                        startLine: lastNonBlankLine,
                        indentLevel: lastNonBlankIndent,
                        depth: stack.count
                    ))
                } else if currentIndent < lastNonBlankIndent {
                    // 缩进减少：关闭所有缩进层级大于等于当前的块
                    while let top = stack.last, currentIndent <= top.indentLevel {
                        stack.removeLast()
                        // 找到块结束行：当前行的前一个非空行
                        let endLine = findLastNonBlankLine(before: i, lines: lines, isNonBlank: isNonBlank)
                        if endLine > top.startLine {
                            foldRegions.append(EditorFoldRegion(
                                startLine: top.startLine,
                                endLine: endLine,
                                kind: .indent,
                                depth: top.depth
                            ))
                        }
                    }
                }
            }

            lastNonBlankLine = i
            lastNonBlankIndent = currentIndent
        }

        // 关闭所有剩余的块
        while let top = stack.popLast() {
            let endLine = findLastNonBlankLine(before: lineCount, lines: lines, isNonBlank: isNonBlank)
            if endLine > top.startLine {
                foldRegions.append(EditorFoldRegion(
                    startLine: top.startLine,
                    endLine: endLine,
                    kind: .indent,
                    depth: top.depth
                ))
            }
        }

        // 按 startLine 排序
        foldRegions.sort { $0.startLine < $1.startLine }

        // 生成缩进导线
        let guides = buildIndentGuides(indentLevels: indentLevels, lines: lines, tabWidth: tabWidth)

        return EditorStructureSnapshot(
            contentFingerprint: fingerprint,
            language: .python,
            lineCount: lineCount,
            foldRegions: foldRegions,
            lineIndentLevels: indentLevels,
            indentGuides: guides
        )
    }

    // MARK: - 工具方法

    /// 计算行的缩进层级（按 tabWidth 量化）
    private func computeIndentLevel(line: String, tabWidth: Int) -> Int {
        var spaces = 0
        for ch in line {
            if ch == " " {
                spaces += 1
            } else if ch == "\t" {
                spaces += tabWidth
            } else {
                break
            }
        }
        return tabWidth > 0 ? spaces / tabWidth : 0
    }

    /// 裁剪尾部空白行：从 endLine 向上找到最后一个非空行
    private func trimTrailingBlankLines(from startLine: Int, to endLine: Int, lines: [String]) -> Int {
        var trimmed = endLine
        while trimmed > startLine {
            let line = lines[trimmed]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            trimmed -= 1
        }
        return trimmed
    }

    /// 在指定行之前找到最后一个非空行
    private func findLastNonBlankLine(before lineIndex: Int, lines: [String], isNonBlank: [Bool]) -> Int {
        var i = lineIndex - 1
        while i >= 0 {
            if isNonBlank[i] { return i }
            i -= 1
        }
        return 0
    }

    /// 构建缩进导线段
    private func buildIndentGuides(indentLevels: [Int], lines: [String], tabWidth: Int) -> [EditorIndentGuideSegment] {
        guard !lines.isEmpty else { return [] }

        let lineCount = lines.count
        let isNonBlank = lines.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // 对于空白行，取相邻非空行的最小缩进（允许导线跨越空白行）
        var effectiveIndent = indentLevels
        for i in 0..<lineCount {
            if !isNonBlank[i] {
                // 向上和向下查找最近的非空行
                var above = 0
                var below = 0
                for j in stride(from: i - 1, through: 0, by: -1) {
                    if isNonBlank[j] { above = indentLevels[j]; break }
                }
                for j in (i + 1)..<lineCount {
                    if isNonBlank[j] { below = indentLevels[j]; break }
                }
                effectiveIndent[i] = min(above, below)
            }
        }

        // 找到最大缩进深度
        let maxDepth = effectiveIndent.max() ?? 0
        guard maxDepth > 0 else { return [] }

        var guides: [EditorIndentGuideSegment] = []

        // 为每个深度级别生成导线段
        for depth in 1...maxDepth {
            var segmentStart: Int? = nil
            for i in 0..<lineCount {
                if effectiveIndent[i] >= depth {
                    if segmentStart == nil {
                        segmentStart = i
                    }
                } else {
                    if let start = segmentStart {
                        guides.append(EditorIndentGuideSegment(
                            startLine: start,
                            endLine: i - 1,
                            depth: depth,
                            column: (depth - 1) * tabWidth
                        ))
                        segmentStart = nil
                    }
                }
            }
            // 收尾未关闭的段
            if let start = segmentStart {
                guides.append(EditorIndentGuideSegment(
                    startLine: start,
                    endLine: lineCount - 1,
                    depth: depth,
                    column: (depth - 1) * tabWidth
                ))
            }
        }

        return guides
    }
}
