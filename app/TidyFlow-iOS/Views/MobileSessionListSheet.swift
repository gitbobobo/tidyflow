import SwiftUI

/// iOS 端会话列表 Sheet，顶部支持“全部/单工具”筛选
struct MobileSessionListSheet: View {
    @EnvironmentObject var appState: MobileAppState
    @Binding var showSessionList: Bool
    var onLoadSession: (AISessionInfo) -> Void
    var onCreateNewSession: () -> Void

    @State private var filter: AISessionListFilter = .all

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 工具筛选 Picker
                Picker("AI 工具", selection: $filter) {
                    ForEach(AISessionListFilter.allOptions) { currentFilter in
                        HStack(spacing: 6) {
                            if let iconAssetName = currentFilter.iconAssetName {
                                Image(iconAssetName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "square.stack.3d.up")
                            }
                            Text(currentFilter.displayName)
                        }
                        .tag(currentFilter)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                let pageState = appState.sessionListPageState(for: filter)
                let sessions = pageState.sessions
                let isLoadingSessions = pageState.isLoadingInitial
                if isLoadingSessions && sessions.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                        Text("加载中…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("暂无会话")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sessions) { session in
                            Button(action: {
                                onLoadSession(session)
                                showSessionList = false
                            }) {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.displayTitle)
                                            .font(.headline)
                                            .lineLimit(2)
                                        HStack(spacing: 6) {
                                            Image(session.aiTool.iconAssetName)
                                                .resizable()
                                                .renderingMode(.original)
                                                .scaledToFit()
                                                .frame(width: 12, height: 12)
                                            Text("·")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(session.formattedDate)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if session.id == appState.aiCurrentSessionId && session.aiTool == appState.aiChatTool {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    appState.deleteAISession(session)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        if pageState.isLoadingNextPage || pageState.hasMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .onAppear {
                                _ = appState.loadNextAISessionListPage(for: filter)
                            }
                        }
                    }
                }
            }
            .navigationTitle("会话")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showSessionList = false }) {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        onCreateNewSession()
                        showSessionList = false
                    }) {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("tf.ios.ai.new-session")
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { showSessionList = false }) {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        onCreateNewSession()
                        showSessionList = false
                    }) {
                        Image(systemName: "plus")
                    }
                }
                #endif
            }
        }
        .onAppear {
            filter = .all
            requestSessionList(for: filter)
        }
        .onChange(of: filter) { _, newFilter in
            requestSessionList(for: newFilter)
        }
        .accessibilityIdentifier("tf.ios.ai.sessions-panel")
    }

    /// 向服务端请求指定筛选条件的 AI 会话列表
    private func requestSessionList(for filter: AISessionListFilter) {
        _ = appState.requestAISessionList(for: filter)
    }
}
