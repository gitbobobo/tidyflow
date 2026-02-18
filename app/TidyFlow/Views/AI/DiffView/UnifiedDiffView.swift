import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 独立 Diff 渲染组件，视觉对齐 VS Code / GitHub 风格
struct UnifiedDiffView: View {
    let diff: ParsedDiff

    var body: some View {
        HStack(spacing: 0) {
            lineNumberColumn
                .frame(width: 64)
                .background(Color.secondary.opacity(0.04))

            codeContentColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(8)
        .textSelection(.enabled)
    }

    private var lineNumberColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(diff.rows) { row in
                lineNumberRow(row)
            }
        }
    }

    private func lineNumberRow(_ row: DiffRow) -> some View {
        HStack(spacing: 0) {
            Text(padNumber(row.oldLine))
            Text(padNumber(row.newLine))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.secondary.opacity(0.55))
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 8)
        .background(rowBackground(row.kind))
    }

    private var codeContentColumn: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diff.rows) { row in
                    contentRow(row)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        }
    }

    private func contentRow(_ row: DiffRow) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)

            if row.kind == .hunk || row.kind == .meta {
                Text(row.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.leading, 6)
            } else {
                HStack(spacing: 0) {
                    Text(row.marker)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(markerColor(row.kind))
                        .frame(width: 14)
                    inlineHighlightedText(row)
                }
                .padding(.leading, 2)
            }
        }
        .frame(height: rowHeight, alignment: .leading)
        .background(rowBackground(row.kind))
    }

    @ViewBuilder
    private func inlineHighlightedText(_ row: DiffRow) -> some View {
        if row.inlineRanges.isEmpty {
            Text(row.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
        } else {
            Text(buildAttributedString(row))
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func buildAttributedString(_ row: DiffRow) -> AttributedString {
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

    private var rowHeight: CGFloat {
        #if os(macOS)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading)
        #else
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ceil(font.lineHeight)
        #endif
    }

    private func rowBackground(_ kind: DiffRowKind) -> Color {
        switch kind {
        case .added:   return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .hunk:    return Color.blue.opacity(0.08)
        case .context, .meta: return Color.clear
        }
    }

    private func markerColor(_ kind: DiffRowKind) -> Color {
        switch kind {
        case .added:   return .green
        case .removed: return .red
        default:       return .secondary
        }
    }

    private func padNumber(_ value: Int?) -> String {
        guard let value else { return "    " }
        let raw = String(value)
        if raw.count >= 4 { return raw }
        return String(repeating: " ", count: 4 - raw.count) + raw
    }
}
