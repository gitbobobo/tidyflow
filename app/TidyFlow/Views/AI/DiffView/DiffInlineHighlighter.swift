import Foundation
import SwiftUI

/// 字符级 inline diff 高亮：对相邻 removed/added 行对计算变更区间
enum DiffInlineHighlighter {

    /// 就地标注 ParsedDiff 中每行的 inlineRanges，并预计算带高亮的 AttributedString。
    static func annotate(_ diff: inout ParsedDiff) {
        let rows = diff.rows
        var i = 0
        while i < rows.count {
            // 找到连续 removed 块
            guard rows[i].kind == .removed else { i += 1; continue }
            let removedStart = i
            while i < rows.count && rows[i].kind == .removed { i += 1 }
            let removedEnd = i

            // 紧跟的连续 added 块
            let addedStart = i
            while i < rows.count && rows[i].kind == .added { i += 1 }
            let addedEnd = i

            let removedCount = removedEnd - removedStart
            let addedCount = addedEnd - addedStart
            guard removedCount > 0 && addedCount > 0 else { continue }

            // 逐对比较，仅对配对行做字符级高亮
            // 未配对行不加 inlineRanges，行背景色已足够区分
            let pairCount = min(removedCount, addedCount)
            for p in 0..<pairCount {
                let ri = removedStart + p
                let ai = addedStart + p
                let (rRanges, aRanges) = computeInlineRanges(
                    old: rows[ri].text, new: rows[ai].text
                )
                diff.rows[ri].inlineRanges = rRanges
                diff.rows[ai].inlineRanges = aRanges
            }
        }

        // 预计算所有带 inlineRanges 行的 AttributedString，避免渲染时每帧重算。
        for idx in diff.rows.indices {
            guard !diff.rows[idx].inlineRanges.isEmpty else { continue }
            diff.rows[idx].cachedAttributedString = buildAttributedString(diff.rows[idx])
        }
    }

    /// 构建带 inline 高亮的 AttributedString（仅在解析阶段调用一次）。
    private static func buildAttributedString(_ row: DiffRow) -> AttributedString {
        var result = AttributedString(row.text)
        result.foregroundColor = .primary
        let highlightColor: Color = row.kind == .added
            ? .green.opacity(0.28) : .red.opacity(0.28)
        let utf16 = row.text.utf16
        for range in row.inlineRanges {
            let start = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex) ?? utf16.endIndex
            let end = utf16.index(start, offsetBy: range.length, limitedBy: utf16.endIndex) ?? utf16.endIndex
            if let attrRange = Range(start..<end, in: result) {
                result[attrRange].backgroundColor = highlightColor
            }
        }
        return result
    }

    // MARK: - 前后缀匹配算法

    /// 返回 (oldRanges, newRanges)，基于公共前后缀裁剪
    private static func computeInlineRanges(
        old: String, new: String
    ) -> ([InlineHighlightRange], [InlineHighlightRange]) {
        let oldChars = Array(old.utf16)
        let newChars = Array(new.utf16)

        // 公共前缀长度
        var prefix = 0
        while prefix < oldChars.count && prefix < newChars.count
                && oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        // 公共后缀长度（不与前缀重叠）
        var suffix = 0
        while suffix < (oldChars.count - prefix)
                && suffix < (newChars.count - prefix)
                && oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let oldDiffLen = oldChars.count - prefix - suffix
        let newDiffLen = newChars.count - prefix - suffix

        let oldRanges: [InlineHighlightRange] = oldDiffLen > 0
            ? [InlineHighlightRange(location: prefix, length: oldDiffLen)]
            : []
        let newRanges: [InlineHighlightRange] = newDiffLen > 0
            ? [InlineHighlightRange(location: prefix, length: newDiffLen)]
            : []

        return (oldRanges, newRanges)
    }
}
