import SwiftUI
import ImageIO
import CoreGraphics
import Shimmer
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private struct ChatImagePreviewPayload {
    let data: Data
    let previewCGImage: CGImage
}

private actor ChatImageLoader {
    static let shared = ChatImageLoader()

    private struct CacheEntry {
        let payload: ChatImagePreviewPayload?
        let failedAt: Date?
    }

    private var cache: [String: CacheEntry] = [:]
    private let failureTTL: TimeInterval = 30
    private let previewMaxPixelSize = 1_400

    func loadImage(key: String, urlString: String) async -> ChatImagePreviewPayload? {
        if let entry = cache[key] {
            if let payload = entry.payload {
                return payload
            }
            if let failedAt = entry.failedAt,
               Date().timeIntervalSince(failedAt) < failureTTL {
                return nil
            }
        }

        let payload = await Task.detached(priority: .utility) { [previewMaxPixelSize] in
            Self.makePayload(urlString: urlString, previewMaxPixelSize: previewMaxPixelSize)
        }.value

        if let payload {
            cache[key] = CacheEntry(payload: payload, failedAt: nil)
        } else {
            cache[key] = CacheEntry(payload: nil, failedAt: Date())
        }
        return payload
    }

    private static func makePayload(urlString: String, previewMaxPixelSize: Int) -> ChatImagePreviewPayload? {
        guard let data = loadData(urlString: urlString),
              let previewCGImage = makePreviewImage(data: data, previewMaxPixelSize: previewMaxPixelSize) else {
            return nil
        }
        return ChatImagePreviewPayload(data: data, previewCGImage: previewCGImage)
    }

    private static func loadData(urlString: String) -> Data? {
        if let data = decodeDataURL(urlString) {
            return data
        }
        guard let url = URL(string: urlString), url.isFileURL else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func decodeDataURL(_ value: String) -> Data? {
        guard value.hasPrefix("data:"),
              let comma = value.firstIndex(of: ",") else { return nil }
        let header = String(value[..<comma]).lowercased()
        let payload = String(value[value.index(after: comma)...])

        if header.contains(";base64") {
            return Data(base64Encoded: payload)
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    private static func makePreviewImage(data: Data, previewMaxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixelSize
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return thumbnail
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
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
    let bottomOverlayInset: CGFloat
    @State private var isNearBottom: Bool = true
    @State private var isAutoFollowActive: Bool = true
    @State private var scrollDistanceToBottom: CGFloat = 0
    @State private var scrollPolicy: ChatScrollPolicy = ChatScrollPolicy()
    @State private var lastTailMessageID: String?
    @State private var lastDisplayMessageCount: Int = 0
    @State private var visibleMessageIDs: Set<String> = []
    @State private var jumpToBottomRequestID: Int = 0
    /// 程序化滚动保护截止时间：在此时间点前，不允许因 onScrollGeometryChange 的异步反馈中断 autoFollow。
    /// 解决 proxy.scrollTo() 异步执行期间旧 metrics 误触发 autoFollow 断开的竞态问题。
    @State private var programmaticScrollProtectedUntil: Date = .distantPast

    private let bottomAnchorId = "ai_message_bottom_anchor"
    /// 虚拟化窗口决策模型；buffer=12 与 ChatScrollConfiguration.renderBufferCount 保持一致。
    private let virtualizationWindow = MessageVirtualizationWindow()
    private var pendingQuestions: [String: AIQuestionRequestInfo] { aiChatStore.pendingToolQuestions }

    init(
        messages: [AIChatMessage],
        sessionToken: String?,
        canLoadOlderMessages: Bool = false,
        isLoadingOlderMessages: Bool = false,
        onLoadOlderMessages: (() -> Void)? = nil,
        bottomOverlayInset: CGFloat = 0,
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
        self.bottomOverlayInset = bottomOverlayInset
        self.onQuestionReply = onQuestionReply
        self.onQuestionReject = onQuestionReject
        self.onQuestionReplyAsMessage = onQuestionReplyAsMessage
        self.onOpenLinkedSession = onOpenLinkedSession
    }

    /// 过滤掉"无可见内容且非流式"的消息，避免空消息把相邻回复撑开。
    private var displayMessages: [AIChatMessage] {
        messages.filter { message in
            if message.isStreaming { return true }
            return AIChatMessageLayoutSemantics.hasRenderableContent(
                in: message,
                pendingQuestions: pendingQuestions
            )
        }
    }

    /// 预计算虚拟化渲染范围，供 messageStack() 在 ForEach 外一次性调用。
    /// 避免在 ForEach 内部对每条消息重复触发 O(n) 扫描，将 O(n²) 降为 O(n)。
    private func precomputeFullRenderRange(for msgs: [AIChatMessage]) -> ClosedRange<Int>? {
        let visibleIndices = msgs.indices.filter { visibleMessageIDs.contains(msgs[$0].id) }
        return virtualizationWindow.computeFullRenderRange(
            visibleIndices: visibleIndices,
            totalCount: msgs.count
        )
    }

    var body: some View {
        let _ = Self.debugPrintChangesIfNeeded()
        ScrollViewReader { proxy in
            ScrollView {
                messageStack()
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(
                for: MessageListScrollMetrics.self,
                of: { geometry in
                    MessageListScrollMetrics(geometry: geometry)
                },
                action: { _, metrics in
                    handleScrollMetricsChanged(metrics)
                }
            )
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onAppear {
                initializeScrollPolicyStateIfNeeded()
                // defaultScrollAnchor(.bottom) 处理初始定位，
                // 但仍需手动滚动以确保在已有消息时精确定位底部。
                scrollToBottom(proxy: proxy, animation: .none)
            }
            .onChange(of: sessionToken) { _, _ in
                handleSessionTokenChangeIfNeeded()
            }
            .onChange(of: aiChatStore.tailRevision) { _, _ in
                handleTailChanged(proxy: proxy)
            }
            .onChange(of: jumpToBottomRequestID) {
                scrollToBottom(proxy: proxy, animation: .jumpToBottom)
            }
        }
        .tfRenderProbe("AIMessageList", metadata: [
            "session": sessionToken ?? "none",
            "message_count": String(messages.count)
        ])
        .overlay(alignment: .bottom) {
            if showJumpToBottomButton {
                jumpToBottomButton
            }
        }
    }

    private static func debugPrintChangesIfNeeded() {
        SwiftUIPerformanceDebug.runPrintChangesIfEnabled(
            SwiftUIPerformanceDebug.aiMessageListPrintChangesEnabled
        ) {
#if DEBUG
            Self._printChanges()
#endif
        }
    }

    @ViewBuilder
    private func messageStack() -> some View {
        // 提前计算避免 ForEach 内部重复调用 O(n) 的 displayMessages，将整体复杂度从 O(n²) 降为 O(n)。
        let msgs = displayMessages
        let renderRange = precomputeFullRenderRange(for: msgs)

        LazyVStack(spacing: 0) {
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

            ForEach(Array(msgs.enumerated()), id: \.element.id) { index, message in
                MessageBubble(
                    message: message,
                    prefersFullRender: virtualizationWindow.shouldFullyRender(
                        index: index,
                        isStreaming: message.isStreaming,
                        fullRenderRange: renderRange,
                        totalCount: msgs.count
                    ),
                    pendingQuestionToken: pendingQuestionToken(for: message),
                    pendingQuestions: pendingQuestions,
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
                .padding(.top, messageSpacing(at: index, in: msgs))
                .onAppear {
                    visibleMessageIDs.insert(message.id)
                }
                .onDisappear {
                    visibleMessageIDs.remove(message.id)
                }
            }

            Color.clear
                .frame(height: bottomOverlayInset)

            Color.clear
                .frame(height: 1)
                .id(bottomAnchorId)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 统一的工具卡片消息间距常量（8pt），macOS 与 iOS 共用
    private static let toolCardSpacing: CGFloat = 8

    /// 消息间动态间距规则：
    /// - 连续工具类消息（assistant 且全为工具/推理 part）之间使用 8pt 紧凑间距，
    ///   与同一消息内部 part 间距保持一致，避免视觉不规则。
    /// - 其余组合保持 16pt 阅读节奏。
    private func messageSpacing(at index: Int, in messages: [AIChatMessage]) -> CGFloat {
        guard index > 0 else { return 0 }
        let prev = messages[index - 1]
        let current = messages[index]
        if isToolOnlyAssistantMessage(prev) && isToolOnlyAssistantMessage(current) {
            return Self.toolCardSpacing
        }
        return 16
    }

    /// 是否为工具类 assistant 消息（所有有实际内容的 part 均为 tool 或 reasoning）
    private func isToolOnlyAssistantMessage(_ message: AIChatMessage) -> Bool {
        guard message.role == .assistant, !message.parts.isEmpty else { return false }
        // 过滤出有实际内容的 part（空 text part 不计入判断）
        let significantParts = message.parts.filter { part in
            switch part.kind {
            case .tool, .reasoning, .file, .plan, .compaction:
                return true
            case .text:
                let trimmed = (part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty
            }
        }
        guard !significantParts.isEmpty else { return false }
        return significantParts.allSatisfy { $0.kind == .tool || $0.kind == .reasoning }
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
            // 区间 1：在底部附近，确认并可能恢复 autoFollow，同时清除保护期
            programmaticScrollProtectedUntil = .distantPast
            _ = scrollPolicy.reduce(event: .userScrolled(nearBottom: true))
            isAutoFollowActive = scrollPolicy.isAutoScrollEnabled
        } else if !withinAutoFollowZone {
            // 区间 3：远离底部，但若在程序化滚动保护期内，忽略此误报，避免竞态中断 autoFollow
            guard Date() >= programmaticScrollProtectedUntil else { return }
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
        // 新消息出现（messageAppended）用 spring 动画，流式增量（throttledScrollToBottom）保持无动画避免频繁抖动。
        let animation: ChatScrollAnimation = decision.action == .scrollToBottom ? .spring() : .none
        scrollToBottom(proxy: proxy, animation: animation)
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
                .foregroundStyle(Color.primary)
                .frame(width: 38, height: 38)
                .modifier(AIChatFloatingButtonStyle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, bottomOverlayInset + 4)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animation: ChatScrollAnimation = .none) {
        scrollDistanceToBottom = 0
        isNearBottom = true
        isAutoFollowActive = true
        // 设置保护窗口：proxy.scrollTo() 是异步的，滚动完成前 onScrollGeometryChange 可能
        // 仍报告旧的（偏离底部的）距离，错误中断 autoFollow。保护期内忽略这些误报。
        programmaticScrollProtectedUntil = Date().addingTimeInterval(0.5)
        let action = {
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
        }
        switch animation {
        case .none:
            action()
        case .smooth(let duration):
            withAnimation(.easeInOut(duration: duration)) {
                action()
            }
        case .spring(let response, let dampingFraction):
            withAnimation(.spring(response: response, dampingFraction: dampingFraction)) {
                action()
            }
            // SwiftUI 的动画滚动在 macOS 上有时会停在距底部几个像素的位置，
            // 动画结束后再补一次无动画校正，确保最终精确贴到底部。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                guard isAutoFollowActive else { return }
                action()
                scrollDistanceToBottom = 0
                isNearBottom = true
                isAutoFollowActive = true
                _ = scrollPolicy.reduce(event: .userScrolled(nearBottom: true))
            }
        }
        // 自动滚动后刷新近底部确认时间戳
        _ = scrollPolicy.reduce(event: .userScrolled(nearBottom: true))
    }

    private func handleScrollMetricsChanged(_ metrics: MessageListScrollMetrics) {
        scrollDistanceToBottom = metrics.distanceToBottom
        let config = scrollPolicy.configuration
        let nearBottom = !metrics.canScrollVertically || metrics.distanceToBottom <= config.nearBottomThreshold
        let withinAutoFollowZone = !metrics.canScrollVertically || metrics.distanceToBottom <= config.autoFollowBreakThreshold
        updateNearBottomState(nearBottom: nearBottom, withinAutoFollowZone: withinAutoFollowZone)
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
        let trimmed = part.toolView?.question?.requestID
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let question = part.toolView?.question, question.interactive else { return nil }
        let questions = question.promptItems
        guard !questions.isEmpty else { return nil }

        let trimmedRequestId = question.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestId = trimmedRequestId.isEmpty
            ? (part.toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? part.id)
            : trimmedRequestId
        guard !requestId.isEmpty else { return nil }

        return AIQuestionRequestInfo(
            id: requestId,
            sessionId: sessionId,
            questions: questions,
            toolMessageId: question.toolMessageID ?? message.messageId ?? part.id,
            toolCallId: part.toolCallId
        )
    }
}

private struct MessageListScrollMetrics: Equatable {
    let distanceToBottom: CGFloat
    let canScrollVertically: Bool

    init(geometry: ScrollGeometry) {
        let contentHeight = geometry.contentSize.height
        let visibleMaxY = geometry.visibleRect.maxY
        let distanceByVisibleRect = max(0, contentHeight - visibleMaxY)

        let maxOffsetY = max(0, contentHeight - geometry.containerSize.height)
        let rawOffsetY = geometry.contentOffset.y + geometry.contentInsets.top
        let clampedOffsetY = min(max(rawOffsetY, 0), maxOffsetY)
        let distanceByOffset = max(0, maxOffsetY - clampedOffsetY)

        self.distanceToBottom = max(distanceByVisibleRect, distanceByOffset)
        self.canScrollVertically = maxOffsetY > 1
    }
}

private struct MessageBubble: View, Equatable {
    let message: AIChatMessage
    let prefersFullRender: Bool
    let pendingQuestionToken: String
    let pendingQuestions: [String: AIQuestionRequestInfo]
    let sessionId: String
    let questionRequestResolver: (String?, String?, String?, String?) -> AIQuestionRequestInfo?
    let onQuestionReply: (AIQuestionRequestInfo, [[String]]) -> Void
    let onQuestionReject: (AIQuestionRequestInfo) -> Void
    let onQuestionReplyAsMessage: (String) -> Void
    let onOpenLinkedSession: ((String) -> Void)?

    @State private var fullscreenImageData: Data?

    private var isUser: Bool { message.role == .user }
    private var bubbleCornerRadius: CGFloat { 12 }
    private var usesWideAssistantLayout: Bool {
        guard !isUser else { return false }
        let nodes = displayNodes
        guard !nodes.isEmpty else { return false }
        return nodes.allSatisfy { node in
            switch node {
            case .textGroup:
                return false
            case .part(let part):
                switch part.kind {
                case .tool, .plan, .compaction:
                    return true
                case .text, .reasoning, .file:
                    return false
                }
            }
        }
    }
    private var contentMaxWidth: CGFloat {
        if isUser {
            return 520
        }
        return usesWideAssistantLayout ? .infinity : 760
    }
    private var trailingBubblePadding: CGFloat {
        if isUser { return 0 }
        return usesWideAssistantLayout ? 8 : 12
    }
    private var primaryTextColor: Color { .primary }
    private var secondaryTextColor: Color { .secondary }

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message.id == rhs.message.id &&
            lhs.message.renderRevision == rhs.message.renderRevision &&
            lhs.message.isStreaming == rhs.message.isStreaming &&
            lhs.prefersFullRender == rhs.prefersFullRender &&
            lhs.pendingQuestionToken == rhs.pendingQuestionToken &&
            lhs.sessionId == rhs.sessionId
    }

    private var displayNodes: [AIChatMessageDisplayNode] {
        AIChatMessageLayoutSemantics.displayNodes(
            for: message,
            pendingQuestions: pendingQuestions
        )
    }

    private var showsStreamingStatus: Bool {
        !isUser && message.isStreaming
    }

    /// 相邻节点之间的动态间距规则：
    /// - 连续工具卡之间使用 8pt 紧凑间距，避免过度分散
    /// - 文本块紧接工具卡或计划卡时使用更宽松间距
    /// - 其余组合保持 10pt 阅读节奏
    private func spacingBeforeNode(at index: Int, in nodes: [AIChatMessageDisplayNode]) -> CGFloat {
        guard index > 0 else { return 0 }
        let previousNode = nodes[index - 1]
        let currentNode = nodes[index]
        switch (previousNode, currentNode) {
        case (.part(let lhs), .part(let rhs)) where lhs.kind == .tool && rhs.kind == .tool:
            return 8
        case (.part(let lhs), .textGroup) where lhs.kind == .tool || lhs.kind == .plan:
            return 12
        case (.textGroup, .part(let rhs)) where rhs.kind == .tool:
            return 12
        default:
            return 10
        }
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            bubble
                .frame(maxWidth: contentMaxWidth, alignment: isUser ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.trailing, trailingBubblePadding)
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
            let nodes = displayNodes
            VStack(alignment: .leading, spacing: 0) {
                if nodes.isEmpty {
                    EmptyView()
                } else {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        displayNodeView(node)
                            .padding(.top, spacingBeforeNode(at: index, in: nodes))
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                    }
                }
                if showsStreamingStatus {
                    streamingStatusView
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: nodes.count)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bubbleBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .stroke(bubbleBorderColor, lineWidth: isUser ? 0 : 1)
            )
            .clipShape(.rect(cornerRadius: bubbleCornerRadius))
        }
    }

    @ViewBuilder
    private func displayNodeView(_ node: AIChatMessageDisplayNode) -> some View {
        switch node {
        case .textGroup(let group):
            textGroupView(group)
        case .part(let part):
            partContentView(part)
        }
    }

    @ViewBuilder
    private func textGroupView(_ group: AIChatTextRunGroup) -> some View {
        if let markdownText = normalizedMarkdownDisplayText(
            group.markdownText(renderReasoningAsBlockQuote: !isUser),
            keepOriginalForUser: isUser
        ) {
            MarkdownTextView(
                text: markdownText,
                role: isUser ? .user : .assistant,
                baseFontSize: 13
            )
        }
    }

    @ViewBuilder
    private func partContentView(_ part: AIChatPart) -> some View {
        switch part.kind {
        case .text, .reasoning:
            EmptyView()
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
                callID: part.toolCallId,
                toolView: part.toolView,
                questionRequest: pendingQuestion,
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
        let direct = part.toolView?.question?.requestID
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
        guard let question = part.toolView?.question, question.interactive else { return nil }
        let questions = question.promptItems
        guard !questions.isEmpty else { return nil }

        let requestId =
            questionRequestId(from: part) ??
            part.toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            part.id
        guard !requestId.isEmpty else { return nil }

        return AIQuestionRequestInfo(
            id: requestId,
            sessionId: sessionId,
            questions: questions,
            toolMessageId: question.toolMessageID ?? message.messageId ?? part.id,
            toolCallId: part.toolCallId
        )
    }

    private var streamingStatusView: some View {
        HStack(spacing: 0) {
            Text("思考中")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .shimmering(active: true, animation: .linear(duration: 1.4).repeatForever(autoreverses: false))
        }
        .padding(.top, displayNodes.isEmpty ? 0 : 4)
    }

    private var lightweightBubble: some View {
        let summary = compactSummaryText()
        return VStack(alignment: .leading, spacing: 6) {
            if summary.isEmpty {
                Text("...")
                    .font(.system(size: 12))
                    .foregroundStyle(isUser ? primaryTextColor.opacity(0.85) : .secondary)
            } else {
                Text(summary)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bubbleBackgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: bubbleCornerRadius)
                .stroke(bubbleBorderColor, lineWidth: isUser ? 0 : 1)
        )
        .clipShape(.rect(cornerRadius: bubbleCornerRadius))
    }

    private func compactSummaryText() -> String {
        var lines: [String] = []
        for node in displayNodes {
            switch node {
            case .textGroup(let group):
                let text = group.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lines.append(text)
                }
            case .part(let part):
                switch part.kind {
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
                case .text, .reasoning:
                    break
                }
            }
        }
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n")
    }

    private var bubbleBackgroundColor: Color {
        if isUser {
            return Color.primary.opacity(0.08)
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

    private func styledStreamingText(for group: AIChatTextRunGroup) -> Text? {
        var result: Text?

        for run in group.displayRuns {
            guard let normalizedText = normalizedStreamingDisplayText(
                run.text,
                keepOriginalForUser: isUser
            ) else {
                continue
            }

            let chunk = Text(verbatim: normalizedText)
                .foregroundColor(
                    (!isUser && run.kind == .reasoning) ? .secondary : .primary
                )

            result = result.map { $0 + chunk } ?? chunk
        }

        return result
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
        let fileName = part.filename ?? "attachment"
        let mime = part.mime ?? "application/octet-stream"
        let isImageAttachment = mime.lowercased().hasPrefix("image/")
        let hidesMetadata = isUser && isImageAttachment

        VStack(alignment: .leading, spacing: 8) {
            if let cacheKey = imageCacheKey(for: part),
               let imageURL = part.url,
               isImageAttachment {
                AsyncChatAttachmentImageView(
                    cacheKey: cacheKey,
                    urlString: imageURL,
                    onOpenFullscreen: { data in
                        fullscreenImageData = data
                    }
                )
                .frame(maxWidth: 320, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
                .help("点击查看大图")
            }

            if !hidesMetadata {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12))
                        .foregroundStyle(secondaryTextColor)
                    Text(fileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                }

                Text(mime)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryTextColor)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func imageCacheKey(for part: AIChatPart) -> String? {
        guard let url = part.url, !url.isEmpty else { return nil }
        return "\(part.id)|\(url)"
    }
}

private struct AIChatFloatingButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
        }
        #else
        content
        #endif
    }
}

// MARK: - 图片全屏查看支持

private struct AsyncChatAttachmentImageView: View {
    let cacheKey: String
    let urlString: String
    let onOpenFullscreen: (Data) -> Void

    @State private var payload: ChatImagePreviewPayload?
    @State private var loading = false

    var body: some View {
        Group {
            if let payload {
                Image(decorative: payload.previewCGImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .onTapGesture {
                        onOpenFullscreen(payload.data)
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        if loading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .task(id: cacheKey) {
            loading = true
            payload = await ChatImageLoader.shared.loadImage(key: cacheKey, urlString: urlString)
            loading = false
        }
    }
}

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
