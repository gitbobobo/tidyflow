import SwiftUI
import ImageIO
import CoreGraphics
import Shimmer

private struct ChatImagePreviewPayload {
    let data: Data
    let previewCGImage: CGImage
}

struct AIChatTranscriptDisplayCacheSnapshot {
    let messages: [AIChatMessage]
    let sourceCount: Int
}

enum AIChatTranscriptDisplayCacheSemantics {
    static func makeSnapshot(
        sourceMessages: [AIChatMessage],
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> AIChatTranscriptDisplayCacheSnapshot {
        AIChatTranscriptDisplayCacheSnapshot(
            messages: filteredDisplayMessages(
                from: sourceMessages,
                pendingQuestions: pendingQuestions
            ),
            sourceCount: sourceMessages.count
        )
    }

    /// 流式过程中只补丁尾消息，避免每个 token 都触发整表过滤；
    /// 一旦尾消息结束流式或消息数变化，则回退到完整重建，保证可见性判定不陈旧。
    static func synchronizeAfterTailChange(
        sourceMessages: [AIChatMessage],
        pendingQuestions: [String: AIQuestionRequestInfo],
        cachedDisplayMessages: [AIChatMessage],
        cachedSourceCount: Int
    ) -> AIChatTranscriptDisplayCacheSnapshot {
        guard cachedSourceCount == sourceMessages.count,
              let lastMessage = sourceMessages.last,
              lastMessage.isStreaming else {
            return makeSnapshot(
                sourceMessages: sourceMessages,
                pendingQuestions: pendingQuestions
            )
        }

        var nextMessages = cachedDisplayMessages
        if let lastIndex = nextMessages.indices.last,
           nextMessages[lastIndex].id == lastMessage.id {
            nextMessages[lastIndex] = lastMessage
        } else {
            nextMessages.append(lastMessage)
        }

        return AIChatTranscriptDisplayCacheSnapshot(
            messages: nextMessages,
            sourceCount: sourceMessages.count
        )
    }

    static func filteredDisplayMessages(
        from sourceMessages: [AIChatMessage],
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> [AIChatMessage] {
        sourceMessages.filter { message in
            if message.isStreaming { return true }
            return AIChatMessageLayoutSemantics.hasRenderableContent(
                in: message,
                pendingQuestions: pendingQuestions
            )
        }
    }
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
    let jumpToBottomClearance: CGFloat

    init(
        messages: [AIChatMessage],
        sessionToken: String?,
        canLoadOlderMessages: Bool = false,
        isLoadingOlderMessages: Bool = false,
        onLoadOlderMessages: (() -> Void)? = nil,
        bottomOverlayInset: CGFloat = 0,
        jumpToBottomClearance: CGFloat = AIChatComposerLayoutSemantics.jumpToBottomClearance,
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
        self.jumpToBottomClearance = jumpToBottomClearance
        self.onQuestionReply = onQuestionReply
        self.onQuestionReject = onQuestionReject
        self.onQuestionReplyAsMessage = onQuestionReplyAsMessage
        self.onOpenLinkedSession = onOpenLinkedSession
    }

    var body: some View {
        AIChatTranscriptContainer(
            messages: messages,
            sessionToken: sessionToken,
            canLoadOlderMessages: canLoadOlderMessages,
            isLoadingOlderMessages: isLoadingOlderMessages,
            onLoadOlderMessages: onLoadOlderMessages,
            bottomOverlayInset: bottomOverlayInset,
            jumpToBottomClearance: jumpToBottomClearance,
            onQuestionReply: onQuestionReply,
            onQuestionReject: onQuestionReject,
            onQuestionReplyAsMessage: onQuestionReplyAsMessage,
            onOpenLinkedSession: onOpenLinkedSession
        )
    }
}

struct AIChatTranscriptContainer: View {
    @Environment(AIChatStore.self) var aiChatStore
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
    let jumpToBottomClearance: CGFloat
    @State private var isNearBottom: Bool = true
    @State private var isAutoFollowActive: Bool = true
    @State private var scrollDistanceToBottom: CGFloat = 0
    @State private var scrollPolicy: ChatScrollPolicy = ChatScrollPolicy()
    @State private var lastTailMessageID: String?
    @State private var lastDisplayMessageCount: Int = 0
    @State private var visibleMessageIDs: Set<String> = []
    @State private var jumpToBottomRequestID: Int = 0
    @State private var scrollExecutionGate: ChatScrollExecutionGate = ChatScrollExecutionGate()
    @State private var pendingPrependAnchorID: String?
    /// 程序化滚动保护截止时间：在此时间点前，不允许因 onScrollGeometryChange 的异步反馈中断 autoFollow。
    /// 解决 proxy.scrollTo() 异步执行期间旧 metrics 误触发 autoFollow 断开的竞态问题。
    @State private var programmaticScrollProtectedUntil: Date = .distantPast
    /// 上一帧的 ScrollView 内容高度，用于区分"内容增长"和"用户滚动"。
    /// 当 distanceToBottom 增加时，如果内容高度同步增长，说明是内容推远了底部，而非用户主动滚离。
    @State private var lastKnownContentHeight: CGFloat = 0
    /// 缓存的显示消息列表，仅在消息数量或会话变化时完整重算。
    /// 流式增量更新只修改最后一条消息内容，无需重跑 O(n) filter。
    @State private var cachedDisplayMessages: [AIChatMessage] = []
    /// 上次完整重算时的消息数量，用于检测结构性变化。
    @State private var cachedDisplayMessageSourceCount: Int = -1

    static let bottomAnchorId = "ai_message_bottom_anchor"
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
        jumpToBottomClearance: CGFloat = AIChatComposerLayoutSemantics.jumpToBottomClearance,
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
        self.jumpToBottomClearance = jumpToBottomClearance
        self.onQuestionReply = onQuestionReply
        self.onQuestionReject = onQuestionReject
        self.onQuestionReplyAsMessage = onQuestionReplyAsMessage
        self.onOpenLinkedSession = onOpenLinkedSession
    }

    /// 返回当前显示消息列表：优先使用缓存，仅在流式消息内容变化时补丁最后一条。
    /// 完整的 filter 重算通过 recomputeDisplayMessages() 在 onChange 中触发。
    private var displayMessages: [AIChatMessage] {
        guard cachedDisplayMessageSourceCount == messages.count else {
            return recomputeDisplayMessagesSnapshot()
        }
        guard !cachedDisplayMessages.isEmpty else { return [] }
        // 流式期间，消息数量不变但最后一条消息内容持续更新。
        // 直接在缓存基础上补丁最后一条，避免 O(n) filter + displayNodes 计算。
        if let lastMessage = messages.last, lastMessage.isStreaming {
            var result = cachedDisplayMessages
            if let lastIdx = result.indices.last, result[lastIdx].id == lastMessage.id {
                result[lastIdx] = lastMessage
            } else {
                // 新的流式消息还未进入缓存，追加
                result.append(lastMessage)
            }
            return result
        }
        return cachedDisplayMessages
    }

    /// 完整重算显示消息（O(n) filter + displayNodes），仅在消息数量或结构变化时调用。
    private func recomputeDisplayMessagesSnapshot() -> [AIChatMessage] {
        AIChatTranscriptDisplayCacheSemantics.filteredDisplayMessages(
            from: messages,
            pendingQuestions: pendingQuestions
        )
    }

    private func refreshDisplayMessagesCache() {
        let snapshot = AIChatTranscriptDisplayCacheSemantics.makeSnapshot(
            sourceMessages: messages,
            pendingQuestions: pendingQuestions
        )
        cachedDisplayMessages = snapshot.messages
        cachedDisplayMessageSourceCount = snapshot.sourceCount
    }

    private func synchronizeDisplayMessagesCacheAfterTailChange() {
        let snapshot = AIChatTranscriptDisplayCacheSemantics.synchronizeAfterTailChange(
            sourceMessages: messages,
            pendingQuestions: pendingQuestions,
            cachedDisplayMessages: cachedDisplayMessages,
            cachedSourceCount: cachedDisplayMessageSourceCount
        )
        cachedDisplayMessages = snapshot.messages
        cachedDisplayMessageSourceCount = snapshot.sourceCount
    }

    var body: some View {
        let _ = Self.debugPrintChangesIfNeeded()
        ScrollViewReader { proxy in
            ScrollView {
                AIChatTranscriptContent(
                    messages: displayMessages,
                    pendingQuestions: pendingQuestions,
                    virtualizationWindow: virtualizationWindow,
                    visibleMessageIDs: visibleMessageIDs,
                    sessionId: aiChatStore.currentSessionId ?? "",
                    loadingOlderState: loadingOlderState,
                    bottomOverlayInset: bottomOverlayInset,
                    onLoadOlderMessages: handleLoadOlderMessages,
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
                    onOpenLinkedSession: onOpenLinkedSession,
                    onMessageAppear: { messageId in
                        visibleMessageIDs.insert(messageId)
                    },
                    onMessageDisappear: { messageId in
                        visibleMessageIDs.remove(messageId)
                    }
                )
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
                refreshDisplayMessagesCache()
                initializeScrollPolicyStateIfNeeded()
                // defaultScrollAnchor(.bottom) 处理初始定位，
                // 但仍需手动滚动以确保在已有消息时精确定位底部。
                executeScrollCommand(.scrollToBottom(.none), proxy: proxy)
            }
            .onChange(of: messages.count) { oldCount, newCount in
                refreshDisplayMessagesCache()
                handleMessageCountChanged(oldCount: oldCount, newCount: newCount, proxy: proxy)
            }
            .onChange(of: sessionToken) { _, _ in
                refreshDisplayMessagesCache()
                handleSessionTokenChangeIfNeeded()
            }
            .onChange(of: aiChatStore.tailRevision) { _, _ in
                synchronizeDisplayMessagesCacheAfterTailChange()
                handleTailChanged(proxy: proxy)
            }
            .onChange(of: jumpToBottomRequestID) {
                executeScrollCommand(.scrollToBottom(.jumpToBottom), proxy: proxy)
            }
            .onChange(of: bottomOverlayInset) { oldValue, newValue in
                // 输入框高度增加时（多行输入、待处理交互等），dock 向上扩展覆盖更多视口，
                // 而 ScrollView 滚动位置不变，导致原本可见的消息被遮挡。
                // 仅在 autoFollow 激活且 inset 增加时重新贴底，用无动画避免视觉跳动。
                guard newValue > oldValue, isAutoFollowActive else { return }
                scrollToBottom(proxy: proxy, animation: .none)
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

    private var loadingOlderState: AIChatLoadingOlderState {
        if isLoadingOlderMessages {
            return .loading
        }
        if canLoadOlderMessages {
            return .available
        }
        return .hidden
    }

    private func handleLoadOlderMessages() {
        pendingPrependAnchorID = currentTopVisibleAnchorID()
        onLoadOlderMessages?()
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
        lastKnownContentHeight = 0

        guard decision.command != .noOp else { return }
        jumpToBottomRequestID += 1
    }

    private func handleMessageCountChanged(oldCount: Int, newCount: Int, proxy: ScrollViewProxy) {
        guard newCount > oldCount else { return }
        guard let prependAnchor = pendingPrependAnchorID else { return }
        pendingPrependAnchorID = nil
        guard displayMessages.contains(where: { $0.id == prependAnchor }) else { return }
        let decision = scrollPolicy.reduce(event: .historyPrepended(anchorID: prependAnchor))
        executeScrollCommand(decision.command, proxy: proxy)
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
        guard decision.command != .noOp else { return }
        guard scrollExecutionGate.consumeAutoScrollRequest() else { return }
        executeScrollCommand(decision.command, proxy: proxy)
    }

    /// 按钮显隐只取决于是否在底部附近：到达底部时立即隐藏，无论 autoFollow 状态如何。
    /// autoFollow 的开关状态仅影响新消息到来时是否自动滚动，与按钮可见性语义无关。
    private var showJumpToBottomButton: Bool {
        !isNearBottom
    }

    private var jumpToBottomButton: some View {
        Button {
            _ = scrollPolicy.reduce(event: .jumpToBottomClicked)
            isAutoFollowActive = true
            isNearBottom = true
            scrollExecutionGate.beginManualJumpToBottom()
            jumpToBottomRequestID += 1
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 38, height: 38)
                .modifier(AIChatFloatingButtonStyle())
        }
        .buttonStyle(.plain)
        .padding(
            .bottom,
            bottomOverlayInset + jumpToBottomClearance
        )
    }

    private func currentTopVisibleAnchorID() -> String? {
        let msgs = displayMessages
        let visibleIndices = msgs.indices.filter { visibleMessageIDs.contains(msgs[$0].id) }
        guard let index = visibleIndices.min() else { return msgs.first?.id }
        return msgs[index].id
    }

    private func executeScrollCommand(_ command: ChatScrollCommand, proxy: ScrollViewProxy) {
        switch command {
        case .noOp:
            break
        case .scrollToBottom(let animation):
            scrollToBottom(proxy: proxy, animation: animation)
        case .preserveVisibleContentAfterPrepend(let anchorID):
            preserveVisibleContent(proxy: proxy, anchorID: anchorID)
        }
    }

    private func preserveVisibleContent(proxy: ScrollViewProxy, anchorID: String) {
        programmaticScrollProtectedUntil = Date().addingTimeInterval(0.2)
        proxy.scrollTo(anchorID, anchor: .top)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animation: ChatScrollAnimation = .none) {
        scrollDistanceToBottom = 0
        isNearBottom = true
        isAutoFollowActive = true
        // 设置保护窗口：proxy.scrollTo() 是异步的，滚动完成前 onScrollGeometryChange 可能
        // 仍报告旧的（偏离底部的）距离，错误中断 autoFollow。保护期内忽略这些误报。
        programmaticScrollProtectedUntil = Date().addingTimeInterval(0.5)
        let action = {
            proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
        }
        let finalizeManualJumpIfNeeded = {
            guard scrollExecutionGate.completeManualJumpToBottom() else { return }
            action()
            scrollDistanceToBottom = 0
            isNearBottom = true
            isAutoFollowActive = true
            _ = scrollPolicy.reduce(event: .userScrolled(nearBottom: true))
        }
        switch animation {
        case .none:
            action()
            finalizeManualJumpIfNeeded()
        case .smooth(let duration):
            withAnimation(.easeInOut(duration: duration)) {
                action()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.08) {
                finalizeManualJumpIfNeeded()
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
                finalizeManualJumpIfNeeded()
            }
        }
        // 自动滚动后刷新近底部确认时间戳
        _ = scrollPolicy.reduce(event: .userScrolled(nearBottom: true))
    }

    private func handleScrollMetricsChanged(_ metrics: MessageListScrollMetrics) {
        scrollDistanceToBottom = metrics.distanceToBottom
        let config = scrollPolicy.configuration
        let nearBottom = !metrics.canScrollVertically || metrics.distanceToBottom <= config.nearBottomThreshold

        // 用内容高度增量修正 autoFollow zone 判断：
        // 如果 distanceToBottom 增加是因为内容增长（流式输出），不应中断 autoFollow。
        // 只有扣除内容增长后仍超过阈值（即用户主动上滚），才视为离开底部。
        let contentHeightGrowth = max(0, metrics.contentHeight - lastKnownContentHeight)
        lastKnownContentHeight = metrics.contentHeight
        let adjustedDistance = max(0, metrics.distanceToBottom - contentHeightGrowth)
        let withinAutoFollowZone = !metrics.canScrollVertically || adjustedDistance <= config.autoFollowBreakThreshold

        updateNearBottomState(nearBottom: nearBottom, withinAutoFollowZone: withinAutoFollowZone)
    }
}

struct AIChatTranscriptContent: View {
    let messages: [AIChatMessage]
    let pendingQuestions: [String: AIQuestionRequestInfo]
    let virtualizationWindow: MessageVirtualizationWindow
    let visibleMessageIDs: Set<String>
    let sessionId: String
    let loadingOlderState: AIChatLoadingOlderState
    let bottomOverlayInset: CGFloat
    let onLoadOlderMessages: (() -> Void)?
    let questionRequestResolver: (String?, String?, String?, String?) -> AIQuestionRequestInfo?
    let onQuestionReply: (AIQuestionRequestInfo, [[String]]) -> Void
    let onQuestionReject: (AIQuestionRequestInfo) -> Void
    let onQuestionReplyAsMessage: (String) -> Void
    let onOpenLinkedSession: ((String) -> Void)?
    let onMessageAppear: (String) -> Void
    let onMessageDisappear: (String) -> Void

    private var showsStreamingFooter: Bool {
        guard let lastMessage = messages.last else { return false }
        return lastMessage.role == .assistant && lastMessage.isStreaming
    }

    var body: some View {
        let renderRange = precomputeFullRenderRange(for: messages)

        // 用 VStack 包裹，将底部锚点放在 LazyVStack 外部，确保无论滚到多远都能被 proxy.scrollTo 找到。
        // 若锚点留在 LazyVStack 内部，惰性渲染会在远离底部时将其从视图树移除，导致 scrollTo 静默失败。
        VStack(spacing: 0) {
            LazyVStack(spacing: 0) {
                loadingOlderHeader

                let msgIndexMap = Dictionary(
                    uniqueKeysWithValues: messages.enumerated().map { ($1.id, $0) }
                )
                ForEach(messages) { message in
                    let index = msgIndexMap[message.id] ?? 0
                    AIChatMessageRow(
                        message: message,
                        prefersFullRender: virtualizationWindow.shouldFullyRender(
                            index: index,
                            isStreaming: message.isStreaming,
                            fullRenderRange: renderRange,
                            totalCount: messages.count
                        ),
                        pendingQuestionToken: pendingQuestionToken(for: message),
                        pendingQuestions: pendingQuestions,
                        sessionId: sessionId,
                        questionRequestResolver: questionRequestResolver,
                        onQuestionReply: onQuestionReply,
                        onQuestionReject: onQuestionReject,
                        onQuestionReplyAsMessage: onQuestionReplyAsMessage,
                        onOpenLinkedSession: onOpenLinkedSession
                    )
                    .equatable()
                    .id(message.id)
                    .padding(.top, messageSpacing(at: index, in: messages))
                    .onAppear {
                        onMessageAppear(message.id)
                    }
                    .onDisappear {
                        onMessageDisappear(message.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if showsStreamingFooter {
                AIChatStreamingStatusFooter()
                    .padding(.horizontal, 24)
                    .padding(.leading, 6)
                    .padding(.top, messages.isEmpty ? 0 : 4)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            } else {
                Color.clear
                    .frame(height: 10)
            }

            // 为底部悬浮遮罩（输入框）预留弹出空间，始终在 LazyVStack 外部渲染，不受惰性卸载影响。
            Color.clear
                .frame(height: bottomOverlayInset)

            // 底部滚动锚点，必须始终存在于视图树中，供 proxy.scrollTo 可靠定位。
            Color.clear
                .frame(height: 1)
                .id(AIChatTranscriptContainer.bottomAnchorId)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var loadingOlderHeader: some View {
        switch loadingOlderState {
        case .hidden:
            EmptyView()
        case .loading:
            HStack {
                Spacer(minLength: 0)
                ProgressView("加载中…")
                    .controlSize(.small)
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
        case .available:
            HStack {
                Spacer(minLength: 0)
                Button("加载更早消息") {
                    onLoadOlderMessages?()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }

    private func precomputeFullRenderRange(for msgs: [AIChatMessage]) -> ClosedRange<Int>? {
        let visibleIndices = msgs.indices.filter { visibleMessageIDs.contains(msgs[$0].id) }
        return virtualizationWindow.computeFullRenderRange(
            visibleIndices: visibleIndices,
            totalCount: msgs.count
        )
    }

    private func pendingQuestionToken(for message: AIChatMessage) -> String {
        guard message.parts.contains(where: { $0.kind == .tool }) else {
            return ""
        }
        let items: [String] = message.parts.compactMap { part in
            guard part.kind == .tool else { return nil }
            let requestId = questionRequestIdFromPart(part)
            let request = questionRequestResolver(
                part.toolCallId,
                part.id,
                message.messageId,
                requestId
            ) ?? fallbackQuestionRequestFromPart(
                message: message,
                part: part,
                sessionId: sessionId
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

    private func messageSpacing(at index: Int, in messages: [AIChatMessage]) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = messages[index - 1]
        let current = messages[index]
        if isToolOnlyAssistantMessage(previous) && isToolOnlyAssistantMessage(current) {
            return 8
        }
        return 16
    }

    private func isToolOnlyAssistantMessage(_ message: AIChatMessage) -> Bool {
        guard message.role == .assistant, !message.parts.isEmpty else { return false }
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
}

private struct AIChatStreamingStatusFooter: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("思考中")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .shimmering(
                    active: true,
                    animation: .linear(duration: 1.4).repeatForever(autoreverses: false)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageListScrollMetrics: Equatable {
    let distanceToBottom: CGFloat
    let canScrollVertically: Bool
    let contentHeight: CGFloat

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
        self.contentHeight = contentHeight
    }
}

struct AIChatMessageRow: View, Equatable {
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

    static func == (lhs: AIChatMessageRow, rhs: AIChatMessageRow) -> Bool {
        lhs.message.id == rhs.message.id &&
            lhs.message.renderRevision == rhs.message.renderRevision &&
            lhs.message.isStreaming == rhs.message.isStreaming &&
            lhs.prefersFullRender == rhs.prefersFullRender &&
            lhs.pendingQuestionToken == rhs.pendingQuestionToken &&
            lhs.sessionId == rhs.sessionId
    }

    var body: some View {
        let nodes = AIChatMessageLayoutSemantics.displayNodes(
            for: message,
            pendingQuestions: pendingQuestions
        )
        let contentMaxWidth: CGFloat = isUser ? 520 : .infinity

        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            AIChatMessageBody(
                message: message,
                nodes: nodes,
                prefersFullRender: prefersFullRender,
                sessionId: sessionId,
                questionRequestResolver: questionRequestResolver,
                onQuestionReply: onQuestionReply,
                onQuestionReject: onQuestionReject,
                onQuestionReplyAsMessage: onQuestionReplyAsMessage,
                onOpenLinkedSession: onOpenLinkedSession,
                onOpenFullscreenImage: { fullscreenImageData = $0 }
            )
            .frame(maxWidth: contentMaxWidth, alignment: isUser ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, 8)
        .sheet(item: Binding(
            get: { fullscreenImageData.map { FullscreenImageItem(data: $0) } },
            set: { if $0 == nil { fullscreenImageData = nil } }
        )) { item in
            FullscreenImageSheet(data: item.data)
        }
    }
}

private struct AIChatMessageBody: View {
    let message: AIChatMessage
    let nodes: [AIChatMessageDisplayNode]
    let prefersFullRender: Bool
    let sessionId: String
    let questionRequestResolver: (String?, String?, String?, String?) -> AIQuestionRequestInfo?
    let onQuestionReply: (AIQuestionRequestInfo, [[String]]) -> Void
    let onQuestionReject: (AIQuestionRequestInfo) -> Void
    let onQuestionReplyAsMessage: (String) -> Void
    let onOpenLinkedSession: ((String) -> Void)?
    let onOpenFullscreenImage: (Data) -> Void

    private var isUser: Bool { message.role == .user }
    private var bubbleCornerRadius: CGFloat { 12 }
    private var primaryTextColor: Color { .primary }
    private var secondaryTextColor: Color { .secondary }

    var body: some View {
        Group {
            if !prefersFullRender {
                lightweightBubble
            } else {
                fullRenderBubble
            }
        }
    }

    private var fullRenderBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            if nodes.isEmpty {
                EmptyView()
            } else {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    displayNodeView(node)
                        .padding(.top, spacingBeforeNode(at: index))
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                }
            }
        }
        .animation(message.isStreaming ? nil : .easeOut(duration: 0.18), value: nodes.count)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bubbleBackgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: bubbleCornerRadius)
                .stroke(bubbleBorderColor, lineWidth: isUser ? 0 : 1)
        )
        .clipShape(.rect(cornerRadius: bubbleCornerRadius))
    }

    private var lightweightBubble: some View {
        let summary = compactSummaryText
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

    /// 相邻节点之间的动态间距规则：
    /// - 连续工具卡之间使用 8pt 紧凑间距，避免过度分散
    /// - 文本块紧接工具卡或计划卡时使用更宽松间距
    /// - 其余组合保持 10pt 阅读节奏
    private func spacingBeforeNode(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let previousPart = nodes[index - 1].part
        let currentPart = nodes[index].part
        switch (previousPart.kind, currentPart.kind) {
        case (.tool, .tool):
            return 8
        case (.tool, .text), (.tool, .reasoning), (.plan, .text), (.plan, .reasoning):
            return 12
        case (.text, .tool), (.reasoning, .tool):
            return 12
        default:
            return 10
        }
    }

    @ViewBuilder
    private func displayNodeView(_ node: AIChatMessageDisplayNode) -> some View {
        partContentView(node.part)
    }

    @ViewBuilder
    private func partContentView(_ part: AIChatPart) -> some View {
        switch part.kind {
        case .text, .reasoning:
            if let markdownText = markdownText(for: part) {
                MarkdownTextView(
                    text: markdownText,
                    role: isUser ? .user : .assistant,
                    baseFontSize: 13,
                    isStreaming: message.isStreaming
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
            ) ?? fallbackQuestionRequest(message: message, part: part)
            ToolCardView(
                name: part.toolName ?? "unknown",
                toolKind: part.toolKind,
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
        part: AIChatPart
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

    private var compactSummaryText: String {
        var lines: [String] = []
        for node in nodes {
            let part = node.part
            switch part.kind {
            case .text, .reasoning:
                let text = (part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
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
        return lines.joined(separator: "\n")
    }

    private var bubbleBackgroundColor: Color {
        isUser ? Color.primary.opacity(0.08) : .clear
    }

    private var bubbleBorderColor: Color {
        .clear
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

    private func markdownText(for part: AIChatPart) -> String? {
        guard let raw = part.text else { return nil }
        let displayText: String
        if part.kind == .reasoning, !isUser {
            displayText = blockQuoteMarkdown(for: raw)
        } else {
            displayText = raw
        }
        return normalizedMarkdownDisplayText(displayText, keepOriginalForUser: isUser)
    }

    private func blockQuoteMarkdown(for text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? ">" : "> \(line)"
            }
            .joined(separator: "\n")
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
                    onOpenFullscreen: onOpenFullscreenImage
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
        #if os(iOS)
        NavigationStack {
            imageContent
                .navigationTitle("图片查看")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            imageContent
        }
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image = decodeFullImage() {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .padding()
        } else {
            ContentUnavailableView("图片加载失败", systemImage: "photo")
        }
    }

    private func decodeFullImage() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
