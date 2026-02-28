#if os(macOS)
import SwiftUI

/// 右侧面板中的 AI 会话列表视图
/// 顶部下拉菜单筛选 AI 工具，按工具分别显示历史会话
struct SessionsPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：工具筛选下拉 + 新建按钮
            HStack(spacing: 8) {
                Menu {
                    ForEach(AIChatTool.allCases) { tool in
                        Button(action: {
                            appState.sessionPanelFilterTool = tool
                        }) {
                            Label {
                                Text(tool.displayName)
                            } icon: {
                                FixedSizeAssetImage(name: tool.iconAssetName, targetSize: 16)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        FixedSizeAssetImage(name: appState.sessionPanelFilterTool.iconAssetName, targetSize: 16)
                        Text(appState.sessionPanelFilterTool.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button(action: {
                    appState.sessionPanelAction = .createNewSession
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("新建会话")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 会话列表
            let sessions = appState.aiSessionsForTool(appState.sessionPanelFilterTool)
            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("暂无会话")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: session.id == appState.aiStore(for: appState.sessionPanelFilterTool).currentSessionId
                            && appState.sessionPanelFilterTool == appState.aiChatTool,
                        status: appState.aiSessionStatus(for: session)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.sessionPanelAction = .loadSession(session)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            appState.sessionPanelAction = .deleteSession(session)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear {
            // 默认显示当前聊天工具的会话
            appState.sessionPanelFilterTool = appState.aiChatTool
        }
    }
}

#Preview {
    SessionsPanelView()
        .environmentObject(AppState())
        .frame(width: 300, height: 500)
}
#endif
