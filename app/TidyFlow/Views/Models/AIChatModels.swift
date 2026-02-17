import Foundation
#if os(macOS)
import AppKit
#endif

enum AIChatRole: String {
    case user
    case assistant
}

enum AIChatPartKind: String {
    case text
    case reasoning
    case tool
}

struct AIChatPart: Identifiable {
    let id: String
    let kind: AIChatPartKind
    var text: String?
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
    let role: AIChatRole
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
}

private enum AIChatStreamEvent {
    case messageUpdated(messageId: String)
    case partUpdated(messageId: String, part: AIProtocolPartInfo)
    case partDelta(messageId: String, partId: String, partType: String, field: String, delta: String)
}

/// AI 聊天状态域：隔离高频流式更新，避免全局 AppState 频繁刷新。
final class AIChatStore: ObservableObject {
    @Published var currentSessionId: String?
    @Published var messages: [AIChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var abortPendingSessionId: String?

    /// 工作空间快照缓存（key: "projectName/workspaceName"）
    var snapshotCache: [String: AIChatSnapshot] = [:]

    private var messageIndexByMessageId: [String: Int] = [:]
    private var partIndexByPartId: [String: (msgIdx: Int, partIdx: Int)] = [:]
    private var streamingAssistantIndex: Int?

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
            partIndexByPartId: partIndexByPartId
        )
    }

    // MARK: - Public State Ops

    func clearAll() {
        flushPendingStreamEvents()
        currentSessionId = nil
        messages = []
        abortPendingSessionId = nil
        isStreaming = false
        messageIndexByMessageId = [:]
        partIndexByPartId = [:]
        streamingAssistantIndex = nil
    }

    func clearMessages() {
        flushPendingStreamEvents()
        messages = []
        isStreaming = false
        messageIndexByMessageId = [:]
        partIndexByPartId = [:]
        streamingAssistantIndex = nil
    }

    func replaceMessages(_ newMessages: [AIChatMessage]) {
        flushPendingStreamEvents()
        messages = newMessages
        abortPendingSessionId = nil
        clearAssistantStreaming()
        isStreaming = false
        rebuildIndexes()
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

    func enqueueMessageUpdated(messageId: String) {
        pendingStreamEvents.append(.messageUpdated(messageId: messageId))
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

        for event in events {
            switch event {
            case .messageUpdated(let messageId):
                latestMessageIndex = ensureAssistantMessage(messageId: messageId)
            case .partUpdated(let messageId, let part):
                let msgIdx = ensureAssistantMessage(messageId: messageId)
                upsertPart(msgIdx: msgIdx, part: part)
                latestMessageIndex = msgIdx
            case .partDelta(let messageId, let partId, let partType, let field, let delta):
                let msgIdx = ensureAssistantMessage(messageId: messageId)
                appendDelta(msgIdx: msgIdx, partId: partId, partType: partType, field: field, delta: delta)
                latestMessageIndex = msgIdx
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
        isStreaming = false
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
        isStreaming = false
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
        partIndexByPartId = [:]
        streamingAssistantIndex = nil

        for (i, msg) in messages.enumerated() {
            if let mid = msg.messageId {
                messageIndexByMessageId[mid] = i
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
    private func ensureAssistantMessage(messageId: String) -> Int {
        if let idx = messageIndexByMessageId[messageId],
           idx < messages.count,
           messages[idx].messageId == messageId {
            return idx
        }
        messageIndexByMessageId.removeValue(forKey: messageId)

        // 优先复用本地占位气泡（发送时插入）。
        if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.messageId == nil && $0.isStreaming && $0.parts.isEmpty }) {
            messages[idx].messageId = messageId
            messageIndexByMessageId[messageId] = idx
            return idx
        }

        let msg = AIChatMessage(messageId: messageId, role: .assistant, parts: [], isStreaming: true)
        messages.append(msg)
        let idx = messages.count - 1
        messageIndexByMessageId[messageId] = idx
        return idx
    }

    private func upsertPart(msgIdx: Int, part: AIProtocolPartInfo) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        let kind = AIChatPartKind(rawValue: part.partType) ?? .text

        if let existing = partIndexByPartId[part.id], existing.msgIdx == msgIdx,
           existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
            messages[msgIdx].parts[existing.partIdx].text = part.text
            messages[msgIdx].parts[existing.partIdx].toolName = part.toolName
            messages[msgIdx].parts[existing.partIdx].toolState = part.toolState
            messages[msgIdx].parts[existing.partIdx].toolCallId = part.toolCallId
            messages[msgIdx].parts[existing.partIdx].toolPartMetadata = part.toolPartMetadata
            return
        }

        partIndexByPartId.removeValue(forKey: part.id)
        let p = AIChatPart(
            id: part.id,
            kind: kind,
            text: part.text,
            toolName: part.toolName,
            toolState: part.toolState,
            toolCallId: part.toolCallId,
            toolPartMetadata: part.toolPartMetadata
        )
        messages[msgIdx].parts.append(p)
        let partIdx = messages[msgIdx].parts.count - 1
        partIndexByPartId[part.id] = (msgIdx, partIdx)
    }

    private func appendDelta(msgIdx: Int, partId: String, partType: String, field: String, delta: String) {
        guard field == "text" else { return }
        guard msgIdx >= 0, msgIdx < messages.count else { return }

        if let existing = partIndexByPartId[partId], existing.msgIdx == msgIdx,
           existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
            let current = messages[msgIdx].parts[existing.partIdx].text ?? ""
            messages[msgIdx].parts[existing.partIdx].text = current + delta
            return
        }

        let kind = AIChatPartKind(rawValue: partType) ?? .text
        let p = AIChatPart(id: partId, kind: kind, text: delta, toolName: nil, toolState: nil)
        messages[msgIdx].parts.append(p)
        let partIdx = messages[msgIdx].parts.count - 1
        partIndexByPartId[partId] = (msgIdx, partIdx)
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
        isStreaming = (streamingAssistantIndex != nil)
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
