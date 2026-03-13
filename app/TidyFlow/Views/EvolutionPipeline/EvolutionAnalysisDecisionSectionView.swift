import SwiftUI
import TidyFlowShared

#if os(macOS)

/// 智能决策展示区块
///
/// 所有数据来自 `EvolutionAnalysisSummary`（Core 权威，Projection 层预计算），
/// View 只做展示映射，不做二次推导。
struct EvolutionAnalysisDecisionSectionView: View, Equatable {
    let decisionSummary: EvolutionAnalysisSummary?
    let hasCurrentItem: Bool

    var body: some View {
        if let summary = decisionSummary {
            VStack(alignment: .leading, spacing: 8) {
                // 区块标题
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("evolution.page.pipeline.intelligentDecision".localized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(summary.pressureLevel.rawValue.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(pressureColor(summary.pressureLevel))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(pressureColor(summary.pressureLevel).opacity(0.12)))
                }

                // 健康与风险评分行
                HStack(spacing: 12) {
                    decisionScoreChip(
                        label: "evolution.page.pipeline.healthScore".localized,
                        value: summary.healthScore,
                        invert: false
                    )
                    decisionScoreChip(
                        label: "evolution.page.pipeline.riskScore".localized,
                        value: summary.overallRiskScore,
                        invert: true
                    )
                    Spacer()
                }

                // 瓶颈列表（最多展示 3 条）
                if !summary.bottlenecks.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(summary.bottlenecks.prefix(3).enumerated()), id: \.offset) { _, bottleneck in
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 9))
                                    .foregroundColor(riskScoreColor(bottleneck.riskScore))
                                Text(bottleneck.reasonCode)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // 前 3 条建议
                if !summary.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(summary.suggestions.prefix(3).enumerated()), id: \.offset) { _, sug in
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: sug.scope == .system ? "arrow.triangle.2.circlepath" : "arrow.right.circle")
                                    .font(.system(size: 9))
                                    .foregroundColor(.blue)
                                Text(sug.summary)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.03))
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            if hasCurrentItem {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("evolution.page.pipeline.noDecisionSummary".localized)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 辅助

    private func pressureColor(_ level: ResourcePressureLevel) -> Color {
        switch level {
        case .low: return .green
        case .moderate: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }

    private func riskScoreColor(_ score: Double) -> Color {
        if score >= 0.8 { return .red }
        if score >= 0.5 { return .orange }
        if score >= 0.2 { return .yellow }
        return .green
    }

    @ViewBuilder
    private func decisionScoreChip(label: String, value: Double, invert: Bool) -> some View {
        let displayColor: Color = invert
            ? riskScoreColor(value)
            : (value >= 0.8 ? .green : (value >= 0.5 ? .yellow : .red))
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            Text(String(format: "%.0f%%", value * 100))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(displayColor)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.decisionSummary == rhs.decisionSummary
        && lhs.hasCurrentItem == rhs.hasCurrentItem
    }
}

#endif
