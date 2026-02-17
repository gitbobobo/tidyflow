#if os(macOS)
import SwiftUI

struct AITabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var aiChatStore: AIChatStore
    @EnvironmentObject var fileCache: FileCacheState

    @State private var inputText: String = ""
    @State private var imageAttachments: [ImageAttachment] = []
    @State private var showSessionList = false
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
        HSplitView {
            if showSessionList {
                SessionListView(
                    sessions: Binding(
                        get: { appState.aiSessions },
                        set: { appState.aiSessions = $0 }
                    ),
                    currentSessionId: Binding(
                        get: { aiChatStore.currentSessionId },
                        set: { aiChatStore.setCurrentSessionId($0) }
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
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            }

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
                      pending.workspaceName == ws else {
                    pendingSendRequest = nil
                    return
                }
                pendingSendRequest = nil
                sendPendingRequest(
                    pending.kind,
                    sessionId: newSessionId,
                    projectName: appState.selectedProjectName,
                    workspaceName: ws
                )
            }
        }
    }

    /// 等待会话创建后的发送请求（含发起时工作空间，防止跨空间误发）
    private enum PendingAIRequestKind {
        case message(
            text: String,
            imageParts: [[String: String]]?,
            model: [String: String]?,
            agent: String?,
            fileRefs: [String]?
        )
        case command(
            command: String,
            arguments: String,
            imageParts: [[String: String]]?,
            model: [String: String]?,
            agent: String?,
            fileRefs: [String]?
        )
    }

    @State private var pendingSendRequest: (
        projectName: String,
        workspaceName: String,
        kind: PendingAIRequestKind
    )? = nil

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

            if aiChatStore.messages.isEmpty {
                emptyState
            } else {
                MessageListView(messages: aiChatStore.messages)
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
            imageAttachments: $imageAttachments,
            isStreaming: aiChatStore.isStreaming || aiChatStore.abortPendingSessionId != nil,
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
        return "\(appState.selectedProjectName)/\(ws)"
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
        if let newKey, let snapshot = aiChatStore.snapshot(forKey: newKey) {
            aiChatStore.applySnapshot(snapshot)
            appState.aiSessions = snapshot.sessions
        } else {
            aiChatStore.clearAll()
            appState.aiSessions = []
        }
        loadSessions()
        reloadCurrentSessionIfNeeded()
    }

    /// 切换项目/工作空间时保存旧快照、恢复新快照
    private func resetAIContext() {
        // 清除待发消息，避免跨工作空间误发
        pendingSendRequest = nil
        aiChatStore.setAbortPendingSessionId(nil)

        // 保存旧工作空间快照
        if let oldKey = previousSnapshotKey {
            saveSnapshot(forKey: oldKey)
        }

        let newKey = currentSnapshotKey
        previousSnapshotKey = newKey

        if let newKey, let snapshot = aiChatStore.snapshot(forKey: newKey) {
            // 恢复缓存的快照
            aiChatStore.applySnapshot(snapshot)
            appState.aiSessions = snapshot.sessions
        } else {
            // 无缓存，清空并从服务端加载
            aiChatStore.clearAll()
            appState.aiSessions = []
        }
        // 始终刷新会话列表（保持与服务端同步）
        loadSessions()
        // 若有选中会话，重新加载消息以弥补切走期间丢失的增量
        reloadCurrentSessionIfNeeded()
    }

    private func loadSessions() {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else {
            appState.aiSessions = []
            return
        }
        appState.wsClient.requestAISessionList(projectName: appState.selectedProjectName, workspaceName: ws)
        // 同时加载 provider/agent/斜杠命令 列表
        appState.wsClient.requestAIProviderList(projectName: appState.selectedProjectName, workspaceName: ws)
        appState.wsClient.requestAIAgentList(projectName: appState.selectedProjectName, workspaceName: ws)
        appState.wsClient.requestAISlashCommands(projectName: appState.selectedProjectName, workspaceName: ws)
    }

    private func loadSession(_ session: AISessionInfo) {
        aiChatStore.setCurrentSessionId(session.id)
        aiChatStore.clearMessages()
        appState.wsClient.requestAISessionMessages(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            sessionId: session.id,
            limit: 200
        )
    }

    private func deleteSession(_ session: AISessionInfo) {
        appState.wsClient.requestAISessionDelete(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            sessionId: session.id
        )
        appState.aiSessions.removeAll { $0.id == session.id }
        if aiChatStore.currentSessionId == session.id {
            aiChatStore.clearAll()
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
    private func reloadCurrentSessionIfNeeded() {
        guard let sessionId = aiChatStore.currentSessionId,
              let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        appState.wsClient.requestAISessionMessages(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            sessionId: sessionId,
            limit: 200
        )
    }

    private func sendPendingRequest(
        _ kind: PendingAIRequestKind,
        sessionId: String,
        projectName: String,
        workspaceName: String
    ) {
        switch kind {
        case let .message(text, imageParts, model, agent, fileRefs):
            appState.wsClient.requestAIChatSend(
                projectName: projectName,
                workspaceName: workspaceName,
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

    private func sendMessage() {
        // 上一次停止请求尚未收敛时，不允许发新消息，避免同会话事件串扰。
        if aiChatStore.abortPendingSessionId != nil {
            return
        }
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty else { return }

        let text = inputText
        let images = imageAttachments
        inputText = ""
        imageAttachments = []
        autocomplete.reset()

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

        // 构建图片 parts（base64）
        let imageParts: [[String: String]]? = images.isEmpty ? nil : images.map { img in
            [
                "filename": img.filename,
                "mime": img.mime,
                "data": img.data.base64EncodedString()
            ]
        }

        // 模型选择
        let model: [String: String]? = appState.aiSelectedModel.map {
            ["provider_id": $0.providerID, "model_id": $0.modelID]
        }

        // Agent 选择
        let agentName = appState.aiSelectedAgent

        // 添加用户消息到 UI
        let userMessage = AIChatMessage(
            role: .user,
            parts: [AIChatPart(id: UUID().uuidString, kind: .text, text: text, toolName: nil, toolState: nil)],
            isStreaming: false
        )
        aiChatStore.appendMessage(userMessage)
        aiChatStore.isStreaming = true

        // 预先插入一个"回复气泡占位"，首包到达后由 message_updated 绑定 messageId
        aiChatStore.appendAssistantPlaceholder()

        if let sessionId = aiChatStore.currentSessionId {
            // 已有会话，直接发送
            if let slash = slashCommand {
                appState.wsClient.requestAIChatCommand(
                    projectName: appState.selectedProjectName,
                    workspaceName: ws,
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
            sessionId: sessionId
        )
        aiChatStore.stopStreamingLocallyAndPrunePlaceholder()
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
