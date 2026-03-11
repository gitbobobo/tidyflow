import Foundation
import Observation
import AppIntents

enum AIChatRole: String {
    case user
    case assistant
}

// AIChatTool, AISessionOrigin, AISessionSelectionHint 已迁移至 TidyFlowShared，
// 此处添加平台特有的视图层属性扩展。

extension AIChatTool {
    var displayName: String {
        switch self {
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        case .kimi: return "Kimi Code"
        case .claude_code: return "Claude Code"
        }
    }

    var iconAssetName: String {
        switch self {
        case .opencode: return "opencode-icon"
        case .codex: return "codex-icon"
        case .copilot: return "copilot-icon"
        case .kimi: return "kimi-icon"
        case .claude_code: return "claude-code-icon"
        }
    }
}

enum AISessionListFilter: Hashable, Identifiable, Equatable {
    case all
    case tool(AIChatTool)

    static var allOptions: [AISessionListFilter] {
        [.all] + AIChatTool.allCases.map { .tool($0) }
    }

    var id: String {
        switch self {
        case .all:
            return "all"
        case .tool(let tool):
            return tool.rawValue
        }
    }

    var displayName: String {
        switch self {
        case .all:
            return "全部"
        case .tool(let tool):
            return tool.displayName
        }
    }

    var iconAssetName: String? {
        switch self {
        case .all:
            return nil
        case .tool(let tool):
            return tool.iconAssetName
        }
    }

    var tool: AIChatTool? {
        switch self {
        case .all:
            return nil
        case .tool(let tool):
            return tool
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
    case plan
    case compaction
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
    var toolCallId: String? = nil
    var toolKind: String? = nil
    var toolView: AIToolView? = nil
}

enum AIChatPartNormalization {
    static func normalizedKind(from partType: String) -> AIChatPartKind {
        AIChatPartKind(rawValue: partType) ?? .text
    }

    static func apply(protocolPart: AIProtocolPartInfo, to part: inout AIChatPart) {
        part.kind = normalizedKind(from: protocolPart.partType)
        part.text = protocolPart.text
        part.mime = protocolPart.mime
        part.filename = protocolPart.filename
        part.url = protocolPart.url
        part.synthetic = protocolPart.synthetic
        part.ignored = protocolPart.ignored
        part.source = protocolPart.source
        part.toolName = protocolPart.toolName
        part.toolCallId = protocolPart.toolCallId
        part.toolKind = protocolPart.toolKind
        part.toolView = protocolPart.toolView
    }

    static func makeChatPart(from protocolPart: AIProtocolPartInfo) -> AIChatPart {
        AIChatPart(
            id: protocolPart.id,
            kind: normalizedKind(from: protocolPart.partType),
            text: protocolPart.text,
            mime: protocolPart.mime,
            filename: protocolPart.filename,
            url: protocolPart.url,
            synthetic: protocolPart.synthetic,
            ignored: protocolPart.ignored,
            source: protocolPart.source,
            toolName: protocolPart.toolName,
            toolCallId: protocolPart.toolCallId,
            toolKind: protocolPart.toolKind,
            toolView: protocolPart.toolView
        )
    }
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
                let partRequestID = part.toolView?.question?.requestID
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
                    optionID: nil,
                    label: yesOption,
                    description: "切换到 Default 模式并开始编码"
                ),
                AIQuestionOptionInfo(
                    optionID: nil,
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
        let toolView = AIToolView(
            status: .pending,
            displayTitle: "question",
            statusText: "pending",
            summary: nil,
            headerCommandSummary: nil,
            durationMs: nil,
            sections: [],
            locations: [],
            question: AIToolViewQuestion(
                requestID: request.id,
                toolMessageID: messageID,
                promptItems: [
                    AIQuestionInfo(
                        question: "实现这个计划？",
                        header: "计划已就绪",
                        options: [
                            AIQuestionOptionInfo(optionID: nil, label: yesOption, description: "切换到 Default 模式并开始编码"),
                            AIQuestionOptionInfo(optionID: nil, label: noOption, description: "继续完善计划，不开始实现"),
                        ],
                        multiple: false,
                        custom: false
                    ),
                ],
                interactive: true,
                answers: nil
            ),
            linkedSession: nil
        )
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
            toolCallId: callID,
            toolView: toolView
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
        guard let question = part.toolView?.question else { return false }
        if candidateIDs.contains(question.requestID) {
            return true
        }
        if let toolMessageId = normalizedString(question.toolMessageID),
           candidateIDs.contains(toolMessageId) {
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
        guard var toolView = part.toolView else { return }
        toolView = AIToolView(
            status: .completed,
            displayTitle: toolView.displayTitle,
            statusText: toolView.statusText,
            summary: toolView.summary,
            headerCommandSummary: toolView.headerCommandSummary,
            durationMs: toolView.durationMs,
            sections: toolView.sections,
            locations: toolView.locations,
            question: toolView.question.map {
                AIToolViewQuestion(
                    requestID: requestId,
                    toolMessageID: $0.toolMessageID,
                    promptItems: $0.promptItems,
                    interactive: false,
                    answers: answers
                )
            },
            linkedSession: toolView.linkedSession
        )
        part.toolView = toolView
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
        guard let toolView = part.toolView else { return false }
        return toolView.status == .pending || toolView.status == .running || toolView.status == .unknown
    }
}

// AIToolStatus 已迁移至 TidyFlowShared/Protocol/AIChatProtocolModels.swift，
// 此处添加平台视图层属性扩展。

extension AIToolStatus {
    var text: String { rawValue }
}

struct AIToolSection: Identifiable {
    let id: String
    let title: String
    let content: String
    let isCode: Bool
    /// 代码块语言标识（如 "swift"、"rust"、"bash"、"json"），仅在 isCode=true 时有意义
    var language: String?

    init(id: String, title: String, content: String, isCode: Bool, language: String? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.isCode = isCode
        self.language = language
    }
}

struct AIToolPresentation {
    let toolID: String
    let displayTitle: String
    let statusText: String
    let summary: String?
    let sections: [AIToolSection]
    /// 仅终端工具有值：头部独立展示的命令摘要（已截断），用于标题行下方的代码风格行。
    let headerCommandSummary: String?

    init(
        toolID: String,
        displayTitle: String,
        statusText: String,
        summary: String?,
        sections: [AIToolSection],
        headerCommandSummary: String? = nil
    ) {
        self.toolID = toolID
        self.displayTitle = displayTitle
        self.statusText = statusText
        self.summary = summary
        self.sections = sections
        self.headerCommandSummary = headerCommandSummary
    }
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
    /// 渲染修订号：每次可见内容变化时递增，用于低成本驱动 SwiftUI 刷新判定。
    var renderRevision: UInt32
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        messageId: String? = nil,
        role: AIChatRole,
        parts: [AIChatPart] = [],
        isStreaming: Bool = false,
        renderRevision: UInt32 = 0,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.messageId = messageId
        self.role = role
        self.parts = parts
        self.isStreaming = isStreaming
        self.renderRevision = renderRevision
        self.timestamp = timestamp
    }
}

struct AIAssistantTailPartMeta: Equatable {
    let messageId: String?
    let localMessageId: String
    let partId: String
    let kind: AIChatPartKind
    let source: [String: Any]?

