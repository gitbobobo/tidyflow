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
    let sessionToken: String?
    let canLoadOlderMessages: Bool
    let isLoadingOlderMessages: Bool
    let onLoadOlderMessages: (() -> Void)?
    let onQuestionReply: (AIQuestionRequestInfo, [[String]]) -> Void
    let onQuestionReject: (AIQuestionRequestInfo) -> Void
    let onQuestionReplyAsMessage: (String) -> Void
    let onOpenLinkedSession: ((String) -> Void)?
    @State private var viewportHeight: CGFloat = 0
    @State private var isNearBottom: Bool = true
    @State private var isAutoFollowActive: Bool = true
    @State private var scrollPolicy: ChatScrollPolicy = ChatScrollPolicy()
    @State private var lastTailMessageID: String?
    @State private var lastDisplayMessageCount: Int = 0
    @State private var visibleMessageIDs: Set<String> = []
    @State private var jumpToBottomRequestID: Int = 0

    private let scrollSpaceName = "ai_message_scroll_space"
    private let bottomAnchorId = "ai_message_bottom_anchor"
    private let renderBufferCount: Int = 12

    init(
        messages: [AIChatMessage],
        sessionToken: String?,
        canLoadOlderMessages: Bool = false,
        isLoadingOlderMessages: Bool = false,
        onLoadOlderMessages: (() -> Void)? = nil,
        onQuestionReply: @escaping (AIQuestionRequestInfo, [[String]]) -> Void,
        onQuestionReject: @escaping (AIQuestionRequestInfo) -> Void,
        onQuestionReplyAsMessage: @escaping (String) -> Void,
        onOpenLinkedSession: ((String) -> Void)?
    ) {
        self.messages = messages
        self.sessionToken = sessionToken
        self.canLoadOlderMessages = canLoadOlderMessages
        self.isLoadingOlderMessages = isLoadingOlderMessages
        self.onLoadOlderMessages = onLoadOlderMessages
        self.onQuestionReply = onQuestionReply
        self.onQuestionReject = onQuestionReject
        self.onQuestionReplyAsMessage = onQuestionReplyAsMessage
        self.onOpenLinkedSession = onOpenLinkedSession
    }

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
            case .plan:
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
                messageStack()
            }
            .defaultScrollAnchor(.bottom)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onAppear {
                initializeScrollPolicyStateIfNeeded()
                // defaultScrollAnchor(.bottom) 处理初始定位，
                // 但仍需手动滚动以确保在已有消息时精确定位底部。
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: sessionToken) { _, _ in
                handleSessionTokenChangeIfNeeded()
            }
            .onChange(of: tailChangeToken) {
                handleTailChanged(proxy: proxy)
            }
            .onChange(of: jumpToBottomRequestID) {
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: viewportHeight) { _, _ in
                guard isAutoFollowActive else { return }
                guard isNearBottom else { return }
                scrollToBottom(proxy: proxy, animated: false)
            }
        }
        .coordinateSpace(name: scrollSpaceName)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: MessageListViewportHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(MessageListViewportHeightKey.self) { newHeight in
            guard abs(newHeight - viewportHeight) > 0.5 else { return }
            viewportHeight = newHeight
        }
        .onPreferenceChange(MessageListBottomAnchorMaxYKey.self) { bottomMaxY in
            guard viewportHeight > 0 else { return }
            let config = scrollPolicy.configuration
            let nearBottom = bottomMaxY <= (viewportHeight + config.nearBottomThreshold)
            let withinAutoFollowZone = bottomMaxY <= (viewportHeight + config.autoFollowBreakThreshold)
            updateNearBottomState(nearBottom: nearBottom, withinAutoFollowZone: withinAutoFollowZone)
        }
        .overlay(alignment: .bottomTrailing) {
            if showJumpToBottomButton {
                jumpToBottomButton
            }
        }
    }

    @ViewBuilder
    private func messageStack() -> some View {
        LazyVStack(spacing: 16) {
            if canLoadOlderMessages || isLoadingOlderMessages {
                HStack {
                    Spacer(minLength: 0)
                    if isLoadingOlderMessages {
                        ProgressView("加载中…")
                            .controlSize(.small)
                            .font(.caption)
                    } else if canLoadOlderMessages, let onLoadOlderMessages {
                        Button("加载更早消息", action: onLoadOlderMessages)
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }

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
                            key: MessageListBottomAnchorMaxYKey.self,
                            value: geo.frame(in: .named(scrollSpaceName)).maxY
                        )
                    }
                )
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 使用双阈值策略更新滚动状态：
    /// - `nearBottom` (36pt)：紧凑阈值，控制"回到底部"按钮的显隐
    /// - `withinAutoFollowZone` (200pt)：宽松阈值，保护 autoFollow 不被流式内容增长的竞态误断
    ///
    /// 三个区间的行为：
    /// 1. 距底部 ≤ 36pt：确认在底部，恢复 autoFollow
    /// 2. 距底部 36~200pt："缓冲区"，不通知 policy，保持 autoFollow 不变
    /// 3. 距底部 > 200pt：用户明确离开底部，中断 autoFollow
    private func updateNearBottomState(nearBottom: Bool, withinAutoFollowZone: Bool) {
        isNearBottom = nearBottom

        if nearBottom {
            // 区间 1：在底部附近，确认并可能恢复 autoFollow
            _ = scrollPolicy.reduce(event: .userScrolled(nearBottom: true))
            isAutoFollowActive = scrollPolicy.isAutoScrollEnabled
        } else if !withinAutoFollowZone {
            // 区间 3：远离底部，中断 autoFollow
            _ = scrollPolicy.reduce(event: .userScrolled(nearBottom: false))
            isAutoFollowActive = scrollPolicy.isAutoScrollEnabled
        }
        // 区间 2（缓冲区）：不通知 policy，保持当前 autoFollow 状态。
        // 这避免了流式输出时 proxy.scrollTo() 异步延迟导致 autoFollow 被误断。
    }

    private func initializeScrollPolicyStateIfNeeded() {
        isNearBottom = scrollPolicy.nearBottom
        isAutoFollowActive = scrollPolicy.isAutoScrollEnabled
        lastDisplayMessageCount = displayMessages.count
        lastTailMessageID = displayMessages.last?.id
    }

    private func handleSessionTokenChangeIfNeeded() {
        guard sessionToken != nil else { return }

        let decision = scrollPolicy.reduce(event: .sessionSwitched)
        isNearBottom = scrollPolicy.nearBottom
        isAutoFollowActive = scrollPolicy.isAutoScrollEnabled
        lastDisplayMessageCount = displayMessages.count
        lastTailMessageID = displayMessages.last?.id

        guard decision.shouldScrollToBottom else { return }
        jumpToBottomRequestID += 1
    }

    private func tailChangeEvent() -> ChatScrollEvent {
        let currentCount = displayMessages.count
        let currentTailID = displayMessages.last?.id
        let event: ChatScrollEvent
        if currentCount > lastDisplayMessageCount || currentTailID != lastTailMessageID {
            event = .messageAppended
        } else {
            event = .messageIncremented
        }
        lastDisplayMessageCount = currentCount
        lastTailMessageID = currentTailID
        return event
    }

    private func handleTailChanged(proxy: ScrollViewProxy) {
        let decision = scrollPolicy.reduce(event: tailChangeEvent())
        guard decision.shouldScrollToBottom else { return }
        scrollToBottom(proxy: proxy, animated: false)
    }

    private var showJumpToBottomButton: Bool {
        !isAutoFollowActive || !isNearBottom
    }

    private var jumpToBottomButton: some View {
        Button {
            _ = scrollPolicy.reduce(event: .jumpToBottomClicked)
            isAutoFollowActive = true
            isNearBottom = true
            jumpToBottomRequestID += 1
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(10)
                .background(Color.accentColor)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
        }
        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                action()
            }
        } else {
            action()
        }
        // 自动滚动后刷新近底部确认时间戳
        _ = scrollPolicy.reduce(event: .userScrolled(nearBottom: true))
    }

    private func pendingQuestionToken(for message: AIChatMessage) -> String {
        guard message.parts.contains(where: { $0.kind == .tool }) else {
            return ""
        }
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
            let optionID =
                (option["option_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ??
                (option["optionId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AIQuestionOptionInfo(
                optionID: optionID?.isEmpty == false ? optionID : nil,
                label: label,
                description: description
            )
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

private struct MessageListBottomAnchorMaxYKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity

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

    @State private var fullscreenImageData: Data?

    private var isUser: Bool { message.role == .user }

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message.id == rhs.message.id &&
            lhs.message.renderRevision == rhs.message.renderRevision &&
            lhs.message.isStreaming == rhs.message.isStreaming &&
            lhs.prefersFullRender == rhs.prefersFullRender &&
            lhs.pendingQuestionToken == rhs.pendingQuestionToken &&
            lhs.sessionId == rhs.sessionId
    }

    /// 仅渲染有实际可见内容的 part，避免空 part 也参与布局导致工具卡之间出现“幽灵间距”。
    private var renderableParts: [AIChatPart] {
        message.parts.filter { part in
            isRenderablePart(part)
        }
    }

    private func isRenderablePart(_ part: AIChatPart) -> Bool {
        switch part.kind {
        case .tool, .file, .plan, .compaction:
            return true
        case .text, .reasoning:
            guard let text = part.text else { return false }
            if message.isStreaming {
                return normalizedStreamingDisplayText(text, keepOriginalForUser: false) != nil
            }
            return normalizedMarkdownDisplayText(text, keepOriginalForUser: false) != nil
        }
    }

    /// 连续工具卡之间使用 8pt 间距，其他类型 part 保持 10pt 阅读节奏。
    private func spacingBeforePart(at index: Int, in parts: [AIChatPart]) -> CGFloat {
        guard index > 0 else { return 0 }
        let previousPart = parts[index - 1]
        let currentPart = parts[index]
        if previousPart.kind == .tool, currentPart.kind == .tool {
            return 8
        }
        return 10
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            bubble
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.trailing, isUser ? 0 : 12)
        .sheet(item: Binding(
            get: { fullscreenImageData.map { FullscreenImageItem(data: $0) } },
            set: { if $0 == nil { fullscreenImageData = nil } }
        )) { item in
            FullscreenImageSheet(data: item.data)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if !prefersFullRender {
            lightweightBubble
        } else {
            let parts = renderableParts
            VStack(alignment: .leading, spacing: 0) {
                if parts.isEmpty {
                    EmptyView()
                } else {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        partContentView(part)
                            .padding(.top, spacingBeforePart(at: index, in: parts))
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
                if message.isStreaming,
                   let normalizedText = normalizedStreamingDisplayText(text, keepOriginalForUser: false) {
                    Text(verbatim: normalizedText)
                        .textSelection(.enabled)
                        .font(.system(size: 13))
                        .foregroundColor(isUser ? .white : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isUser,
                          let markdownText = normalizedMarkdownDisplayText(text, keepOriginalForUser: false) {
                    MarkdownTextView(
                        text: markdownText,
                        baseFontSize: 13,
                        textColor: .white
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
                Text(verbatim: normalizedText)
                    .textSelection(.enabled)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
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
        case .plan:
            AIPlanCardView(part: part)
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
                toolKind: part.toolKind,
                toolTitle: part.toolTitle,
                toolRawInput: part.toolRawInput,
                toolRawOutput: part.toolRawOutput,
                toolLocations: part.toolLocations,
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
            let optionID =
                (option["option_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ??
                (option["optionId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AIQuestionOptionInfo(
                optionID: optionID?.isEmpty == false ? optionID : nil,
                label: label,
                description: description
            )
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
            case .plan:
                if let payload = AIPlanCardPayload.from(source: part.source) {
                    lines.append(payload.summaryLine)
                } else {
                    lines.append("[计划] 已更新")
                }
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
            return .clear
        }
    }

    private var bubbleBorderColor: Color {
        return .clear
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
                    .onTapGesture {
                        fullscreenImageData = imageData
                    }
                    .help("点击查看大图")
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

// MARK: - 图片全屏查看支持

private struct FullscreenImageItem: Identifiable {
    let id = UUID()
    let data: Data
}

private struct FullscreenImageSheet: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .padding()
            }
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        #else
        NavigationView {
            Group {
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
            }
            .navigationTitle("图片查看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        #endif
    }
}
