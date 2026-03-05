import SwiftUI

private struct MobileSubAgentSessionRoute: Identifiable {
    let id: String
    let sourceToolName: String
}

struct MobileAIChatView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String

    @State private var inputText: String = ""
    @State private var imageAttachments: [ImageAttachment] = []
    @State private var showSessionList = false
    @State private var referenceSearchTask: Task<Void, Never>?
    @State private var sessionStatusPollingTask: Task<Void, Never>?
    @State private var sawCodexPlanProposalInCurrentTurn = false
    @State private var codexPlanProposalPartIDInCurrentTurn: String?
    @State private var presentedSubAgentSession: MobileSubAgentSessionRoute?
    @State private var mainMessageListScrollSessionToken: Int = 0
    @State private var aiChatHintMessage: String?

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
            .safeAreaInset(edge: .top, spacing: 0) {
                if let aiChatHintMessage, !aiChatHintMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.accentColor)
                        Text(aiChatHintMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            self.aiChatHintMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(systemBackgroundColor)
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
            MobileSessionListSheet(
                showSessionList: $showSessionList,
                onLoadSession: { session in
                    loadSession(session)
                },
                onCreateNewSession: createNewSession
            )
            .environmentObject(appState)
        }
        .sheet(item: $presentedSubAgentSession, onDismiss: {
            appState.clearSubAgentSessionViewer()
        }) { _ in
            NavigationStack {
                ZStack {
                    if appState.subAgentViewerStore.messages.isEmpty {
                        if appState.subAgentViewerLoading {
                            ProgressView("加载子会话中…")
                        } else if let error = appState.subAgentViewerError, !error.isEmpty {
                            Text("加载失败：\(error)")
                                .foregroundColor(.secondary)
                        } else {
                            Text("暂无消息")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        MessageListView(
                            messages: appState.subAgentViewerStore.messages,
                            sessionToken: appState.subAgentViewerStore.currentSessionId,
                            onQuestionReply: { _, _ in },
                            onQuestionReject: { _ in },
                            onQuestionReplyAsMessage: { _ in },
                            onOpenLinkedSession: { sessionId in
                                appState.openSubAgentSessionViewer(
                                    project: appState.aiActiveProject,
                                    workspace: appState.aiActiveWorkspace,
                                    aiTool: appState.aiChatTool,
                                    sessionId: sessionId,
                                    sourceToolName: "task"
                                )
                                presentedSubAgentSession = MobileSubAgentSessionRoute(id: sessionId, sourceToolName: "task")
                            }
                        )
                        .environmentObject(appState.subAgentViewerStore)
                    }
                }
                .navigationTitle(appState.subAgentViewerTitle.isEmpty ? "子会话" : appState.subAgentViewerTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            presentedSubAgentSession = nil
                        }
                    }
                }
            }
        }
        .onAppear {
            appState.openAIChat(project: project, workspace: workspace)
            consumeOneShotHintIfNeeded()
            requestCurrentSessionStatus(force: true)
            restartSessionStatusPollingIfNeeded()
        }
        .onDisappear {
            referenceSearchTask?.cancel()
            sessionStatusPollingTask?.cancel()
            sessionStatusPollingTask = nil
            appState.closeAIChat()
        }
        .onChange(of: appState.aiCurrentSessionId) { _, _ in
            mainMessageListScrollSessionToken += 1
            requestCurrentSessionStatus(force: true)
            restartSessionStatusPollingIfNeeded()
        }
        .onChange(of: appState.aiIsStreaming) { _, _ in
            requestCurrentSessionStatus()
            restartSessionStatusPollingIfNeeded()
        }
        .onReceive(appState.$aiChatMessages) { messages in
            observeCodexPlanProposal(messages)
        }
        .onChange(of: appState.aiIsStreaming) { _, isStreaming in
            if isStreaming {
                sawCodexPlanProposalInCurrentTurn = false
                codexPlanProposalPartIDInCurrentTurn = nil
                return
            }
            maybeInsertPlanImplementationQuestionCard()
            sawCodexPlanProposalInCurrentTurn = false
            codexPlanProposalPartIDInCurrentTurn = nil
        }
    }

    private var isLoadingMessages: Bool {
        appState.aiCurrentSessionId != nil && appState.aiChatMessages.isEmpty
    }

    private var messageArea: some View {
        ZStack {
            if appState.aiChatMessages.isEmpty {
                AIChatEmptyStateView(
                    currentTool: appState.aiChatTool,
                    selectedTool: aiToolBinding,
                    canSwitchTool: appState.canSwitchAIChatTool,
                    isLoading: isLoadingMessages
                )
            } else {
                let currentSessionId = appState.aiCurrentSessionId ?? ""
                MessageListView(
                    messages: appState.aiChatMessages,
                    sessionToken: appState.aiCurrentSessionId,
                    onQuestionReply: { request, answers in
                        handleQuestionReply(request: request, answers: answers)
                    },
                    onQuestionReject: { request in
                        handleQuestionReject(request: request)
                    },
                    onQuestionReplyAsMessage: { text in
                        _ = appState.sendAIMessage(text: text, imageAttachments: [])
                    },
                    onOpenLinkedSession: { sessionId in
                        appState.openSubAgentSessionViewer(
                            project: appState.aiActiveProject,
                            workspace: appState.aiActiveWorkspace,
                            aiTool: appState.aiChatTool,
                            sessionId: sessionId,
                            sourceToolName: "task"
                        )
                        presentedSubAgentSession = MobileSubAgentSessionRoute(id: sessionId, sourceToolName: "task")
                    }
                )
                .environmentObject(appState.aiChatStore)
                .id("main-session-\(appState.aiChatTool.rawValue)-\(currentSessionId)-\(mainMessageListScrollSessionToken)")
            }
        }
        .background(systemGroupedBackgroundColor)
    }

    private func consumeOneShotHintIfNeeded() {
        guard let message = appState.consumeAIChatOneShotHint(project: project, workspace: workspace) else {
            return
        }
        aiChatHintMessage = message
    }

    private var inputArea: some View {
        let contextRemainingPercent: Double? = {
            guard let sessionId = appState.aiCurrentSessionId else { return nil }
            let session = AISessionInfo(
                projectName: appState.aiActiveProject,
                workspaceName: appState.aiActiveWorkspace,
                aiTool: appState.aiChatTool,
                id: sessionId,
                title: "",
                updatedAt: 0
            )
            return appState.aiSessionStatus(for: session)?.contextRemainingPercent
        }()

        return VStack(spacing: 0) {
            Divider()
            ChatInputView(
                text: $inputText,
                imageAttachments: $imageAttachments,
                isStreaming: appState.aiIsStreaming || appState.aiAbortPendingSessionId != nil,
                autoFocusOnAppear: true,
                canStopStreaming: appState.aiCurrentSessionId != nil && appState.aiAbortPendingSessionId == nil,
                isSendingPending: appState.aiIsSendingPending,
                onSend: { sendMessage() },
                onStop: { stopStreaming() },
                providers: appState.aiProviders,
                selectedModel: $appState.aiSelectedModel,
                contextRemainingPercent: contextRemainingPercent,
                agents: appState.aiAgents,
                selectedAgent: $appState.aiSelectedAgent,
                thoughtLevelOptions: appState.thoughtLevelOptions(),
                selectedThoughtLevel: $appState.aiSelectedThoughtLevel,
                isLoadingModels: appState.isAILoadingModels,
                isLoadingAgents: appState.isAILoadingAgents,
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

    private func requestCurrentSessionStatus(force: Bool = false) {
        appState.requestCurrentAISessionStatus(force: force)
    }

    private func handleQuestionReply(request: AIQuestionRequestInfo, answers: [[String]]) {
        if isPlanImplementationQuestionRequest(request.id) {
            appState.completeAIQuestionRequestLocally(requestId: request.id, answers: answers)
            if AIPlanImplementationQuestion.shouldStartImplementation(answers) {
                appState.startImplementingCodexPlan()
            }
            return
        }

        let protocolAnswers = request.protocolAnswers(from: answers)
        appState.replyAIQuestion(
            requestId: request.id,
            sessionId: request.sessionId,
            answers: protocolAnswers
        )
        appState.completeAIQuestionRequestLocally(requestId: request.id, answers: answers)
    }

    private func handleQuestionReject(request: AIQuestionRequestInfo) {
        if isPlanImplementationQuestionRequest(request.id) {
            appState.completeAIQuestionRequestLocally(requestId: request.id)
            return
        }

        appState.rejectAIQuestion(
            requestId: request.id,
            sessionId: request.sessionId
        )
        appState.completeAIQuestionRequestLocally(requestId: request.id)
    }

    private func observeCodexPlanProposal(_ messages: [AIChatMessage]) {
        guard appState.aiIsStreaming else { return }
        guard appState.aiChatTool == .codex else { return }
        guard isPlanAgentSelected() else { return }
        guard !sawCodexPlanProposalInCurrentTurn else { return }

        for message in messages.reversed() where message.role == .assistant {
            for part in message.parts where part.kind == .text {
                if isCodexPlanProposalPart(part) {
                    sawCodexPlanProposalInCurrentTurn = true
                    codexPlanProposalPartIDInCurrentTurn = part.id
                    return
                }
            }
        }
    }

    private func isCodexPlanProposalPart(_ part: AIChatPart) -> Bool {
        AIPlanImplementationQuestion.isCodexPlanProposalPart(part)
    }

    private func maybeInsertPlanImplementationQuestionCard() {
        guard appState.aiChatTool == .codex else { return }
        guard isPlanAgentSelected() else { return }
        guard sawCodexPlanProposalInCurrentTurn else { return }
        guard let planPartID = codexPlanProposalPartIDInCurrentTurn, !planPartID.isEmpty else { return }
        guard appState.aiAbortPendingSessionId == nil else { return }
        guard let sessionID = appState.aiCurrentSessionId, !sessionID.isEmpty else { return }

        let requestID = AIPlanImplementationQuestion.requestId(sessionId: sessionID, planPartId: planPartID)
        if appState.hasCodexPlanImplementationQuestionCard(requestId: requestID) {
            return
        }
        appState.insertCodexPlanImplementationQuestionCard(
            requestID: requestID,
            sessionID: sessionID,
            planPartID: planPartID
        )
    }

    private func isPlanImplementationQuestionRequest(_ requestID: String) -> Bool {
        AIPlanImplementationQuestion.isPlanImplementationQuestionRequest(requestID)
    }

    private func isPlanAgentSelected() -> Bool {
        AIPlanImplementationQuestion.isPlanAgentSelected(appState.aiSelectedAgent)
    }

    private func restartSessionStatusPollingIfNeeded() {
        sessionStatusPollingTask?.cancel()
        sessionStatusPollingTask = nil
        guard appState.aiCurrentSessionId != nil else { return }
        let shouldPoll = appState.aiIsStreaming || appState.aiAbortPendingSessionId != nil
        guard shouldPoll else { return }

        sessionStatusPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { break }
                await MainActor.run {
                    requestCurrentSessionStatus()
                }
            }
        }
    }
}