    static func == (lhs: AIAssistantTailPartMeta, rhs: AIAssistantTailPartMeta) -> Bool {
        lhs.messageId == rhs.messageId &&
        lhs.localMessageId == rhs.localMessageId &&
        lhs.partId == rhs.partId &&
        lhs.kind == rhs.kind &&
        NSDictionary(dictionary: lhs.source ?? [:]).isEqual(to: rhs.source ?? [:])
    }
}

// MARK: - AISessionMessagesV2 平台侧扩展：转换为视图模型消息列表

extension AISessionMessagesV2 {
    func toChatMessages() -> [AIChatMessage] {
        messages.compactMap { message in
            let role: AIChatRole = (message.role == "assistant") ? .assistant : .user
            let parts: [AIChatPart] = message.parts.map { AIChatPartNormalization.makeChatPart(from: $0) }
            return AIChatMessage(messageId: message.id, role: role, parts: parts, isStreaming: false)
        }
    }
}

struct AISessionInfo: Identifiable, Equatable {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let id: String
    let title: String
    let updatedAt: Int64
    let origin: AISessionOrigin

    init(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        id: String,
        title: String,
        updatedAt: Int64,
        origin: AISessionOrigin = .user
    ) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.origin = origin
    }

    var sessionKey: String {
        AISessionSemantics.sessionKey(
            project: projectName,
            workspace: workspaceName,
            aiTool: aiTool,
            sessionId: id
        )
    }

    var isVisibleInDefaultSessionList: Bool {
        AISessionSemantics.isSessionVisibleInDefaultList(origin: origin)
    }

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

struct AISessionListPageState: Equatable {
    var sessions: [AISessionInfo] = []
    var hasMore: Bool = false
    var nextCursor: String? = nil
    var isLoadingInitial: Bool = false
    var isLoadingNextPage: Bool = false

    static func empty() -> AISessionListPageState {
        AISessionListPageState()
    }
}

/// 会话状态（由 Rust Core 统一维护并推送）
struct AISessionStatusSnapshot: Equatable {
    /// "idle" | "running" | "awaiting_input" | "success" | "failure" | "cancelled"
    let status: String
    let errorMessage: String?
    let contextRemainingPercent: Double?

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isActive: Bool {
        normalizedStatus == "busy" ||
        normalizedStatus == "running" ||
        normalizedStatus == "retry" ||
        normalizedStatus == "awaiting_input"
    }

    var isBusy: Bool { isActive }
    var isError: Bool { normalizedStatus == "error" || normalizedStatus == "failure" }
}

/// subscribe 发出后待 ack 的订阅上下文
struct AIPendingSubscribeContext {
    let session: AISessionInfo
    /// 待 unsubscribe 的旧会话 ID（切换会话时使用）
    let oldSessionId: String?
}

// MARK: - 工作空间快照（切换时保留对话上下文）

struct AIChatSnapshot {
    var currentSessionId: String?
    var subscribedSessionIds: Set<String>
    var messages: [AIChatMessage]
    var historyHasMore: Bool = false
    var historyNextBeforeMessageId: String? = nil
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
/// 使用 @Observable 实现按属性粒度的变更追踪，流式场景下仅读取变化属性的视图才重渲染。
@Observable
final class AIChatStore {
    var currentSessionId: String?
    var subscribedSessionIds: Set<String> = []
    var messages: [AIChatMessage] = []
    var historyHasMore: Bool = false
    var historyNextBeforeMessageId: String?
    /// 首屏最近页历史消息加载态；仅用于详情页首次打开/重载时的空白页加载反馈。
    var recentHistoryIsLoading: Bool = false
    var historyIsLoading: Bool = false
    var isStreaming: Bool = false
    var abortPendingSessionId: String?
    var awaitingUserEcho: Bool = false
    var lastUserEchoMessageId: String?
    var pendingToolQuestions: [String: AIQuestionRequestInfo] = [:]
    /// 已发送请求、等待服务端首个内容到达期间为 true；首个内容到达或会话结束/出错时清除。
    var hasPendingFirstContent: Bool = false
    /// 仅表示消息尾部可见内容发生变化，用于替代对整份 messages 的监听。
    private(set) var tailRevision: UInt64 = 0
    /// 最新 assistant 尾部 part 摘要，供上层做轻量判定，不必每次遍历整份消息。
    private(set) var latestAssistantPartMeta: AIAssistantTailPartMeta?

