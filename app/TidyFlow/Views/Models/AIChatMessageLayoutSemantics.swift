import Foundation

struct AIChatTextRunSegment: Equatable, Identifiable {
    let id: String
    let kind: AIChatPartKind
    let text: String
}

struct AIChatTextDisplayRun: Equatable, Identifiable {
    let id: String
    let kind: AIChatPartKind
    let text: String
}

struct AIChatTextRunGroup: Equatable, Identifiable {
    let id: String
    let segments: [AIChatTextRunSegment]

    var displayRuns: [AIChatTextDisplayRun] {
        var runs: [AIChatTextDisplayRun] = []
        var previousText: String?

        for segment in segments {
            guard !segment.text.isEmpty else { continue }
            let prefix = Self.separator(previous: previousText, current: segment.text)
            runs.append(
                AIChatTextDisplayRun(
                    id: segment.id,
                    kind: segment.kind,
                    text: prefix + segment.text
                )
            )
            previousText = segment.text
        }

        return runs
    }

    var combinedText: String {
        displayRuns.map(\.text).joined()
    }

    var containsReasoning: Bool {
        segments.contains { $0.kind == .reasoning }
    }

    func markdownText(renderReasoningAsBlockQuote: Bool) -> String {
        var result = ""
        var previousText: String?

        for segment in segments {
            guard !segment.text.isEmpty else { continue }
            result += Self.separator(previous: previousText, current: segment.text)
            if renderReasoningAsBlockQuote, segment.kind == .reasoning {
                result += Self.blockQuoteMarkdown(for: segment.text)
            } else {
                result += segment.text
            }
            previousText = segment.text
        }

        return result
    }

    private static func separator(previous: String?, current: String) -> String {
        guard let previous, !previous.isEmpty else { return "" }
        if previous.hasSuffix("\n") || current.hasPrefix("\n") {
            return ""
        }
        return "\n\n"
    }

    private static func blockQuoteMarkdown(for text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? ">" : "> \(line)"
            }
            .joined(separator: "\n")
    }
}

enum AIChatMessageDisplayNode: Equatable, Identifiable {
    case textGroup(AIChatTextRunGroup)
    case part(AIChatPart)

    var id: String {
        switch self {
        case .textGroup(let group):
            return group.id
        case .part(let part):
            return part.id
        }
    }

    static func == (lhs: AIChatMessageDisplayNode, rhs: AIChatMessageDisplayNode) -> Bool {
        switch (lhs, rhs) {
        case (.textGroup(let lhsGroup), .textGroup(let rhsGroup)):
            return lhsGroup == rhsGroup
        case (.part(let lhsPart), .part(let rhsPart)):
            return partSignature(lhsPart) == partSignature(rhsPart)
        default:
            return false
        }
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
            toolKind: part.toolKind
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
        var nodes: [AIChatMessageDisplayNode] = []
        var bufferedSegments: [AIChatTextRunSegment] = []

        func flushBufferedSegments() {
            guard !bufferedSegments.isEmpty else { return }
            let ids = bufferedSegments.map(\.id).joined(separator: "|")
            nodes.append(.textGroup(AIChatTextRunGroup(id: ids, segments: bufferedSegments)))
            bufferedSegments.removeAll(keepingCapacity: true)
        }

        for part in message.parts {
            if let segment = textSegment(from: part) {
                bufferedSegments.append(segment)
                continue
            }

            flushBufferedSegments()

            guard shouldRender(part: part, in: message, pendingQuestions: pendingQuestions) else {
                continue
            }
            nodes.append(.part(part))
        }

        flushBufferedSegments()
        return nodes
    }

    static func hasRenderableContent(
        in message: AIChatMessage,
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> Bool {
        !displayNodes(for: message, pendingQuestions: pendingQuestions).isEmpty
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

    private static func textSegment(from part: AIChatPart) -> AIChatTextRunSegment? {
        guard part.kind == .text || part.kind == .reasoning else { return nil }
        guard let text = part.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return AIChatTextRunSegment(id: part.id, kind: part.kind, text: text)
    }

    private static func shouldRender(
        part: AIChatPart,
        in message: AIChatMessage,
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> Bool {
        switch part.kind {
        case .tool:
            return pendingRequest(for: part, in: message, pendingQuestions: pendingQuestions) == nil
        case .file, .plan, .compaction:
            return true
        case .text, .reasoning:
            return false
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
