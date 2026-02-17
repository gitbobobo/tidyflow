import Foundation
#if os(macOS)
import AppKit
#endif

enum AIChatRole: String {
    case user
    case assistant
}

enum AIChatTool: String, CaseIterable, Identifiable {
    case opencode
    case codex
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        }
    }
}

struct AIToolBadgeState {
    var hasRunning: Bool = false
    var hasUnread: Bool = false

    var showDot: Bool {
        hasRunning || hasUnread
    }
}

enum AIChatPartKind: String {
    case text
    case reasoning
    case tool
    case file
}

struct AIChatPart: Identifiable {
    let id: String
    let kind: AIChatPartKind
    var text: String?
    var mime: String? = nil
    var filename: String? = nil
    var url: String? = nil
    var synthetic: Bool? = nil
    var ignored: Bool? = nil
    var source: [String: Any]? = nil
    var toolName: String?
    var toolState: [String: Any]?
    var toolCallId: String? = nil
    var toolPartMetadata: [String: Any]? = nil
}

enum AIToolStatus: String {
    case pending
    case running
    case completed
    case error
    case unknown

    var text: String {
        switch self {
        case .pending: return "pending"
        case .running: return "running"
        case .completed: return "completed"
        case .error: return "error"
        case .unknown: return "unknown"
        }
    }
}

struct AIToolInvocationState {
    let status: AIToolStatus
    let input: [String: Any]
    let raw: String?
    let title: String?
    let output: String?
    let error: String?
    let metadata: [String: Any]?
    let timeStart: Double?
    let timeEnd: Double?
    let attachments: [[String: Any]]?

    static func from(state: [String: Any]?) -> AIToolInvocationState? {
        guard let state else { return nil }
        let statusRaw = (state["status"] as? String ?? "").lowercased()
        let status = AIToolStatus(rawValue: statusRaw) ?? .unknown
        let input = state["input"] as? [String: Any] ?? [:]
        let raw = state["raw"] as? String
        let title = state["title"] as? String
        let output = state["output"] as? String
        let error = state["error"] as? String
        let metadata = state["metadata"] as? [String: Any]
        let time = state["time"] as? [String: Any] ?? [:]
        let attachments = state["attachments"] as? [[String: Any]]

        return AIToolInvocationState(
            status: status,
            input: input,
            raw: raw,
            title: title,
            output: output,
            error: error,
            metadata: metadata,
            timeStart: Self.parseDouble(time["start"]),
            timeEnd: Self.parseDouble(time["end"]),
            attachments: attachments
        )
    }

    var durationMs: Double? {
        guard let start = timeStart, let end = timeEnd else { return nil }
        return max(0, end - start)
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        switch value {
        case let v as Double:
            return v
        case let v as Float:
            return Double(v)
        case let v as Int:
            return Double(v)
        case let v as Int64:
            return Double(v)
        case let v as UInt:
            return Double(v)
        case let v as NSNumber:
            return v.doubleValue
        case let v as String:
            return Double(v)
        default:
            return nil
        }
    }
}

struct AIToolSection: Identifiable {
    let id: String
    let title: String
    let content: String
    let isCode: Bool
}

struct AIToolPresentation {
    let toolID: String
    let displayTitle: String
    let statusText: String
    let summary: String?
    let sections: [AIToolSection]
}

/// 一条消息对应一个 OpenCode message（message_id），内部包含多个 part
struct AIChatMessage: Identifiable {
    /// SwiftUI 稳定 id（本地生成）
    let id: String
    /// OpenCode messageID（服务端下发）；本地占位消息可为 nil
    var messageId: String?
    var role: AIChatRole
    var parts: [AIChatPart]
    var isStreaming: Bool
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        messageId: String? = nil,
        role: AIChatRole,
        parts: [AIChatPart] = [],
        isStreaming: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.messageId = messageId
        self.role = role
        self.parts = parts
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }
}

struct AISessionInfo: Identifiable {
    let projectName: String
    let workspaceName: String
    let id: String
    let title: String
    let updatedAt: Int64

    var displayTitle: String {
        return title.isEmpty ? "New Chat" : title
    }

