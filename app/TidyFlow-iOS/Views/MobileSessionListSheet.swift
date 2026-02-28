import SwiftUI

/// iOS 端会话列表 Sheet，顶部可筛选 AI 工具
struct MobileSessionListSheet: View {
    @EnvironmentObject var appState: MobileAppState
    @Binding var showSessionList: Bool
    var onLoadSession: (AISessionInfo) -> Void
    var onCreateNewSession: () -> Void

    @State private var filterTool: AIChatTool = .opencode

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 工具筛选 Picker
                Picker("AI 工具", selection: $filterTool) {
                    ForEach(AIChatTool.allCases) { tool in
                        Label {
                            Text(tool.displayName)
                        } icon: {
                            Image(tool.iconAssetName)
                                .resizable()
                                .scaledToFit()
                        }
                        .tag(tool)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                let sessions = appState.aiSessionsForTool(filterTool)
                if sessions.isEmpty {
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
                    List(sessions) { session in
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
                                            .foregroundColor(.secondary)
                                        Text(session.formattedDate)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if session.id == appState.aiCurrentSessionId && session.aiTool == appState.aiChatTool {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
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
            filterTool = appState.aiChatTool
        }
    }
}