    /// 工作空间快照缓存（key: "projectName/workspaceName"）
    var snapshotCache: [String: AIChatSnapshot] = [:]

    private var messageIndexByMessageId: [String: Int] = [:]
    private var messageRoleByMessageId: [String: AIChatRole] = [:]
    private var partIndexByPartId: [String: (msgIdx: Int, partIdx: Int)] = [:]
    private var sessionCacheRevisionBySessionId: [String: UInt64] = [:]
    private var questionRequestToCallId: [String: String] = [:]
    private var streamingAssistantIndex: Int?
    /// assistant 工具 part 中 status=running/pending 的数量（增量维护，避免反复全量扫描）。
    private var runningToolPartCount: Int = 0
    /// 用户主动终止后，对应会话的“tool running 推导流式”本地抑制集合。
    /// 仅用于避免历史/陈旧 running 状态导致 UI 长期显示“终止中”。
    private var suppressedActiveToolSessions: Set<String> = []
    /// 当前轮次中 assistant 首条消息的锚点（用于 user echo 晚到时插回 assistant 之前）。
    private var pendingUserEchoAssistantMessageId: String?
    /// 进入 awaiting 前的消息数量快照；用于过滤“旧 user 消息更新”误触发收敛。
    private var awaitingUserEchoBaselineIndex: Int?
    private var pendingStreamEvents: [AIChatStreamEvent] = []
    private var streamFlushWorkItem: DispatchWorkItem?
    private let streamIngressQueue = DispatchQueue(
        label: "cn.tidyflow.ai.stream.reducer",
        qos: .userInitiated
    )
    private static let streamCommitInterval: TimeInterval = 0.05
    weak var performanceTracer: TFPerformanceTracer?
    var performanceContextProvider: (() -> (project: String, workspace: String)?)?

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
        subscribedSessionIds = snapshot.subscribedSessionIds
        if let currentSessionId {
            subscribedSessionIds.insert(currentSessionId)
        }
        messages = snapshot.messages
        historyHasMore = snapshot.historyHasMore
        historyNextBeforeMessageId = snapshot.historyNextBeforeMessageId
        recentHistoryIsLoading = false
        historyIsLoading = false
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
        publishTailSignals()
    }

    func makeSnapshot(sessions: [AISessionInfo]) -> AIChatSnapshot {
        AIChatSnapshot(
            currentSessionId: currentSessionId,
            subscribedSessionIds: subscribedSessionIds,
            messages: messages,
            historyHasMore: historyHasMore,
            historyNextBeforeMessageId: historyNextBeforeMessageId,
            isStreaming: isStreaming,
            sessions: sessions,
            messageIndexByMessageId: messageIndexByMessageId,
            partIndexByPartId: partIndexByPartId,
            pendingToolQuestions: pendingToolQuestions,
            questionRequestToCallId: questionRequestToCallId
        )
    }

    // MARK: - Public State Ops

    func addSubscription(_ sessionId: String) { subscribedSessionIds.insert(sessionId) }
    func removeSubscription(_ sessionId: String) { subscribedSessionIds.remove(sessionId) }

    func clearAll() {
        flushPendingStreamEvents()
        currentSessionId = nil
        // 清除所有会话订阅，防止旧会话流式事件在 clearAll 后仍被接受
        subscribedSessionIds = []
        messages = []
        historyHasMore = false
        historyNextBeforeMessageId = nil
        recentHistoryIsLoading = false
        historyIsLoading = false
        abortPendingSessionId = nil
        awaitingUserEcho = false
        hasPendingFirstContent = false
        lastUserEchoMessageId = nil
        isStreaming = false
        messageIndexByMessageId = [:]
        messageRoleByMessageId = [:]
        partIndexByPartId = [:]
        sessionCacheRevisionBySessionId = [:]
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        streamingAssistantIndex = nil
        runningToolPartCount = 0
        suppressedActiveToolSessions = []
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        publishTailSignals()
    }

    func clearMessages() {
        flushPendingStreamEvents()
        messages = []
        historyHasMore = false
        historyNextBeforeMessageId = nil
        recentHistoryIsLoading = false
        historyIsLoading = false
        awaitingUserEcho = false
        hasPendingFirstContent = false
        lastUserEchoMessageId = nil
        isStreaming = false
        messageIndexByMessageId = [:]
        messageRoleByMessageId = [:]
        partIndexByPartId = [:]
        sessionCacheRevisionBySessionId = [:]
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        streamingAssistantIndex = nil
        runningToolPartCount = 0
        suppressedActiveToolSessions = []
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        publishTailSignals()
    }

    func replaceMessages(_ newMessages: [AIChatMessage]) {
        flushPendingStreamEvents()
        messages = newMessages
        abortPendingSessionId = nil
        recentHistoryIsLoading = false
        historyIsLoading = false
        awaitingUserEcho = false
        hasPendingFirstContent = false
        lastUserEchoMessageId = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
        clearAssistantStreaming()
        isStreaming = false
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        rebuildIndexes()
        recomputeIsStreaming()
        publishTailSignals()
    }

