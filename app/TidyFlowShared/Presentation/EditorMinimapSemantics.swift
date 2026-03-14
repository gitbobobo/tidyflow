import Foundation

// MARK: - 编辑器 Minimap 共享语义层
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 提供跨 macOS/iOS 共享的编辑器 minimap 语义概览、视口投影和跳转映射。
//
// 设计约束：
// - 共享层只输出语义角色、可见行映射、密度/层级信息和 viewport 比例，不输出平台颜色或像素。
// - 折叠隐藏行在 minimap 中按可见行压缩，折叠占位行保留。
// - viewport 投影会对超短文档、空文档和越界可见行范围做 clamp。
// - minimap 显示阈值统一在共享层判定，双端不各自重复推导。

// MARK: - 视口状态

/// 单文档当前可见范围的共享模型。
/// 不存平台像素值，只记录基于行号的逻辑视口。
public struct EditorViewportState: Equatable, Sendable {
    /// 视口中第一条可见行（0-based）
    public var firstVisibleLine: Int
    /// 视口中最后一条可见行（0-based）
    public var lastVisibleLine: Int
    /// 视口可同时容纳的行数
    public var viewportLineSpan: Int
    /// 文档总行数
    public var lineCount: Int

    public init(
        firstVisibleLine: Int = 0,
        lastVisibleLine: Int = 0,
        viewportLineSpan: Int = 0,
        lineCount: Int = 0
    ) {
        self.firstVisibleLine = firstVisibleLine
        self.lastVisibleLine = lastVisibleLine
        self.viewportLineSpan = viewportLineSpan
        self.lineCount = lineCount
    }
}

// MARK: - Minimap 行描述符

/// minimap 中一条可见概览线的语义描述。
/// 平台层根据此描述选择颜色和绘制宽度/高度。
public struct EditorMinimapLineDescriptor: Equatable, Sendable {
    /// 原始文本行号（0-based）
    public let sourceLine: Int
    /// 在可见行序列中的索引（0-based，折叠压缩后）
    public let visibleLineIndex: Int
    /// 该行的主导语义角色
    public let dominantRole: EditorSyntaxRole
    /// 缩进层级（0 为顶层）
    public let indentLevel: Int
    /// 非空白字符占比，clamp 到 0.15...1.0
    public let emphasis: Double
    /// 是否为折叠占位行
    public let isFoldPlaceholder: Bool

    public init(
        sourceLine: Int,
        visibleLineIndex: Int,
        dominantRole: EditorSyntaxRole,
        indentLevel: Int,
        emphasis: Double,
        isFoldPlaceholder: Bool
    ) {
        self.sourceLine = sourceLine
        self.visibleLineIndex = visibleLineIndex
        self.dominantRole = dominantRole
        self.indentLevel = indentLevel
        self.emphasis = emphasis
        self.isFoldPlaceholder = isFoldPlaceholder
    }
}

// MARK: - Minimap 快照

/// 基于文本、语法高亮和结构快照生成的稳定概览语义。
/// 表达全文可见行的概览信息，不包含平台颜色或像素。
public struct EditorMinimapSnapshot: Equatable, Sendable {
    /// 可见行描述符列表（按 visibleLineIndex 升序）
    public let lineDescriptors: [EditorMinimapLineDescriptor]
    /// 文档总行数
    public let totalLineCount: Int
    /// 可见行总数（折叠压缩后）
    public let visibleLineCount: Int

    public init(
        lineDescriptors: [EditorMinimapLineDescriptor],
        totalLineCount: Int,
        visibleLineCount: Int
    ) {
        self.lineDescriptors = lineDescriptors
        self.totalLineCount = totalLineCount
        self.visibleLineCount = visibleLineCount
    }

    /// 空快照
    public static let empty = EditorMinimapSnapshot(
        lineDescriptors: [],
        totalLineCount: 0,
        visibleLineCount: 0
    )
}

// MARK: - Minimap 视口投影

