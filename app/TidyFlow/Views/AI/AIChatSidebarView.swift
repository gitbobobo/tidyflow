#if os(macOS)
import SwiftUI

/// AI 聊天界面左侧常驻侧边栏，显示会话列表
/// 顶部筛选 AI 工具，列表显示对应工具的历史会话
struct AIChatSidebarView: View {
    @EnvironmentObject var appState: AppState

    var onSelect: (AISessionInfo) -> Void
    var onDelete: (AISessionInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：工具筛选下拉
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 会话列表
            let sessions = appState.aiSessionsForTool(appState.sessionPanelFilterTool)
            let isLoadingSessions = appState.aiSessionListLoadingTools.contains(appState.sessionPanelFilterTool)
            if isLoadingSessions && sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("加载中…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
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
                        isSelected: session.id == appState.aiChatStore.currentSessionId
                            && session.aiTool == appState.aiChatTool,
                        status: appState.aiSessionStatus(for: session)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(session)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(session)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 260)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .onAppear {
            appState.sessionPanelFilterTool = appState.aiChatTool
            requestSessionList(for: appState.aiChatTool)
        }
        .onChange(of: appState.sessionPanelFilterTool) { _, newTool in
            requestSessionList(for: newTool)
        }
        .onChange(of: appState.currentGlobalWorkspaceKey) { _, _ in
            requestSessionList(for: appState.sessionPanelFilterTool)
        }
    }

    /// 向服务端请求指定 AI 工具的会话列表
    private func requestSessionList(for tool: AIChatTool) {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty,
              appState.connectionState == .connected else { return }
        appState.aiSessionListLoadingTools.insert(tool)
        appState.wsClient.requestAISessionList(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: tool,
            limit: 50
        )
    }
}

#Preview {
    AIChatSidebarView(
        onSelect: { _ in },
        onDelete: { _ in }
    )
    .environmentObject(AppState())
    .frame(height: 500)
}
#endif
