import SwiftUI

#if os(macOS)

/// 独立 Equatable 子视图：循环列表行（当前循环与历史循环共用）
///
/// 只接收不可变投影与动作闭包，不依赖父视图状态。
struct EvolutionCycleListRowView: View, Equatable {
    let round: Int
    let color: Color
    let title: String
    let badge: String?
    let startTimeText: String
    let stageEntries: [PipelineCycleStageEntry]
    let isHistory: Bool
    let failureSummary: String?
    let hasDocumentAction: Bool

    // 动作闭包（不参与 Equatable 比较）
    var onDocumentTap: (() -> Void)?
    var onTap: () -> Void = {}

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.round == rhs.round &&
        lhs.title == rhs.title &&
        lhs.badge == rhs.badge &&
        lhs.startTimeText == rhs.startTimeText &&
        lhs.stageEntries == rhs.stageEntries &&
        lhs.isHistory == rhs.isHistory &&
        lhs.failureSummary == rhs.failureSummary &&
        lhs.hasDocumentAction == rhs.hasDocumentAction
    }

    var body: some View {
        let totalDuration: TimeInterval = stageEntries.reduce(0) { $0 + $1.durationSeconds }

        VStack(alignment: .leading, spacing: 6) {
            // 标题行
            HStack(alignment: .top, spacing: 6) {
                roundBadge

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if hasDocumentAction, let onDocumentTap {
                    Button(action: onDocumentTap) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("evolution.page.action.previewPlanDocument".localized)
                }
            }

            // 元信息行
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Image(systemName: "clock")
                        .font(.system(size: 8))
                    Text(startTimeText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.secondary)

                if totalDuration > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                            .font(.system(size: 8))
                        Text(EvolutionPipelineDateFormatting.formatDuration(totalDuration))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }

                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.8)))
                }
            }

            // 失败诊断摘要
            if let failureSummary {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.red)
                    Text(failureSummary)
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.9))
                        .lineLimit(2)
                }
            }

            // 分段彩色线条
            if !stageEntries.isEmpty {
                EvolutionProportionalStageBar(entries: stageEntries, height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHistory ? Color.secondary.opacity(0.05) : color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isHistory ? Color.secondary.opacity(0.10) : color.opacity(0.22), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(perform: onTap)
    }

    // MARK: - 私有子视图

    private var roundBadge: some View {
        Text("\(max(1, round))")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(color.opacity(0.14))
            )
            .overlay(
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 1)
            )
    }
}

// MARK: - 比例分段进度条

/// 按各阶段耗时比例展示的彩色分段条
struct EvolutionProportionalStageBar: View, Equatable {
    let entries: [PipelineCycleStageEntry]
    let height: CGFloat

    var body: some View {
        let segments = makeSegments()
        let segmentSpacing: CGFloat = 2

        GeometryReader { geo in
            let totalSpacing = segmentSpacing * CGFloat(max(segments.count - 1, 0))
            let drawableWidth = max(geo.size.width - totalSpacing, 0)
            HStack(spacing: segmentSpacing) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(EvolutionStageSemantics.stageColor(segment.stage))
                        .frame(width: max(0, drawableWidth * segment.ratio), height: height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: animationToken(segments))
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    // MARK: - 内部类型

    private struct Segment: Identifiable {
        let id: String
        let stage: String
        let ratio: CGFloat
    }

    private func makeSegments() -> [Segment] {
        guard !entries.isEmpty else { return [] }

        let rawDurations = entries.map { max(0, $0.durationSeconds) }
        let positiveDurations = rawDurations.filter { $0 > 0 }
        let weights: [TimeInterval]

        if !positiveDurations.isEmpty {
            let averagePositive = positiveDurations.reduce(0, +) / Double(positiveDurations.count)
            let fallbackWeight = max(averagePositive * 0.12, 0.3)
            weights = rawDurations.map { duration in
                duration > 0 ? duration : fallbackWeight
            }
        } else {
            weights = Array(repeating: 1, count: entries.count)
        }

        let totalWeight = max(weights.reduce(0, +), 0.0001)
        return zip(entries, weights).map { entry, weight in
            Segment(id: entry.id, stage: entry.stage, ratio: CGFloat(weight / totalWeight))
        }
    }

    private func animationToken(_ segments: [Segment]) -> String {
        segments
            .map { "\($0.id)=\(String(format: "%.6f", Double($0.ratio)))" }
            .joined(separator: "|")
    }
}

#endif
