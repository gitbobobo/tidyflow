import SwiftUI

#if os(iOS)
struct DisconnectBannerView: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        VStack(spacing: 0) {
            // 连接断开横幅（原有逻辑不变）
            Group {
                switch appState.connectionPhase {
                case .reconnecting(let attempt, let maxAttempts):
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                        Text("连接已断开，正在重连... (\(attempt)/\(maxAttempts))")
                            .font(.footnote)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .foregroundColor(.white)
                case .reconnectFailed:
                    HStack {
                        Text("重连失败")
                            .font(.footnote)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            appState.retryReconnect()
                        } label: {
                            Text("点击重试")
                                .font(.footnote)
                                .fontWeight(.bold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .foregroundColor(.white)
                default:
                    EmptyView()
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.connectionPhase)
            .transition(.move(edge: .top).combined(with: .opacity))

            // 性能诊断上下文提示条（WI-005：仅在连接正常且有 critical/warning 诊断时显示）
            if appState.connectionPhase.isConnected {
                performanceBanner
            }
        }
    }

    /// 性能诊断提示条：消费 Core 权威 `performanceObservability.diagnoses`，不在视图层推导诊断结论。
    @ViewBuilder
    private var performanceBanner: some View {
        let diagnoses = appState.performanceObservability.diagnoses
        let critical = diagnoses.filter { $0.severity == .critical }
        let warnings = diagnoses.filter { $0.severity == .warning }

        if !critical.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                Text(critical.first.map { $0.summary } ?? "性能严重异常")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(critical.count) critical")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.88))
            .foregroundColor(.white)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if !warnings.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                Text(warnings.first.map { $0.summary } ?? "性能存在告警")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(warnings.count) warning")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.88))
            .foregroundColor(.white)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#Preview {
    VStack {
        DisconnectBannerView()
            .environmentObject(MobileAppState())
        Spacer()
    }
}
#endif