    var formattedDate: String {
        let date = Date(timeIntervalSince1970: Double(updatedAt) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 工作空间快照（切换时保留对话上下文）

struct AIChatSnapshot {
    var currentSessionId: String?
    var messages: [AIChatMessage]
    var isStreaming: Bool
    var sessions: [AISessionInfo]
    var messageIndexByMessageId: [String: Int]
    var partIndexByPartId: [String: (msgIdx: Int, partIdx: Int)]
    var pendingToolQuestions: [String: AIQuestionRequestInfo]
    var questionRequestToCallId: [String: String]
}

private enum AIChatStreamEvent {
    case messageUpdated(messageId: String, role: String)
    case partUpdated(messageId: String, part: AIProtocolPartInfo)
    case partDelta(messageId: String, partId: String, partType: String, field: String, delta: String)
}

/// AI 聊天状态域：隔离高频流式更新，避免全局 AppState 频繁刷新。
final class AIChatStore: ObservableObject {
    @Published var currentSessionId: String?
    @Published var messages: [AIChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var abortPendingSessionId: String?
    @Published var awaitingUserEcho: Bool = false
    @Published var lastUserEchoMessageId: String?
    @Published var pendingToolQuestions: [String: AIQuestionRequestInfo] = [:]

    /// 工作空间快照缓存（key: "projectName/workspaceName"）
    var snapshotCache: [String: AIChatSnapshot] = [:]

    private var messageIndexByMessageId: [String: Int] = [:]
    private var messageRoleByMessageId: [String: AIChatRole] = [:]
    private var partIndexByPartId: [String: (msgIdx: Int, partIdx: Int)] = [:]
    private var questionRequestToCallId: [String: String] = [:]
    private var streamingAssistantIndex: Int?
    /// 当前轮次中 assistant 首条消息的锚点（用于 user echo 晚到时插回 assistant 之前）。
    private var pendingUserEchoAssistantMessageId: String?
    /// 进入 awaiting 前的消息数量快照；用于过滤“旧 user 消息更新”误触发收敛。
    private var awaitingUserEchoBaselineIndex: Int?

    private var pendingStreamEvents: [AIChatStreamEvent] = []
    private var streamFlushWorkItem: DispatchWorkItem?
    private let streamFlushInterval: TimeInterval = 1.0 / 30.0

    // MARK: - Snapshot

    func saveSnapshot(forKey key: String, sessions: [AISessionInfo]) {
        flushPendingStreamEvents()
        snapshotCache[key] = makeSnapshot(sessions: sessions)
    }

    func snapshot(forKey key: String) -> AIChatSnapshot? {
        snapshotCache[key]
    }

    func applySnapshot(_ snapshot: AIChatSnapshot) {
        flushPendingStreamEvents()
        currentSessionId = snapshot.currentSessionId
        messages = snapshot.messages
        // 切换工作空间后不恢复流式态，后续由服务端事件重新驱动。
        abortPendingSessionId = nil
        awaitingUserEcho = false
        lastUserEchoMessageId = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        pendingToolQuestions = snapshot.pendingToolQuestions
        questionRequestToCallId = snapshot.questionRequestToCallId
        clearAssistantStreaming()
        isStreaming = false
        rebuildIndexes()
    }

    func makeSnapshot(sessions: [AISessionInfo]) -> AIChatSnapshot {
        AIChatSnapshot(
            currentSessionId: currentSessionId,
            messages: messages,
            isStreaming: isStreaming,
            sessions: sessions,
            messageIndexByMessageId: messageIndexByMessageId,
            partIndexByPartId: partIndexByPartId,
            pendingToolQuestions: pendingToolQuestions,
            questionRequestToCallId: questionRequestToCallId
        )
    }

    // MARK: - Public State Ops

    func clearAll() {
        flushPendingStreamEvents()
        currentSessionId = nil
        messages = []
        abortPendingSessionId = nil
        awaitingUserEcho = false
        lastUserEchoMessageId = nil
        isStreaming = false
        messageIndexByMessageId = [:]
        messageRoleByMessageId = [:]
        partIndexByPartId = [:]
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        streamingAssistantIndex = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
    }

    func clearMessages() {
        flushPendingStreamEvents()
        messages = []
        awaitingUserEcho = false
        lastUserEchoMessageId = nil
        isStreaming = false
        messageIndexByMessageId = [:]
        messageRoleByMessageId = [:]
        partIndexByPartId = [:]
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        streamingAssistantIndex = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
    }

    func replaceMessages(_ newMessages: [AIChatMessage]) {
        flushPendingStreamEvents()
        messages = newMessages
        abortPendingSessionId = nil
        awaitingUserEcho = false
        lastUserEchoMessageId = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        clearAssistantStreaming()
        isStreaming = false
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        rebuildIndexes()
        recomputeIsStreaming()
    }

    func appendMessage(_ message: AIChatMessage) {
        flushPendingStreamEvents()
        messages.append(message)
        rebuildIndexes()
        recomputeIsStreaming()
    }

    func appendAssistantPlaceholder() {
        appendMessage(AIChatMessage(role: .assistant, parts: [], isStreaming: true))
        if let idx = messages.indices.last {
            markOnlyStreamingAssistant(at: idx)
            recomputeIsStreaming()
        }
    }

    func setCurrentSessionId(_ sessionId: String?) {
        if currentSessionId != sessionId {
            pendingToolQuestions = [:]
            questionRequestToCallId = [:]
            awaitingUserEcho = false
            lastUserEchoMessageId = nil
            pendingUserEchoAssistantMessageId = nil
            awaitingUserEchoBaselineIndex = nil
        }
        currentSessionId = sessionId
    }

    func setAbortPendingSessionId(_ sessionId: String?) {
        abortPendingSessionId = sessionId
    }

    func clearAbortPendingIfMatches(_ sessionId: String) {
        if abortPendingSessionId == sessionId {
            abortPendingSessionId = nil
        }
    }

    func isAbortPending(for sessionId: String) -> Bool {
        abortPendingSessionId == sessionId
    }

    func beginAwaitingUserEcho() {
        awaitingUserEcho = true
        lastUserEchoMessageId = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = messages.count
    }

    func markUserEchoReceived(messageId: String) {
        guard awaitingUserEcho else { return }
        if let baseline = awaitingUserEchoBaselineIndex,
           let idx = messageIndexByMessageId[messageId],
           idx < baseline {
            TFLog.app.debug(
                "AI user echo ignored (stale message): message_id=\(messageId, privacy: .public), idx=\(idx), baseline=\(baseline)"
            )
            return
        }
        awaitingUserEcho = false
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        lastUserEchoMessageId = messageId
    }

    func upsertQuestionRequest(_ request: AIQuestionRequestInfo) {
        guard let callId = request.toolCallId, !callId.isEmpty else { return }
        pendingToolQuestions[callId] = request
        questionRequestToCallId[request.id] = callId
    }

    func clearQuestionRequest(requestId: String) {
        if let callId = questionRequestToCallId.removeValue(forKey: requestId) {
            pendingToolQuestions.removeValue(forKey: callId)
            return
        }
        if let matched = pendingToolQuestions.first(where: { $0.value.id == requestId }) {
            pendingToolQuestions.removeValue(forKey: matched.key)
        }
    }

    func questionRequest(forToolCallId callId: String?) -> AIQuestionRequestInfo? {
        guard let callId, !callId.isEmpty else { return nil }
        return pendingToolQuestions[callId]
    }

    func stopStreamingLocallyAndPrunePlaceholder() {
        flushPendingStreamEvents()
        isStreaming = false
        clearAssistantStreaming()
        messages.removeAll { msg in
            msg.role == .assistant && msg.messageId == nil && msg.parts.isEmpty
        }
        rebuildIndexes()
        recomputeIsStreaming()
    }

    // MARK: - Streaming Batch Apply

    func enqueueMessageUpdated(messageId: String, role: String) {
        pendingStreamEvents.append(.messageUpdated(messageId: messageId, role: role))
        scheduleStreamFlushIfNeeded()
    }

    func enqueuePartUpdated(messageId: String, part: AIProtocolPartInfo) {
        pendingStreamEvents.append(.partUpdated(messageId: messageId, part: part))
        scheduleStreamFlushIfNeeded()
    }

    func enqueuePartDelta(messageId: String, partId: String, partType: String, field: String, delta: String) {
        pendingStreamEvents.append(
            .partDelta(messageId: messageId, partId: partId, partType: partType, field: field, delta: delta)
        )
        scheduleStreamFlushIfNeeded()
    }

    func flushPendingStreamEvents() {
        streamFlushWorkItem?.cancel()
        streamFlushWorkItem = nil
        guard !pendingStreamEvents.isEmpty else { return }

        let events = pendingStreamEvents
        pendingStreamEvents.removeAll(keepingCapacity: true)
        var latestMessageIndex: Int?

        // 先消费 message.updated，尽量先建立 message_id -> role 映射，
        // 避免同批次里 part 先到导致角色误判。
        for event in events {
            guard case let .messageUpdated(messageId, roleToken) = event else { continue }
            let role = roleFromToken(roleToken)
            let msgIdx = ensureMessage(messageId: messageId, roleHint: role)
            if role == .user || (role == nil && messages[msgIdx].role == .user) {
                markUserEchoReceived(messageId: messageId)
            }
            if messages[msgIdx].role == .assistant {
                if awaitingUserEcho, pendingUserEchoAssistantMessageId == nil {
                    pendingUserEchoAssistantMessageId = messageId
                }
                latestMessageIndex = msgIdx
            }
        }

        for event in events {
            switch event {
            case .messageUpdated:
                continue
            case .partUpdated(let messageId, let part):
                var roleHint = messageRoleByMessageId[messageId]
                if roleHint == nil,
                   let sourceRole = part.source?["role"] as? String {
                    roleHint = roleFromToken(sourceRole.lowercased())
                    if roleHint != nil {
                        TFLog.app.debug(
                            "AI role inferred from part.source: message_id=\(messageId, privacy: .public), role=\(sourceRole, privacy: .public), part_type=\(part.partType, privacy: .public)"
                        )
                    }
                }
                if roleHint == nil, awaitingUserEcho {
                    if part.partType == AIChatPartKind.file.rawValue {
                        roleHint = .user
                        TFLog.app.debug(
                            "AI role inferred (file part): message_id=\(messageId, privacy: .public), role=user, part_type=\(part.partType, privacy: .public)"
                        )
                    } else if let anchorMessageId = pendingUserEchoAssistantMessageId {
                        roleHint = (anchorMessageId == messageId) ? .assistant : .user
                        TFLog.app.debug(
                            "AI role inferred (anchor): message_id=\(messageId, privacy: .public), role=\(roleHint?.rawValue ?? "nil", privacy: .public), anchor=\(anchorMessageId, privacy: .public), part_type=\(part.partType, privacy: .public)"
                        )
                    } else if hasUnboundAssistantPlaceholder() {
                        // 存在未绑定 assistant 占位时，首个未知消息优先视为 assistant。
                        roleHint = .assistant
                        TFLog.app.debug(
                            "AI role inferred (placeholder): message_id=\(messageId, privacy: .public), role=assistant, part_type=\(part.partType, privacy: .public)"
                        )
                    }
                }
                let msgIdx = ensureMessage(messageId: messageId, roleHint: roleHint)
                upsertPart(msgIdx: msgIdx, part: part)
                if messages[msgIdx].role == .assistant {
                    if awaitingUserEcho,
                       pendingUserEchoAssistantMessageId == nil,
                       let assistantMessageId = messages[msgIdx].messageId {
                        pendingUserEchoAssistantMessageId = assistantMessageId
                    }
                    latestMessageIndex = msgIdx
                }
            case .partDelta(let messageId, let partId, let partType, let field, let delta):
                var roleHint = messageRoleByMessageId[messageId]
                if roleHint == nil, awaitingUserEcho {
                    if let anchorMessageId = pendingUserEchoAssistantMessageId {
                        roleHint = (anchorMessageId == messageId) ? .assistant : .user
                    } else if hasUnboundAssistantPlaceholder() {
                        roleHint = .assistant
                    }
                    if roleHint != nil {
                        TFLog.app.debug(
                            "AI role inferred (delta): message_id=\(messageId, privacy: .public), role=\(roleHint?.rawValue ?? "nil", privacy: .public), part_type=\(partType, privacy: .public), part_id=\(partId, privacy: .public)"
                        )
                    }
                }
                let msgIdx = ensureMessage(messageId: messageId, roleHint: roleHint)
                appendDelta(msgIdx: msgIdx, partId: partId, partType: partType, field: field, delta: delta)
                if messages[msgIdx].role == .assistant {
                    if awaitingUserEcho,
                       pendingUserEchoAssistantMessageId == nil,
                       let assistantMessageId = messages[msgIdx].messageId {
                        pendingUserEchoAssistantMessageId = assistantMessageId
                    }
                    latestMessageIndex = msgIdx
                }
            }
        }

        if let idx = latestMessageIndex {
            markOnlyStreamingAssistant(at: idx)
        }
        recomputeIsStreaming()
    }

    func handleChatDone(sessionId: String) {
        flushPendingStreamEvents()
        clearAbortPendingIfMatches(sessionId)
        // 严格模式兜底：若 user echo 未回传，也要收敛输入状态，避免输入框长期不清空/禁用。
        if awaitingUserEcho {
            awaitingUserEcho = false
            awaitingUserEchoBaselineIndex = nil
            lastUserEchoMessageId = "done-\(sessionId)-\(UUID().uuidString)"
        }
        isStreaming = false
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        clearAssistantStreaming()
        messages.removeAll { msg in
            msg.role == .assistant && msg.messageId == nil && msg.parts.isEmpty
        }
        rebuildIndexes()
        recomputeIsStreaming()
    }

    func handleChatError(sessionId: String, error: String) {
        flushPendingStreamEvents()
        clearAbortPendingIfMatches(sessionId)
        awaitingUserEcho = false
        awaitingUserEchoBaselineIndex = nil
        pendingUserEchoAssistantMessageId = nil
        isStreaming = false
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        clearAssistantStreaming()
        messages.removeAll { msg in
            msg.role == .assistant && msg.messageId == nil && msg.parts.isEmpty
        }
        messages.append(
            AIChatMessage(
                role: .assistant,
                parts: [AIChatPart(id: UUID().uuidString, kind: .text, text: "⚠️ \(error)", toolName: nil, toolState: nil)],
                isStreaming: false
            )
        )
        rebuildIndexes()
        recomputeIsStreaming()
    }

    // MARK: - Internal Helpers

    private func scheduleStreamFlushIfNeeded() {
        guard streamFlushWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingStreamEvents()
        }
        streamFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + streamFlushInterval, execute: workItem)
    }

    private func rebuildIndexes() {
        messageIndexByMessageId = [:]
        messageRoleByMessageId = [:]
        partIndexByPartId = [:]
        streamingAssistantIndex = nil

        for (i, msg) in messages.enumerated() {
            if let mid = msg.messageId {
                messageIndexByMessageId[mid] = i
                messageRoleByMessageId[mid] = msg.role
            }
            for (j, p) in msg.parts.enumerated() {
                partIndexByPartId[p.id] = (i, j)
            }
            if msg.role == .assistant, msg.isStreaming {
                streamingAssistantIndex = i
            }
        }
    }

    @discardableResult
    private func roleFromToken(_ token: String) -> AIChatRole? {
        switch token {
        case "assistant":
            return .assistant
        case "user":
            return .user
        default:
            return nil
        }
    }

    @discardableResult
    private func ensureMessage(messageId: String, roleHint: AIChatRole?) -> Int {
        if let idx = messageIndexByMessageId[messageId],
           idx < messages.count,
           messages[idx].messageId == messageId {
            if let roleHint, messages[idx].role != roleHint {
                messages[idx].role = roleHint
                if roleHint == .user {
                    messages[idx].isStreaming = false
                    if streamingAssistantIndex == idx {
                        streamingAssistantIndex = nil
                    }
                }
            }
            messageRoleByMessageId[messageId] = messages[idx].role
            return idx
        }
        messageIndexByMessageId.removeValue(forKey: messageId)
        messageRoleByMessageId.removeValue(forKey: messageId)

        let resolvedRole = resolveIncomingRole(messageId: messageId, roleHint: roleHint)

        // 仅 assistant 消息复用本地占位气泡（发送时插入）。
        if resolvedRole == .assistant,
           (!awaitingUserEcho || roleHint == .assistant || pendingUserEchoAssistantMessageId == messageId),
           let idx = messages.lastIndex(where: { $0.role == .assistant && $0.messageId == nil && $0.isStreaming && $0.parts.isEmpty }) {
            messages[idx].messageId = messageId
            messages[idx].role = resolvedRole
            messageIndexByMessageId[messageId] = idx
            messageRoleByMessageId[messageId] = resolvedRole
            return idx
        }

        let msg = AIChatMessage(
            messageId: messageId,
            role: resolvedRole,
            parts: [],
            isStreaming: (resolvedRole == .assistant)
        )

        if resolvedRole == .assistant,
           awaitingUserEcho,
           pendingUserEchoAssistantMessageId == nil {
            pendingUserEchoAssistantMessageId = messageId
        }

        // 优先使用当前轮次 assistant 锚点，保证 user echo 晚到时插回正确位置。
        if resolvedRole == .user,
           let anchorMessageId = pendingUserEchoAssistantMessageId,
           let anchorIdx = messageIndexByMessageId[anchorMessageId],
           anchorIdx >= 0,
           anchorIdx < messages.count,
           messages[anchorIdx].role == .assistant {
            messages.insert(msg, at: anchorIdx)
            rebuildIndexes()
            if let idx = messageIndexByMessageId[messageId] {
                return idx
            }
            return anchorIdx
        }

        // 严格模式下，若 user echo 晚于 assistant 首包到达，需把 user 放到当前流式 assistant 前面。
        if resolvedRole == .user,
           awaitingUserEcho,
           let assistantIdx = streamingAssistantIndex,
           assistantIdx >= 0,
           assistantIdx < messages.count,
           messages[assistantIdx].role == .assistant,
           messages[assistantIdx].isStreaming {
            messages.insert(msg, at: assistantIdx)
            rebuildIndexes()
            if let idx = messageIndexByMessageId[messageId] {
                return idx
            }
            return assistantIdx
        }

        messages.append(msg)
        let idx = messages.count - 1
        messageIndexByMessageId[messageId] = idx
        messageRoleByMessageId[messageId] = resolvedRole
        return idx
    }

    private func resolveIncomingRole(messageId: String, roleHint: AIChatRole?) -> AIChatRole {
        if let roleHint {
            return roleHint
        }
        if let knownRole = messageRoleByMessageId[messageId] {
            return knownRole
        }
        guard awaitingUserEcho else {
            return .assistant
        }
        if let anchorMessageId = pendingUserEchoAssistantMessageId {
            return anchorMessageId == messageId ? .assistant : .user
        }
        // 严格模式下，发送后会先插入一个未绑定 message_id 的 assistant 占位。
        // role 未知时优先绑定占位，避免把 assistant 首包误判为 user。
        if hasUnboundAssistantPlaceholder() {
            return .assistant
        }
        return .assistant
    }

    private func hasUnboundAssistantPlaceholder() -> Bool {
        messages.contains { $0.role == .assistant && $0.messageId == nil && $0.isStreaming && $0.parts.isEmpty }
    }

    private func upsertPart(msgIdx: Int, part: AIProtocolPartInfo) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        let kind = AIChatPartKind(rawValue: part.partType) ?? .text

        if let existing = partIndexByPartId[part.id], existing.msgIdx == msgIdx,
           existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
            messages[msgIdx].parts[existing.partIdx].text = part.text
            messages[msgIdx].parts[existing.partIdx].mime = part.mime
            messages[msgIdx].parts[existing.partIdx].filename = part.filename
            messages[msgIdx].parts[existing.partIdx].url = part.url
            messages[msgIdx].parts[existing.partIdx].synthetic = part.synthetic
            messages[msgIdx].parts[existing.partIdx].ignored = part.ignored
            messages[msgIdx].parts[existing.partIdx].source = part.source
            messages[msgIdx].parts[existing.partIdx].toolName = part.toolName
            messages[msgIdx].parts[existing.partIdx].toolState = part.toolState
            messages[msgIdx].parts[existing.partIdx].toolCallId = part.toolCallId
            messages[msgIdx].parts[existing.partIdx].toolPartMetadata = part.toolPartMetadata
            if messages[msgIdx].role == .user, let messageId = messages[msgIdx].messageId {
                markUserEchoReceived(messageId: messageId)
            }
            return
        }

        partIndexByPartId.removeValue(forKey: part.id)
        let p = AIChatPart(
            id: part.id,
            kind: kind,
            text: part.text,
            mime: part.mime,
            filename: part.filename,
            url: part.url,
            synthetic: part.synthetic,
            ignored: part.ignored,
            source: part.source,
            toolName: part.toolName,
            toolState: part.toolState,
            toolCallId: part.toolCallId,
            toolPartMetadata: part.toolPartMetadata
        )
        messages[msgIdx].parts.append(p)
        let partIdx = messages[msgIdx].parts.count - 1
        partIndexByPartId[part.id] = (msgIdx, partIdx)
        if messages[msgIdx].role == .user, let messageId = messages[msgIdx].messageId {
            markUserEchoReceived(messageId: messageId)
        }
    }

