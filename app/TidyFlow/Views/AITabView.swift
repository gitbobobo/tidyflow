#if os(macOS)
import SwiftUI

private struct SubAgentSessionRoute: Identifiable {
    let id: String
    let sourceToolName: String
}

struct AITabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var aiChatStore: AIChatStore
    @EnvironmentObject var fileCache: FileCacheState

    @State private var inputText: String = ""
    @State private var imageAttachments: [ImageAttachment] = []
    /// 记录上一次所在的工作空间 key，用于切换时保存快照
    @State private var previousSnapshotKey: String?
    /// 自动补全状态
    @StateObject private var autocomplete = AutocompleteState()
    /// 光标在输入框内的位置（用于定位弹出层）
    @State private var cursorRectInInput: CGRect = .zero
    /// 输入框光标 UTF16 位置（用于基于光标触发自动补全）
    @State private var inputCursorLocation: Int = 0
    /// 是否处于 IME 组合态（组合态中不刷新自动补全，避免和中文输入法冲突）
    @State private var inputIsComposing: Bool = false
    /// 当前轮是否检测到 Codex proposed plan（用于 turn 完成后弹出实现确认）
    @State private var sawCodexPlanProposalInCurrentTurn: Bool = false
    @State private var codexPlanProposalPartIDInCurrentTurn: String?
    @State private var presentedSubAgentSession: SubAgentSessionRoute?
    @State private var mainMessageListScrollSessionToken: Int = 0
    @State private var aiChatHintMessage: String?

    private let planImplementationMessage = AIPlanImplementationQuestion.messageText

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
        mainPane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #endif
        .onAppear {
            restoreAIContextOnAppear()
            requestCurrentSessionStatus()
            consumeOneShotHintIfNeeded()
        }
        .onDisappear {
            // 用 previousSnapshotKey（onAppear 时记录的工作空间）而非 currentSnapshotKey，
            // 因为工作空间切换和视图移除可能在同一更新周期，此时 currentSnapshotKey 已指向新空间
            if let key = previousSnapshotKey {
                saveSnapshot(forKey: key)
            }
            deferredSessionListLoadWorkItem?.cancel()
            deferredSessionListLoadWorkItem = nil
        }
        .onChange(of: appState.selectedWorkspaceKey) { _, _ in
            resetAIContext()
            consumeOneShotHintIfNeeded()
        }
        .onChange(of: appState.selectedProjectName) { _, _ in
            resetAIContext()
            consumeOneShotHintIfNeeded()
        }
        .onChange(of: aiChatStore.currentSessionId) { _, newSessionId in
            mainMessageListScrollSessionToken += 1
            requestCurrentSessionStatus()
            guard let newSessionId else { return }

            // 会话创建完成后，发送待发消息（校验工作空间一致性）
            if let pending = pendingSendRequest {
                guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty,
                      pending.projectName == appState.selectedProjectName,
                      pending.workspaceName == ws,
                      pending.aiTool == appState.aiChatTool else {
                    pendingSendRequest = nil
                    return
                }
                pendingSendRequest = nil
                appState.wsClient.requestAISessionSubscribe(
                    project: appState.selectedProjectName,
                    workspace: ws,
                    aiTool: pending.aiTool.rawValue,
                    sessionId: newSessionId
                )
                applyPendingSelectionHintIfNeeded(
                    pending.kind,
                    sessionId: newSessionId,
                    aiTool: pending.aiTool
                )
                sendPendingRequest(
                    pending.kind,
                    sessionId: newSessionId,
                    projectName: appState.selectedProjectName,
                    workspaceName: ws,
                    aiTool: appState.aiChatTool
                )
            }
        }
        .onChange(of: appState.aiChatTool) { oldTool, newTool in
            guard oldTool != newTool else { return }
            guard canSwitchAITool else {
                appState.aiChatTool = oldTool
                return
            }
            pendingSendRequest = nil
            aiChatStore.setAbortPendingSessionId(nil)
            previousSnapshotKey = currentSnapshotKey
            loadSessions()
            let currentSessionId = appState.aiStore(for: newTool).currentSessionId
            if let skip = skipNextAutoReload,
               skip.tool == newTool,
               skip.sessionId == currentSessionId {
                skipNextAutoReload = nil
            } else {
                reloadCurrentSessionIfNeeded(for: newTool)
            }
        }
        .onChange(of: aiChatStore.lastUserEchoMessageId) { _, _ in
            // user echo 到达时不再需要清空输入——已在发送时立即清空。
        }
        .onChange(of: appState.sessionPanelAction) { _, action in
            guard let action else { return }
            appState.sessionPanelAction = nil
            switch action {
            case .loadSession(let session):
                loadSession(session)
            case .deleteSession(let session):
                deleteSession(session)
            case .createNewSession:
                createNewSession()
            }
        }
        .onReceive(aiChatStore.$messages) { messages in
            observeCodexPlanProposal(messages)
        }
        .onChange(of: aiChatStore.isStreaming) { _, isStreaming in
            requestCurrentSessionStatus()
            if isStreaming {
                sawCodexPlanProposalInCurrentTurn = false
                codexPlanProposalPartIDInCurrentTurn = nil
                return
            }
            maybeInsertPlanImplementationQuestionCard()
            sawCodexPlanProposalInCurrentTurn = false
            codexPlanProposalPartIDInCurrentTurn = nil
        }
        .onChange(of: aiChatStore.awaitingUserEcho) { _, _ in
            requestCurrentSessionStatus()
        }
        .sheet(item: $presentedSubAgentSession, onDismiss: {
            appState.clearSubAgentSessionViewer()
        }) { _ in
            NavigationStack {
                ZStack {
                    if appState.subAgentViewerMessages.isEmpty {
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
                                openLinkedSessionDetail(sessionId: sessionId, sourceToolName: "task")
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
            .frame(minWidth: 560, minHeight: 460)
        }
    }

    /// 等待会话创建后的发送请求（含发起时工作空间，防止跨空间误发）
    private enum PendingAIRequestKind {
        case message(
            text: String,
            imageParts: [[String: Any]]?,
            model: [String: String]?,
            agent: String?,
            fileRefs: [String]?
        )
        case command(
            command: String,
            arguments: String,
            imageParts: [[String: Any]]?,
            model: [String: String]?,
            agent: String?,
            fileRefs: [String]?
        )
    }

    @State private var pendingSendRequest: (
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        kind: PendingAIRequestKind
    )? = nil
    /// 跨工具点击会话时，避免工具切换后的自动重载重复请求同一 session。
    @State private var skipNextAutoReload: (tool: AIChatTool, sessionId: String)? = nil
    /// 延迟拉取非当前工具会话列表的任务（削峰）
    @State private var deferredSessionListLoadWorkItem: DispatchWorkItem? = nil
    private let aiSessionListLimit = 50
    private let deferredSessionListDelay: TimeInterval = 0.35

    private var canSwitchAITool: Bool {
        pendingSendRequest == nil
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            toolbar
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
                .background(controlBackgroundColor)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(separatorColor),
                    alignment: .bottom
                )
            }
            messageArea
                .overlay {
                    // 弹出层可见时，点击消息区域关闭
                    if autocomplete.isVisible {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { autocomplete.reset() }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // 自动补全弹出层：底边对齐消息区域底部（即输入区域顶部）
                    if autocomplete.isVisible {
                        AutocompletePopupView(autocomplete: autocomplete) { item in
                            handleAutocompleteSelect(item)
                        }
                        .frame(width: 320)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: 12, y: -6)
                    }
                }
            inputArea
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func consumeOneShotHintIfNeeded() {
        guard let workspace = appState.selectedWorkspaceKey, !workspace.isEmpty else { return }
        guard let message = appState.consumeAIChatOneShotHint(project: appState.selectedProjectName, workspace: workspace) else {
            return
        }
        aiChatHintMessage = message
    }

    private var toolbar: some View {
        HStack {
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
        .frame(height: 44)
        .background(controlBackgroundColor)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(separatorColor),
            alignment: .bottom
        )
    }

    private var isLoadingMessages: Bool {
        aiChatStore.currentSessionId != nil && aiChatStore.messages.isEmpty
    }

    private var messageArea: some View {
        ZStack {
            Color.clear

            if aiChatStore.messages.isEmpty {
                AIChatEmptyStateView(
                    currentTool: appState.aiChatTool,
                    selectedTool: $appState.aiChatTool,
                    canSwitchTool: canSwitchAITool,
                    isLoading: isLoadingMessages
                )
            } else {
                let currentSessionId = aiChatStore.currentSessionId ?? ""
                MessageListView(
                    messages: aiChatStore.messages,
                    sessionToken: aiChatStore.currentSessionId,
                    onQuestionReply: handleQuestionReply,
                    onQuestionReject: handleQuestionReject,
                    onQuestionReplyAsMessage: handleQuestionReplyAsMessage,
                    onOpenLinkedSession: { sessionId in
                        openLinkedSessionDetail(sessionId: sessionId, sourceToolName: "task")
                    }
                )
                .id("main-session-\(appState.aiChatTool.rawValue)-\(currentSessionId)-\(mainMessageListScrollSessionToken)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openLinkedSessionDetail(sessionId: String, sourceToolName: String) {
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty else { return }

        if let matched = AIChatTool.allCases.lazy
            .flatMap({ self.appState.aiSessionsForTool($0) })
            .first(where: { $0.id == trimmedSessionId }) {
            appState.openSubAgentSessionViewer(
                project: matched.projectName,
                workspace: matched.workspaceName,
                aiTool: matched.aiTool,
                sessionId: trimmedSessionId,
                sourceToolName: sourceToolName
            )
        } else {
            guard let workspace = appState.selectedWorkspaceKey else { return }
            appState.openSubAgentSessionViewer(
                project: appState.selectedProjectName,
                workspace: workspace,
                aiTool: appState.aiChatTool,
                sessionId: trimmedSessionId,
                sourceToolName: sourceToolName
            )
        }
        presentedSubAgentSession = SubAgentSessionRoute(id: trimmedSessionId, sourceToolName: sourceToolName)
    }

    private var inputArea: some View {
        let sessionStatus: AISessionStatusSnapshot? = {
            guard let sessionId = aiChatStore.currentSessionId,
                  let ws = appState.selectedWorkspaceKey else { return nil }
            let session = AISessionInfo(
                projectName: appState.selectedProjectName,
                workspaceName: ws,
                aiTool: appState.aiChatTool,
                id: sessionId,
                title: "",
                updatedAt: 0
            )
            return appState.aiSessionStatus(for: session)
        }()
        let sessionBusy = sessionStatus?.isBusy == true
        let contextRemainingPercent = sessionStatus?.contextRemainingPercent
        let localStreaming =
            aiChatStore.isStreaming ||
            aiChatStore.awaitingUserEcho
        let effectiveStreaming =
            aiChatStore.abortPendingSessionId != nil ||
            sessionBusy ||
            localStreaming

        return ChatInputView(
            text: $inputText,
            imageAttachments: $imageAttachments,
            isStreaming: effectiveStreaming,
            canStopStreaming: aiChatStore.currentSessionId != nil &&
                aiChatStore.abortPendingSessionId == nil &&
                (sessionBusy || localStreaming),
            onSend: {
                sendMessage()
            },
            onStop: {
                stopStreaming()
            },
            providers: appState.aiProviders,
            selectedModel: $appState.aiSelectedModel,
            contextRemainingPercent: contextRemainingPercent,
            agents: appState.aiAgents,
            selectedAgent: $appState.aiSelectedAgent,
            thoughtLevelOptions: appState.thoughtLevelOptions(for: appState.aiChatTool),
            selectedThoughtLevel: $appState.aiSelectedThoughtLevel,
            isLoadingModels: appState.isAILoadingModels,
            isLoadingAgents: appState.isAILoadingAgents,
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
        .background(controlBackgroundColor)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(separatorColor),
            alignment: .top
        )
        .onChange(of: inputText) { _, newText in
            if !inputIsComposing {
                refreshAutocomplete(text: newText)
            }

            // 首次触发 @ 时，若文件索引缓存为空则拉取
            if newText.contains("@") || newText.contains("＠") {
                if let ws = appState.selectedWorkspaceKey {
                    let cache = fileCache.fileIndexCache[ws]
                    if cache == nil || cache!.items.isEmpty {
                        appState.fetchFileIndex(workspaceKey: ws)
                    }
                }
            }
        }
        .onChange(of: appState.aiSlashCommands) { _, _ in
            if !inputIsComposing {
                refreshAutocomplete(text: inputText)
            }
        }
        .onReceive(aiChatStore.$currentSessionId) { _ in
            appState.refreshCurrentAISlashCommands(for: appState.aiChatTool)
            if !inputIsComposing {
                refreshAutocomplete(text: inputText)
            }
        }
        .onChange(of: fileCache.fileIndexCache[appState.selectedWorkspaceKey ?? ""]?.items.count) { _, _ in
            // 文件索引加载完成后，重新触发自动补全（解决首次 @ 时索引为空的问题）
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
            // 结束组合后，基于最终已上屏文本刷新补全
            refreshAutocomplete(text: inputText)
        }
    }

    /// 生成当前工作空间的快照 key
    private var currentSnapshotKey: String? {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return nil }
        return "\(appState.selectedProjectName)/\(ws)/\(appState.aiChatTool.rawValue)"
    }

    /// 保存当前 AI 聊天状态到快照缓存
    private func saveSnapshot(forKey key: String) {
        aiChatStore.saveSnapshot(forKey: key, sessions: appState.aiSessions)
    }

    /// 视图出现时，确保 AI 状态与当前工作空间一致
    /// 处理两种场景：
    /// 1. 视图重建（切 tab 后再回来）→ @State 被重置，previousSnapshotKey == nil
    /// 2. 工作空间切换后视图被移除再重建 → onChange 未触发，需要在此恢复
    private func restoreAIContextOnAppear() {
        skipNextAutoReload = nil
        let newKey = currentSnapshotKey
        // 如果 previousSnapshotKey 与当前一致，说明是同一工作空间内的 tab 切换回来，
        // onDisappear 已保存快照，这里恢复即可
        if previousSnapshotKey == newKey && previousSnapshotKey != nil {
            // 同一工作空间，从快照恢复（弥补视图重建导致的 @State 丢失）
            if let key = newKey, let snapshot = aiChatStore.snapshot(forKey: key) {
                aiChatStore.applySnapshot(snapshot)
                appState.aiSessions = snapshot.sessions
            }
            loadSessions()
            reloadCurrentSessionIfNeeded()
            return
        }
        // 工作空间已变化，走完整的 reset 流程
        previousSnapshotKey = newKey
        for tool in AIChatTool.allCases {
            appState.setAISessions([], for: tool)
        }
        appState.clearAISessionStatuses()
        if let newKey, let snapshot = aiChatStore.snapshot(forKey: newKey) {
            aiChatStore.applySnapshot(snapshot)
            appState.aiSessions = snapshot.sessions
        } else {
            aiChatStore.clearAll()
            appState.aiSessions = []
        }
        appState.aiProviders = []
        appState.aiSelectedModel = nil
        appState.aiAgents = []
        appState.aiSelectedAgent = nil
        appState.aiSlashCommands = []
        loadSessions()
        reloadCurrentSessionIfNeeded()
    }

    /// 切换项目/工作空间时保存旧快照、恢复新快照
    private func resetAIContext() {
        // 清除待发消息，避免跨工作空间误发
        pendingSendRequest = nil
        skipNextAutoReload = nil
        aiChatStore.setAbortPendingSessionId(nil)

        // 保存旧工作空间快照
        if let oldKey = previousSnapshotKey {
            saveSnapshot(forKey: oldKey)
        }

        let newKey = currentSnapshotKey
        previousSnapshotKey = newKey

        for tool in AIChatTool.allCases {
            appState.setAISessions([], for: tool)
        }
        appState.clearAISessionStatuses()
        if let newKey, let snapshot = aiChatStore.snapshot(forKey: newKey) {
            // 恢复缓存的快照
            aiChatStore.applySnapshot(snapshot)
            appState.aiSessions = snapshot.sessions
        } else {
            // 无缓存，清空并从服务端加载
            aiChatStore.clearAll()
            appState.aiSessions = []
        }
        appState.aiProviders = []
        appState.aiSelectedModel = nil
        appState.aiAgents = []
        appState.aiSelectedAgent = nil
        appState.aiSlashCommands = []
        // 始终刷新会话列表（保持与服务端同步）
        loadSessions()
        // 若有选中会话，重新加载消息以弥补切走期间丢失的增量
        reloadCurrentSessionIfNeeded()
    }

    private func loadSessions() {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else {
            deferredSessionListLoadWorkItem?.cancel()
            deferredSessionListLoadWorkItem = nil
            for tool in AIChatTool.allCases {
                appState.setAISessions([], for: tool)
            }
            appState.clearAISessionStatuses()
            return
        }

        // 当前工具优先，其余工具延迟拉取，降低首屏大包冲击。
        let aiTool = appState.aiChatTool
        let sessionListLimit = aiSessionListLimit
        let delayedSessionListDelay = deferredSessionListDelay
        appState.wsClient.requestAISessionList(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: aiTool,
            limit: sessionListLimit
        )
        deferredSessionListLoadWorkItem?.cancel()
        let delayedTools = AIChatTool.allCases.filter { $0 != aiTool }
        if !delayedTools.isEmpty {
            let appStateRef = appState
            let expectedProject = appState.selectedProjectName
            let expectedWorkspace = ws
            let workItem = DispatchWorkItem {
                guard appStateRef.selectedProjectName == expectedProject,
                      appStateRef.selectedWorkspaceKey == expectedWorkspace else { return }
                for tool in delayedTools {
                    appStateRef.wsClient.requestAISessionList(
                        projectName: expectedProject,
                        workspaceName: expectedWorkspace,
                        aiTool: tool,
                        limit: sessionListLimit
                    )
                }
            }
            deferredSessionListLoadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delayedSessionListDelay, execute: workItem)
        }

        appState.isAILoadingModels = true
        appState.isAILoadingAgents = true
        appState.wsClient.requestAIProviderList(projectName: appState.selectedProjectName, workspaceName: ws, aiTool: aiTool)
        appState.wsClient.requestAIAgentList(projectName: appState.selectedProjectName, workspaceName: ws, aiTool: aiTool)
        appState.wsClient.requestAISlashCommands(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: aiTool,
            sessionId: appState.aiStore(for: aiTool).currentSessionId
        )
        appState.wsClient.requestAISessionConfigOptions(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: aiTool,
            sessionId: appState.aiStore(for: aiTool).currentSessionId
        )
    }

    private func loadSession(_ session: AISessionInfo) {
        TFLog.app.info(
            "AI loadSession: target_tool=\(session.aiTool.rawValue, privacy: .public), current_tool=\(appState.aiChatTool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public), can_switch=\(canSwitchAITool)"
        )
        if session.aiTool != appState.aiChatTool {
            guard canSwitchAITool else {
                TFLog.app.warning(
                    "AI loadSession skipped: cannot switch tool, target_tool=\(session.aiTool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public)"
                )
                return
            }
        }
        let targetStore = appState.aiStore(for: session.aiTool)
        let oldSessionId = targetStore.currentSessionId
        targetStore.setCurrentSessionId(session.id)
        targetStore.clearMessages()
        TFLog.app.info(
            "AI loadSession: set current session and cleared messages, tool=\(session.aiTool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public)"
        )

        // 保存订阅上下文，ack 后拉消息并 unsubscribe 旧会话
        appState.pendingSubscribeContextByTool[session.aiTool] = AIPendingSubscribeContext(
            session: session,
            oldSessionId: (oldSessionId != session.id) ? oldSessionId : nil
        )

        if session.aiTool != appState.aiChatTool {
            // 先请求目标会话详情，再切换工具；避免首击空白。
            appState.wsClient.requestAISessionStatus(
                projectName: session.projectName,
                workspaceName: session.workspaceName,
                aiTool: session.aiTool,
                sessionId: session.id
            )
            appState.wsClient.requestAISessionConfigOptions(
                projectName: session.projectName,
                workspaceName: session.workspaceName,
                aiTool: session.aiTool,
                sessionId: session.id
            )
            appState.wsClient.requestAISessionSubscribe(
                project: session.projectName,
                workspace: session.workspaceName,
                aiTool: session.aiTool.rawValue,
                sessionId: session.id
            )
            skipNextAutoReload = (session.aiTool, session.id)
            TFLog.app.info(
                "AI loadSession: subscribed before switching tool, target_tool=\(session.aiTool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public)"
            )
            appState.aiChatTool = session.aiTool
            return
        }

        appState.wsClient.requestAISessionStatus(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: session.aiTool,
            sessionId: session.id
        )
        appState.wsClient.requestAISessionConfigOptions(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: session.aiTool,
            sessionId: session.id
        )
        appState.wsClient.requestAISessionSubscribe(
            project: session.projectName,
            workspace: session.workspaceName,
            aiTool: session.aiTool.rawValue,
            sessionId: session.id
        )
        TFLog.app.info(
            "AI loadSession: subscribed, tool=\(session.aiTool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public)"
        )
    }

    private func deleteSession(_ session: AISessionInfo) {
        appState.wsClient.requestAISessionDelete(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: session.aiTool,
            sessionId: session.id
        )

        appState.removeAISession(session.id, for: session.aiTool)

        let store = appState.aiStore(for: session.aiTool)
        if store.currentSessionId == session.id {
            store.clearAll()
        }
    }

    private func createNewSession() {
        inputText = ""
        imageAttachments = []
        pendingSendRequest = nil
        aiChatStore.setAbortPendingSessionId(nil)
        autocomplete.reset()
        aiChatStore.clearAll()
    }

    // MARK: - 自动补全处理

    private func refreshAutocomplete(text: String) {
        let slashItems = appState.aiSlashCommands.map { cmd in
            AutocompleteItem(
                id: "cmd_\(cmd.name)",
                title: cmd.name,
                subtitle: cmd.description,
                icon: slashCommandIcon(cmd.name),
                value: cmd.name,
                action: cmd.action,
                inputHint: cmd.inputHint
            )
        }
        let fileItems = fileCache.fileIndexCache[appState.selectedWorkspaceKey ?? ""]?.items ?? []
        updateAutocomplete(
            text: text,
            cursorLocation: inputCursorLocation,
            autocomplete: autocomplete,
            slashCommands: slashItems,
            fileItems: fileItems
        )
    }

    private func handleAutocompleteSelect(_ item: AutocompleteItem) {
        switch autocomplete.mode {
        case .fileRef:
            // 仅替换当前光标所在 token 的 @query，保留前后文本
            if let replaceRange = autocomplete.replaceRange {
                replaceInputText(in: replaceRange, with: "@\(item.value) ")
            } else {
                inputText += "@\(item.value) "
            }
            autocomplete.reset()

        case .slashCommand:
            // 2a：选中命令仅插入文本，不在此处执行；真正执行统一由 Enter 触发
            let insertion = if let hint = item.inputHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !hint.isEmpty {
                "/\(item.value) \(hint) "
            } else {
                "/\(item.value) "
            }
            if let replaceRange = autocomplete.replaceRange {
                replaceInputText(in: replaceRange, with: insertion)
            } else {
                inputText = insertion
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
        case "new": return "square.and.pencil"
        default: return "command"
        }
    }

    /// 恢复快照后，若有选中会话则重新拉取消息（弥补切走期间丢失的增量）
    private func reloadCurrentSessionIfNeeded(for tool: AIChatTool? = nil) {
        let targetTool = tool ?? appState.aiChatTool
        guard let sessionId = appState.aiStore(for: targetTool).currentSessionId,
              let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        appState.wsClient.requestAISessionSubscribe(
            project: appState.selectedProjectName,
            workspace: ws,
            aiTool: targetTool.rawValue,
            sessionId: sessionId
        )
        appState.wsClient.requestAISessionMessages(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: targetTool,
            sessionId: sessionId,
            limit: 200
        )
        appState.wsClient.requestAISessionConfigOptions(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: targetTool,
            sessionId: sessionId
        )
    }

    private func sendPendingRequest(
        _ kind: PendingAIRequestKind,
        sessionId: String,
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool
    ) {
        switch kind {
        case let .message(text, imageParts, model, agent, fileRefs):
            let configOverrides = appState.aiConfigOverrides(for: aiTool)
            appState.wsClient.requestAIChatSend(
                projectName: projectName,
                workspaceName: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId,
                message: text,
                fileRefs: fileRefs,
                imageParts: imageParts,
                model: model,
                agent: agent,
                configOverrides: configOverrides
            )
        case let .command(command, arguments, imageParts, model, agent, fileRefs):
            let configOverrides = appState.aiConfigOverrides(for: aiTool)
            appState.wsClient.requestAIChatCommand(
                projectName: projectName,
                workspaceName: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId,
                command: command,
                arguments: arguments,
                fileRefs: fileRefs,
                imageParts: imageParts,
                model: model,
                agent: agent,
                configOverrides: configOverrides
            )
        }
    }

    private func applyPendingSelectionHintIfNeeded(
        _ kind: PendingAIRequestKind,
        sessionId: String,
        aiTool: AIChatTool
    ) {
        let hint: AISessionSelectionHint? = {
            switch kind {
            case let .message(_, _, model, agent, _):
                return pendingSelectionHint(model: model, agent: agent)
            case let .command(_, _, _, model, agent, _):
                return pendingSelectionHint(model: model, agent: agent)
            }
        }()

        guard let hint, !hint.isEmpty else { return }
        appState.applyAISessionSelectionHint(
            hint,
            sessionId: sessionId,
            for: aiTool,
            trigger: "pending_send"
        )
    }

    private func pendingSelectionHint(
        model: [String: String]?,
        agent: String?
    ) -> AISessionSelectionHint {
        let configOptions = appState.aiConfigOverrides(for: appState.aiChatTool)
        return AISessionSelectionHint(
            agent: agent,
            modelProviderID: model?["provider_id"],
            modelID: model?["model_id"],
            configOptions: configOptions
        )
    }

    /// 会话标题仅从非空输入提取；空输入（如仅图片）返回 nil 以触发后端默认标题。
    private func sessionStartTitle(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(50))
    }

    private func parseSlashCommand(from text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "/" || first == "／" else { return nil }
        let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        if let separator = body.firstIndex(where: { $0.isWhitespace }) {
            let name = String(body[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let arguments = String(body[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, arguments)
        }
        return (body, "")
    }

    private func selectedModelInfo() -> AIModelInfo? {
        guard let selected = appState.aiSelectedModel else { return nil }
        return appState.aiProviders
            .flatMap(\.models)
            .first {
                $0.id == selected.modelID && $0.providerID == selected.providerID
            }
    }

    private func handleQuestionReply(_ request: AIQuestionRequestInfo, answers: [[String]]) {
        if isPlanImplementationQuestionRequest(request.id) {
            handlePlanImplementationQuestionReply(request: request, answers: answers)
            return
        }
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        let protocolAnswers = request.protocolAnswers(from: answers)
        appState.wsClient.requestAIQuestionReply(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: appState.aiChatTool,
            sessionId: request.sessionId,
            requestId: request.id,
            answers: protocolAnswers
        )
        // 先本地收敛（关闭交互并回显答案），后端会再推送 ai_question_cleared 做最终一致。
        aiChatStore.completeQuestionRequestLocally(requestId: request.id, answers: answers)
    }

    private func handleQuestionReject(_ request: AIQuestionRequestInfo) {
        if isPlanImplementationQuestionRequest(request.id) {
            aiChatStore.completeQuestionRequestLocally(requestId: request.id)
            return
        }
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        appState.wsClient.requestAIQuestionReject(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: appState.aiChatTool,
            sessionId: request.sessionId,
            requestId: request.id
        )
        // 先本地收敛（关闭交互），后端会再推送 ai_question_cleared 做最终一致。
        aiChatStore.completeQuestionRequestLocally(requestId: request.id)
    }

    private func handleQuestionReplyAsMessage(_ rawText: String) {
        // 上一次停止请求尚未收敛时，不允许发新消息，避免同会话事件串扰。
        if aiChatStore.abortPendingSessionId != nil {
            return
        }
        guard pendingSendRequest == nil else { return }
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let model: [String: String]? = appState.aiSelectedModel.map {
            ["provider_id": $0.providerID, "model_id": $0.modelID]
        }
        let agentName = appState.aiSelectedAgent
        let aiTool = appState.aiChatTool
        let configOverrides = appState.aiConfigOverrides(for: aiTool)

        // 历史 question 回答以普通消息发送，保持与手动输入一致的流式状态管理。
        aiChatStore.beginAwaitingUserEcho()
        aiChatStore.isStreaming = true

        if let sessionId = aiChatStore.currentSessionId {
            appState.wsClient.requestAIChatSend(
                projectName: appState.selectedProjectName,
                workspaceName: ws,
                aiTool: aiTool,
                sessionId: sessionId,
                message: text,
                fileRefs: nil,
                imageParts: nil,
                model: model,
                agent: agentName,
                configOverrides: configOverrides
            )
            return
        }

        pendingSendRequest = (
            appState.selectedProjectName,
            ws,
            aiTool,
            .message(
                text: text,
                imageParts: nil,
                model: model,
                agent: agentName,
                fileRefs: nil
            )
        )
        appState.wsClient.requestAIChatStart(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: aiTool,
            title: sessionStartTitle(from: text)
        )
    }

    private func sendMessage() {
        // 上一次停止请求尚未收敛时，不允许发新消息，避免同会话事件串扰。
        if aiChatStore.abortPendingSessionId != nil {
            return
        }
        // 新会话创建中的幂等保护：等待 session_started 回来前，禁止重复触发发送，
        // 避免重复插入本地 user 占位并导致界面出现重复气泡。
        if aiChatStore.currentSessionId == nil, pendingSendRequest != nil {
            return
        }
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty else { return }

        let text = inputText
        let images = imageAttachments

        // 选中模型明确不支持图片输入时，直接在本地提示并阻止发送。
        if !images.isEmpty,
           let modelInfo = selectedModelInfo(),
           modelInfo.supportsImageInput == false {
            aiChatStore.appendMessage(
                AIChatMessage(
                    role: .assistant,
                    parts: [AIChatPart(
                        id: UUID().uuidString,
                        kind: .text,
                        text: "当前模型不支持图片输入，请切换支持图片的模型后再发送。",
                        toolName: nil,
                        toolState: nil
                    )],
                    isStreaming: false
                )
            )
            return
        }

        let slashCommand = parseSlashCommand(from: text)
        let slashAction: String? = {
            guard let slashCommand else { return nil }
            return appState.aiSlashCommands.first(where: {
                $0.name.caseInsensitiveCompare(slashCommand.name) == .orderedSame
            })?.action
        }()
        if let slashCommand {
            let resolvedAction = slashAction ?? (slashCommand.name.caseInsensitiveCompare("new") == .orderedSame ? "client" : "agent")
            if resolvedAction == "client" {
                inputText = ""
                imageAttachments = []
                autocomplete.reset()
                switch slashCommand.name.lowercased() {
                case "new":
                    createNewSession()
                default:
                    // 当前仅支持 /new；未知 client 命令直接提示，避免误路由到 agent。
                    aiChatStore.appendMessage(
                        AIChatMessage(
                            role: .assistant,
                            parts: [AIChatPart(
                                id: UUID().uuidString,
                                kind: .text,
                                text: "暂不支持本地命令：/\(slashCommand.name)",
                                toolName: nil,
                                toolState: nil
                            )],
                            isStreaming: false
                        )
                    )
                }
                return
            }
        }

        // 提取 @文件引用
        let fileRefs = extractFileRefs(from: text)
        let fileRefsParam: [String]? = fileRefs.isEmpty ? nil : fileRefs

        // 构建图片 parts（二进制）
        let imageParts: [[String: Any]]? = images.isEmpty ? nil : images.map { img in
            [
                "filename": img.filename,
                "mime": img.mime,
                "data": img.data
            ]
        }

        // 模型选择
        let model: [String: String]? = appState.aiSelectedModel.map {
            ["provider_id": $0.providerID, "model_id": $0.modelID]
        }

        // Agent 选择
        let agentName = appState.aiSelectedAgent
        let aiTool = appState.aiChatTool
        let configOverrides = appState.aiConfigOverrides(for: aiTool)

        autocomplete.reset()
        if slashCommand == nil {
            aiChatStore.beginAwaitingUserEcho()
            aiChatStore.insertUserPlaceholder(text: text, imageAttachments: images)
            aiChatStore.appendAssistantPlaceholder()
        } else {
            aiChatStore.beginAwaitingAssistantOnly()
            aiChatStore.appendAssistantPlaceholder()
        }

        // 发送请求已入队后立即清空输入区；消息展示以代理回传的 user message 为准。
        inputText = ""
        imageAttachments = []

        if let sessionId = aiChatStore.currentSessionId {
            // 已有会话，直接发送
            if let slash = slashCommand {
                appState.wsClient.requestAIChatCommand(
                    projectName: appState.selectedProjectName,
                    workspaceName: ws,
                    aiTool: aiTool,
                    sessionId: sessionId,
                    command: slash.name,
                    arguments: slash.arguments,
                    fileRefs: fileRefsParam,
                    imageParts: imageParts,
                    model: model,
                    agent: agentName,
                    configOverrides: configOverrides
                )
            } else {
                appState.wsClient.requestAIChatSend(
                    projectName: appState.selectedProjectName,
                    workspaceName: ws,
                    aiTool: aiTool,
                    sessionId: sessionId,
                    message: text,
                    fileRefs: fileRefsParam,
                    imageParts: imageParts,
                    model: model,
                    agent: agentName,
                    configOverrides: configOverrides
                )
            }
        } else {
            // 无会话，先创建再发送
            if let slash = slashCommand {
                pendingSendRequest = (
                    appState.selectedProjectName,
                    ws,
                    aiTool,
                    .command(
                        command: slash.name,
                        arguments: slash.arguments,
                        imageParts: imageParts,
                        model: model,
                        agent: agentName,
                        fileRefs: fileRefsParam
                    )
                )
            } else {
                pendingSendRequest = (
                    appState.selectedProjectName,
                    ws,
                    aiTool,
                    .message(
                        text: text,
                        imageParts: imageParts,
                        model: model,
                        agent: agentName,
                        fileRefs: fileRefsParam
                    )
                )
            }
            appState.wsClient.requestAIChatStart(
                projectName: appState.selectedProjectName,
                workspaceName: ws,
                aiTool: aiTool,
                title: sessionStartTitle(from: text)
            )
        }
    }

    private func observeCodexPlanProposal(_ messages: [AIChatMessage]) {
        guard aiChatStore.isStreaming else { return }
        guard appState.aiChatTool == .codex else { return }
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
        guard pendingSendRequest == nil else { return }
        guard aiChatStore.abortPendingSessionId == nil else { return }
        guard let sessionID = aiChatStore.currentSessionId, !sessionID.isEmpty else { return }

        let requestID = AIPlanImplementationQuestion.requestId(sessionId: sessionID, planPartId: planPartID)
        if hasPlanImplementationQuestionCard(requestID: requestID) {
            return
        }
        insertPlanImplementationQuestionCard(requestID: requestID, sessionID: sessionID, planPartID: planPartID)
    }

    private func hasPlanImplementationQuestionCard(requestID: String) -> Bool {
        AIPlanImplementationQuestion.hasCard(
            messages: aiChatStore.messages,
            pendingQuestions: aiChatStore.pendingToolQuestions,
            requestID: requestID
        )
    }

    private func insertPlanImplementationQuestionCard(
        requestID: String,
        sessionID: String,
        planPartID: String
    ) {
        let request = AIPlanImplementationQuestion.buildRequest(
            requestID: requestID,
            sessionID: sessionID,
            planPartID: planPartID
        )
        aiChatStore.upsertQuestionRequest(request)
        aiChatStore.appendMessage(AIPlanImplementationQuestion.buildQuestionMessage(request: request, planPartID: planPartID))
    }

    private func isPlanImplementationQuestionRequest(_ requestID: String) -> Bool {
        AIPlanImplementationQuestion.isPlanImplementationQuestionRequest(requestID)
    }

    private func handlePlanImplementationQuestionReply(
        request: AIQuestionRequestInfo,
        answers: [[String]]
    ) {
        aiChatStore.completeQuestionRequestLocally(requestId: request.id, answers: answers)
        if AIPlanImplementationQuestion.shouldStartImplementation(answers) {
            startImplementingPlan()
        }
    }

    private func isPlanAgentSelected() -> Bool {
        AIPlanImplementationQuestion.isPlanAgentSelected(appState.aiSelectedAgent)
    }

    private func resolveDefaultAgentName() -> String {
        AIAgentSelectionPolicy.defaultAgentName(from: appState.aiAgents)
    }

    private func startImplementingPlan() {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        guard pendingSendRequest == nil else { return }
        if aiChatStore.abortPendingSessionId != nil { return }

        let text = planImplementationMessage
        let model: [String: String]? = appState.aiSelectedModel.map {
            ["provider_id": $0.providerID, "model_id": $0.modelID]
        }
        let agentName = resolveDefaultAgentName()
        let aiTool = appState.aiChatTool

        if let agentInfo = appState.aiAgents.first(where: { $0.name == agentName }) {
            appState.aiSelectedAgent = agentInfo.name
            appState.applyAgentDefaultModel(agentInfo)
        }
        let configOverrides = appState.aiConfigOverrides(for: aiTool)

        autocomplete.reset()
        aiChatStore.beginAwaitingUserEcho()
        aiChatStore.insertUserPlaceholder(text: text)
        aiChatStore.appendAssistantPlaceholder()

        inputText = ""
        imageAttachments = []
        sawCodexPlanProposalInCurrentTurn = false
        codexPlanProposalPartIDInCurrentTurn = nil

        if let sessionId = aiChatStore.currentSessionId {
            appState.wsClient.requestAIChatSend(
                projectName: appState.selectedProjectName,
                workspaceName: ws,
                aiTool: aiTool,
                sessionId: sessionId,
                message: text,
                fileRefs: nil,
                imageParts: nil,
                model: model,
                agent: agentName,
                configOverrides: configOverrides
            )
            return
        }

        pendingSendRequest = (
            appState.selectedProjectName,
            ws,
            aiTool,
            .message(
                text: text,
                imageParts: nil,
                model: model,
                agent: agentName,
                fileRefs: nil
            )
        )
        appState.wsClient.requestAIChatStart(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: aiTool,
            title: sessionStartTitle(from: text)
        )
    }

    private func stopStreaming() {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty,
              let sessionId = aiChatStore.currentSessionId else { return }
        aiChatStore.setAbortPendingSessionId(sessionId)
        TFLog.app.info("AI Stop requested: session_id=\(sessionId, privacy: .public)")
        appState.wsClient.requestAIChatAbort(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: appState.aiChatTool,
            sessionId: sessionId
        )
        aiChatStore.stopStreamingLocallyAndPrunePlaceholder()

        // 兜底：若 done/error 丢失，2s 后解除 pending，避免输入区永久不可用。
        let store = aiChatStore
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if store.isAbortPending(for: sessionId) {
                TFLog.app.warning(
                    "AI Stop fallback timeout: clearing abort pending, session_id=\(sessionId, privacy: .public)"
                )
                store.clearAbortPendingIfMatches(sessionId)
            }
        }
    }

    private func requestCurrentSessionStatus() {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty,
              let sessionId = aiChatStore.currentSessionId, !sessionId.isEmpty else { return }
        appState.wsClient.requestAISessionStatus(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: appState.aiChatTool,
            sessionId: sessionId
        )
    }

    private func requestCurrentSessionMessages(limit: Int = 200) {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty,
              let sessionId = aiChatStore.currentSessionId, !sessionId.isEmpty else { return }
        appState.wsClient.requestAISessionMessages(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: appState.aiChatTool,
            sessionId: sessionId,
            limit: limit
        )
    }
}

struct AITabView_Previews: PreviewProvider {
    static var previews: some View {
        AITabView()
            .environmentObject(AppState())
            .environmentObject(AIChatStore())
            .environmentObject(FileCacheState())
    }
}
#endif
