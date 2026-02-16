import SwiftUI

struct MobileAIChatView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String

    @State private var inputText: String = ""
    @State private var imageAttachments: [ImageAttachment] = []
    @State private var showSessionList = false
    @StateObject private var autocomplete = AutocompleteState()
    @State private var cursorRectInInput: CGRect = .zero
    @State private var inputCursorLocation: Int = 0
    @State private var inputIsComposing: Bool = false
    @State private var messageAreaWidth: CGFloat = 0

    private var aiContextKey: String { "\(project):\(workspace)" }
    private let popupHorizontalInset: CGFloat = 12

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

    private var autocompletePopupWidth: CGFloat {
        let available = max(messageAreaWidth - popupHorizontalInset * 2, 0)
        guard available > 0 else { return 0 }
        return min(320, available)
    }

    private var autocompletePopupOffsetX: CGFloat {
        let popupWidth = autocompletePopupWidth
        guard popupWidth > 0 else { return popupHorizontalInset }

        let desired = cursorRectInInput.minX + 2
        let maxOffset = max(popupHorizontalInset, messageAreaWidth - popupWidth - popupHorizontalInset)
        return min(max(desired, popupHorizontalInset), maxOffset)
    }

    var body: some View {
        messageArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            messageAreaWidth = proxy.size.width
                        }
                        .onChange(of: proxy.size.width) { _, newValue in
                            messageAreaWidth = newValue
                        }
                }
            )
            .overlay {
                if autocomplete.isVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { autocomplete.reset() }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if autocomplete.isVisible {
                    AutocompletePopupView(autocomplete: autocomplete) { item in
                        handleAutocompleteSelect(item)
                    }
                    .frame(width: autocompletePopupWidth > 0 ? autocompletePopupWidth : 280)
                    .offset(x: autocompletePopupOffsetX, y: -6)
                }
            }
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
                    Image(systemName: "sidebar.left")
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
                List(appState.aiSessions) { session in
                    Button(action: {
                        loadSession(session)
                        showSessionList = false
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.displayTitle)
                                    .font(.headline)
                                Text(session.formattedDate)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if session.id == appState.aiCurrentSessionId {
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
            appState.closeAIChat()
        }
        .onChange(of: inputText) { _, newText in
            if !inputIsComposing {
                refreshAutocomplete(text: newText)
            }
            if (newText.contains("@") || newText.contains("＠")),
               appState.aiCurrentFileItems().isEmpty {
                appState.fetchAIFileIndexIfNeeded()
            }
        }
        .onChange(of: appState.aiFileIndexCache[aiContextKey]?.items.count) { _, _ in
            if !inputIsComposing {
                refreshAutocomplete(text: inputText)
            }
        }
        .onChange(of: inputCursorLocation) { _, _ in
            if !inputIsComposing {
                refreshAutocomplete(text: inputText)
            }
        }
        .onChange(of: inputIsComposing) { _, composing in
            if composing {
                autocomplete.reset()
                return
            }
            refreshAutocomplete(text: inputText)
        }
    }

    private var messageArea: some View {
        ZStack {
            if appState.aiChatMessages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 34))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("还没有消息")
                        .foregroundColor(.secondary)
                    Text("输入问题开始对话")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                MessageListView(messages: appState.aiChatMessages)
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
                canStopStreaming: appState.aiCurrentSessionId != nil && appState.aiAbortPendingSessionId == nil,
                onSend: { sendMessage() },
                onStop: { stopStreaming() },
                providers: appState.aiProviders,
                selectedModel: $appState.aiSelectedModel,
                agents: appState.aiAgents,
                selectedAgent: $appState.aiSelectedAgent,
                autocomplete: autocomplete,
                onSelectAutocomplete: { item in
                    handleAutocompleteSelect(item)
                },
                onInputContextChange: { cursorLocation, isComposing in
                    inputCursorLocation = cursorLocation
                    inputIsComposing = isComposing
                },
                cursorRectInInput: $cursorRectInInput
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
        autocomplete.reset()
        appState.createNewAISession()
    }

    private func sendMessage() {
        let text = inputText
        let images = imageAttachments
        guard appState.sendAIMessage(text: text, imageAttachments: images) else { return }
        inputText = ""
        imageAttachments = []
        autocomplete.reset()
    }

    private func stopStreaming() {
        appState.stopAIStreaming()
    }

    // MARK: - 自动补全

    private func refreshAutocomplete(text: String) {
        let slashItems = appState.aiSlashCommands.map { cmd in
            AutocompleteItem(
                id: "cmd_\(cmd.name)",
                title: cmd.name,
                subtitle: cmd.description,
                icon: slashCommandIcon(cmd.name),
                value: cmd.name,
                action: cmd.action
            )
        }
        updateAutocomplete(
            text: text,
            cursorLocation: inputCursorLocation,
            autocomplete: autocomplete,
            slashCommands: slashItems,
            fileItems: appState.aiCurrentFileItems()
        )
    }

    private func handleAutocompleteSelect(_ item: AutocompleteItem) {
        switch autocomplete.mode {
        case .fileRef:
            if let replaceRange = autocomplete.replaceRange {
                replaceInputText(in: replaceRange, with: "@\(item.value) ")
            } else {
                inputText += "@\(item.value) "
            }
            autocomplete.reset()
        case .slashCommand:
            if let replaceRange = autocomplete.replaceRange {
                replaceInputText(in: replaceRange, with: "/\(item.value) ")
            } else {
                inputText = "/\(item.value) "
            }
            autocomplete.reset()
        case .none:
            break
        }
    }

    private func replaceInputText(in nsRange: NSRange, with replacement: String) {
        guard let range = Range(nsRange, in: inputText) else {
            inputText += replacement
            return
        }
        inputText.replaceSubrange(range, with: replacement)
    }

    private func slashCommandIcon(_ name: String) -> String {
        switch name {
        case "new":
            return "square.and.pencil"
        default:
            return "command"
        }
    }
}
