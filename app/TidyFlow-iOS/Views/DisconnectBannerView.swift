import SwiftUI

#if os(iOS)
struct DisconnectBannerView: View {
    @EnvironmentObject var appState: MobileAppState
    
    var body: some View {
        Group {
            switch appState.reconnectState {
            case .idle:
                EmptyView()
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
            case .failed:
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
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.reconnectState)
        .transition(.move(edge: .top).combined(with: .opacity))
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
