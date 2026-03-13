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

enum AIChatPerfFixtureFactory {
    private static let fixtureHistoryMessageCount = 48

    static func makeSeedMessages(
        project: String,
        workspace: String,
        sessionId: String,
        messageId: String,
        partId: String,
        longMarkdown: String
    ) -> [AIChatMessage] {
        let history = makeHistoryMessages(count: fixtureHistoryMessageCount)
        let assistantSeed = AIChatMessage(
            id: "fixture-local-\(messageId)",
            messageId: messageId,
            role: .assistant,
            parts: [
                AIChatPart(
                    id: partId,
                    kind: .text,
                    text: longMarkdown,
                    source: [
                        "fixture": true,
                        "project": project,
                        "workspace": workspace,
                        "session_id": sessionId
                    ]
                ),
                AIChatPart(
                    id: "\(partId)-reasoning",
                    kind: .reasoning,
                    text: """
                    - 目标：稳定回放 300 次 delta
                    - 约束：不依赖真实服务端
                    - 观测：尾消息刷新与内存快照
                    """
                ),
                AIChatPart(
                    id: "\(partId)-plan",
                    kind: .plan,
                    text: """
                    1. 预装轻量历史消息
                    2. 注入基线文本
                    3. 追加 300 次 delta
                    """
                )
            ],
            isStreaming: true,
            renderRevision: 1,
            timestamp: Date()
        )
        return history + [assistantSeed]
    }

    static func makeHistoryMessages(count: Int) -> [AIChatMessage] {
        (0..<count).map { index in
            let isUser = index.isMultiple(of: 2)
            let role: AIChatRole = isUser ? .user : .assistant
            let kind: AIChatPartKind = isUser ? .text : .reasoning
            let text: String = isUser
                ? "历史问题 #\(index + 1)：请总结项目 \(index % 5) 的上下文切换成本，并给出下一步建议。"
                : "历史回答 #\(index + 1)：已记录工作区边界、消息列表热路径与滚动状态。"
            return AIChatMessage(
                id: "fixture-history-\(index)",
                messageId: "fixture-history-msg-\(index)",
                role: role,
                parts: [
                    AIChatPart(
                        id: "fixture-history-part-\(index)",
                        kind: kind,
                        text: text
                    )
                ],
                isStreaming: false,
                renderRevision: 1,
                timestamp: Date().addingTimeInterval(Double(index - count))
            )
        }
    }

    static func longMarkdownBlock() -> String {
        """
        # Streaming Fixture

        用于聊天流式热路径观测的基线文本。

        - 历史消息窗口稳定性
        - delta 追加耗时
        - 完成态切换时序

        ```swift
        struct PerfFixtureToken: Sendable {
            let index: Int
            let flush: Int
        }
        ```
        """
    }

