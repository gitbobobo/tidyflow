import Foundation

// MARK: - Diff 行类型

enum DiffRowKind {
    case hunk
    case added
    case removed
    case context
    case meta
}

// MARK: - 字符级高亮区间

struct InlineHighlightRange {
    let location: Int
    let length: Int
}

// MARK: - Diff 行

struct DiffRow: Identifiable {
    let id: Int
    let kind: DiffRowKind
    let marker: String
    let text: String
    let oldLine: Int?
    let newLine: Int?
    /// 字符级变更高亮区间（仅 added/removed 行可能有值）
    var inlineRanges: [InlineHighlightRange] = []
}

// MARK: - 解析结果

struct ParsedDiff {
    let filePath: String?
    let addedCount: Int
    let removedCount: Int
    var rows: [DiffRow]
}
