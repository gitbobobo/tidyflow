import SwiftUI

struct AITabView: View {
    @EnvironmentObject var appState: AppState

    @State private var inputText: String = ""
    @State private var imageAttachments: [ImageAttachment] = []
    @State private var showSessionList = false
    /// 记录上一次所在的工作空间 key，用于切换时保存快照
    @State private var previousSnapshotKey: String?

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
                .frame(minWidth: 220, maxWidth: 300)
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
        .onChange(of: appState.aiCurrentSessionId) { _, newSessionId in
            // 会话创建完成后，发送待发消息（校验工作空间一致性）
            if let newSessionId, let pending = pendingSendMessage {
                guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty,
                      pending.projectName == appState.selectedProjectName,
                      pending.workspaceName == ws else {
                    pendingSendMessage = nil
                    return
                }
                pendingSendMessage = nil
                appState.wsClient.requestAIChatSend(
                    projectName: appState.selectedProjectName,
                    workspaceName: ws,
                    sessionId: newSessionId,
                    message: pending.text,
                    imageParts: pending.imageParts,
                    model: pending.model,
                    agent: pending.agent
                )
            }
        }
    }

    /// 等待会话创建后发送的消息（含发起时的工作空间信息，防止跨空间误发）
    @State private var pendingSendMessage: (projectName: String, workspaceName: String, text: String, imageParts: [[String: String]]?, model: [String: String]?, agent: String?)? = nil

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
            imageAttachments: $imageAttachments,
            isStreaming: appState.aiIsStreaming,
            onSend: {
                sendMessage()
            },
            onStop: {
                stopStreaming()
            },
            providers: appState.aiProviders,
            selectedModel: $appState.aiSelectedModel,
            agents: appState.aiAgents,
            selectedAgent: $appState.aiSelectedAgent
        )
        .background(controlBackgroundColor)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(separatorColor),
            alignment: .top
        )
    }

    /// 生成当前工作空间的快照 key
    private var currentSnapshotKey: String? {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return nil }
        return "\(appState.selectedProjectName)/\(ws)"
    }

    /// 保存当前 AI 聊天状态到快照缓存
    private func saveSnapshot(forKey key: String) {
        appState.aiChatSnapshotCache[key] = AIChatSnapshot(
            currentSessionId: appState.aiCurrentSessionId,
            messages: appState.aiChatMessages,
            isStreaming: appState.aiIsStreaming,
            sessions: appState.aiSessions,
            messageIndexByMessageId: appState.aiMessageIndexByMessageId,
            partIndexByPartId: appState.aiPartIndexByPartId
        )
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
            if let key = newKey, let snapshot = appState.aiChatSnapshotCache[key] {
                appState.aiCurrentSessionId = snapshot.currentSessionId
                appState.aiChatMessages = snapshot.messages
                appState.aiIsStreaming = false
                appState.aiSessions = snapshot.sessions
                appState.aiMessageIndexByMessageId = snapshot.messageIndexByMessageId
                appState.aiPartIndexByPartId = snapshot.partIndexByPartId
            }
            loadSessions()
            reloadCurrentSessionIfNeeded()
            return
        }
        // 工作空间已变化，走完整的 reset 流程
        previousSnapshotKey = newKey
        if let newKey, let snapshot = appState.aiChatSnapshotCache[newKey] {
            appState.aiCurrentSessionId = snapshot.currentSessionId
            appState.aiChatMessages = snapshot.messages
            appState.aiIsStreaming = false
            appState.aiSessions = snapshot.sessions
            appState.aiMessageIndexByMessageId = snapshot.messageIndexByMessageId
            appState.aiPartIndexByPartId = snapshot.partIndexByPartId
        } else {
            appState.aiCurrentSessionId = nil
            appState.aiChatMessages = []
            appState.aiIsStreaming = false
            appState.aiSessions = []
            appState.aiMessageIndexByMessageId = [:]
            appState.aiPartIndexByPartId = [:]
        }
        loadSessions()
        reloadCurrentSessionIfNeeded()
    }

    /// 切换项目/工作空间时保存旧快照、恢复新快照
    private func resetAIContext() {
        // 清除待发消息，避免跨工作空间误发
        pendingSendMessage = nil

        // 保存旧工作空间快照
        if let oldKey = previousSnapshotKey {
            saveSnapshot(forKey: oldKey)
        }

        let newKey = currentSnapshotKey
        previousSnapshotKey = newKey

        if let newKey, let snapshot = appState.aiChatSnapshotCache[newKey] {
            // 恢复缓存的快照
            appState.aiCurrentSessionId = snapshot.currentSessionId
            appState.aiChatMessages = snapshot.messages
            appState.aiIsStreaming = false // 不恢复流式状态，由后续事件驱动
            appState.aiSessions = snapshot.sessions
            appState.aiMessageIndexByMessageId = snapshot.messageIndexByMessageId
            appState.aiPartIndexByPartId = snapshot.partIndexByPartId
        } else {
            // 无缓存，清空并从服务端加载
            appState.aiCurrentSessionId = nil
            appState.aiChatMessages = []
            appState.aiIsStreaming = false
            appState.aiSessions = []
            appState.aiMessageIndexByMessageId = [:]
            appState.aiPartIndexByPartId = [:]
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
        // 同时加载 provider/agent 列表
        appState.wsClient.requestAIProviderList(projectName: appState.selectedProjectName, workspaceName: ws)
        appState.wsClient.requestAIAgentList(projectName: appState.selectedProjectName, workspaceName: ws)
    }

    private func loadSession(_ session: AISessionInfo) {
        appState.aiCurrentSessionId = session.id
        appState.aiChatMessages = []
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
        if appState.aiCurrentSessionId == session.id {
            appState.aiCurrentSessionId = nil
            appState.aiChatMessages = []
        }
    }

    private func createNewSession() {
        inputText = ""
        imageAttachments = []
        pendingSendMessage = nil
        appState.aiChatMessages = []
        appState.aiCurrentSessionId = nil
        appState.aiIsStreaming = false
    }

    /// 恢复快照后，若有选中会话则重新拉取消息（弥补切走期间丢失的增量）
    private func reloadCurrentSessionIfNeeded() {
        guard let sessionId = appState.aiCurrentSessionId,
              let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        appState.wsClient.requestAISessionMessages(
            projectName: appState.selectedProjectName,
            workspaceName: ws,
            sessionId: sessionId,
            limit: 200
        )
    }

    private func sendMessage() {
        guard let ws = appState.selectedWorkspaceKey, !ws.isEmpty else { return }
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty else { return }

        let text = inputText
        let images = imageAttachments
        inputText = ""
        imageAttachments = []

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
        appState.aiChatMessages.append(userMessage)
        appState.aiIsStreaming = true

        // 预先插入一个"回复气泡占位"，首包到达后由 message_updated 绑定 messageId
        appState.aiChatMessages.append(AIChatMessage(role: .assistant, parts: [], isStreaming: true))

        if let sessionId = appState.aiCurrentSessionId {
            // 已有会话，直接发送
            appState.wsClient.requestAIChatSend(
                projectName: appState.selectedProjectName,
                workspaceName: ws,
                sessionId: sessionId,
                message: text,
                imageParts: imageParts,
                model: model,
                agent: agentName
            )
        } else {
            // 无会话，先创建再发送
            pendingSendMessage = (appState.selectedProjectName, ws, text, imageParts, model, agentName)
            appState.wsClient.requestAIChatStart(
                projectName: appState.selectedProjectName,
                workspaceName: ws,
                title: String(text.prefix(50))
            )
        }
    }

    private func stopStreaming() {
        if let sessionId = appState.aiCurrentSessionId {
            if let ws = appState.selectedWorkspaceKey, !ws.isEmpty {
                appState.wsClient.requestAIChatAbort(
                    projectName: appState.selectedProjectName,
                    workspaceName: ws,
                    sessionId: sessionId
                )
            }
        }
        appState.aiIsStreaming = false

        // 立即停止所有“加载中”展示，避免等待服务端 done 才收敛
        for idx in appState.aiChatMessages.indices.reversed() {
            guard appState.aiChatMessages[idx].role == .assistant,
                  appState.aiChatMessages[idx].isStreaming else { continue }
            appState.aiChatMessages[idx].isStreaming = false
            if appState.aiChatMessages[idx].parts.isEmpty {
                appState.aiChatMessages.remove(at: idx)
            }
        }
    }
}

struct AITabView_Previews: PreviewProvider {
    static var previews: some View {
        AITabView()
            .environmentObject(AppState())
    }
}