    static func makeDeltaFlushes(count: Int) -> [String] {
        (0..<count).map { index in
            " [\(index + 1)]"
        }
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

enum AIChatStreamEvent {
    case messageUpdated(messageId: String, role: String)
    case partUpdated(messageId: String, part: AIProtocolPartInfo)
    case partDelta(messageId: String, partId: String, partType: String, field: String, delta: String)
}

// MARK: - 流式 ingress 会话作用域

/// 流式事件作用域：用于隔离不同会话或同一会话不同代际的 pending 事件。
/// sessionId 标识远端会话，generation 为本地单调递增计数器，
/// 在 setCurrentSessionId/clearAll/clearMessages/replaceMessages 等入口处递增。
struct AIChatStreamScope: Equatable {
    let sessionId: String?
    let generation: UInt64
}

/// 携带作用域的流式事件包装：在 enqueue 时捕获当前作用域，
/// flush 时只应用与当前作用域匹配的事件，不匹配的直接丢弃。
struct ScopedAIChatStreamEvent {
    let scope: AIChatStreamScope
    let event: AIChatStreamEvent
}

/// 已从 ingress 队列摘出、等待主线程应用的 flush 批次。
/// 终态提交时需要与 pending 事件一起回收，避免“已排队但未应用”的 delta 丢失。
struct QueuedAIChatStreamFlush {
    let id: UInt64
    let scope: AIChatStreamScope
    let events: [AIChatStreamEvent]
    let rawEventCount: Int
    let rawUTF16Delta: Int
    let hadStructuralEvent: Bool
}

// MARK: - Prepared Snapshot

/// snapshot 分支的后台预处理结果；在后台线程构建，在主线程一次性提交。
/// 各端各路径共用同一类型，revision gate 由调用方在主线程执行，不在此方法内校验。
struct AIChatPreparedSnapshot {
    let messages: [AIChatMessage]
    let pendingQuestionRequests: [AIQuestionRequestInfo]
    let effectiveSelectionHint: AISessionSelectionHint?
    let isStreaming: Bool
    let fromRevision: UInt64
    let toRevision: UInt64
}

/// 在后台线程将协议消息归一化为 [AIChatMessage]，供所有 snapshot 分支共享。
/// 等价于 replaceMessagesFromSessionCache 内部的 role 映射 + part 去重逻辑。
enum AIChatPreparedSnapshotBuilder {
    static func build(
        protocolMessages: [AIProtocolMessageInfo],
        pendingQuestionRequests: [AIQuestionRequestInfo],
        effectiveSelectionHint: AISessionSelectionHint?,
        isStreaming: Bool,
        fromRevision: UInt64,
        toRevision: UInt64
    ) -> AIChatPreparedSnapshot {
        AIChatPreparedSnapshot(
            messages: normalizeMessages(protocolMessages),
            pendingQuestionRequests: pendingQuestionRequests,
            effectiveSelectionHint: effectiveSelectionHint,
            isStreaming: isStreaming,
            fromRevision: fromRevision,
            toRevision: toRevision
        )
    }

    /// 将协议消息列表归一化为视图层 AIChatMessage 列表，与 replaceMessagesFromSessionCache 内部逻辑等价。
    static func normalizeMessages(_ protocolMessages: [AIProtocolMessageInfo]) -> [AIChatMessage] {
        protocolMessages.map { message in
            let role: AIChatRole = (message.role == "assistant") ? .assistant : .user
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
    }
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
    /// pendingToolQuestions 的单调版本号；每次 question 集合变化时递增，
    /// 避免根视图读取整份字典来判断是否需要刷新投影。
    private(set) var pendingQuestionVersion: UInt64 = 0

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
    private var pendingStreamEvents: [ScopedAIChatStreamEvent] = []
    private var queuedMainThreadFlushes: [QueuedAIChatStreamFlush] = []
    private var streamFlushWorkItem: DispatchWorkItem?
    private let streamIngressQueue = DispatchQueue(
        label: "cn.tidyflow.ai.stream.reducer",
        qos: .userInitiated
    )
    private var lastPublishedTailSnapshot: [AIChatMessage] = []
    // 以下属性仅在 streamIngressQueue 上访问，用于批处理决策
    private var pendingHasStructuralEvent: Bool = false
    private var pendingUTF16DeltaCount: Int = 0
    private var nextQueuedMainThreadFlushID: UInt64 = 0
    /// 当前流式 ingress 作用域（主线程读写 generation，streamIngressQueue 读取 snapshot）
    private var streamScopeGeneration: UInt64 = 0
    /// streamIngressQueue 上缓存的作用域快照，由 invalidateStreamScope() 同步更新
    private var ingressScopeSnapshot: AIChatStreamScope = AIChatStreamScope(sessionId: nil, generation: 0)
    weak var performanceTracer: TFPerformanceTracer?
    var performanceContextProvider: (() -> (project: String, workspace: String)?)?

    /// 当前主线程作用域
    private var currentStreamScope: AIChatStreamScope {
        AIChatStreamScope(sessionId: currentSessionId, generation: streamScopeGeneration)
    }

    /// 当 sessionId 直接变更时，同步更新 ingress 队列使用的作用域快照，
    /// 避免结构性事件立即 flush 时仍按旧 session 过滤。
    private func syncIngressScopeSnapshotToCurrentScope() {
        let newScope = currentStreamScope
        streamIngressQueue.sync {
            ingressScopeSnapshot = newScope
        }
    }

    /// 失效旧作用域：递增 generation 并同步取消延迟 flush、清空 pending 事件。
    /// 必须在主线程调用（所有会改变消息归属的入口处）。
    private func invalidateStreamScope() {
        streamScopeGeneration &+= 1
        let newScope = currentStreamScope
        streamIngressQueue.sync {
            streamFlushWorkItem?.cancel()
            streamFlushWorkItem = nil
            if !pendingStreamEvents.isEmpty {
                TFLog.perf.debug(
                    "ai_stream_scope_invalidated dropped=\(self.pendingStreamEvents.count, privacy: .public) old_gen=\(newScope.generation &- 1, privacy: .public) new_gen=\(newScope.generation, privacy: .public)"
                )
            }
            pendingStreamEvents.removeAll(keepingCapacity: true)
            queuedMainThreadFlushes.removeAll(keepingCapacity: true)
            pendingHasStructuralEvent = false
            pendingUTF16DeltaCount = 0
            ingressScopeSnapshot = newScope
        }
    }

    /// 当前流式 ingress 作用域的 generation（测试用）
    var testStreamScopeGeneration: UInt64 { streamScopeGeneration }

    // MARK: - Snapshot

    func saveSnapshot(forKey key: String, sessions: [AISessionInfo]) {
        flushPendingStreamEvents()
        snapshotCache[key] = makeSnapshot(sessions: sessions)
    }

    func snapshot(forKey key: String) -> AIChatSnapshot? {
        snapshotCache[key]
    }

    func applySnapshot(_ snapshot: AIChatSnapshot) {
        invalidateStreamScope()
        currentSessionId = snapshot.currentSessionId
        syncIngressScopeSnapshotToCurrentScope()
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
        invalidateStreamScope()
        currentSessionId = nil
        syncIngressScopeSnapshotToCurrentScope()
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
        invalidateStreamScope()
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
        replaceMessages(newMessages, shouldPublishTailSignals: true)
    }

    private func replaceMessages(
        _ newMessages: [AIChatMessage],
        shouldPublishTailSignals: Bool
    ) {
        invalidateStreamScope()
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
        if shouldPublishTailSignals {
            publishTailSignals()
        }
    }

    func applyPerfFixtureScenario(_ scenario: AIChatPerfFixtureScenario) {
        currentSessionId = scenario.sessionId
        syncIngressScopeSnapshotToCurrentScope()
        subscribedSessionIds = [scenario.sessionId]
        messages = scenario.seedMessages
        historyHasMore = false
        historyNextBeforeMessageId = nil
        recentHistoryIsLoading = false
        historyIsLoading = false
        abortPendingSessionId = nil
        awaitingUserEcho = false
        hasPendingFirstContent = false
        lastUserEchoMessageId = nil
        pendingToolQuestions = [:]
        questionRequestToCallId = [:]
        pendingQuestionVersion = 0
        isStreaming = true
        streamingAssistantIndex = messages.indices.last
        rebuildIndexes()
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
        replaceMessages(mapped, shouldPublishTailSignals: false)
        if isStreaming,
           let assistantIndex = messages.indices.reversed().first(where: { messages[$0].role == .assistant }) {
            markOnlyStreamingAssistant(at: assistantIndex)
        }
        recomputeIsStreaming()
        publishTailSignals()
    }

    /// 主线程提交后台预处理的 snapshot 结果。
    /// revision gate 由调用方在主线程执行，不在此方法内校验。
    func applyPreparedSnapshot(_ snapshot: AIChatPreparedSnapshot) {
        // 使用不发布的 replaceMessages，最终只发布一次 tail 信号
        replaceMessages(snapshot.messages, shouldPublishTailSignals: false)
        if snapshot.isStreaming,
           let assistantIndex = messages.indices.reversed().first(where: { messages[$0].role == .assistant }) {
            markOnlyStreamingAssistant(at: assistantIndex)
        }
        recomputeIsStreaming()
        replaceQuestionRequests(snapshot.pendingQuestionRequests)
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
        // 在主线程捕获当前作用域快照
        let capturedScope = currentStreamScope
        streamIngressQueue.async { [weak self] in
            guard let self else { return }
            // 用捕获的作用域包装每个事件
            let scoped = events.map { ScopedAIChatStreamEvent(scope: capturedScope, event: $0) }
            self.pendingStreamEvents.append(contentsOf: scoped)
            // 分类事件：统计结构性事件与纯文本增量，供批处理决策使用
            for event in events {
                switch event {
                case .messageUpdated, .partUpdated:
                    self.pendingHasStructuralEvent = true
                case .partDelta(_, _, _, _, let delta):
                    self.pendingUTF16DeltaCount += delta.utf16.count
                }
            }
            self.scheduleStreamFlushIfNeeded()
        }
    }

    private func drainPreparedStreamEvents() -> [AIChatStreamEvent] {
        let scope = currentStreamScope
        return streamIngressQueue.sync {
            streamFlushWorkItem?.cancel()
            streamFlushWorkItem = nil
            let validEvents = pendingStreamEvents.compactMap { scoped -> AIChatStreamEvent? in
                guard scoped.scope == scope else { return nil }
                return scoped.event
            }
            let validQueuedFlushes = queuedMainThreadFlushes.filter { $0.scope == scope }
            let queuedEvents = validQueuedFlushes.flatMap(\.events)
            let droppedCount = pendingStreamEvents.count - validEvents.count
            let droppedQueuedCount = queuedMainThreadFlushes.count - validQueuedFlushes.count
            if droppedCount > 0 {
                TFLog.perf.debug(
                    "ai_stream_drain_dropped=\(droppedCount, privacy: .public) scope_gen=\(scope.generation, privacy: .public)"
                )
            }
            if droppedQueuedCount > 0 {
                TFLog.perf.debug(
                    "ai_stream_drain_queued_dropped=\(droppedQueuedCount, privacy: .public) scope_gen=\(scope.generation, privacy: .public)"
                )
            }
            pendingStreamEvents.removeAll(keepingCapacity: true)
            queuedMainThreadFlushes.removeAll(keepingCapacity: true)
            pendingHasStructuralEvent = false
            pendingUTF16DeltaCount = 0
            return Self.coalesceStreamEvents(validEvents + queuedEvents)
        }
    }

    private func flushPreparedStreamEventsFromIngressQueue() {
        let currentScope = ingressScopeSnapshot
        // 过滤：只保留与当前作用域匹配的事件
        var validRawEvents: [AIChatStreamEvent] = []
        var droppedCount = 0
        for scoped in pendingStreamEvents {
            if scoped.scope == currentScope {
                validRawEvents.append(scoped.event)
            } else {
                droppedCount += 1
            }
        }
        let rawUTF16Delta = pendingUTF16DeltaCount
        let hadStructuralEvent = pendingHasStructuralEvent
        pendingStreamEvents.removeAll(keepingCapacity: true)
        pendingHasStructuralEvent = false
        pendingUTF16DeltaCount = 0
        streamFlushWorkItem = nil
        if droppedCount > 0 {
            TFLog.perf.debug(
                "ai_stream_flush_dropped=\(droppedCount, privacy: .public) scope_gen=\(currentScope.generation, privacy: .public)"
            )
        }
        let events = Self.coalesceStreamEvents(validRawEvents)
        guard !events.isEmpty else { return }

        nextQueuedMainThreadFlushID &+= 1
        let flush = QueuedAIChatStreamFlush(
            id: nextQueuedMainThreadFlushID,
            scope: currentScope,
            events: events,
            rawEventCount: validRawEvents.count,
            rawUTF16Delta: rawUTF16Delta,
            hadStructuralEvent: hadStructuralEvent
        )
        queuedMainThreadFlushes.append(flush)
        DispatchQueue.main.async { [weak self] in
            self?.applyQueuedMainThreadFlush(flush.id)
        }
    }

    private static func coalesceStreamEvents(_ events: [AIChatStreamEvent]) -> [AIChatStreamEvent] {
        AIChatStreamCoalescer.coalesce(events)
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
            // 会话变化时失效旧作用域，丢弃旧会话的延迟 flush
            invalidateStreamScope()
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
        syncIngressScopeSnapshotToCurrentScope()
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
            pendingQuestionVersion += 1
            questionRequestToCallId[request.id] = callId
            return
        }
        // 其次使用 toolMessageId 作为 key
        if let messageId = request.toolMessageId, !messageId.isEmpty {
            pendingToolQuestions[messageId] = request
            pendingQuestionVersion += 1
            questionRequestToCallId[request.id] = messageId
            return
        }
        // 最后使用 request.id 作为 key，确保 question 总是被存储
        pendingToolQuestions[request.id] = request
        pendingQuestionVersion += 1
        questionRequestToCallId[request.id] = request.id
    }

    func clearQuestionRequest(requestId: String) {
        if let callId = questionRequestToCallId.removeValue(forKey: requestId) {
            pendingToolQuestions.removeValue(forKey: callId)
            pendingQuestionVersion += 1
            return
        }
        if let matched = pendingToolQuestions.first(where: { $0.value.id == requestId }) {
            pendingToolQuestions.removeValue(forKey: matched.key)
            pendingQuestionVersion += 1
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
        pendingQuestionVersion += 1
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

    /// 向指定 part 追加文本 delta，供性能 fixture 测试使用。
    func appendStreamDelta(partId: String, messageId: String, delta: String) {
        enqueuePartDelta(messageId: messageId, partId: partId, partType: "text", field: "text", delta: delta)
        flushPendingStreamEvents()
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
            guard let message = messages[safe: msgIdx] else { continue }
            if role == .user || (role == nil && message.role == .user) {
                markUserEchoReceived(messageId: messageId)
            }
            if message.role == .assistant {
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
                guard let message = messages[safe: msgIdx] else { continue }
                if message.role == .assistant {
                    if awaitingUserEcho,
                       pendingUserEchoAssistantMessageId == nil,
                       let assistantMessageId = message.messageId {
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
                guard let message = messages[safe: msgIdx] else { continue }
                if message.role == .assistant {
                    if awaitingUserEcho,
                       pendingUserEchoAssistantMessageId == nil,
                       let assistantMessageId = message.messageId {
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
        commitTerminalState(sessionId: sessionId)
    }

    func handleChatError(sessionId: String, error: String) {
        commitTerminalState(sessionId: sessionId)
        appendTerminalErrorMessage(error)
    }

    /// 终态提交入口：统一处理 terminal update、done、error 三类收敛。
    ///
    /// 固定执行顺序：
    /// 1. 校验作用域与 revision
    /// 2. 显式调用 flushPendingStreamEvents() 冲刷当前作用域待处理事件
    /// 3. 清除 streaming/abort/pending-first-content/question 等瞬态
    /// 4. 单次发布 tail 信号
    ///
    /// AppState 的终态分支（terminal update、done、error）统一调用此入口，
    /// 不再通过 `applySessionCacheOps([], isStreaming: false)` 间接收敛。
    func commitTerminalState(sessionId: String) {
        // 1. 终态立即冲刷当前作用域的待处理事件
        flushPendingStreamEvents()
        // 2. 失效作用域，阻止后续延迟 flush
        invalidateStreamScope()
        // 3. 清除瞬态
        clearAbortPendingIfMatches(sessionId)
        suppressActiveToolStreaming(for: sessionId)
        if awaitingUserEcho {
            awaitingUserEcho = false
            awaitingUserEchoBaselineIndex = nil
            lastUserEchoMessageId = "terminal-\(sessionId)-\(UUID().uuidString)"
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
        // 4. 单次发布 tail 信号
        publishTailSignals()
    }

    // MARK: - Internal Helpers

    func appendTerminalErrorMessage(_ error: String) {
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

    private func applyQueuedMainThreadFlush(_ flushID: UInt64) {
        let flush: QueuedAIChatStreamFlush? = streamIngressQueue.sync {
            guard let index = queuedMainThreadFlushes.firstIndex(where: { $0.id == flushID }) else {
                return nil
            }
            return queuedMainThreadFlushes.remove(at: index)
        }
        guard let flush else { return }
        guard currentStreamScope == flush.scope else {
            TFLog.perf.debug(
                "ai_stream_flush_rejected_on_main events=\(flush.events.count, privacy: .public) captured_gen=\(flush.scope.generation, privacy: .public) current_gen=\(self.currentStreamScope.generation, privacy: .public)"
            )
            return
        }
        let perfTraceId: String? = {
            guard let context = performanceContextProvider?(),
                  let tracer = performanceTracer else { return nil }
            return tracer.begin(TFPerformanceContext(
                event: .aiMessageTailFlush,
                project: context.project,
                workspace: context.workspace,
                metadata: [
                    "events": String(flush.events.count),
                    "raw_events": String(flush.rawEventCount),
                    "utf16_delta": String(flush.rawUTF16Delta),
                    "structural": flush.hadStructuralEvent ? "1" : "0",
                ]
            ))
        }()
        applyStreamEvents(flush.events)
        if let perfTraceId, let tracer = performanceTracer {
            tracer.end(perfTraceId)
        }
        TFLog.perf.debug(
            "ai_stream_commit events=\(flush.events.count, privacy: .public) raw_events=\(flush.rawEventCount, privacy: .public) utf16_delta=\(flush.rawUTF16Delta, privacy: .public) structural=\(flush.hadStructuralEvent ? 1 : 0, privacy: .public)"
        )
    }

    private func scheduleStreamFlushIfNeeded() {
        let input = AIChatStreamBatchInput(
            pendingEventCount: pendingStreamEvents.count,
            pendingUTF16Delta: pendingUTF16DeltaCount,
            containsStructuralEvent: pendingHasStructuralEvent,
            isStreamEnding: false
        )
        let decision = AIChatStreamingBatchScheduler.decide(input)

        if decision.shouldFlushImmediately {
            // 结构性事件：取消已排队的延迟 flush，立即执行
            streamFlushWorkItem?.cancel()
            streamFlushWorkItem = nil
            flushPreparedStreamEventsFromIngressQueue()
            return
        }

        // 纯 delta 批次：若已有调度则保留，不重复排队
        guard streamFlushWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPreparedStreamEventsFromIngressQueue()
        }
        streamFlushWorkItem = workItem
        streamIngressQueue.asyncAfter(deadline: .now() + decision.nextFlushDelay, execute: workItem)
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
        let summary = AIChatStreamCoalescer.summarizeTailChange(
            before: lastPublishedTailSnapshot,
            after: messages
        )
        if summary.hasMeaningfulChange {
            tailRevision &+= 1
        }
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
        lastPublishedTailSnapshot = messages
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

        if let partIdx = validatedPartIndex(part.id, in: msgIdx),
           var existingPart = messages[msgIdx].parts[safe: partIdx] {
            AIChatPartNormalization.apply(protocolPart: part, to: &existingPart)
            messages[msgIdx].parts[partIdx] = existingPart
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

    private func toolDeltaSectionIndex(in sections: [AIToolViewSection], field: String) -> Int? {
        let normalizedTitle = field == "progress" ? "progress" : "output"
        if let exactTitle = sections.firstIndex(where: { $0.title.caseInsensitiveCompare(normalizedTitle) == .orderedSame }) {
            return exactTitle
        }
        let fallbackID = field == "progress" ? "generic-progress" : "generic-output"
        return sections.firstIndex(where: { $0.id == fallbackID })
    }

    private func makeToolDeltaSection(field: String, content: String) -> AIToolViewSection {
        if field == "progress" {
            return AIToolViewSection(
                id: "generic-progress",
                title: "progress",
                content: content,
                style: .text,
                language: nil,
                copyable: true,
                collapsedByDefault: false
            )
        }
        return AIToolViewSection(
            id: "generic-output",
            title: "output",
            content: content,
            style: .code,
            language: "text",
            copyable: true,
            collapsedByDefault: false
        )
    }

    private func updatedToolView(
        from current: AIToolView?,
        sections: [AIToolViewSection]
    ) -> AIToolView {
        AIToolView(
            status: .running,
            displayTitle: current?.displayTitle ?? "unknown",
            statusText: current?.statusText ?? "running",
            summary: current?.summary,
            headerCommandSummary: current?.headerCommandSummary,
            durationMs: current?.durationMs,
            sections: sections,
            locations: current?.locations ?? [],
            question: current?.question,
            linkedSession: current?.linkedSession
        )
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
            if let partIdx = validatedPartIndex(partId, in: msgIdx),
               var part = messages[msgIdx].parts[safe: partIdx] {
                var sections = part.toolView?.sections ?? []
                if let index = toolDeltaSectionIndex(in: sections, field: field) {
                    guard var section = sections[safe: index] else { return }
                    if section.content.isEmpty {
                        section.content = delta
                    } else {
                        section.content.append("\n")
                        section.content.append(contentsOf: delta)
                    }
                    sections[index] = section
                } else {
                    sections.append(makeToolDeltaSection(field: field, content: delta))
                }
                part.toolView = updatedToolView(
                    from: part.toolView ?? AIToolView(
                        status: .running,
                        displayTitle: part.toolName ?? "unknown",
                        statusText: "running",
                        summary: nil,
                        headerCommandSummary: nil,
                        durationMs: nil,
                        sections: [],
                        locations: [],
                        question: nil,
                        linkedSession: nil
                    ),
                    sections: sections
                )
                part.kind = .tool
                messages[msgIdx].parts[partIdx] = part
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
                    sections: [makeToolDeltaSection(field: field, content: delta)],
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
            if let partIdx = validatedPartIndex(partId, in: msgIdx),
               var part = messages[msgIdx].parts[safe: partIdx] {
                var sections = part.toolView?.sections ?? []
                if let index = toolDeltaSectionIndex(in: sections, field: field) {
                    guard var section = sections[safe: index] else { return }
                    section.content.append(contentsOf: delta)
                    sections[index] = section
                } else {
                    sections.append(makeToolDeltaSection(field: field, content: delta))
                }
                part.toolView = updatedToolView(
                    from: part.toolView ?? AIToolView(
                        status: .running,
                        displayTitle: part.toolName ?? "unknown",
                        statusText: "running",
                        summary: nil,
                        headerCommandSummary: nil,
                        durationMs: nil,
                        sections: [],
                        locations: [],
                        question: nil,
                        linkedSession: nil
                    ),
                    sections: sections
                )
                part.kind = .tool
                messages[msgIdx].parts[partIdx] = part
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
                    sections: [makeToolDeltaSection(field: field, content: delta)],
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

        if let partIdx = validatedPartIndex(partId, in: msgIdx),
           var part = messages[msgIdx].parts[safe: partIdx] {
            if part.text != nil {
                part.text!.append(contentsOf: delta)
            } else {
                part.text = delta
            }
            messages[msgIdx].parts[partIdx] = part
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

    private func validatedPartIndex(_ partId: String, in msgIdx: Int) -> Int? {
        guard messages.indices.contains(msgIdx) else {
            partIndexByPartId.removeValue(forKey: partId)
            return nil
        }
        if let existing = partIndexByPartId[partId],
           existing.msgIdx == msgIdx,
           messages[msgIdx].parts.indices.contains(existing.partIdx) {
            return existing.partIdx
        }
        partIndexByPartId.removeValue(forKey: partId)
        guard let partIdx = messages[msgIdx].parts.firstIndex(where: { $0.id == partId }) else {
            return nil
        }
        partIndexByPartId[partId] = (msgIdx, partIdx)
        return partIdx
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
