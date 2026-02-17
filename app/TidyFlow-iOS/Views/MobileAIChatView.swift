import SwiftUI

struct MobileAIChatView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String

    @State private var inputText: String = ""
    @State private var imageAttachments: [ImageAttachment] = []
    @State private var showSessionList = false
    @State private var referenceSearchTask: Task<Void, Never>?
    /// MessageListView 依赖 @EnvironmentObject AIChatStore（用于 pending tool question 等）。
    /// iOS 端目前由 MobileAppState 承载 AI 状态，因此这里注入一个轻量 store 作为兜底，避免缺失导致闪退。
    @StateObject private var aiChatStore = AIChatStore()

    private var aiToolBinding: Binding<AIChatTool> {
        Binding(
            get: { appState.aiChatTool },
            set: { appState.switchAIChatTool($0) }
        )
    }

    private var systemBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.controlBackgroundColor)
        #endif
    }

    private var systemGroupedBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.systemGroupedBackground)
        #else
        return Color(NSColor.textBackgroundColor)
        #endif
    }

    var body: some View {
        messageArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputArea
            }
        .navigationTitle("AI 聊天")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showSessionList.toggle()
                }) {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    createNewSession()
                }) {
                    Image(systemName: "square.and.pencil")
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    showSessionList.toggle()
                }) {
                    Image(systemName: "list.bullet")
                }
            }
            #endif
        }
        .sheet(isPresented: $showSessionList) {
            NavigationStack {
                List(appState.aiMergedSessions) { session in
                    Button(action: {
                        loadSession(session)
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
                .navigationTitle("会话")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") {
                            showSessionList = false
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: createNewSession) {
                            Image(systemName: "plus")
                        }
                    }
                    #else
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            showSessionList = false
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button(action: createNewSession) {
                            Image(systemName: "plus")
                        }
                    }
                    #endif
                }
            }
        }
        .onAppear {
            appState.openAIChat(project: project, workspace: workspace)
        }
        .onDisappear {
            referenceSearchTask?.cancel()
            appState.closeAIChat()
        }
    }

    private var messageArea: some View {
        ZStack {
            if appState.aiChatMessages.isEmpty {
                VStack(spacing: 16) {
                    Image(appState.aiChatTool.iconAssetName)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Picker("AI Tool", selection: aiToolBinding) {
                        ForEach(AIChatTool.allCases) { tool in
                            Text(tool.displayName).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .disabled(!appState.canSwitchAIChatTool)

                    Text("还没有消息")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("输入问题开始对话")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                MessageListView(
                    messages: appState.aiChatMessages,
                    onQuestionReply: { _, _ in },
                    onQuestionReject: { _ in },
                    onQuestionReplyAsMessage: { text in
                        _ = appState.sendAIMessage(text: text, imageAttachments: [])
                    }
                )
                .environmentObject(aiChatStore)
            }
        }
        .background(systemGroupedBackgroundColor)
    }

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
            ChatInputView(
                text: $inputText,
                imageAttachments: $imageAttachments,
                isStreaming: appState.aiIsStreaming || appState.aiAbortPendingSessionId != nil,
                autoFocusOnAppear: true,
                canStopStreaming: appState.aiCurrentSessionId != nil && appState.aiAbortPendingSessionId == nil,
                onSend: { sendMessage() },
                onStop: { stopStreaming() },
                providers: appState.aiProviders,
                selectedModel: $appState.aiSelectedModel,
                agents: appState.aiAgents,
                selectedAgent: $appState.aiSelectedAgent,
                autocomplete: nil,
                onSelectAutocomplete: nil,
                slashCommands: appState.aiSlashCommands,
                fileReferenceItems: appState.aiCurrentFileItems(),
                onRequestFileReferences: {
                    appState.fetchAIFileIndexIfNeeded()
                },
                onSearchFileReferences: { query in
                    scheduleReferenceSearch(query: query)
                },
                onInputContextChange: nil,
                cursorRectInInput: .constant(.zero)
            )
        }
        .background(systemBackgroundColor)
    }

    private func loadSession(_ session: AISessionInfo) {
        appState.loadAISession(session)
    }

    private func createNewSession() {
        inputText = ""
        imageAttachments = []
        appState.createNewAISession()
    }

    private func sendMessage() {
        let text = inputText
        let images = imageAttachments
        guard appState.sendAIMessage(text: text, imageAttachments: images) else { return }
        inputText = ""
        imageAttachments = []
    }

    private func stopStreaming() {
        appState.stopAIStreaming()
    }

    private func scheduleReferenceSearch(query: String) {
        referenceSearchTask?.cancel()
        referenceSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            appState.searchAIFileReferences(query: query)
        }
    }
}