/// 基于 EditorViewportState 计算出来的 minimap 视口窗口。
/// 使用 0...1 的比例表达顶部、底部位置，平台层据此绘制半透明指示区。
public struct EditorMinimapViewportProjection: Equatable, Sendable {
    /// 视口顶部在 minimap 中的比例位置（0...1）
    public let topRatio: Double
    /// 视口底部在 minimap 中的比例位置（0...1）
    public let bottomRatio: Double
    /// 最小高度比例（避免视口指示器过小不可见）
    public let minimumHeightRatio: Double

    public init(topRatio: Double, bottomRatio: Double, minimumHeightRatio: Double = 0.02) {
        self.topRatio = topRatio
        self.bottomRatio = bottomRatio
        self.minimumHeightRatio = minimumHeightRatio
    }

    /// 空投影（空文档使用，占满全部范围）
    public static let full = EditorMinimapViewportProjection(
        topRatio: 0.0,
        bottomRatio: 1.0,
        minimumHeightRatio: 0.02
    )

    /// 实际高度比例（不小于 minimumHeightRatio）
    public var effectiveHeightRatio: Double {
        max(bottomRatio - topRatio, minimumHeightRatio)
    }

    /// 实际顶部比例（考虑最小高度后的修正值）
    public var effectiveTopRatio: Double {
        let height = effectiveHeightRatio
        let rawTop = topRatio
        // 如果修正后底部超出 1.0，从底部往上推
        let effectiveBottom = min(rawTop + height, 1.0)
        return effectiveBottom - height
    }

    /// 实际底部比例
    public var effectiveBottomRatio: Double {
        effectiveTopRatio + effectiveHeightRatio
    }
}

// MARK: - Minimap 完整投影

/// 平台直接消费的 minimap 投影：包含概览快照和视口窗口。
public struct EditorMinimapProjection: Equatable, Sendable {
    /// minimap 概览快照
    public let snapshot: EditorMinimapSnapshot
    /// 视口投影
    public let viewportProjection: EditorMinimapViewportProjection
    /// 是否应显示 minimap（基于统一阈值判定）
    public let shouldDisplay: Bool

    public init(
        snapshot: EditorMinimapSnapshot,
        viewportProjection: EditorMinimapViewportProjection,
        shouldDisplay: Bool
    ) {
        self.snapshot = snapshot
        self.viewportProjection = viewportProjection
        self.shouldDisplay = shouldDisplay
    }

    /// 空投影（不显示 minimap）
    public static let hidden = EditorMinimapProjection(
        snapshot: .empty,
        viewportProjection: .full,
        shouldDisplay: false
    )
}

// MARK: - Minimap 投影构建器

/// 统一构建入口：输入语法高亮快照、结构快照、折叠投影和 viewport 状态，
/// 输出平台直接消费的 minimap 投影。
public enum EditorMinimapProjectionBuilder {

    /// 构建 minimap 投影。
    ///
    /// - Parameters:
    ///   - text: 文档全文
    ///   - filePath: 文件路径
    ///   - syntaxSnapshot: 语法高亮快照
    ///   - structureSnapshot: 结构分析快照
    ///   - foldingProjection: 折叠投影
    ///   - viewportState: 当前视口状态
    /// - Returns: 完整的 minimap 投影
    public static func make(
        text: String,
        filePath: String,
        syntaxSnapshot: EditorSyntaxSnapshot,
        structureSnapshot: EditorStructureSnapshot,
        foldingProjection: EditorCodeFoldingProjection,
        viewportState: EditorViewportState
    ) -> EditorMinimapProjection {
        let snapshot = buildSnapshot(
            text: text,
            syntaxSnapshot: syntaxSnapshot,
            structureSnapshot: structureSnapshot,
            foldingProjection: foldingProjection
        )

        let viewportProjection = buildViewportProjection(
            viewportState: viewportState,
            visibleLineCount: snapshot.visibleLineCount
        )

        let shouldDisplay = evaluateDisplayThreshold(
            viewportState: viewportState,
            visibleLineCount: snapshot.visibleLineCount
        )

        return EditorMinimapProjection(
            snapshot: snapshot,
            viewportProjection: viewportProjection,
            shouldDisplay: shouldDisplay
        )
    }

    // MARK: - 概览快照构建

