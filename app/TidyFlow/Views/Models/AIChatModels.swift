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

    var iconAssetName: String {
        switch self {
        case .opencode: return "opencode-icon"
        case .codex: return "codex-icon"
        case .copilot: return "copilot-icon"
        }
    }
}

struct AIToolBadgeState: Equatable {
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
    var kind: AIChatPartKind
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

enum AIPlanImplementationQuestion {
    static let messageText = "Implement the plan."
    static let yesOption = "是，开始实现该计划"
    static let noOption = "否，保持计划模式"
    static let requestPrefix = "codex-plan-implementation-"

    static func isPlanAgentSelected(_ agentName: String?) -> Bool {
        let token = (agentName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !token.isEmpty else { return false }
        return token == "plan" || token.contains("plan")
    }

    static func isCodexPlanProposalPart(_ part: AIChatPart) -> Bool {
        guard let source = part.source else { return false }
        let itemType = (source["item_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let vendor = (source["vendor"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return itemType == "plan" && vendor == "codex"
    }

    static func requestId(sessionId: String, planPartId: String) -> String {
        "\(requestPrefix)\(sessionId)-\(planPartId)"
    }

    static func isPlanImplementationQuestionRequest(_ requestID: String) -> Bool {
        requestID.hasPrefix(requestPrefix)
    }

    static func shouldStartImplementation(_ answers: [[String]]) -> Bool {
        let choice = answers.first?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return choice == yesOption
    }

    static func hasCard(
        messages: [AIChatMessage],
        pendingQuestions: [String: AIQuestionRequestInfo],
        requestID: String
    ) -> Bool {
        if pendingQuestions.values.contains(where: { $0.id == requestID }) {
            return true
        }
        for message in messages {
            for part in message.parts where part.kind == .tool {
                let partRequestID =
                    (part.toolPartMetadata?["request_id"] as? String) ??
                    ((part.toolState?["metadata"] as? [String: Any])?["request_id"] as? String)
                if partRequestID == requestID {
                    return true
                }
            }
        }
        return false
    }

    static func buildRequest(requestID: String, sessionID: String, planPartID: String) -> AIQuestionRequestInfo {
        let question = AIQuestionInfo(
            question: "实现这个计划？",
            header: "计划已就绪",
            options: [
                AIQuestionOptionInfo(
                    label: yesOption,
                    description: "切换到 Default 模式并开始编码"
                ),
                AIQuestionOptionInfo(
                    label: noOption,
                    description: "继续完善计划，不开始实现"
                ),
            ],
            multiple: false,
            custom: false
        )

        let messageID = "codex-plan-action-msg-\(sessionID)-\(planPartID)"
        let callID = "codex-plan-action-call-\(sessionID)-\(planPartID)"
        return AIQuestionRequestInfo(
            id: requestID,
            sessionId: sessionID,
            questions: [question],
            toolMessageId: messageID,
            toolCallId: callID
        )
    }

    static func buildQuestionMessage(request: AIQuestionRequestInfo, planPartID: String) -> AIChatMessage {
        let messageID = request.toolMessageId ?? "codex-plan-action-msg-\(request.sessionId)-\(planPartID)"
        let callID = request.toolCallId ?? "codex-plan-action-call-\(request.sessionId)-\(planPartID)"
        let toolState: [String: Any] = [
            "status": "pending",
            "input": [
                "questions": [
                    [
                        "question": "实现这个计划？",
                        "header": "计划已就绪",
                        "options": [
                            ["label": yesOption, "description": "切换到 Default 模式并开始编码"],
                            ["label": noOption, "description": "继续完善计划，不开始实现"],
                        ],
                        "multiple": false,
                        "custom": false,
                    ],
                ],
            ],
            "metadata": [
                "request_id": request.id,
                "tool_message_id": messageID,
                "source": "codex_plan_implementation",
                "plan_part_id": planPartID,
            ],
        ]
        let part = AIChatPart(
            id: "codex-plan-action-part-\(request.sessionId)-\(planPartID)",
            kind: .tool,
            text: nil,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: ["vendor": "tidyflow", "type": "plan_implementation_question"],
            toolName: "question",
            toolState: toolState,
            toolCallId: callID,
            toolPartMetadata: [
                "request_id": request.id,
                "tool_message_id": messageID,
                "source": "codex_plan_implementation",
                "plan_part_id": planPartID,
            ]
        )
        return AIChatMessage(
            messageId: messageID,
            role: .assistant,
            parts: [part],
            isStreaming: false
        )
    }
}

enum AIAgentSelectionPolicy {
    static func defaultAgentName(from agents: [AIAgentInfo]) -> String {
        if let exact = agents.first(where: { $0.name.caseInsensitiveCompare("default") == .orderedSame }) {
            return exact.name
        }
        if let contains = agents.first(where: { $0.name.lowercased().contains("default") }) {
            return contains.name
        }
        if let nonPlan = agents.first(where: { !$0.name.lowercased().contains("plan") }) {
            return nonPlan.name
        }
        return "default"
    }
}

enum AIQuestionPartMatcher {
    static func candidateIDs(
        requestId: String,
        mappedKey: String?,
        request: AIQuestionRequestInfo?
    ) -> Set<String> {
        var ids: Set<String> = [requestId]
        if let mappedKey = normalizedString(mappedKey) {
            ids.insert(mappedKey)
        }
        if let toolCallId = normalizedString(request?.toolCallId) {
            ids.insert(toolCallId)
        }
        if let toolMessageId = normalizedString(request?.toolMessageId) {
            ids.insert(toolMessageId)
        }
        return ids
    }

    static func isQuestionPart(_ part: AIChatPart) -> Bool {
        guard part.kind == .tool else { return false }
        let toolName = (part.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return toolName == "question"
    }

    static func partMatches(_ part: AIChatPart, candidateIDs: Set<String>) -> Bool {
        if let callId = normalizedString(part.toolCallId),
           candidateIDs.contains(callId) {
            return true
        }
        if candidateIDs.contains(part.id) {
            return true
        }

        if let metadata = part.toolPartMetadata {
            if let requestId = normalizedString(metadata["request_id"]) ?? normalizedString(metadata["requestId"]),
               candidateIDs.contains(requestId) {
                return true
            }
            if let toolCallId = normalizedString(metadata["tool_call_id"]) ?? normalizedString(metadata["toolCallId"]),
               candidateIDs.contains(toolCallId) {
                return true
            }
            if let toolMessageId = normalizedString(metadata["tool_message_id"]) ?? normalizedString(metadata["toolMessageId"]),
               candidateIDs.contains(toolMessageId) {
                return true
            }
        }

        guard let toolState = part.toolState else { return false }
        if let requestId = normalizedString(toolState["request_id"]) ?? normalizedString(toolState["requestId"]),
           candidateIDs.contains(requestId) {
            return true
        }
        if let metadata = toolState["metadata"] as? [String: Any],
           let requestId = normalizedString(metadata["request_id"]) ?? normalizedString(metadata["requestId"]),
           candidateIDs.contains(requestId) {
            return true
        }
        return false
    }

    private static func normalizedString(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }
}

enum AIQuestionCompletionUpdater {
    static func applyCompletedState(
        to part: inout AIChatPart,
        requestId: String,
        answers: [[String]]?
    ) {
        var toolState = part.toolState ?? [:]
        toolState["status"] = "completed"

        var metadata = toolState["metadata"] as? [String: Any] ?? [:]
        metadata["request_id"] = requestId
        if let answers {
            metadata["answers"] = answers
        }
        toolState["metadata"] = metadata
        part.toolState = toolState
    }
}

enum AIQuestionLocalCompletion {
    @discardableResult
    static func apply(
        to messages: inout [AIChatMessage],
        requestId: String,
        mappedKey: String?,
        request: AIQuestionRequestInfo?,
        answers: [[String]]?,
        allowFallback: Bool = true
    ) -> Bool {
        let candidateIDs = AIQuestionPartMatcher.candidateIDs(
            requestId: requestId,
            mappedKey: mappedKey,
            request: request
        )

        var updated = false
        for msgIdx in messages.indices.reversed() {
            for partIdx in messages[msgIdx].parts.indices.reversed() {
                guard AIQuestionPartMatcher.isQuestionPart(messages[msgIdx].parts[partIdx]) else { continue }
                guard AIQuestionPartMatcher.partMatches(messages[msgIdx].parts[partIdx], candidateIDs: candidateIDs) else {
                    continue
                }
                AIQuestionCompletionUpdater.applyCompletedState(
                    to: &messages[msgIdx].parts[partIdx],
                    requestId: requestId,
                    answers: answers
                )
                updated = true
            }
        }

        if !updated, allowFallback, request != nil {
            var fallback: (msgIdx: Int, partIdx: Int)?
            for msgIdx in messages.indices.reversed() {
                for partIdx in messages[msgIdx].parts.indices.reversed() {
                    let part = messages[msgIdx].parts[partIdx]
                    guard AIQuestionPartMatcher.isQuestionPart(part), questionPartIsInteractive(part) else { continue }
                    fallback = (msgIdx, partIdx)
                    break
                }
                if fallback != nil {
                    break
                }
            }
            if let fallback {
                AIQuestionCompletionUpdater.applyCompletedState(
                    to: &messages[fallback.msgIdx].parts[fallback.partIdx],
                    requestId: requestId,
                    answers: answers
                )
                updated = true
            }
        }

        return updated
    }

    private static func questionPartIsInteractive(_ part: AIChatPart) -> Bool {
        let rawStatus = (part.toolState?["status"] as? String) ?? ""
        let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return status.isEmpty || status == "pending" || status == "running" || status == "unknown"
    }
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
    let aiTool: AIChatTool
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

/// 会话状态（由 Rust Core 统一维护并推送）
struct AISessionStatusSnapshot: Equatable {
    /// "idle" | "busy" | "error"
    let status: String
    let errorMessage: String?
    let contextRemainingPercent: Double?

    var isBusy: Bool { status.lowercased() == "busy" }
    var isError: Bool { status.lowercased() == "error" }
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
    /// 用户主动终止后，对应会话的“tool running 推导流式”本地抑制集合。
    /// 仅用于避免历史/陈旧 running 状态导致 UI 长期显示“终止中”。
    private var suppressedActiveToolSessions: Set<String> = []
    /// 当前轮次中 assistant 首条消息的锚点（用于 user echo 晚到时插回 assistant 之前）。
    private var pendingUserEchoAssistantMessageId: String?
    /// 进入 awaiting 前的消息数量快照；用于过滤“旧 user 消息更新”误触发收敛。
    private var awaitingUserEchoBaselineIndex: Int?
    /// 已绑定 message_id 的本地 user 占位，等待首个服务端 part 到达后替换，避免同气泡双文本。
    private var userPlaceholderMessageIdsPendingServerPart: Set<String> = []

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
        userPlaceholderMessageIdsPendingServerPart = []
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
        suppressedActiveToolSessions = []
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        userPlaceholderMessageIdsPendingServerPart = []
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
        suppressedActiveToolSessions = []
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        userPlaceholderMessageIdsPendingServerPart = []
    }

    func replaceMessages(_ newMessages: [AIChatMessage]) {
        flushPendingStreamEvents()
        messages = newMessages
        abortPendingSessionId = nil
        awaitingUserEcho = false
        lastUserEchoMessageId = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        userPlaceholderMessageIdsPendingServerPart = []
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

    /// 发送后立即插入用户消息占位（无 messageId），等待服务端 user echo 绑定真实 ID。
    func insertUserPlaceholder(text: String) {
        let textPart = AIChatPart(
            id: UUID().uuidString,
            kind: .text,
            text: text,
            toolName: nil,
            toolState: nil
        )
        let placeholder = AIChatMessage(
            role: .user,
            parts: [textPart],
            isStreaming: false
        )
        appendMessage(placeholder)
    }

    func setCurrentSessionId(_ sessionId: String?) {
        if currentSessionId != sessionId {
            // 首次发送（尚无会话）时，可能先插入本地 user 占位，再收到 session_started。
            // 此场景不能清空 awaitingUserEcho，否则后续 user echo 无法复用占位，产生重复气泡。
            let isFirstSendSessionBinding = currentSessionId == nil &&
                sessionId != nil &&
                awaitingUserEcho &&
                hasUnboundUserPlaceholder()

            pendingToolQuestions = [:]
            questionRequestToCallId = [:]
            if !isFirstSendSessionBinding {
                awaitingUserEcho = false
                lastUserEchoMessageId = nil
                pendingUserEchoAssistantMessageId = nil
                awaitingUserEchoBaselineIndex = nil
                userPlaceholderMessageIdsPendingServerPart = []
            }
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
        if let sessionId = currentSessionId {
            suppressedActiveToolSessions.remove(sessionId)
        }
        awaitingUserEcho = true
        lastUserEchoMessageId = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = messages.count
    }

    func suppressActiveToolStreaming(for sessionId: String) {
        guard !sessionId.isEmpty else { return }
        suppressedActiveToolSessions.insert(sessionId)
        recomputeIsStreaming()
    }

    func suppressActiveToolStreamingForCurrentSession() {
        guard let sessionId = currentSessionId else { return }
        suppressActiveToolStreaming(for: sessionId)
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
        // 优先使用 toolCallId 作为 key（与 tool part 的 callID 匹配）
        if let callId = request.toolCallId, !callId.isEmpty {
            pendingToolQuestions[callId] = request
            questionRequestToCallId[request.id] = callId
            return
        }
        // 其次使用 toolMessageId 作为 key
        if let messageId = request.toolMessageId, !messageId.isEmpty {
            pendingToolQuestions[messageId] = request
            questionRequestToCallId[request.id] = messageId
            return
        }
        // 最后使用 request.id 作为 key，确保 question 总是被存储
        pendingToolQuestions[request.id] = request
        questionRequestToCallId[request.id] = request.id
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

    /// 本地收敛 question：立即关闭交互并写入已选答案（如有），等待后端事件做最终一致。
    func completeQuestionRequestLocally(requestId: String, answers: [[String]]? = nil) {
        let mappedKey = questionRequestToCallId[requestId]
        let request = mappedKey.flatMap { pendingToolQuestions[$0] } ??
            pendingToolQuestions.first(where: { $0.value.id == requestId })?.value

        let updated = AIQuestionLocalCompletion.apply(
            to: &messages,
            requestId: requestId,
            mappedKey: mappedKey,
            request: request,
            answers: answers
        )

        clearQuestionRequest(requestId: requestId)
        if updated {
            recomputeIsStreaming()
        }
    }

    func questionRequest(forToolCallId callId: String?) -> AIQuestionRequestInfo? {
        guard let callId, !callId.isEmpty else { return nil }
        return pendingToolQuestions[callId]
    }

    func replaceQuestionRequests(_ requests: [AIQuestionRequestInfo]) {
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        for request in requests {
            upsertQuestionRequest(request)
        }
    }

    func questionRequest(forToolCallId callId: String?, toolMessageId: String?) -> AIQuestionRequestInfo? {
        questionRequest(forToolCallId: callId, toolPartId: nil, toolMessageId: toolMessageId)
    }

    func questionRequest(
        forToolCallId callId: String?,
        toolPartId: String?,
        toolMessageId: String?,
        requestId: String? = nil
    ) -> AIQuestionRequestInfo? {
        if let requestId, !requestId.isEmpty {
            if let mappedKey = questionRequestToCallId[requestId],
               let mapped = pendingToolQuestions[mappedKey] {
                return mapped
            }
            if let direct = pendingToolQuestions[requestId] {
                return direct
            }
            if let matched = pendingToolQuestions.first(where: { $0.value.id == requestId }) {
                return matched.value
            }
        }

        // 优先用 toolCallId 查找（对应 tool part 的 callID）
        if let callId, !callId.isEmpty, let request = pendingToolQuestions[callId] {
            return request
        }

        // 用 toolPartId 查找（可能是 part.id 或 request.id）
        if let toolPartId, !toolPartId.isEmpty {
            if let request = pendingToolQuestions[toolPartId] {
                return request
            }
            if let matched = pendingToolQuestions.first(where: { $0.value.toolMessageId == toolPartId }) {
                return matched.value
            }
        }

        // 用 toolMessageId 查找
        guard let toolMessageId, !toolMessageId.isEmpty else { return nil }
        if let request = pendingToolQuestions[toolMessageId] {
            return request
        }
        return pendingToolQuestions.first { $0.value.toolMessageId == toolMessageId }?.value
    }

    func stopStreamingLocallyAndPrunePlaceholder() {
        flushPendingStreamEvents()
        suppressActiveToolStreamingForCurrentSession()
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
        if let sessionId = currentSessionId {
            suppressedActiveToolSessions.remove(sessionId)
        }
        pendingStreamEvents.append(.messageUpdated(messageId: messageId, role: role))
        scheduleStreamFlushIfNeeded()
    }

    func enqueuePartUpdated(messageId: String, part: AIProtocolPartInfo) {
        if let sessionId = currentSessionId {
            suppressedActiveToolSessions.remove(sessionId)
        }
        pendingStreamEvents.append(.partUpdated(messageId: messageId, part: part))
        scheduleStreamFlushIfNeeded()
    }

    func enqueuePartDelta(messageId: String, partId: String, partType: String, field: String, delta: String) {
        if let sessionId = currentSessionId {
            suppressedActiveToolSessions.remove(sessionId)
        }
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
                    } else if hasUnboundUserPlaceholder() {
                        // 首次发送时若 user echo 先以 part.* 到达且缺少 role，
                        // 优先绑定本地用户占位，避免产生重复 user 气泡。
                        roleHint = .user
                        TFLog.app.debug(
                            "AI role inferred (user placeholder): message_id=\(messageId, privacy: .public), role=user, part_type=\(part.partType, privacy: .public)"
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
                    if hasUnboundUserPlaceholder() {
                        roleHint = .user
                    } else if let anchorMessageId = pendingUserEchoAssistantMessageId {
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
        suppressActiveToolStreaming(for: sessionId)
        // 严格模式兜底：若 user echo 未回传，也要收敛输入状态，避免输入框长期不清空/禁用。
        if awaitingUserEcho {
            awaitingUserEcho = false
            awaitingUserEchoBaselineIndex = nil
            lastUserEchoMessageId = "done-\(sessionId)-\(UUID().uuidString)"
        }
        userPlaceholderMessageIdsPendingServerPart = []
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
        suppressActiveToolStreaming(for: sessionId)
        awaitingUserEcho = false
        awaitingUserEchoBaselineIndex = nil
        pendingUserEchoAssistantMessageId = nil
        userPlaceholderMessageIdsPendingServerPart = []
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

        // user echo 到达时复用本地用户占位气泡（发送时通过 insertUserPlaceholder 插入）。
        if resolvedRole == .user,
           awaitingUserEcho,
           let idx = messages.lastIndex(where: { $0.role == .user && $0.messageId == nil }) {
            let hasLocalPlaceholderParts = !messages[idx].parts.isEmpty
            messages[idx].messageId = messageId
            messageIndexByMessageId[messageId] = idx
            messageRoleByMessageId[messageId] = resolvedRole
            if hasLocalPlaceholderParts {
                userPlaceholderMessageIdsPendingServerPart.insert(messageId)
            }
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

    private func hasUnboundUserPlaceholder() -> Bool {
        messages.contains { $0.role == .user && $0.messageId == nil }
    }

    private func upsertPart(msgIdx: Int, part: AIProtocolPartInfo) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        replaceUserPlaceholderPartsIfNeeded(msgIdx: msgIdx, incomingPartId: part.id)
        let kind = AIChatPartKind(rawValue: part.partType) ?? .text

        if let existing = partIndexByPartId[part.id], existing.msgIdx == msgIdx,
           existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
            messages[msgIdx].parts[existing.partIdx].kind = kind
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
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        replaceUserPlaceholderPartsIfNeeded(msgIdx: msgIdx, incomingPartId: partId)

        if field == "progress", partType == "tool" {
            if let existing = partIndexByPartId[partId], existing.msgIdx == msgIdx,
               existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
                var part = messages[msgIdx].parts[existing.partIdx]
                var toolState = part.toolState ?? [:]
                var metadata = toolState["metadata"] as? [String: Any] ?? [:]
                var lines = (metadata["progress_lines"] as? [String]) ?? []
                lines.append(delta)
                if lines.count > 300 {
                    lines.removeFirst(lines.count - 300)
                }
                metadata["progress_lines"] = lines
                toolState["metadata"] = metadata
                if toolState["status"] == nil {
                    toolState["status"] = "running"
                }
                part.toolState = toolState
                part.kind = .tool
                messages[msgIdx].parts[existing.partIdx] = part
                return
            }

            let p = AIChatPart(
                id: partId,
                kind: .tool,
                text: nil,
                mime: nil,
                filename: nil,
                url: nil,
                synthetic: nil,
                ignored: nil,
                source: nil,
                toolName: "unknown",
                toolState: [
                    "status": "running",
                    "metadata": [
                        "progress_lines": [delta],
                    ],
                ],
                toolCallId: nil,
                toolPartMetadata: nil
            )
            messages[msgIdx].parts.append(p)
            let partIdx = messages[msgIdx].parts.count - 1
            partIndexByPartId[partId] = (msgIdx, partIdx)
            return
        }

        if field == "output", partType == "tool" {
            if let existing = partIndexByPartId[partId], existing.msgIdx == msgIdx,
               existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
                var part = messages[msgIdx].parts[existing.partIdx]
                var toolState = part.toolState ?? [:]
                let currentOutput = (toolState["output"] as? String) ?? ""
                toolState["output"] = currentOutput + delta
                if toolState["status"] == nil {
                    toolState["status"] = "running"
                }
                part.toolState = toolState
                part.kind = .tool
                messages[msgIdx].parts[existing.partIdx] = part
                return
            }
            // output 增量先于 tool 全量 part 到达时，创建占位 tool part，避免丢失实时输出。
            let p = AIChatPart(
                id: partId,
                kind: .tool,
                text: nil,
                mime: nil,
                filename: nil,
                url: nil,
                synthetic: nil,
                ignored: nil,
                source: nil,
                toolName: "unknown",
                toolState: [
                    "status": "running",
                    "output": delta,
                ],
                toolCallId: nil,
                toolPartMetadata: nil
            )
            messages[msgIdx].parts.append(p)
            let partIdx = messages[msgIdx].parts.count - 1
            partIndexByPartId[partId] = (msgIdx, partIdx)
            return
        }

        guard field == "text" else { return }

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

    private func replaceUserPlaceholderPartsIfNeeded(msgIdx: Int, incomingPartId: String) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        guard messages[msgIdx].role == .user,
              let messageId = messages[msgIdx].messageId,
              userPlaceholderMessageIdsPendingServerPart.contains(messageId) else { return }
        // 若服务端 part_id 已存在，说明不是“首次覆盖”，仅清理标记。
        if partIndexByPartId[incomingPartId]?.msgIdx == msgIdx {
            userPlaceholderMessageIdsPendingServerPart.remove(messageId)
            return
        }
        for part in messages[msgIdx].parts {
            partIndexByPartId.removeValue(forKey: part.id)
        }
        messages[msgIdx].parts.removeAll(keepingCapacity: true)
        userPlaceholderMessageIdsPendingServerPart.remove(messageId)
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
        if normalizeStreamingAssistantIfNeeded() != nil {
            isStreaming = true
            return
        }

        let hasRunningTool = hasActiveAssistantTool()
        if hasRunningTool,
           let sessionId = currentSessionId,
           !suppressedActiveToolSessions.contains(sessionId) {
            isStreaming = true
            return
        }

        isStreaming = false
    }

    /// 流式消息理论上只会有一条；若出现多条并存，统一收敛到最新 assistant，避免历史气泡残留“加载中”。
    @discardableResult
    private func normalizeStreamingAssistantIfNeeded() -> Int? {
        let latestStreamingIdx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming })
        guard let latestStreamingIdx else {
            streamingAssistantIndex = nil
            return nil
        }

        for idx in messages.indices where idx != latestStreamingIdx {
            guard messages[idx].role == .assistant, messages[idx].isStreaming else { continue }
            messages[idx].isStreaming = false
        }
        streamingAssistantIndex = latestStreamingIdx
        return latestStreamingIdx
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

/// 历史会话最近一次输入选择提示（后端 best-effort 下发）
struct AISessionSelectionHint: Equatable {
    let agent: String?
    let modelProviderID: String?
    let modelID: String?

    var isEmpty: Bool {
        let agentEmpty = agent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let modelEmpty = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return agentEmpty && modelEmpty
    }
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
