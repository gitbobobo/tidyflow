import SwiftUI
import TidyFlowShared

#if os(macOS)

/// 进化面板标题栏区域
///
/// 只接收不可变投影数据，不持有 AppState 引用。
struct EvolutionPipelineHeaderSectionView: View, Equatable {
    let bottleneckCount: Int
    let maxRiskScore: Double
    let performanceDashboard: PerformanceDashboardProjection

    var body: some View {
        HStack(spacing: 8) {
            Text("evolution.page.title".localized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            analysisStatusIndicator
            Spacer()
            EvolutionPerformanceBadge(projection: performanceDashboard)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var analysisStatusIndicator: some View {
        if bottleneckCount > 0 || maxRiskScore > 0.5 {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(maxRiskScore > 0.7 ? .red : .orange)
                    .font(.caption)
                Text("\(bottleneckCount) 瓶颈")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help("Core 识别到 \(bottleneckCount) 个性能瓶颈，综合风险 \(String(format: "%.0f%%", maxRiskScore * 100))")
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bottleneckCount == rhs.bottleneckCount
        && lhs.maxRiskScore == rhs.maxRiskScore
        && lhs.performanceDashboard == rhs.performanceDashboard
    }
}

/// 性能预算胶囊（标题栏右侧）
struct EvolutionPerformanceBadge: View {
    let projection: PerformanceDashboardProjection

    var body: some View {
        if projection.budgetStatus != .unknown {
            HStack(spacing: 6) {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text("性能: \(projection.budgetStatus.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !projection.regressionSummary.degradationReasons.isEmpty {
                        Text(projection.regressionSummary.degradationReasons.first ?? "")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if projection.isTrendDegrading {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var badgeColor: Color {
        switch projection.budgetStatus {
        case .pass:    return .green
        case .warn:    return .yellow
        case .fail:    return .red
        case .unknown: return .gray
        }
    }
}

#endif