    /// 从文本和分析快照构建 minimap 概览。
    public static func buildSnapshot(
        text: String,
        syntaxSnapshot: EditorSyntaxSnapshot,
        structureSnapshot: EditorStructureSnapshot,
        foldingProjection: EditorCodeFoldingProjection
    ) -> EditorMinimapSnapshot {
        let lines = text.splitLines()
        let lineCount = lines.count

        guard lineCount > 0 else {
            return .empty
        }

        // 构建隐藏行集合
        var hiddenLines = Set<Int>()
        for range in foldingProjection.hiddenLineRanges {
            for line in range {
                hiddenLines.insert(line)
            }
        }

        // 构建折叠起始行集合（用于标记占位行）
        var collapsedStartLines = Set<Int>()
        for control in foldingProjection.foldControls where control.isCollapsed {
            collapsedStartLines.insert(control.region.startLine)
        }

        // 构建每行 token 角色频率表
        let lineRoles = computeLineRoles(
            lines: lines,
            syntaxSnapshot: syntaxSnapshot
        )

        // 生成行描述符
        var descriptors: [EditorMinimapLineDescriptor] = []
        var visibleIndex = 0

        for lineIndex in 0..<lineCount {
            if hiddenLines.contains(lineIndex) { continue }

            let line = lineIndex < lines.count ? lines[lineIndex] : ""
            let dominantRole = lineRoles[lineIndex]
            let indentLevel = lineIndex < structureSnapshot.lineIndentLevels.count
                ? structureSnapshot.lineIndentLevels[lineIndex]
                : 0
            let emphasis = computeEmphasis(line: line)
            let isFoldPlaceholder = collapsedStartLines.contains(lineIndex)

            descriptors.append(EditorMinimapLineDescriptor(
                sourceLine: lineIndex,
                visibleLineIndex: visibleIndex,
                dominantRole: dominantRole,
                indentLevel: indentLevel,
                emphasis: emphasis,
                isFoldPlaceholder: isFoldPlaceholder
            ))
            visibleIndex += 1
        }

        return EditorMinimapSnapshot(
            lineDescriptors: descriptors,
            totalLineCount: lineCount,
            visibleLineCount: visibleIndex
        )
    }

    // MARK: - 视口投影构建

    /// 从视口状态和可见行数构建 minimap 视口投影。
    public static func buildViewportProjection(
        viewportState: EditorViewportState,
        visibleLineCount: Int
    ) -> EditorMinimapViewportProjection {
        guard visibleLineCount > 0 else {
            return .full
        }

        let total = Double(visibleLineCount)
        let first = Double(max(0, min(viewportState.firstVisibleLine, visibleLineCount - 1)))
        let last = Double(max(0, min(viewportState.lastVisibleLine, visibleLineCount - 1)))

        let topRatio = first / total
        let bottomRatio = min((last + 1.0) / total, 1.0)

        return EditorMinimapViewportProjection(
            topRatio: max(0.0, topRatio),
            bottomRatio: min(1.0, bottomRatio)
        )
    }

    // MARK: - 显示阈值判定

    /// 统一判定是否应该显示 minimap。
    /// 阈值：lineCount >= max(80, viewportLineSpan * 2)
    public static func evaluateDisplayThreshold(
        viewportState: EditorViewportState,
        visibleLineCount: Int
    ) -> Bool {
        let threshold = max(80, viewportState.viewportLineSpan * 2)
        return visibleLineCount >= threshold
    }

    // MARK: - 点击跳转映射

    /// 从 minimap 可见行索引映射回原始文本行号。
    ///
    /// - Parameters:
    ///   - visibleLineIndex: minimap 中被点击的可见行索引
    ///   - snapshot: 当前 minimap 快照
    /// - Returns: 对应的原始文本行号（0-based），越界返回 nil
    public static func targetSourceLine(
        fromVisibleLineIndex visibleLineIndex: Int,
        in snapshot: EditorMinimapSnapshot
    ) -> Int? {
        guard visibleLineIndex >= 0,
              visibleLineIndex < snapshot.lineDescriptors.count else {
            return nil
        }
        return snapshot.lineDescriptors[visibleLineIndex].sourceLine
    }

