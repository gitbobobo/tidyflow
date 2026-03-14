import Foundation

// MARK: - 编辑器 Gutter 共享语义层
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 提供跨 macOS/iOS 共享的编辑器 gutter 行号、当前行高亮、断点标记与折叠控件语义。
//
// 设计约束：
// - 共享层只输出语义行号、宽度指标和行项列表，不持有平台 rect、颜色或命中区域。
// - 内部计算全部使用 0-based 行号，所有显示文案输出为 1-based。
// - 隐藏行范围复用 EditorCodeFoldingProjection，不重新计算。
// - 断点为客户端展示层运行时标记，不涉及 Core 协议或持久化。

// MARK: - 断点集合

/// 单文档断点集合，内部使用 0-based 行号。
/// 断点是客户端展示层运行时标记，不入协议、不持久化、不同步到 Core。
public struct EditorBreakpointSet: Equatable, Sendable {
    /// 内部存储：0-based 行号集合
    private var lines: Set<Int>

    public init(lines: Set<Int> = []) {
        self.lines = lines
    }

    /// 切换指定行的断点状态
    public mutating func toggle(line: Int) {
        if lines.contains(line) {
            lines.remove(line)
        } else {
            lines.insert(line)
        }
    }

    /// 查询指定行是否有断点
    public func contains(line: Int) -> Bool {
        lines.contains(line)
    }

    /// 清除所有断点
    public mutating func removeAll() {
        lines.removeAll()
    }

    /// 断点数量
    public var count: Int { lines.count }

    /// 是否为空
    public var isEmpty: Bool { lines.isEmpty }

    /// 所有断点行号（0-based）
    public var allLines: Set<Int> { lines }
}

// MARK: - Gutter 运行时状态

/// 单文档运行时 gutter 状态。
/// 平台状态容器以 EditorDocumentKey 为键保存此对象。
/// 与查找替换、折叠状态同级，不混入 EditorDocumentSession。
public struct EditorGutterState: Equatable, Sendable {
    /// 当前行（0-based），nil 表示无焦点
    public var currentLine: Int?
    /// 断点集合
    public var breakpoints: EditorBreakpointSet
    /// 是否显示当前行高亮
    public var showsCurrentLineHighlight: Bool

    public init(
        currentLine: Int? = nil,
        breakpoints: EditorBreakpointSet = EditorBreakpointSet(),
        showsCurrentLineHighlight: Bool = true
    ) {
        self.currentLine = currentLine
        self.breakpoints = breakpoints
        self.showsCurrentLineHighlight = showsCurrentLineHighlight
    }
}

// MARK: - Gutter 宽度指标

/// 纯语义宽度指标，不保存平台像素。
/// 平台层根据此指标计算实际像素宽度。
public struct EditorGutterLayoutMetrics: Equatable, Sendable {
    /// 行号显示所需的最大位数（例如 99 行 → 2，1000 行 → 4）
    public let lineNumberDigits: Int
    /// 行号左侧附件槽位数（固定覆盖断点位 + 折叠按钮位）
    public let leadingAccessorySlots: Int
    /// 行号区域最小字符列数（不含附件槽位）
    public let minimumCharacterColumns: Int

    public init(lineNumberDigits: Int, leadingAccessorySlots: Int = 2, minimumCharacterColumns: Int = 2) {
        self.lineNumberDigits = lineNumberDigits
        self.leadingAccessorySlots = leadingAccessorySlots
        self.minimumCharacterColumns = minimumCharacterColumns
    }

    /// 基于最大可显示行号计算位数
    public static func computeDigits(forMaxLine maxLine: Int) -> Int {
        guard maxLine > 0 else { return 1 }
        var digits = 0
        var value = maxLine
        while value > 0 {
            digits += 1
            value /= 10
        }
        return digits
    }
}

// MARK: - Gutter 行项

/// 单行 gutter 投影项。
/// 对被折叠隐藏的行不生成 item；折叠起始行保留 item 并可携带 foldControl。
public struct EditorGutterLineItem: Equatable, Sendable {
    /// 原始行号（0-based）
    public let line: Int
    /// 显示用行号文案（1-based 字符串）
    public let displayLineNumber: String
    /// 是否为当前行
    public let isCurrentLine: Bool
    /// 是否有断点
    public let hasBreakpoint: Bool
    /// 是否为折叠占位行（折叠起始行用于占位显示）
    public let isFoldPlaceholder: Bool
    /// 折叠控制信息（仅折叠区域起始行有值）
    public let foldControl: EditorFoldControl?