    func replaceMessagesFromSessionCache(
        _ protocolMessages: [AIProtocolMessageInfo],
        isStreaming: Bool
    ) {
        let mapped = protocolMessages.map { message in
            let role: AIChatRole = (message.role == "assistant") ? .assistant : .user
            // Core 历史消息中，同一 tool_call_id 可能产生多次更新（运行中 → 完成），
            // 去重保留最后一次（最完整的合并状态），避免同一工具渲染多个卡片。
            var dedupedParts: [AIChatPart] = []
            var seenPartIds: [String: Int] = [:]
            for protoPart in message.parts {
                let chatPart = AIChatPartNormalization.makeChatPart(from: protoPart)
                if let existing = seenPartIds[chatPart.id] {
                    dedupedParts[existing] = chatPart
                } else {
                    seenPartIds[chatPart.id] = dedupedParts.count
                    dedupedParts.append(chatPart)
                }
            }
            return AIChatMessage(messageId: message.id, role: role, parts: dedupedParts, isStreaming: false)
        }
        replaceMessages(mapped)
        if isStreaming,
           let assistantIndex = messages.indices.reversed().first(where: { messages[$0].role == .assistant }) {
            markOnlyStreamingAssistant(at: assistantIndex)
        }
        recomputeIsStreaming()
        publishTailSignals()
    }

    func prependMessages(_ olderMessages: [AIChatMessage]) {
        guard !olderMessages.isEmpty else { return }
        flushPendingStreamEvents()

        let existingMessageIDs = Set(messages.compactMap(\.messageId))
        let existingLocalIDs = Set(messages.map(\.id))
        let filtered = olderMessages.filter { message in
            if let messageId = message.messageId {
                return !existingMessageIDs.contains(messageId)
            }
            return !existingLocalIDs.contains(message.id)
        }
        guard !filtered.isEmpty else { return }

        messages.insert(contentsOf: filtered, at: 0)
        rebuildIndexes()
        recomputeIsStreaming()
        publishTailSignals()
    }

    func setHistoryLoading(_ isLoading: Bool) {
        historyIsLoading = isLoading
    }

    func setRecentHistoryLoading(_ isLoading: Bool) {
        recentHistoryIsLoading = isLoading
    }

    func updateHistoryPagination(hasMore: Bool, nextBeforeMessageId: String?) {
        historyHasMore = hasMore
        historyNextBeforeMessageId = nextBeforeMessageId
        recentHistoryIsLoading = false
        historyIsLoading = false
    }

    func applySessionCacheOps(
        _ ops: [AIProtocolSessionCacheOp],
        isStreaming: Bool
    ) {
        let events = ops.map(Self.streamEvent(from:))
        if isStreaming {
            enqueuePreparedStreamEvents(events)
        } else {
            applyStreamEvents(events)
        }
        if !isStreaming {
            clearAssistantStreaming()
            self.isStreaming = false
            recomputeIsStreaming()
        }
    }

    private static func streamEvent(from op: AIProtocolSessionCacheOp) -> AIChatStreamEvent {
        switch op {
        case .messageUpdated(let messageId, let role):
            return .messageUpdated(messageId: messageId, role: role)
        case .partUpdated(let messageId, let part):
            return .partUpdated(messageId: messageId, part: part)
        case .partDelta(let messageId, let partId, let partType, let field, let delta):
            return .partDelta(messageId: messageId, partId: partId, partType: partType, field: field, delta: delta)
        }
    }

    private func enqueuePreparedStreamEvents(_ events: [AIChatStreamEvent]) {
        guard !events.isEmpty else { return }
        streamIngressQueue.async { [weak self] in
            guard let self else { return }
            self.pendingStreamEvents.append(contentsOf: events)
            self.scheduleStreamFlushIfNeeded()
        }
    }

    private func drainPreparedStreamEvents() -> [AIChatStreamEvent] {
        streamIngressQueue.sync {
            streamFlushWorkItem?.cancel()
            streamFlushWorkItem = nil
            let events = Self.coalesceStreamEvents(pendingStreamEvents)
            pendingStreamEvents.removeAll(keepingCapacity: true)
            return events
        }
    }

    private func flushPreparedStreamEventsFromIngressQueue() {
        let rawEvents = pendingStreamEvents
        pendingStreamEvents.removeAll(keepingCapacity: true)
        streamFlushWorkItem = nil
        let events = Self.coalesceStreamEvents(rawEvents)
        guard !events.isEmpty else { return }

        let rawEventCount = rawEvents.count
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let perfTraceId: String? = {
                guard let context = self.performanceContextProvider?(),
                      let tracer = self.performanceTracer else { return nil }
                return tracer.begin(TFPerformanceContext(
                    event: .aiMessageTailFlush,
                    project: context.project,
                    workspace: context.workspace,
                    metadata: [
                        "events": String(events.count),
                        "raw_events": String(rawEventCount),
                    ]
                ))
            }()
            self.applyStreamEvents(events)
            if let perfTraceId, let tracer = self.performanceTracer {
                tracer.end(perfTraceId)
            }
            TFLog.perf.debug(
                "ai_stream_commit events=\(events.count, privacy: .public) raw_events=\(rawEventCount, privacy: .public)"
            )
        }
    }

    private static func coalesceStreamEvents(_ events: [AIChatStreamEvent]) -> [AIChatStreamEvent] {
        guard !events.isEmpty else { return [] }

        var result: [AIChatStreamEvent] = []
        var pendingMessageUpdates: [String: String] = [:]
        var pendingMessageOrder: [String] = []
        var pendingDelta: AIChatStreamEvent?

        func flushMessageUpdates() {
            guard !pendingMessageOrder.isEmpty else { return }
            for messageId in pendingMessageOrder {
                if let role = pendingMessageUpdates.removeValue(forKey: messageId) {
                    result.append(.messageUpdated(messageId: messageId, role: role))
                }
            }
            pendingMessageOrder.removeAll(keepingCapacity: true)
        }

        func flushPendingDelta() {
            if let pendingDelta {
                result.append(pendingDelta)
            }
            pendingDelta = nil
        }

        for event in events {
            switch event {
            case .messageUpdated(let messageId, let role):
                flushPendingDelta()
                if pendingMessageUpdates[messageId] == nil {
                    pendingMessageOrder.append(messageId)
                }
                pendingMessageUpdates[messageId] = role
            case .partUpdated:
                flushMessageUpdates()
                flushPendingDelta()
                result.append(event)
            case .partDelta(let messageId, let partId, let partType, let field, let delta):
                flushMessageUpdates()
                if case let .partDelta(existingMessageId, existingPartId, existingPartType, existingField, existingDelta)? = pendingDelta,
                   existingMessageId == messageId,
                   existingPartId == partId,
                   existingPartType == partType,
                   existingField == field {
                    pendingDelta = .partDelta(
                        messageId: messageId,
                        partId: partId,
                        partType: partType,
                        field: field,
                        delta: existingDelta + delta
                    )
                } else {
                    flushPendingDelta()
                    pendingDelta = event
                }
            }
        }

        flushMessageUpdates()
        flushPendingDelta()
        return result
    }

