#if os(macOS)
import SwiftUI

/// 右侧面板中的 AI 会话列表视图
/// 顶部下拉菜单支持“全部/单工具”筛选，统一展示当前工作区历史会话
struct SessionsPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：工具筛选下拉 + 新建按钮
            HStack(spacing: 8) {
                Menu {
                    ForEach(AISessionListFilter.allOptions) { filter in
                        Button(action: {
                            appState.sessionPanelFilter = filter
                        }) {
                            Label {
                                Text(filter.displayName)
                            } icon: {
                                if let iconAssetName = filter.iconAssetName {
                                    FixedSizeAssetImage(name: iconAssetName, targetSize: 16)
                                } else {
                                    Image(systemName: "square.stack.3d.up")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let iconAssetName = appState.sessionPanelFilter.iconAssetName {
                            FixedSizeAssetImage(name: iconAssetName, targetSize: 16)
                        } else {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(appState.sessionPanelFilter.displayName)
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
                .accessibilityIdentifier("tf.mac.ai.new-session")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 会话列表
            let pageState = appState.displayedAISessionListState
            let sessions = pageState.sessions
            let isLoadingSessions = pageState.isLoadingInitial
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
                List {
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            isSelected: AISessionListSemantics.isSessionSelected(
                                session: session,
                                currentSessionId: appState.aiStore(for: session.aiTool).currentSessionId,
                                currentTool: appState.aiChatTool
                            ),
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
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
                    if pageState.isLoadingNextPage || pageState.hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .onAppear {
                            _ = appState.loadNextAISessionListPage(for: appState.sessionPanelFilter)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear {
            appState.sessionPanelFilter = .all
            requestSessionList(for: appState.sessionPanelFilter)
        }
        .onChange(of: appState.sessionPanelFilter) { _, newFilter in
            requestSessionList(for: newFilter)
        }
        .onChange(of: appState.currentGlobalWorkspaceKey) { _, _ in
            requestSessionList(for: appState.sessionPanelFilter)
        }
        .accessibilityIdentifier("tf.mac.ai.sessions-panel")
    }

    /// 向服务端请求指定筛选条件的 AI 会话列表
    private func requestSessionList(for filter: AISessionListFilter) {
        _ = appState.requestAISessionList(for: filter, limit: 50)
    }
}

#Preview {
    SessionsPanelView()
        .environmentObject(AppState())
        .frame(width: 300, height: 500)
}
#endif