    public init(
        line: Int,
        displayLineNumber: String,
        isCurrentLine: Bool,
        hasBreakpoint: Bool,
        isFoldPlaceholder: Bool = false,
        foldControl: EditorFoldControl? = nil
    ) {
        self.line = line
        self.displayLineNumber = displayLineNumber
        self.isCurrentLine = isCurrentLine
        self.hasBreakpoint = hasBreakpoint
        self.isFoldPlaceholder = isFoldPlaceholder
        self.foldControl = foldControl
    }
}

// MARK: - Gutter 投影

/// 平台唯一消费的 gutter 投影对象。
/// 包含宽度指标、行项列表和可见缩进导线。
public struct EditorGutterProjection: Equatable, Sendable {
    /// 宽度指标
    public let layoutMetrics: EditorGutterLayoutMetrics
    /// 可见行的 gutter 项列表（按行号升序，不含隐藏行）
    public let lineItems: [EditorGutterLineItem]
    /// 可见缩进导线段（直接复用折叠投影输出）
    public let visibleIndentGuides: [EditorIndentGuideSegment]

    public init(
        layoutMetrics: EditorGutterLayoutMetrics,
        lineItems: [EditorGutterLineItem],
        visibleIndentGuides: [EditorIndentGuideSegment]
    ) {
        self.layoutMetrics = layoutMetrics
        self.lineItems = lineItems
        self.visibleIndentGuides = visibleIndentGuides
    }

    /// 空投影
    public static let empty = EditorGutterProjection(
        layoutMetrics: EditorGutterLayoutMetrics(lineNumberDigits: 1),
        lineItems: [],
        visibleIndentGuides: []
    )
}

// MARK: - Gutter 投影构建器

/// 统一构建入口，输入为结构快照、折叠投影和 gutter 状态，输出 EditorGutterProjection。
public enum EditorGutterProjectionBuilder {

    /// 构建 gutter 投影。
    ///
    /// - Parameters:
    ///   - snapshot: 结构分析快照（提供总行数和折叠区域）
    ///   - folding: 折叠投影（提供隐藏行范围、折叠控制点和可见缩进导线）
    ///   - state: 当前 gutter 运行时状态（当前行、断点）
    /// - Returns: 完整的 gutter 投影
    public static func make(
        snapshot: EditorStructureSnapshot,
        folding: EditorCodeFoldingProjection,
        state: EditorGutterState
    ) -> EditorGutterProjection {
        let totalLines = snapshot.lineCount

        // 构建隐藏行集合以便快速查询
        var hiddenLines = Set<Int>()
        for range in folding.hiddenLineRanges {
            for line in range {
                hiddenLines.insert(line)
            }
        }

        // 建立折叠控制索引：startLine → foldControl
        var foldControlByLine: [Int: EditorFoldControl] = [:]
        for control in folding.foldControls {
            foldControlByLine[control.region.startLine] = control
        }

        // 计算最大可显示行号（1-based）
        // 这里用总行数而不是可见行数，因为折叠/展开后行号会变化，
        // 使用总行数可以保持 gutter 宽度稳定不抖动。
        let maxDisplayLine = totalLines
        let digits = EditorGutterLayoutMetrics.computeDigits(forMaxLine: maxDisplayLine)
        let metrics = EditorGutterLayoutMetrics(
            lineNumberDigits: max(digits, 1)
        )

        // 生成行项列表
        var lineItems: [EditorGutterLineItem] = []
        lineItems.reserveCapacity(totalLines - hiddenLines.count)

        for line in 0..<totalLines {
            // 隐藏行不生成 item
            if hiddenLines.contains(line) { continue }

            let displayNumber = String(line + 1) // 1-based
            let isCurrentLine = state.showsCurrentLineHighlight && state.currentLine == line
            let hasBreakpoint = state.breakpoints.contains(line: line)
            let foldControl = foldControlByLine[line]
            let isFoldPlaceholder = foldControl?.isCollapsed == true

            lineItems.append(EditorGutterLineItem(
                line: line,
                displayLineNumber: displayNumber,
                isCurrentLine: isCurrentLine,
                hasBreakpoint: hasBreakpoint,
                isFoldPlaceholder: isFoldPlaceholder,
                foldControl: foldControl
            ))
        }

        return EditorGutterProjection(
            layoutMetrics: metrics,
            lineItems: lineItems,
            visibleIndentGuides: folding.visibleIndentGuides
        )
    }
}
