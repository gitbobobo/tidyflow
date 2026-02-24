import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private func isInteractiveQuestionToolState(_ state: [String: Any]) -> Bool {
    if let metadata = state["metadata"] as? [String: Any], metadata["answers"] != nil {
        return false
    }

    let status = (state["status"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    if status.isEmpty {
        // 兼容旧数据：缺失状态时保守视为可交互
        return true
    }
    switch status {
    case "pending", "running", "unknown", "awaiting_input", "requires_input", "in_progress":
        return true
    default:
        return false
    }
}

struct MessageListView: View {
    @EnvironmentObject var aiChatStore: AIChatStore
    let messages: [AIChatMessage]
    let onQuestionReply: (AIQuestionRequestInfo, [[String]]) -> Void
    let onQuestionReject: (AIQuestionRequestInfo) -> Void
    let onQuestionReplyAsMessage: (String) -> Void
    let onOpenLinkedSession: ((String) -> Void)?
    @State private var viewportHeight: CGFloat = 0
    @State private var isNearBottom: Bool = true
    @State private var shouldAutoScroll: Bool = true
    @State private var isUserDragging: Bool = false
    @State private var visibleMessageIDs: Set<String> = []

    private let scrollSpaceName = "ai_message_scroll_space"
    private let bottomAnchorId = "ai_message_bottom_anchor"
    private let bottomTolerance: CGFloat = 36
    private let renderBufferCount: Int = 12

    /// 仅关注消息尾部变化：新消息、流式增量、尾部 part 增长等。
    private var tailChangeToken: String {
        guard let last = displayMessages.last else { return "0" }
        let lastPart = last.parts.last
        return [
            "\(displayMessages.count)",
            last.id,
            last.isStreaming ? "1" : "0",
            "\(last.parts.count)",
            lastPart?.id ?? "",
            "\(lastPart?.text?.count ?? 0)"
        ].joined(separator: "|")
    }

    /// 过滤掉“无可见内容且非流式”的消息，避免空消息把相邻回复撑开。
    private var displayMessages: [AIChatMessage] {
        messages.filter { message in
            // Codex 过程信息（仅 reasoning）：流式阶段展示；结束后若仍仅 reasoning 则隐藏。
            if isProcessInfoMessage(message) {
                return message.isStreaming && hasRenderablePartContent(message)
            }
            // Codex commentary 文本仅在流式阶段展示；完成后隐藏，减少对最终回答的干扰。
            if isCodexCommentaryMessage(message) {
                return message.isStreaming && hasRenderablePartContent(message)
            }
            if message.isStreaming { return true }
            return hasRenderablePartContent(message)
        }
    }

    private func isProcessInfoMessage(_ message: AIChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard !message.parts.isEmpty else { return false }
        return message.parts.allSatisfy { $0.kind == .reasoning }
    }

    private func isCodexCommentaryMessage(_ message: AIChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard !message.parts.isEmpty else { return false }
        return message.parts.allSatisfy { part in
            guard part.kind == .text else { return false }
            guard let source = part.source else { return false }
            let vendor = (source["vendor"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let phaseRaw = ((source["message_phase"] as? String) ?? (source["phase"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let normalizedPhase: String
            switch phaseRaw {
            case "commentary":
                normalizedPhase = "commentary"
            case "finalanswer", "final_answer":
                normalizedPhase = "finalanswer"
            default:
                normalizedPhase = phaseRaw
            }
            return vendor == "codex" && normalizedPhase == "commentary"
        }
    }

    private func hasRenderablePartContent(_ message: AIChatMessage) -> Bool {
        message.parts.contains { part in
            switch part.kind {
            case .tool:
                return true
            case .file:
                return true
            case .compaction:
                return true
            case .text, .reasoning:
                return !(part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
        }
    }

    private var fullRenderRange: ClosedRange<Int>? {
        let visibleIndices = displayMessages.enumerated().compactMap { index, message in
            visibleMessageIDs.contains(message.id) ? index : nil
        }
        guard let minVisible = visibleIndices.min(),
              let maxVisible = visibleIndices.max() else {
            return nil
        }
        let lower = max(0, minVisible - renderBufferCount)
        let upper = min(displayMessages.count - 1, maxVisible + renderBufferCount)
        return lower...upper
    }

    private func shouldFullyRender(message: AIChatMessage, index: Int) -> Bool {
        if message.isStreaming {
            return true
        }
        guard let range = fullRenderRange else {
            let warmStartCount = renderBufferCount * 3
            let lowerBound = max(0, displayMessages.count - warmStartCount)
            return index >= lowerBound
        }
        return range.contains(index)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(Array(displayMessages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(
                            message: message,
                            prefersFullRender: shouldFullyRender(message: message, index: index),
                            pendingQuestionToken: pendingQuestionToken(for: message),
                            sessionId: aiChatStore.currentSessionId ?? "",
                            questionRequestResolver: { callId, toolPartId, messageId, requestId in
                                aiChatStore.questionRequest(
                                    forToolCallId: callId,
                                    toolPartId: toolPartId,
                                    toolMessageId: messageId,
                                    requestId: requestId
                                )
                            },
                            onQuestionReply: onQuestionReply,
                            onQuestionReject: onQuestionReject,
                            onQuestionReplyAsMessage: onQuestionReplyAsMessage,
                            onOpenLinkedSession: onOpenLinkedSession
                        )
                            .equatable()
                            .id(message.id)
                            .onAppear {
                                visibleMessageIDs.insert(message.id)
                            }
                            .onDisappear {
                                visibleMessageIDs.remove(message.id)
                            }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorId)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: MessageListBottomAnchorKey.self,
                                    value: geo.frame(in: .named(scrollSpaceName)).maxY
                                )
                            }
                        )
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: scrollSpaceName)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: MessageListViewportHeightKey.self, value: geo.size.height)
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        if !isUserDragging {
                            isUserDragging = true
                        }
                    }
                    .onEnded { _ in
                        if isUserDragging {
                            isUserDragging = false
                        }
                        let shouldFollow = isNearBottom
                        if shouldAutoScroll != shouldFollow {
                            shouldAutoScroll = shouldFollow
                        }
                    }
            )
            .onPreferenceChange(MessageListViewportHeightKey.self) { newHeight in
                guard abs(newHeight - viewportHeight) > 0.5 else { return }
                viewportHeight = newHeight
            }
            .onPreferenceChange(MessageListBottomAnchorKey.self) { newBottom in
                updateBottomState(withBottomAnchorMaxY: newBottom)
            }
            .onAppear {
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: tailChangeToken) {
                guard shouldAutoScroll else { return }
                scrollToBottom(proxy: proxy, animated: true)
            }
        }
    }

    private func updateBottomState(withBottomAnchorMaxY bottomAnchorMaxY: CGFloat) {
        guard viewportHeight > 0 else { return }
        let distanceToBottom = max(0, bottomAnchorMaxY - viewportHeight)
        let nearBottomNow = distanceToBottom <= bottomTolerance
        if nearBottomNow != isNearBottom {
            isNearBottom = nearBottomNow
        }

        // 只有用户主动拖拽离开底部时才关闭自动跟随，避免流式增量误判。
        if nearBottomNow {
            if !shouldAutoScroll {
                shouldAutoScroll = true
            }
        } else if isUserDragging && shouldAutoScroll {
            shouldAutoScroll = false
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
        }
        if animated {
            withAnimation {
                action()
            }
        } else {
            action()
        }
    }

    private func pendingQuestionToken(for message: AIChatMessage) -> String {
        let items: [String] = message.parts.compactMap { part in
            guard part.kind == .tool else { return nil }
            let requestId = questionRequestIdFromPart(part)
            let request = aiChatStore.questionRequest(
                forToolCallId: part.toolCallId,
                toolPartId: part.id,
                toolMessageId: message.messageId,
                requestId: requestId
            ) ?? fallbackQuestionRequestFromPart(
                message: message,
                part: part,
                sessionId: aiChatStore.currentSessionId ?? ""
            )
            guard let request else { return nil }
            let linkKey =
                (requestId?.isEmpty == false ? requestId : nil) ??
                (part.toolCallId?.isEmpty == false ? part.toolCallId : nil) ??
                part.id
            return "\(linkKey):\(request.id):\(request.questions.count)"
        }
        if items.isEmpty { return "" }
        return items.sorted().joined(separator: "|")
    }

    private func questionRequestIdFromPart(_ part: AIChatPart) -> String? {
        let raw = (part.toolPartMetadata?["request_id"] as? String) ??
            (part.toolPartMetadata?["requestId"] as? String) ??
            (part.toolState?["request_id"] as? String) ??
            (part.toolState?["requestId"] as? String) ??
            ((part.toolState?["metadata"] as? [String: Any])?["request_id"] as? String) ??
            ((part.toolState?["metadata"] as? [String: Any])?["requestId"] as? String)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func fallbackQuestionRequestFromPart(
        message: AIChatMessage,
        part: AIChatPart,
        sessionId: String
    ) -> AIQuestionRequestInfo? {
        guard part.kind == .tool else { return nil }
        let toolName = (part.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard toolName == "question" else { return nil }
        guard let state = part.toolState else { return nil }
        guard isInteractiveQuestionToolState(state) else { return nil }

        let input = state["input"] as? [String: Any]
        let questionsValue = input?["questions"] ?? state["questions"]
        let questions = parseFallbackQuestionInfos(from: questionsValue)
        guard !questions.isEmpty else { return nil }

        let requestId =
            questionRequestIdFromPart(part) ??
            part.toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            part.id
        guard !requestId.isEmpty else { return nil }

        let toolMessageId =
            ((part.toolPartMetadata?["tool_message_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines))

        return AIQuestionRequestInfo(
            id: requestId,
            sessionId: sessionId,
            questions: questions,
            toolMessageId: (toolMessageId?.isEmpty == false) ? toolMessageId : (message.messageId ?? part.id),
            toolCallId: part.toolCallId
        )
    }

    private func parseFallbackQuestionInfos(from value: Any?) -> [AIQuestionInfo] {
        if let items = value as? [[String: Any]] {
            return items.compactMap { parseFallbackQuestionInfo(from: $0) }
        }
        if let items = value as? [Any] {
            return items.compactMap { item in
                guard let dict = item as? [String: Any] else { return nil }
                return parseFallbackQuestionInfo(from: dict)
            }
        }
        if let dict = value as? [String: Any], let nested = dict["questions"] {
            return parseFallbackQuestionInfos(from: nested)
        }
        return []
    }

    private func parseFallbackQuestionInfo(from dict: [String: Any]) -> AIQuestionInfo? {
        let question = (dict["question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !question.isEmpty else { return nil }
        let header = (dict["header"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let optionItems: [[String: Any]] = dict["options"] as? [[String: Any]] ?? []
        let options: [AIQuestionOptionInfo] = optionItems.compactMap { option -> AIQuestionOptionInfo? in
            guard let label = (option["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return nil }
            let description = ((option["description"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AIQuestionOptionInfo(label: label, description: description)
        }
        let multiple = (dict["multiple"] as? Bool) ?? false
        let custom = (dict["custom"] as? Bool) ?? ((dict["isOther"] as? Bool) ?? true)
        return AIQuestionInfo(
            question: question,
            header: header,
            options: options,
            multiple: multiple,
            custom: custom
        )
    }
}

private struct MessageListViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MessageListBottomAnchorKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MessageBubble: View, Equatable {
    let message: AIChatMessage
    let prefersFullRender: Bool
    let pendingQuestionToken: String
    let sessionId: String
    let questionRequestResolver: (String?, String?, String?, String?) -> AIQuestionRequestInfo?
    let onQuestionReply: (AIQuestionRequestInfo, [[String]]) -> Void
    let onQuestionReject: (AIQuestionRequestInfo) -> Void
    let onQuestionReplyAsMessage: (String) -> Void
    let onOpenLinkedSession: ((String) -> Void)?

    private var isUser: Bool { message.role == .user }

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.prefersFullRender == rhs.prefersFullRender &&
            lhs.pendingQuestionToken == rhs.pendingQuestionToken &&
            lhs.sessionId == rhs.sessionId &&
            lhs.renderKey == rhs.renderKey
    }

    private var renderKey: String {
        let partToken = message.parts.map { part in
            let textToken = compactTextToken(part.text)
            let toolName = part.toolName ?? ""
            let toolStatus = (part.toolState?["status"] as? String) ?? ""
            let toolStateToken = compactToolStateToken(part.toolState)
            let metadataCount = part.toolPartMetadata?.count ?? 0
            let metadataToken = compactDictionaryToken(part.toolPartMetadata)
            let fileName = part.filename ?? ""
            let fileURL = part.url ?? ""
            let fileMime = part.mime ?? ""
            return "\(part.id)|\(part.kind.rawValue)|\(textToken)|\(toolName)|\(toolStatus)|\(toolStateToken)|\(metadataCount)|\(metadataToken)|\(fileName)|\(fileMime)|\(fileURL)"
        }.joined(separator: ",")
        return [
            message.id,
            message.role.rawValue,
            message.isStreaming ? "1" : "0",
            "\(message.parts.count)",
            partToken
        ].joined(separator: "#")
    }

    /// 仅取长度 + 前后缀摘要，兼顾变更感知和计算成本。
    private func compactTextToken(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "0:0:0" }
        let prefixHash = String(text.prefix(48)).hashValue
        let suffixHash = String(text.suffix(24)).hashValue
        return "\(text.count):\(prefixHash):\(suffixHash)"
    }

    private func compactToolStateToken(_ state: [String: Any]?) -> String {
        guard let state else { return "0" }
        let output = (state["output"] as? String) ?? ""
        let error = (state["error"] as? String) ?? ""
        let metadata = state["metadata"] as? [String: Any]
        let progressLines = (metadata?["progress_lines"] as? [String]) ?? []
        let progressJoined = progressLines.joined(separator: "\n")

        let outputToken = compactTextToken(output)
        let errorToken = compactTextToken(error)
        let progressToken = compactTextToken(progressJoined)
        return "\(outputToken)|\(errorToken)|\(progressLines.count)|\(progressToken)"
    }

    private func compactDictionaryToken(_ value: [String: Any]?) -> String {
        guard let value else { return "0" }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(value.count):invalid"
        }
        return compactTextToken(text)
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            bubble
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.trailing, isUser ? 0 : 12)
    }

    @ViewBuilder
    private var bubble: some View {
        if !prefersFullRender {
            lightweightBubble
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if message.parts.isEmpty {
                    EmptyView()
                } else {
                    ForEach(Array(message.parts.enumerated()), id: \.element.id) { _, part in
                        partContentView(part)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bubbleBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(bubbleBorderColor, lineWidth: isUser ? 0 : 1)
            )
            .cornerRadius(12)
        }
    }

    @ViewBuilder
    private func partContentView(_ part: AIChatPart) -> some View {
        switch part.kind {
        case .text:
            if let text = part.text {
                if isUser,
                   let normalizedText = normalizedStreamingDisplayText(text, keepOriginalForUser: true) {
                    Text(normalizedText)
                        .textSelection(.enabled)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                } else if message.isStreaming,
                          let normalizedText = normalizedStreamingDisplayText(text, keepOriginalForUser: false) {
                    StreamingMarkdownText(
                        text: normalizedText,
                        isStreaming: message.isStreaming,
                        baseFontSize: 13,
                        textColor: .primary
                    )
                } else if let markdownText = normalizedMarkdownDisplayText(text, keepOriginalForUser: false) {
                    MarkdownTextView(
                        text: markdownText,
                        baseFontSize: 13,
                        textColor: .primary
                    )
                }
            }
        case .reasoning:
            if let text = part.text, message.isStreaming,
               let normalizedText = normalizedStreamingDisplayText(text, keepOriginalForUser: false) {
                StreamingMarkdownText(
                    text: normalizedText,
                    isStreaming: true,
                    baseFontSize: 12,
                    textColor: .secondary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let text = part.text,
                      let markdownText = normalizedMarkdownDisplayText(text, keepOriginalForUser: false) {
                MarkdownTextView(
                    text: markdownText,
                    baseFontSize: 12,
                    textColor: .secondary
                )
            }
        case .file:
            filePartView(part)
        case .compaction:
            Label("上下文压缩中", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            let requestId = questionRequestId(from: part)
            let pendingQuestion = questionRequestResolver(
                part.toolCallId,
                part.id,
                message.messageId,
                requestId
            ) ?? fallbackQuestionRequest(message: message, part: part, sessionId: sessionId)
            ToolCardView(
                name: part.toolName ?? "unknown",
                state: part.toolState,
                callID: part.toolCallId,
                partMetadata: part.toolPartMetadata,
                pendingQuestion: pendingQuestion,
                onQuestionReply: pendingQuestion == nil ? nil : { answers in
                    guard let pendingQuestion else { return }
                    onQuestionReply(pendingQuestion, answers)
                },
                onQuestionReject: pendingQuestion == nil ? nil : {
                    guard let pendingQuestion else { return }
                    onQuestionReject(pendingQuestion)
                },
                onQuestionReplyAsMessage: pendingQuestion == nil ? onQuestionReplyAsMessage : nil,
                onOpenLinkedSession: onOpenLinkedSession
            )
        }
    }

    private func questionRequestId(from part: AIChatPart) -> String? {
        let direct = (part.toolPartMetadata?["request_id"] as? String) ??
            (part.toolPartMetadata?["requestId"] as? String) ??
            (part.toolState?["request_id"] as? String) ??
            (part.toolState?["requestId"] as? String) ??
            ((part.toolState?["metadata"] as? [String: Any])?["request_id"] as? String) ??
            ((part.toolState?["metadata"] as? [String: Any])?["requestId"] as? String)
        let trimmed = direct?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func fallbackQuestionRequest(
        message: AIChatMessage,
        part: AIChatPart,
        sessionId: String
    ) -> AIQuestionRequestInfo? {
        guard part.kind == .tool else { return nil }
        let toolName = (part.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard toolName == "question" else { return nil }
        guard let state = part.toolState else { return nil }
        guard isInteractiveQuestionToolState(state) else { return nil }

        let input = state["input"] as? [String: Any]
        let questionsValue = input?["questions"] ?? state["questions"]
        let questions = parseQuestionInfos(from: questionsValue)
        guard !questions.isEmpty else { return nil }

        let requestId =
            questionRequestId(from: part) ??
            part.toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            part.id
        guard !requestId.isEmpty else { return nil }

        let toolMessageId =
            ((part.toolPartMetadata?["tool_message_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines))

        return AIQuestionRequestInfo(
            id: requestId,
            sessionId: sessionId,
            questions: questions,
            toolMessageId: (toolMessageId?.isEmpty == false) ? toolMessageId : (message.messageId ?? part.id),
            toolCallId: part.toolCallId
        )
    }

    private func parseQuestionInfos(from value: Any?) -> [AIQuestionInfo] {
        if let items = value as? [[String: Any]] {
            return items.compactMap { parseQuestionInfo(from: $0) }
        }
        if let items = value as? [Any] {
            return items.compactMap { item in
                guard let dict = item as? [String: Any] else { return nil }
                return parseQuestionInfo(from: dict)
            }
        }
        if let dict = value as? [String: Any], let nested = dict["questions"] {
            return parseQuestionInfos(from: nested)
        }
        return []
    }

    private func parseQuestionInfo(from dict: [String: Any]) -> AIQuestionInfo? {
        let question = (dict["question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !question.isEmpty else { return nil }
        let header = (dict["header"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let optionItems: [[String: Any]] = dict["options"] as? [[String: Any]] ?? []
        let options: [AIQuestionOptionInfo] = optionItems.compactMap { option -> AIQuestionOptionInfo? in
            guard let label = (option["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return nil }
            let description = ((option["description"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AIQuestionOptionInfo(label: label, description: description)
        }
        let multiple = (dict["multiple"] as? Bool) ?? false
        let custom = (dict["custom"] as? Bool) ?? ((dict["isOther"] as? Bool) ?? true)
        return AIQuestionInfo(
            question: question,
            header: header,
            options: options,
            multiple: multiple,
            custom: custom
        )
    }

    private var lightweightBubble: some View {
        let summary = compactSummaryText()
        return VStack(alignment: .leading, spacing: 6) {
            if summary.isEmpty {
                Text("...")
                    .font(.system(size: 12))
                    .foregroundColor(isUser ? .white.opacity(0.9) : .secondary)
            } else {
                Text(summary)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .foregroundColor(isUser ? .white : .primary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bubbleBackgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(bubbleBorderColor, lineWidth: isUser ? 0 : 1)
        )
        .cornerRadius(12)
    }

    private func compactSummaryText() -> String {
        var lines: [String] = []
        for part in message.parts {
            switch part.kind {
            case .text, .reasoning:
                if let text = part.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    lines.append(text)
                }
            case .file:
                let name = part.filename ?? "attachment"
                lines.append("[附件] \(name)")
            case .compaction:
                lines.append("[系统] 上下文压缩中")
            case .tool:
                let toolName = part.toolName ?? "tool"
                lines.append("[工具] \(toolName)")
            }
        }
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n")
    }

    private var bubbleBackgroundColor: Color {
        if isUser {
            return Color.blue
        } else {
            return Color.secondary.opacity(0.10)
        }
    }

    private var bubbleBorderColor: Color {
        if isUser { return .clear }
        return Color.secondary.opacity(0.12)
    }

    /// 流式阶段的文本规范化：兼顾可读性与抖动控制。
    private func normalizedStreamingDisplayText(_ raw: String, keepOriginalForUser: Bool) -> String? {
        // 用户消息尽量保留原始格式；仅过滤纯空白输入。
        if keepOriginalForUser {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : raw
        }

        var text = normalizedLineBreaks(raw)

        // 仅用于判空，不直接裁剪文本，避免吞掉“行完成”所需的尾部换行信号。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // 连续 3 行以上空白压缩为最多 2 行，保留基本段落感。
        text = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )

        // 仅去掉首部空白行，保留尾部换行以便“行完成后立即触发 Markdown 渲染”。
        text = text.replacingOccurrences(
            of: #"^\n+"#,
            with: "",
            options: .regularExpression
        )

        return text
    }

    /// 完成态 Markdown 规范化：仅统一换行，不压缩内部空行，避免破坏 Markdown 语义。
    private func normalizedMarkdownDisplayText(_ raw: String, keepOriginalForUser: Bool) -> String? {
        if keepOriginalForUser {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : raw
        }
        let text = normalizedLineBreaks(raw)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func normalizedLineBreaks(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        return text
    }

    @ViewBuilder
    private func filePartView(_ part: AIChatPart) -> some View {
        let primaryTextColor: Color = isUser ? .white : .primary
        let secondaryTextColor: Color = isUser ? .white.opacity(0.85) : .secondary
        let fileName = part.filename ?? "attachment"
        let mime = part.mime ?? "application/octet-stream"

        VStack(alignment: .leading, spacing: 8) {
            if let imageData = resolveImageData(for: part) {
                imagePreview(data: imageData)
                    .frame(maxWidth: 320, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)
                Text(fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(primaryTextColor)
                    .lineLimit(1)
            }

            Text(mime)
                .font(.system(size: 11))
                .foregroundColor(secondaryTextColor)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func resolveImageData(for part: AIChatPart) -> Data? {
        guard let mime = part.mime?.lowercased(), mime.hasPrefix("image/") else { return nil }
        if let url = part.url {
            if let data = decodeDataURL(url) {
                return data
            }
            if let data = loadFromFileURL(url) {
                return data
            }
        }
        return nil
    }

    private func decodeDataURL(_ value: String) -> Data? {
        guard value.hasPrefix("data:"),
              let comma = value.firstIndex(of: ",") else { return nil }
        let header = String(value[..<comma]).lowercased()
        let payloadStart = value.index(after: comma)
        let payload = String(value[payloadStart...])

        if header.contains(";base64") {
            return Data(base64Encoded: payload)
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    private func loadFromFileURL(_ value: String) -> Data? {
        guard let url = URL(string: value), url.isFileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    @ViewBuilder
    private func imagePreview(data: Data) -> some View {
        #if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        }
        #elseif os(iOS)
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        }
        #endif
    }
}

/// 流式 Markdown：已完成行实时走 Markdown，当前未完成尾行维持纯文本打字机。
private struct StreamingMarkdownText: View {
    let text: String
    let isStreaming: Bool
    let baseFontSize: CGFloat
    let textColor: Color

    private var segments: (completedMarkdown: String, tailPlainText: String) {
        splitStreamingMarkdown(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !segments.completedMarkdown.isEmpty {
                MarkdownTextView(
                    text: segments.completedMarkdown,
                    baseFontSize: baseFontSize,
                    textColor: textColor
                )
            }

            if !segments.tailPlainText.isEmpty {
                TypewriterText(text: segments.tailPlainText, isStreaming: isStreaming)
                    .textSelection(.enabled)
                    .font(.system(size: baseFontSize))
                    .foregroundColor(textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func splitStreamingMarkdown(_ source: String) -> (completedMarkdown: String, tailPlainText: String) {
        guard !source.isEmpty else { return ("", "") }

        let hasTrailingNewline = source.hasSuffix("\n")
        let lines = source.components(separatedBy: "\n")
        guard !lines.isEmpty else { return ("", "") }

        let completedCount = hasTrailingNewline ? lines.count : max(0, lines.count - 1)
        let completedMarkdown = completedCount > 0
            ? lines.prefix(completedCount).joined(separator: "\n")
            : ""
        let tail = hasTrailingNewline ? "" : (lines.last ?? "")
        return (completedMarkdown, tail)
    }
}

/// 打字机效果：把“目标文本”平滑地增量渲染到 UI 上。
private struct TypewriterText: View {
    let text: String
    let isStreaming: Bool

    @State private var displayed: String = ""
    @State private var target: String = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        Text(displayed)
            .onAppear {
                target = text
                if isStreaming {
                    startIfNeeded()
                } else {
                    displayed = text
                }
            }
            .onDisappear {
                task?.cancel()
                task = nil
            }
            .onChange(of: text) { _, newValue in
                target = newValue
                if !isStreaming {
                    displayed = newValue
                } else {
                    startIfNeeded()
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                if streaming {
                    startIfNeeded()
                } else {
                    task?.cancel()
                    task = nil
                    displayed = target
                }
            }
    }

    private func startIfNeeded() {
        guard task == nil else { return }
        task = Task { @MainActor in
            let tickNs: UInt64 = 30_000_000
            while !Task.isCancelled {
                if displayed == target {
                    if !isStreaming { break }
                    try? await Task.sleep(nanoseconds: tickNs)
                    continue
                }

                if !target.hasPrefix(displayed) {
                    displayed = target
                    try? await Task.sleep(nanoseconds: tickNs)
                    continue
                }

                let backlog = max(0, target.count - displayed.count)
                let cps: Int
                if backlog > 500 {
                    cps = 2000
                } else if backlog > 200 {
                    cps = 1200
                } else if backlog > 80 {
                    cps = 600
                } else {
                    cps = 240
                }
                let chunkSize = max(1, Int(Double(cps) * (Double(tickNs) / 1_000_000_000.0)))

                let startIdx = target.index(target.startIndex, offsetBy: displayed.count)
                let endIdx = target.index(startIdx, offsetBy: min(chunkSize, backlog))
                displayed.append(contentsOf: target[startIdx..<endIdx])

                try? await Task.sleep(nanoseconds: tickNs)
            }
        }
    }
}