    /// 从 minimap 中的比例位置映射到可见行索引。
    ///
    /// - Parameters:
    ///   - ratio: 点击位置在 minimap 中的纵向比例（0...1）
    ///   - snapshot: 当前 minimap 快照
    /// - Returns: 对应的可见行索引
    public static func visibleLineIndex(
        fromRatio ratio: Double,
        in snapshot: EditorMinimapSnapshot
    ) -> Int {
        guard snapshot.visibleLineCount > 0 else { return 0 }
        let clampedRatio = max(0.0, min(1.0, ratio))
        let index = Int(clampedRatio * Double(snapshot.visibleLineCount))
        return max(0, min(index, snapshot.visibleLineCount - 1))
    }

    // MARK: - 内部算法

    /// 计算每行的主导语义角色。
    /// 规则：该行出现次数最多的 EditorSyntaxRole 胜出；无 token 时回退 .plain。
    private static func computeLineRoles(
        lines: [String],
        syntaxSnapshot: EditorSyntaxSnapshot
    ) -> [EditorSyntaxRole] {
        let lineCount = lines.count
        var result = Array(repeating: EditorSyntaxRole.plain, count: lineCount)

        guard !syntaxSnapshot.runs.isEmpty else { return result }

        // 构建行偏移量表（UTF-16）
        let lineOffsets = computeLineUTF16Offsets(lines: lines)

        // 对每行统计角色频率
        var roleCounts: [[EditorSyntaxRole: Int]] = Array(
            repeating: [:],
            count: lineCount
        )

        for run in syntaxSnapshot.runs {
            let runStart = run.location
            let runEnd = run.location + run.length

            // 使用二分查找定位起始行
            var startLine = binarySearchLine(offset: runStart, lineOffsets: lineOffsets)
            // 一个 run 可能跨多行
            for lineIndex in startLine..<lineCount {
                let lineStart = lineOffsets[lineIndex]
                let lineEnd = lineIndex + 1 < lineOffsets.count
                    ? lineOffsets[lineIndex + 1]
                    : lineStart + (lines[lineIndex] as NSString).length + 1 // +1 for newline
                if runStart >= lineEnd { continue }
                if runEnd <= lineStart { break }

                // 计算此 run 在本行的覆盖长度
                let overlapStart = max(runStart, lineStart)
                let overlapEnd = min(runEnd, lineEnd)
                let overlapLength = overlapEnd - overlapStart
                if overlapLength > 0 {
                    roleCounts[lineIndex][run.role, default: 0] += overlapLength
                }
            }
        }

        // 取每行最高频率角色
        for lineIndex in 0..<lineCount {
            if let dominant = roleCounts[lineIndex].max(by: { $0.value < $1.value }) {
                result[lineIndex] = dominant.key
            }
        }

        return result
    }

    /// 计算每行的 UTF-16 起始偏移量。
    private static func computeLineUTF16Offsets(lines: [String]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += (line as NSString).length + 1 // +1 for newline char
        }
        return offsets
    }

    /// 二分查找：给定 UTF-16 偏移量，返回所在行号。
    private static func binarySearchLine(offset: Int, lineOffsets: [Int]) -> Int {
        var lo = 0
        var hi = lineOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineOffsets[mid] <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    /// 计算一行的强调度（非空白字符占比），clamp 到 0.15...1.0。
    private static func computeEmphasis(line: String) -> Double {
        guard !line.isEmpty else { return 0.15 }
        let totalChars = line.count
        let nonWhitespace = line.filter { !$0.isWhitespace }.count
        let ratio = Double(nonWhitespace) / Double(totalChars)
        return max(0.15, min(1.0, ratio))
    }
}

// MARK: - String 行分割辅助

extension String {
    /// 按换行符分割成行数组（保持空行）。
    /// 用于 minimap 行处理，不引入 Foundation 以外的依赖。
    func splitLines() -> [String] {
        var lines: [String] = []
        self.enumerateSubstrings(in: self.startIndex..., options: [.byLines, .substringNotRequired]) { substring, range, enclosingRange, _ in
            lines.append(String(self[range]))
        }
        // enumerateSubstrings(.byLines) 不包含最后一个空行
        if self.hasSuffix("\n") {
            lines.append("")
        }
        // 空字符串至少有一行
        if lines.isEmpty {
            lines.append("")
        }
        return lines
    }
}
