import Foundation

struct AIChatMessageDisplayNode: Equatable, Identifiable {
    let part: AIChatPart

    var id: String {
        part.id
    }

    static func == (lhs: AIChatMessageDisplayNode, rhs: AIChatMessageDisplayNode) -> Bool {
        partSignature(lhs.part) == partSignature(rhs.part)
    }

    private static func partSignature(_ part: AIChatPart) -> PartSignature {
        PartSignature(
            id: part.id,
            kind: part.kind,
            text: part.text,
            mime: part.mime,
            filename: part.filename,
            url: part.url,
            synthetic: part.synthetic,
            ignored: part.ignored,
            toolName: part.toolName,
            toolCallId: part.toolCallId,
            toolKind: part.toolKind,
            toolStatus: part.toolView?.status,
            toolSectionsCount: part.toolView?.sections.count ?? 0,
            toolLastSectionContentLength: part.toolView?.sections.last?.content.count ?? 0,
            toolDurationMs: part.toolView?.durationMs,
            toolQuestionInteractive: part.toolView?.question?.interactive
        )
    }

    private struct PartSignature: Equatable {
        let id: String
        let kind: AIChatPartKind
        let text: String?
        let mime: String?
        let filename: String?
        let url: String?
        let synthetic: Bool?
        let ignored: Bool?
        let toolName: String?
        let toolCallId: String?
        let toolKind: String?
        // toolView 关键信号，避免完整 toolView Equatable 的开销，同时捕获主要变化
        let toolStatus: AIToolStatus?
        let toolSectionsCount: Int
        let toolLastSectionContentLength: Int
        let toolDurationMs: Double?
        let toolQuestionInteractive: Bool?
    }
}

struct AIChatPendingInteraction: Equatable, Identifiable {
    enum Kind: Equatable {
        case question
    }

    let id: String
    let kind: Kind
    let request: AIQuestionRequestInfo
    let title: String
    let detail: String?
    let sourceMessageId: String?

    static func make(
        request: AIQuestionRequestInfo,
        part: AIChatPart?,
        sourceMessageId: String?
    ) -> AIChatPendingInteraction {
        let titleToken = request.questions.lazy
            .map(\.header)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let fallbackTitle = (part?.toolName ?? part?.toolView?.displayTitle ?? "需要你的反馈")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleToken ?? (fallbackTitle.isEmpty ? "需要你的反馈" : fallbackTitle)
        let detail = request.questions.first?.question
        return AIChatPendingInteraction(
            id: request.id,
            kind: .question,
            request: request,
            title: title,
            detail: detail,
            sourceMessageId: sourceMessageId
        )
    }

    static func == (lhs: AIChatPendingInteraction, rhs: AIChatPendingInteraction) -> Bool {
        lhs.id == rhs.id &&
            lhs.kind == rhs.kind &&
            lhs.title == rhs.title &&
            lhs.detail == rhs.detail &&
            lhs.sourceMessageId == rhs.sourceMessageId &&
            lhs.request.id == rhs.request.id &&
            lhs.request.sessionId == rhs.request.sessionId &&
            lhs.request.questions == rhs.request.questions &&
            lhs.request.toolMessageId == rhs.request.toolMessageId &&
            lhs.request.toolCallId == rhs.request.toolCallId
    }
}

struct AIChatPendingInteractionQueue: Equatable {
    let active: AIChatPendingInteraction?
    let queued: [AIChatPendingInteraction]

    static let empty = AIChatPendingInteractionQueue(active: nil, queued: [])

    var queuedCount: Int {
        queued.count
    }

    var hasPendingInteraction: Bool {
        active != nil
    }
}

enum AIChatMessageLayoutSemantics {
    static func displayNodes(
        for message: AIChatMessage,
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> [AIChatMessageDisplayNode] {
        message.parts.compactMap { part in
            guard shouldRender(part: part, in: message, pendingQuestions: pendingQuestions) else {
                return nil
            }
            return AIChatMessageDisplayNode(part: part)
        }
    }

    static func hasRenderableContent(
        in message: AIChatMessage,
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> Bool {
        message.parts.contains { part in
            shouldRender(part: part, in: message, pendingQuestions: pendingQuestions)
        }
    }

    static func pendingInteractionQueue(
        messages: [AIChatMessage],
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> AIChatPendingInteractionQueue {
        guard !pendingQuestions.isEmpty else { return .empty }

        var interactions: [AIChatPendingInteraction] = []
        var seen: Set<String> = []

        for message in messages.reversed() {
            for part in message.parts.reversed() {
                guard let request = pendingRequest(
                    for: part,
                    in: message,
                    pendingQuestions: pendingQuestions
                ) else { continue }
                guard seen.insert(request.id).inserted else { continue }
                interactions.append(
                    AIChatPendingInteraction.make(
                        request: request,
                        part: part,
                        sourceMessageId: message.messageId
                    )
                )
            }
        }

        if interactions.isEmpty {
            let deduped = uniqueRequests(from: pendingQuestions)
            guard let active = deduped.first else { return .empty }
            let remaining = Array(deduped.dropFirst()).map {
                AIChatPendingInteraction.make(request: $0, part: nil, sourceMessageId: nil)
            }
            return AIChatPendingInteractionQueue(
                active: AIChatPendingInteraction.make(request: active, part: nil, sourceMessageId: nil),
                queued: remaining
            )
        }

        return AIChatPendingInteractionQueue(
            active: interactions.first,
            queued: Array(interactions.dropFirst())
        )
    }

    private static func shouldRender(
        part: AIChatPart,
        in message: AIChatMessage,
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> Bool {
        switch part.kind {
        case .text, .reasoning:
            guard let text = part.text else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .tool:
            return pendingRequest(for: part, in: message, pendingQuestions: pendingQuestions) == nil
        case .file, .plan, .compaction:
            return true
        }
    }

    static func pendingRequest(
        for part: AIChatPart,
        in message: AIChatMessage,
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> AIQuestionRequestInfo? {
        guard part.kind == .tool else { return nil }
        guard let question = part.toolView?.question, question.interactive else { return nil }

        let candidates: [String?] = [
            question.requestID,
            part.toolCallId,
            part.id,
            question.toolMessageID,
            message.messageId
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if let direct = pendingQuestions[candidate] {
                return direct
            }
        }

        return pendingQuestions.values.first { request in
            request.id == question.requestID ||
            request.toolCallId == part.toolCallId ||
            request.toolMessageId == question.toolMessageID ||
            request.toolMessageId == message.messageId
        }
    }

    private static func uniqueRequests(
        from pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> [AIQuestionRequestInfo] {
        var ordered: [AIQuestionRequestInfo] = []
        var seen: Set<String> = []
        for request in pendingQuestions.values {
            guard seen.insert(request.id).inserted else { continue }
            ordered.append(request)
        }
        return ordered
    }
}
