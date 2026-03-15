import SwiftUI

#if os(macOS)

/// 进化面板标题栏区域
///
/// 只接收不可变投影数据，不持有 AppState 引用。
struct EvolutionPipelineHeaderSectionView: View, Equatable {
    let bottleneckCount: Int
    let maxRiskScore: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("evolution.page.title".localized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            analysisStatusIndicator
            Spacer()
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
    }
}

#endif
