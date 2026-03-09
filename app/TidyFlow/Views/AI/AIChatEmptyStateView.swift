import SwiftUI

/// AI 聊天空白提示视图（macOS/iOS 共用）
struct AIChatEmptyStateView: View {
    let currentTool: AIChatTool
    @Binding var selectedTool: AIChatTool
    let canSwitchTool: Bool
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(currentTool.iconAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 44, height: 44)
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    if isLoading {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.92))
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.primary)
                    }
                }

            titleView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var titleView: some View {
        HStack(spacing: 0) {
            Text("使用 ")
                .foregroundStyle(.secondary)

            toolMenu

            Text(" 开始构建")
                .foregroundStyle(.secondary)
        }
        .font(.title3)
    }

    private var toolMenu: some View {
        Menu {
            ForEach(AIChatTool.allCases) { tool in
                Button {
                    selectedTool = tool
                } label: {
                    Label {
                        Text(tool.displayName)
                    } icon: {
                        Image(tool.iconAssetName)
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                    }
                }
            }
        }
        label: {
            HStack(spacing: 0) {
                Text(currentTool.displayName)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(!canSwitchTool)
        .opacity(canSwitchTool ? 1 : 0.5)
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