    /// 仅接受单调不回退、且不出现 revision 断层的流式更新。
    @discardableResult
    func shouldApplySessionCacheRevision(
        fromRevision: UInt64,
        toRevision: UInt64,
        sessionId: String
    ) -> Bool {
        let current = sessionCacheRevisionBySessionId[sessionId] ?? 0
        guard toRevision >= current else { return false }
        guard current == 0 || fromRevision <= current else { return false }
        sessionCacheRevisionBySessionId[sessionId] = toRevision
        return true
    }

    func appendMessage(_ message: AIChatMessage) {
        flushPendingStreamEvents()
        messages.append(message)
        rebuildIndexes()
        recomputeIsStreaming()
        publishTailSignals()
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
            // 首次发送（尚无会话）时，session_started 可能先于 user echo / assistant 首包到达。
            // 该阶段必须保留等待态，避免输入区和流式状态提前收敛。
            let isFirstSendSessionBinding = currentSessionId == nil &&
                sessionId != nil &&
                hasPendingFirstContent

            pendingToolQuestions = [:]
            questionRequestToCallId = [:]
            if !isFirstSendSessionBinding {
                awaitingUserEcho = false
                lastUserEchoMessageId = nil
                pendingUserEchoAssistantMessageId = nil
                awaitingUserEchoBaselineIndex = nil
            }
            historyHasMore = false
            historyNextBeforeMessageId = nil
            recentHistoryIsLoading = false
            historyIsLoading = false
        }
        if let old = currentSessionId, old != sessionId {
            subscribedSessionIds.remove(old)
        }
        if let new = sessionId {
            subscribedSessionIds.insert(new)
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
        hasPendingFirstContent = true
        lastUserEchoMessageId = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = messages.count
    }

    func beginAwaitingAssistantOnly() {
        if let sessionId = currentSessionId {
            suppressedActiveToolSessions.remove(sessionId)
        }
        awaitingUserEcho = false
        hasPendingFirstContent = true
        lastUserEchoMessageId = nil
        pendingUserEchoAssistantMessageId = nil
        awaitingUserEchoBaselineIndex = nil
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
            touchRenderRevisionForAllMessages()
            rebuildIndexes()
            recomputeIsStreaming()
            publishTailSignals()
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
        publishTailSignals()
    }

    // MARK: - Streaming Batch Apply

    func enqueueMessageUpdated(messageId: String, role: String) {
        enqueuePreparedStreamEvents([.messageUpdated(messageId: messageId, role: role)])
    }

    func enqueuePartUpdated(messageId: String, part: AIProtocolPartInfo) {
        enqueuePreparedStreamEvents([.partUpdated(messageId: messageId, part: part)])
    }

    func enqueuePartDelta(messageId: String, partId: String, partType: String, field: String, delta: String) {
        enqueuePreparedStreamEvents([
            .partDelta(messageId: messageId, partId: partId, partType: partType, field: field, delta: delta)
        ])
    }

    func flushPendingStreamEvents() {
        let events = drainPreparedStreamEvents()
        applyStreamEvents(events)
    }

    private func applyStreamEvents(_ events: [AIChatStreamEvent]) {
        guard !events.isEmpty else { return }

        if hasPendingFirstContent {
            hasPendingFirstContent = false
        }

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
                // 取 max 确保始终指向最新（最大索引）的 assistant 消息，
                // 避免同批次中旧消息事件晚到导致流式指针回退。
                if let current = latestMessageIndex {
                    latestMessageIndex = max(current, msgIdx)
                } else {
                    latestMessageIndex = msgIdx
                }
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
                    if let anchorMessageId = pendingUserEchoAssistantMessageId {
                        roleHint = (anchorMessageId == messageId) ? .assistant : .user
                        TFLog.app.debug(
                            "AI role inferred (anchor): message_id=\(messageId, privacy: .public), role=\(roleHint?.rawValue ?? "nil", privacy: .public), anchor=\(anchorMessageId, privacy: .public), part_type=\(part.partType, privacy: .public)"
                        )
                    } else if part.partType == AIChatPartKind.file.rawValue {
                        roleHint = .user
                        TFLog.app.debug(
                            "AI role inferred (file part): message_id=\(messageId, privacy: .public), role=user, part_type=\(part.partType, privacy: .public)"
                        )
                    } else if hasUnboundAssistantPlaceholder() {
                        roleHint = .assistant
                        TFLog.app.debug(
                            "AI role inferred (pending-first-content): message_id=\(messageId, privacy: .public), role=assistant, part_type=\(part.partType, privacy: .public)"
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
                    if let current = latestMessageIndex {
                        latestMessageIndex = max(current, msgIdx)
                    } else {
                        latestMessageIndex = msgIdx
                    }
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
                    if let current = latestMessageIndex {
                        latestMessageIndex = max(current, msgIdx)
                    } else {
                        latestMessageIndex = msgIdx
                    }
                }
            }
        }

