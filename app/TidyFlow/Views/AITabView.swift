import SwiftUI

struct AITabView: View {
    @EnvironmentObject var appState: AppState

    @State private var inputText: String = ""
    @State private var selectedFiles: [String] = []
    @State private var showSessionList = false

    private var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    private var separatorColor: Color {
        #if os(macOS)
        return Color(NSColor.separatorColor)
        #else
        return Color(UIColor.separator)
        #endif
    }

    var body: some View {
        HSplitView {
            if showSessionList {
                SessionListView(
                    sessions: Binding(
                        get: { appState.aiSessions },
                        set: { appState.aiSessions = $0 }
                    ),
                    currentSessionId: Binding(
                        get: { appState.aiCurrentSessionId },
                        set: { appState.aiCurrentSessionId = $0 }
                    ),
                    onSelect: { session in
                        loadSession(session)
                    },
                    onDelete: { session in
                        deleteSession(session)
                    },
                    onCreateNew: {
                        createNewSession()
                    }
                )
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            }

            VStack(spacing: 0) {
                toolbar
                messageArea
                inputArea
            }
        }
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #endif
        .onAppear {
            loadSessions()
        }
        .onChange(of: appState.aiCurrentSessionId) { newSessionId in
            // 会话创建完成后，发送待发消息
            if let newSessionId, let pending = pendingSendMessage {
                pendingSendMessage = nil
                appState.wsClient.requestAIChatSend(
                    sessionId: newSessionId,
                    message: pending.text,
                    fileRefs: pending.files
                )
            }
        }
    }

    /// 等待会话创建后发送的消息
    @State private var pendingSendMessage: (text: String, files: [String]?)? = nil

    private var toolbar: some View {
        HStack {
            Button(action: {
                withAnimation {
                    showSessionList.toggle()
                }
            }) {
                Image(systemName: "sidebar.left")
                    .help("Toggle Session List")
            }
            .buttonStyle(.plain)

            Text("AI Assistant")
                .font(.headline)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: {
                createNewSession()
            }) {
                Image(systemName: "square.and.pencil")
                    .help("New Session")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(controlBackgroundColor)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(separatorColor),
            alignment: .bottom
        )
    }

    private var messageArea: some View {
        ZStack {
            Color.clear

            if appState.aiChatMessages.isEmpty {
                emptyState
            } else {
                MessageListView(messages: appState.aiChatMessages)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No messages yet")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("Start a new conversation")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    private var inputArea: some View {
        ChatInputView(
            text: $inputText,
            selectedFiles: $selectedFiles,
            isStreaming: appState.aiIsStreaming,
            onSend: {
                sendMessage()
            },
            onStop: {
                stopStreaming()
            },
            onFileSelect: {
                showFilePicker()
            }
        )
        .background(controlBackgroundColor)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(separatorColor),
            alignment: .top
        )
    }

    private func loadSessions() {
        appState.wsClient.requestAISessionList()
    }

    private func loadSession(_ session: SessionInfo) {
        appState.aiCurrentSessionId = session.id
        // TODO: 加载历史消息
        appState.aiChatMessages = []
    }

    private func deleteSession(_ session: SessionInfo) {
        appState.wsClient.requestAISessionDelete(sessionId: session.id)
        appState.aiSessions.removeAll { $0.id == session.id }
        if appState.aiCurrentSessionId == session.id {
            appState.aiCurrentSessionId = nil
            appState.aiChatMessages = []
        }
    }

    private func createNewSession() {
        inputText = ""
        selectedFiles = []
        appState.aiChatMessages = []
        appState.aiCurrentSessionId = nil
        appState.aiIsStreaming = false
    }

    private func sendMessage() {
        guard !inputText.isEmpty || !selectedFiles.isEmpty else { return }

        let text = inputText
        let files = selectedFiles.isEmpty ? nil : selectedFiles
        inputText = ""

        // 添加用户消息到 UI
        let userMessage = ChatMessage(role: .user, content: text)
        appState.aiChatMessages.append(userMessage)
        appState.aiIsStreaming = true

        // 预先插入一个“回复气泡占位”，避免工具调用插队或首包延迟导致 UI 没有回复气泡
        appState.aiChatMessages.append(ChatMessage(role: .assistant, kind: .text, content: "", isStreaming: true))

        if let sessionId = appState.aiCurrentSessionId {
            // 已有会话，直接发送
            appState.wsClient.requestAIChatSend(
                sessionId: sessionId,
                message: text,
                fileRefs: files
            )
        } else {
            // 无会话，先创建再发送
            pendingSendMessage = (text, files)
            appState.wsClient.requestAIChatStart(
                projectName: appState.selectedProjectName,
                title: String(text.prefix(50))
            )
        }
    }

    private func stopStreaming() {
        if let sessionId = appState.aiCurrentSessionId {
            appState.wsClient.requestAIChatAbort(sessionId: sessionId)
        }
        appState.aiIsStreaming = false

        // 立即停止“加载中”展示，避免等待服务端 done 才收敛
        if let idx = appState.aiChatMessages.lastIndex(where: { $0.role == .assistant && $0.kind == .text && $0.isStreaming }) {
            let prev = appState.aiChatMessages[idx]
            let contentEmpty = prev.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let thinkingEmpty = (prev.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let toolEmpty = (prev.toolTrace ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if contentEmpty && thinkingEmpty && toolEmpty {
                appState.aiChatMessages.remove(at: idx)
            } else {
                appState.aiChatMessages[idx] = ChatMessage(
                    id: prev.id,
                    role: .assistant,
                    kind: .text,
                    content: prev.content,
                    thinking: prev.thinking,
                    toolTrace: prev.toolTrace,
                    isStreaming: false,
                    timestamp: prev.timestamp
                )
            }
        }
    }

    private func showFilePicker() {}
}

struct AITabView_Previews: PreviewProvider {
    static var previews: some View {
        AITabView()
            .environmentObject(AppState())
    }
}
