import SwiftUI

/// AI 聊天空白提示视图（macOS/iOS 共用）
struct AIChatEmptyStateView: View {
    let currentTool: AIChatTool
    @Binding var selectedTool: AIChatTool
    let canSwitchTool: Bool
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                    .scaleEffect(1.2)
            } else {
                Image(currentTool.iconAssetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("还没有消息")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Text("使用 \(currentTool.displayName) 开始构建")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))

                toolGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var toolGrid: some View {
        HStack(spacing: 8) {
            ForEach(AIChatTool.allCases) { tool in
                Button(action: {
                    selectedTool = tool
                }) {
                    Text(tool.displayName)
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(currentTool == tool ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(currentTool == tool ? Color.accentColor : Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSwitchTool)
                .opacity(canSwitchTool ? 1.0 : 0.5)
            }
        }
    }
}

#if DEBUG
#Preview {
    struct PreviewWrapper: View {
        @State var selectedTool: AIChatTool = .opencode

        var body: some View {
            VStack {
                AIChatEmptyStateView(
                    currentTool: selectedTool,
                    selectedTool: $selectedTool,
                    canSwitchTool: true,
                    isLoading: false
                )

                Divider()

                AIChatEmptyStateView(
                    currentTool: selectedTool,
                    selectedTool: $selectedTool,
                    canSwitchTool: true,
                    isLoading: true
                )
            }
        }
    }

    return PreviewWrapper()
}
#endif
