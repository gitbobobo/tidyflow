#if os(macOS)
import SwiftUI

struct AITabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var aiChatStore: AIChatStore
    @EnvironmentObject var fileCache: FileCacheState

    @State private var inputText: String = ""
    @State private var imageAttachments: [ImageAttachment] = []
    @State private var showSessionList = true
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
        Group {
            if showSessionList {
                HSplitView {
                    sessionListPane
                    mainPane
                }
            } else {
                mainPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #endif
        .onAppear {
            restoreAIContextOnAppear()
        }
        .onDisappear {
            // 用 previousSnapshotKey（onAppear 时记录的工作空间）而非 currentSnapshotKey，
            // 因为工作空间切换和视图移除可能在同一更新周期，此时 currentSnapshotKey 已指向新空间
            if let key = previousSnapshotKey {
                saveSnapshot(forKey: key)
            }
        }
        .onChange(of: appState.selectedWorkspaceKey) { _, _ in
            resetAIContext()
        }
        .onChange(of: appState.selectedProjectName) { _, _ in
            resetAIContext()
        }
        .onChange(of: aiChatStore.currentSessionId) { _, newSessionId in
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
        .onChange(of: aiChatStore.lastUserEchoMessageId) { _, newMessageId in
            guard newMessageId != nil else { return }
            inputText = ""
            imageAttachments = []
            autocomplete.reset()
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

    private var canSwitchAITool: Bool {
        pendingSendRequest == nil
    }

    private var sessionListPane: some View {
        SessionListView(
            sessions: appState.aiMergedSessions,
            currentSessionId: Binding(
                get: { appState.aiStore(for: appState.aiChatTool).currentSessionId },
                set: { appState.aiStore(for: appState.aiChatTool).setCurrentSessionId($0) }
            ),
            currentTool: appState.aiChatTool,
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
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            toolbar
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
        .frame(height: 44)
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

            if aiChatStore.messages.isEmpty {
                emptyState
            } else {
                MessageListView(
                    messages: aiChatStore.messages,
                    onQuestionReply: handleQuestionReply,
                    onQuestionReject: handleQuestionReject,
                    onQuestionReplyAsMessage: handleQuestionReplyAsMessage
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(appState.aiChatTool.iconAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 56, height: 56)
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Picker("Agent Tool", selection: $appState.aiChatTool) {
                ForEach(AIChatTool.allCases) { tool in
                    Text(
                        appState.shouldShowAIBadge(for: tool)
                            ? "\(tool.displayName) •"
                            : tool.displayName
                    )
                    .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(!canSwitchAITool)

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
            imageAttachments: $imageAttachments,
            isStreaming: aiChatStore.isStreaming || aiChatStore.abortPendingSessionId != nil || aiChatStore.awaitingUserEcho,
            canStopStreaming: aiChatStore.currentSessionId != nil && aiChatStore.abortPendingSessionId == nil,
            onSend: {
                sendMessage()
            },
            onStop: {
                stopStreaming()
            },
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
            for tool in AIChatTool.allCases {
                appState.setAISessions([], for: tool)
            }
            return
        }

        // 会话列表按工具分别拉取，再在客户端做跨工具融合排序。
        for tool in AIChatTool.allCases {
            appState.wsClient.requestAISessionList(
                projectName: appState.selectedProjectName,
                workspaceName: ws,
                aiTool: tool
            )
        }

        let aiTool = appState.aiChatTool
        // 同时加载 provider/agent/斜杠命令 列表
        appState.wsClient.requestAIProviderList(projectName: appState.selectedProjectName, workspaceName: ws, aiTool: aiTool)
        appState.wsClient.requestAIAgentList(projectName: appState.selectedProjectName, workspaceName: ws, aiTool: aiTool)
        appState.wsClient.requestAISlashCommands(projectName: appState.selectedProjectName, workspaceName: ws, aiTool: aiTool)
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
        targetStore.setCurrentSessionId(session.id)
        targetStore.clearMessages()
        TFLog.app.info(
            "AI loadSession: set current session and cleared messages, tool=\(session.aiTool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public)"
        )

        if session.aiTool != appState.aiChatTool {
            // 先请求目标会话详情，再切换工具；避免首击空白。
            appState.wsClient.requestAISessionMessages(
                projectName: session.projectName,
                workspaceName: session.workspaceName,
                aiTool: session.aiTool,
                sessionId: session.id,
                limit: 200
            )
            skipNextAutoReload = (session.aiTool, session.id)
            TFLog.app.info(
                "AI loadSession: requested messages before switching tool, target_tool=\(session.aiTool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public)"
            )
            appState.aiChatTool = session.aiTool
            return
        }

        appState.wsClient.requestAISessionMessages(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: session.aiTool,
            sessionId: session.id,
            limit: 200
        )
        TFLog.app.info(
            "AI loadSession: requested messages, tool=\(session.aiTool.rawValue, privacy: .public), session_id=\(session.id, privacy: .public)"
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
                action: cmd.action
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
        case "new": return "square.and.pencil"
        default: return "command"
        }
    }

    /// 恢复快照后，若有选中会话则重新拉取消息（弥补切走期间丢失的增量）
    private func reloadCurrentSessionIfNeeded(for tool: AIChatTool? = nil) {
        let targetTool = tool ?? appState.aiChatTool
        guard let sessionId = appState.aiStore(for: targetTool).currentSessionId,
              let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        appState.wsClient.requestAISessionMessages(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: targetTool,
            sessionId: sessionId,
            limit: 200
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
            appState.wsClient.requestAIChatSend(
                projectName: projectName,
                workspaceName: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId,
                message: text,
                fileRefs: fileRefs,
                imageParts: imageParts,
                model: model,
                agent: agent
            )
        case let .command(command, arguments, imageParts, model, agent, fileRefs):
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
                agent: agent
            )
        }
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
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        appState.wsClient.requestAIQuestionReply(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: appState.aiChatTool,
            sessionId: request.sessionId,
            requestId: request.id,
            answers: answers
        )
        // 先本地收敛，后端会再推送 ai_question_cleared 做最终一致。
        aiChatStore.clearQuestionRequest(requestId: request.id)
    }

    private func handleQuestionReject(_ request: AIQuestionRequestInfo) {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        appState.wsClient.requestAIQuestionReject(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            aiTool: appState.aiChatTool,
            sessionId: request.sessionId,
            requestId: request.id
        )
        // 先本地收敛，后端会再推送 ai_question_cleared 做最终一致。
        aiChatStore.clearQuestionRequest(requestId: request.id)
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
                agent: agentName
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
            title: String(text.prefix(50))
        )
    }

    private func sendMessage() {
        // 上一次停止请求尚未收敛时，不允许发新消息，避免同会话事件串扰。
        if aiChatStore.abortPendingSessionId != nil {
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

        // 严格模式：以代理回传的 user message 为准，发送后先等待回传。
        autocomplete.reset()
        aiChatStore.beginAwaitingUserEcho()
        aiChatStore.isStreaming = true

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
                    agent: agentName
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
                    agent: agentName
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
                title: String(text.prefix(50))
            )
        }
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
