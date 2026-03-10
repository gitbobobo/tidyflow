import SwiftUI

/// 独立 Diff 渲染组件，视觉对齐 VS Code / GitHub 风格。
/// 超过 visibleRowLimit 行时自动截断，避免大 diff 一次性布局全部行导致卡顿。
struct UnifiedDiffView: View {
    let diff: ParsedDiff

    /// 默认最大渲染行数，超出后显示"展开"按钮
    private static let visibleRowLimit = 200

    @State private var isFullyExpanded: Bool = false

    private var visibleRows: [DiffRow] {
        if isFullyExpanded || diff.rows.count <= Self.visibleRowLimit {
            return diff.rows
        }
        return Array(diff.rows.prefix(Self.visibleRowLimit))
    }

    private var isTruncated: Bool {
        !isFullyExpanded && diff.rows.count > Self.visibleRowLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                lineNumberColumn
                    .frame(width: 64)
                    .background(Color.secondary.opacity(0.04))

                codeContentColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isTruncated {
                truncationFooter
            }
        }
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(8)
        .textSelection(.enabled)
    }

    private var lineNumberColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(visibleRows) { row in
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
                ForEach(visibleRows) { row in
                    contentRow(row)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var truncationFooter: some View {
        HStack {
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFullyExpanded = true
                }
            } label: {
                Text("展开全部 \(diff.rows.count) 行")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            Spacer()
        }
        .background(Color.secondary.opacity(0.04))
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
        } else if let cached = row.cachedAttributedString {
            Text(cached)
                .font(.system(size: 11, design: .monospaced))
        } else {
            Text(row.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    private var rowHeight: CGFloat {
        14
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

// MARK: - 冲突内容侧边对比视图

/// 并排展示冲突的 ours/theirs 内容（供 GitConflictWizardView 中的 base 视图使用）
/// 若 diff 不可用，则直接渲染原始文本
struct ConflictSideBySideView: View {
    let leftLabel: String
    let rightLabel: String
    let leftContent: String?
    let rightContent: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            pane(label: leftLabel, content: leftContent, background: Color.blue.opacity(0.06))
            Divider()
            pane(label: rightLabel, content: rightContent, background: Color.purple.opacity(0.06))
        }
    }

    private func pane(label: String, content: String?, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background)
            Divider()
            ScrollView {
                if let text = content {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("git.conflict.noContent".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