    private func appendDelta(msgIdx: Int, partId: String, partType: String, field: String, delta: String) {
        guard field == "text" else { return }
        guard msgIdx >= 0, msgIdx < messages.count else { return }

        if let existing = partIndexByPartId[partId], existing.msgIdx == msgIdx,
           existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
            let current = messages[msgIdx].parts[existing.partIdx].text ?? ""
            messages[msgIdx].parts[existing.partIdx].text = current + delta
            if messages[msgIdx].role == .user, let messageId = messages[msgIdx].messageId {
                markUserEchoReceived(messageId: messageId)
            }
            return
        }

        let kind = AIChatPartKind(rawValue: partType) ?? .text
        let p = AIChatPart(id: partId, kind: kind, text: delta, toolName: nil, toolState: nil)
        messages[msgIdx].parts.append(p)
        let partIdx = messages[msgIdx].parts.count - 1
        partIndexByPartId[partId] = (msgIdx, partIdx)
        if messages[msgIdx].role == .user, let messageId = messages[msgIdx].messageId {
            markUserEchoReceived(messageId: messageId)
        }
    }

    private func markOnlyStreamingAssistant(at msgIdx: Int) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        guard messages[msgIdx].role == .assistant else { return }

        if let previous = streamingAssistantIndex,
           previous != msgIdx,
           previous >= 0, previous < messages.count,
           messages[previous].role == .assistant {
            messages[previous].isStreaming = false
        }

        messages[msgIdx].isStreaming = true
        streamingAssistantIndex = msgIdx
    }

    private func clearAssistantStreaming() {
        if let idx = streamingAssistantIndex,
           idx >= 0, idx < messages.count,
           messages[idx].role == .assistant {
            messages[idx].isStreaming = false
        } else {
            for i in messages.indices {
                guard messages[i].role == .assistant, messages[i].isStreaming else { continue }
                messages[i].isStreaming = false
            }
        }
        streamingAssistantIndex = nil
    }

    private func recomputeIsStreaming() {
        if let idx = streamingAssistantIndex,
           idx >= 0, idx < messages.count,
           messages[idx].role == .assistant,
           messages[idx].isStreaming {
            isStreaming = true
            return
        }
        streamingAssistantIndex = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming })
        if streamingAssistantIndex != nil {
            isStreaming = true
            return
        }

        // 历史回放场景：若工具仍处于 pending/running，视为会话仍在进行中。
        isStreaming = hasActiveAssistantTool()
    }

    private func hasActiveAssistantTool() -> Bool {
        for message in messages where message.role == .assistant {
            for part in message.parts where part.kind == .tool {
                guard let rawStatus = part.toolState?["status"] as? String else { continue }
                let status = rawStatus.lowercased()
                if status == "pending" || status == "running" {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - 图片附件

struct ImageAttachment: Identifiable {
    let id: String
    let filename: String
    let data: Data
    #if os(macOS)
    let thumbnail: NSImage
    #endif
    let mime: String

    init(filename: String, data: Data, mime: String) {
        self.id = UUID().uuidString
        self.filename = filename
        self.data = data
        self.mime = mime
        #if os(macOS)
        self.thumbnail = NSImage(data: data) ?? NSImage()
        #endif
    }
}

// MARK: - Provider / 模型

struct AIProviderInfo: Identifiable {
    let id: String
    let name: String
    let models: [AIModelInfo]
}

struct AIModelInfo: Identifiable {
    let id: String
    let name: String
    let providerID: String
    let supportsImageInput: Bool
}

struct AIModelSelection: Equatable {
    let providerID: String
    let modelID: String
}

// MARK: - Agent

struct AIAgentInfo: Identifiable {
    var id: String { name }
    let name: String
    let description: String?
    let mode: String?
    let color: String?
    /// agent 默认 provider ID
    let defaultProviderID: String?
    /// agent 默认 model ID
    let defaultModelID: String?
}

// MARK: - 斜杠命令（从后端获取）

struct AISlashCommandInfo: Identifiable {
    var id: String { name }
    /// 命令名（不含 / 前缀）
    let name: String
    /// 命令描述
    let description: String
    /// 执行方式："client"（前端本地执行）| "agent"（发送给 AI 代理）
    let action: String
}