        if let idx = latestMessageIndex {
            markOnlyStreamingAssistant(at: idx)
        }
        recomputeIsStreaming()
        publishTailSignals()
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
        hasPendingFirstContent = false
        recentHistoryIsLoading = false
        isStreaming = false
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        clearAssistantStreaming()
        messages.removeAll { msg in
            msg.role == .assistant && msg.messageId == nil && msg.parts.isEmpty
        }
        rebuildIndexes()
        recomputeIsStreaming()
        publishTailSignals()
    }

    func handleChatError(sessionId: String, error: String) {
        flushPendingStreamEvents()
        clearAbortPendingIfMatches(sessionId)
        suppressActiveToolStreaming(for: sessionId)
        awaitingUserEcho = false
        hasPendingFirstContent = false
        awaitingUserEchoBaselineIndex = nil
        pendingUserEchoAssistantMessageId = nil
        recentHistoryIsLoading = false
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
                parts: [AIChatPart(id: UUID().uuidString, kind: .text, text: "⚠️ \(error)", toolName: nil)],
                isStreaming: false
            )
        )
        rebuildIndexes()
        recomputeIsStreaming()
        publishTailSignals()
    }

    // MARK: - Internal Helpers

    private func scheduleStreamFlushIfNeeded() {
        guard streamFlushWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPreparedStreamEventsFromIngressQueue()
        }
        streamFlushWorkItem = workItem
        streamIngressQueue.asyncAfter(deadline: .now() + Self.streamCommitInterval, execute: workItem)
    }

    private func rebuildIndexes() {
        messageIndexByMessageId = [:]
        messageRoleByMessageId = [:]
        partIndexByPartId = [:]
        streamingAssistantIndex = nil
        runningToolPartCount = 0

        for (i, msg) in messages.enumerated() {
            if let mid = msg.messageId {
                messageIndexByMessageId[mid] = i
                messageRoleByMessageId[mid] = msg.role
            }
            for (j, p) in msg.parts.enumerated() {
                partIndexByPartId[p.id] = (i, j)
                if msg.role == .assistant, isRunningToolPart(p) {
                    runningToolPartCount += 1
                }
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

    private func touchRenderRevision(at msgIdx: Int) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        messages[msgIdx].renderRevision &+= 1
    }

    private func touchRenderRevisionForAllMessages() {
        for idx in messages.indices {
            messages[idx].renderRevision &+= 1
        }
    }

    private func publishTailSignals() {
        tailRevision &+= 1
        latestAssistantPartMeta = messages.reversed().lazy
            .filter { $0.role == .assistant }
            .compactMap { message in
                guard let lastPart = message.parts.last else { return nil }
                return AIAssistantTailPartMeta(
                    messageId: message.messageId,
                    localMessageId: message.id,
                    partId: lastPart.id,
                    kind: lastPart.kind,
                    source: lastPart.source
                )
            }
            .first
    }

    private func isRunningToolPart(_ part: AIChatPart) -> Bool {
        guard part.kind == .tool else { return false }
        return part.toolView?.status == .pending || part.toolView?.status == .running
    }

    private func runningToolPartCount(in message: AIChatMessage) -> Int {
        guard message.role == .assistant else { return 0 }
        var count = 0
        for part in message.parts where isRunningToolPart(part) {
            count += 1
        }
        return count
    }

    private func updateRunningToolPartCount(forMessageAt msgIdx: Int, oldMessage: AIChatMessage) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        let oldCount = runningToolPartCount(in: oldMessage)
        let newCount = runningToolPartCount(in: messages[msgIdx])
        runningToolPartCount += (newCount - oldCount)
        if runningToolPartCount < 0 {
            runningToolPartCount = 0
        }
    }

    @discardableResult
    private func ensureMessage(messageId: String, roleHint: AIChatRole?) -> Int {
        if let idx = messageIndexByMessageId[messageId],
           idx < messages.count,
           messages[idx].messageId == messageId {
            let oldMessage = messages[idx]
            if let roleHint, messages[idx].role != roleHint {
                messages[idx].role = roleHint
                if roleHint == .user {
                    messages[idx].isStreaming = false
                    if streamingAssistantIndex == idx {
                        streamingAssistantIndex = nil
                    }
                }
            }
            if oldMessage.role != messages[idx].role || oldMessage.isStreaming != messages[idx].isStreaming {
                updateRunningToolPartCount(forMessageAt: idx, oldMessage: oldMessage)
                touchRenderRevision(at: idx)
            }
            messageRoleByMessageId[messageId] = messages[idx].role
            return idx
        }
        messageIndexByMessageId.removeValue(forKey: messageId)
        messageRoleByMessageId.removeValue(forKey: messageId)

        let resolvedRole = resolveIncomingRole(messageId: messageId, roleHint: roleHint)

        // 仅 assistant 消息复用本地流式占位气泡。
        if resolvedRole == .assistant,
           (!awaitingUserEcho || roleHint == .assistant || pendingUserEchoAssistantMessageId == messageId),
           let idx = messages.lastIndex(where: { $0.role == .assistant && $0.messageId == nil && $0.isStreaming && $0.parts.isEmpty }) {
            let oldMessage = messages[idx]
            messages[idx].messageId = messageId
            messages[idx].role = resolvedRole
            messageIndexByMessageId[messageId] = idx
            messageRoleByMessageId[messageId] = resolvedRole
            if oldMessage.role != messages[idx].role || oldMessage.isStreaming != messages[idx].isStreaming {
                updateRunningToolPartCount(forMessageAt: idx, oldMessage: oldMessage)
                touchRenderRevision(at: idx)
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
        if hasUnboundAssistantPlaceholder() {
            return .assistant
        }
        return .assistant
    }

    private func hasUnboundAssistantPlaceholder() -> Bool {
        if messages.contains(where: { $0.role == .assistant && $0.messageId == nil && $0.isStreaming && $0.parts.isEmpty }) {
            return true
        }
        // 无实体占位时，使用首包等待态作为回退，避免 assistant 首包被误判。
        return hasPendingFirstContent
    }

    private func upsertPart(msgIdx: Int, part: AIProtocolPartInfo) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        let oldMessage = messages[msgIdx]

        if let existing = partIndexByPartId[part.id], existing.msgIdx == msgIdx,
           existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
            var existingPart = messages[msgIdx].parts[existing.partIdx]
            AIChatPartNormalization.apply(protocolPart: part, to: &existingPart)
            messages[msgIdx].parts[existing.partIdx] = existingPart
            updateRunningToolPartCount(forMessageAt: msgIdx, oldMessage: oldMessage)
            touchRenderRevision(at: msgIdx)
            if messages[msgIdx].role == .user, let messageId = messages[msgIdx].messageId {
                markUserEchoReceived(messageId: messageId)
            }
            return
        }

        partIndexByPartId.removeValue(forKey: part.id)
        let p = AIChatPartNormalization.makeChatPart(from: part)
        messages[msgIdx].parts.append(p)
        let partIdx = messages[msgIdx].parts.count - 1
        partIndexByPartId[part.id] = (msgIdx, partIdx)
        updateRunningToolPartCount(forMessageAt: msgIdx, oldMessage: oldMessage)
        touchRenderRevision(at: msgIdx)
        if messages[msgIdx].role == .user, let messageId = messages[msgIdx].messageId {
            markUserEchoReceived(messageId: messageId)
        }
    }

    private func appendDelta(msgIdx: Int, partId: String, partType: String, field: String, delta: String) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        let oldMessage = messages[msgIdx]

        let normalizedPartType: String = {
            if partType == AIChatPartKind.tool.rawValue || field == "progress" || field == "output" {
                return AIChatPartKind.tool.rawValue
            }
            return partType
        }()

        if field == "progress", normalizedPartType == AIChatPartKind.tool.rawValue {
            if let existing = partIndexByPartId[partId], existing.msgIdx == msgIdx,
               existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
                var part = messages[msgIdx].parts[existing.partIdx]
                var sections = part.toolView?.sections ?? []
                if let index = sections.firstIndex(where: { $0.id == "generic-progress" }) {
                    if sections[index].content.isEmpty {
                        sections[index].content = delta
                    } else {
                        sections[index].content.append("\n")
                        sections[index].content.append(contentsOf: delta)
                    }
                } else {
                    sections.append(
                        AIToolViewSection(
                            id: "generic-progress",
                            title: "progress",
                            content: delta,
                            style: .text,
                            language: nil,
                            copyable: true,
                            collapsedByDefault: false
                        )
                    )
                }
                part.toolView = AIToolView(
                    status: .running,
                    displayTitle: part.toolView?.displayTitle ?? (part.toolName ?? "unknown"),
                    statusText: part.toolView?.statusText ?? "running",
                    summary: part.toolView?.summary,
                    headerCommandSummary: part.toolView?.headerCommandSummary,
                    durationMs: part.toolView?.durationMs,
                    sections: sections,
                    locations: part.toolView?.locations ?? [],
                    question: part.toolView?.question,
                    linkedSession: part.toolView?.linkedSession
                )
                part.kind = .tool
                messages[msgIdx].parts[existing.partIdx] = part
                updateRunningToolPartCount(forMessageAt: msgIdx, oldMessage: oldMessage)
                touchRenderRevision(at: msgIdx)
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
                toolCallId: nil,
                toolView: AIToolView(
                    status: .running,
                    displayTitle: "unknown",
                    statusText: "running",
                    summary: nil,
                    headerCommandSummary: nil,
                    durationMs: nil,
                    sections: [
                        AIToolViewSection(
                            id: "generic-progress",
                            title: "progress",
                            content: delta,
                            style: .text,
                            language: nil,
                            copyable: true,
                            collapsedByDefault: false
                        ),
                    ],
                    locations: [],
                    question: nil,
                    linkedSession: nil
                )
            )
            messages[msgIdx].parts.append(p)
            let partIdx = messages[msgIdx].parts.count - 1
            partIndexByPartId[partId] = (msgIdx, partIdx)
            updateRunningToolPartCount(forMessageAt: msgIdx, oldMessage: oldMessage)
            touchRenderRevision(at: msgIdx)
            return
        }

        if field == "output", normalizedPartType == AIChatPartKind.tool.rawValue {
            if let existing = partIndexByPartId[partId], existing.msgIdx == msgIdx,
               existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
                var part = messages[msgIdx].parts[existing.partIdx]
                var sections = part.toolView?.sections ?? []
                if let index = sections.firstIndex(where: { $0.id == "generic-output" }) {
                    sections[index].content.append(contentsOf: delta)
                } else {
                    sections.append(
                        AIToolViewSection(
                            id: "generic-output",
                            title: "output",
                            content: delta,
                            style: .code,
                            language: "text",
                            copyable: true,
                            collapsedByDefault: false
                        )
                    )
                }
                part.toolView = AIToolView(
                    status: .running,
                    displayTitle: part.toolView?.displayTitle ?? (part.toolName ?? "unknown"),
                    statusText: part.toolView?.statusText ?? "running",
                    summary: part.toolView?.summary,
                    headerCommandSummary: part.toolView?.headerCommandSummary,
                    durationMs: part.toolView?.durationMs,
                    sections: sections,
                    locations: part.toolView?.locations ?? [],
                    question: part.toolView?.question,
                    linkedSession: part.toolView?.linkedSession
                )
                part.kind = .tool
                messages[msgIdx].parts[existing.partIdx] = part
                updateRunningToolPartCount(forMessageAt: msgIdx, oldMessage: oldMessage)
                touchRenderRevision(at: msgIdx)
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
                toolCallId: nil,
                toolView: AIToolView(
                    status: .running,
                    displayTitle: "unknown",
                    statusText: "running",
                    summary: nil,
                    headerCommandSummary: nil,
                    durationMs: nil,
                    sections: [
                        AIToolViewSection(
                            id: "generic-output",
                            title: "output",
                            content: delta,
                            style: .code,
                            language: "text",
                            copyable: true,
                            collapsedByDefault: false
                        ),
                    ],
                    locations: [],
                    question: nil,
                    linkedSession: nil
                )
            )
            messages[msgIdx].parts.append(p)
            let partIdx = messages[msgIdx].parts.count - 1
            partIndexByPartId[partId] = (msgIdx, partIdx)
            updateRunningToolPartCount(forMessageAt: msgIdx, oldMessage: oldMessage)
            touchRenderRevision(at: msgIdx)
            return
        }

        guard field == "text" else { return }

        if let existing = partIndexByPartId[partId], existing.msgIdx == msgIdx,
           existing.partIdx >= 0, existing.partIdx < messages[msgIdx].parts.count {
            if messages[msgIdx].parts[existing.partIdx].text != nil {
                messages[msgIdx].parts[existing.partIdx].text!.append(contentsOf: delta)
            } else {
                messages[msgIdx].parts[existing.partIdx].text = delta
            }
            updateRunningToolPartCount(forMessageAt: msgIdx, oldMessage: oldMessage)
            touchRenderRevision(at: msgIdx)
            if messages[msgIdx].role == .user, let messageId = messages[msgIdx].messageId {
                markUserEchoReceived(messageId: messageId)
            }
            return
        }

        let kind = AIChatPartKind(rawValue: normalizedPartType) ?? .text
        let p = AIChatPart(id: partId, kind: kind, text: delta, toolName: nil)
        messages[msgIdx].parts.append(p)
        let partIdx = messages[msgIdx].parts.count - 1
        partIndexByPartId[partId] = (msgIdx, partIdx)
        updateRunningToolPartCount(forMessageAt: msgIdx, oldMessage: oldMessage)
        touchRenderRevision(at: msgIdx)
        if messages[msgIdx].role == .user, let messageId = messages[msgIdx].messageId {
            markUserEchoReceived(messageId: messageId)
        }
    }

    private func markOnlyStreamingAssistant(at msgIdx: Int) {
        guard msgIdx >= 0, msgIdx < messages.count else { return }
        guard messages[msgIdx].role == .assistant else { return }

        // 清除所有其他 streaming assistant，不仅限于缓存的 streamingAssistantIndex，
        // 防止同批次内 ensureMessage 新建的多条 assistant 消息同时保持 isStreaming=true。
        for i in messages.indices where i != msgIdx {
            guard messages[i].role == .assistant, messages[i].isStreaming else { continue }
            messages[i].isStreaming = false
            touchRenderRevision(at: i)
        }

        let wasStreaming = messages[msgIdx].isStreaming
        messages[msgIdx].isStreaming = true
        if !wasStreaming {
            touchRenderRevision(at: msgIdx)
        }
        streamingAssistantIndex = msgIdx
    }

    private func clearAssistantStreaming() {
        if let idx = streamingAssistantIndex,
           idx >= 0, idx < messages.count,
           messages[idx].role == .assistant {
            if messages[idx].isStreaming {
                messages[idx].isStreaming = false
                touchRenderRevision(at: idx)
            }
        } else {
            for i in messages.indices {
                guard messages[i].role == .assistant, messages[i].isStreaming else { continue }
                messages[i].isStreaming = false
                touchRenderRevision(at: i)
            }
        }
        streamingAssistantIndex = nil
    }

    private func recomputeIsStreaming() {
        let newValue: Bool
        if normalizeStreamingAssistantIfNeeded() != nil {
            newValue = true
        } else {
            if runningToolPartCount > 0,
               let sessionId = currentSessionId,
               !suppressedActiveToolSessions.contains(sessionId) {
                newValue = true
            } else {
                newValue = false
            }
        }
        guard isStreaming != newValue else { return }
        isStreaming = newValue
    }

    /// 流式消息理论上只会有一条；若出现多条并存，统一收敛到最新 assistant，避免历史气泡残留“加载中”。
    @discardableResult
    private func normalizeStreamingAssistantIfNeeded() -> Int? {
        // 快速路径：缓存的 streamingAssistantIndex 仍然有效时直接返回，避免 O(n) 扫描
        if let idx = streamingAssistantIndex,
           idx >= 0, idx < messages.count,
           messages[idx].role == .assistant,
           messages[idx].isStreaming {
            return idx
        }

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
}

// MARK: - 图片附件

struct ImageAttachment: Identifiable {
    let id: String
    let filename: String
    let data: Data
    let mime: String

    init(filename: String, data: Data, mime: String) {
        self.id = UUID().uuidString
        self.filename = filename
        self.data = data
        self.mime = mime
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
    let variants: [String]
}

struct AIModelSelection: Equatable {
    let providerID: String
    let modelID: String
}

/// 历史会话最近一次输入选择提示（后端 best-effort 下发）
// AISessionSelectionHint 已迁移至 TidyFlowShared/Protocol/AIChatProtocolModels.swift

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

struct AISlashCommandInfo: Identifiable, Equatable {
    var id: String { name }
    /// 命令名（不含 / 前缀）
    let name: String
    /// 命令描述
    let description: String
    /// 执行方式："client"（前端本地执行）| "agent"（发送给 AI 代理）
    let action: String
    /// 输入提示（可选），用于补全时插入参数模板
    let inputHint: String?
}
