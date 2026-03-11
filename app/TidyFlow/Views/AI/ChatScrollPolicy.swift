import Foundation
import CoreGraphics

enum ChatScrollState: Equatable {
    case autoFollow(Bool)
    case nearBottom(Bool)
}

enum ChatScrollEvent: Equatable {
    case messageAppended
    case messageIncremented
    case historyPrepended(anchorID: String)
    case userScrolled(nearBottom: Bool)
    case jumpToBottomClicked
    case sessionSwitched
}

enum ChatScrollAnimation: Equatable {
    case none
    case smooth(duration: TimeInterval = 0.20)
    case spring(response: Double = 0.28, dampingFraction: Double = 0.85)

    static let `default`: ChatScrollAnimation = .spring()
    static let jumpToBottom: ChatScrollAnimation = .smooth()
}

struct ChatScrollConfiguration: Equatable {
    let bottomTolerance: CGFloat
    let nearBottomThreshold: CGFloat
    let autoResumeThreshold: CGFloat
    /// 中断 autoFollow 的宽松阈值：仅当滚动距离超过此值时才视为用户主动离开底部。
    /// 比 nearBottomThreshold 宽松得多，防止流式输出时内容增长速度超过异步滚动导致 autoFollow 被误断。
    let autoFollowBreakThreshold: CGFloat
    let renderBufferCount: Int
    let incrementThrottleInterval: TimeInterval
    /// 近底部确认超时时间：仅当最近一次确认在底部的时间在此范围内时才允许自动滚动。
    /// 用于解决滚动检测延迟导致的竞态条件（尤其是 macOS 鼠标滚轮）。
    let nearBottomConfirmationTimeout: TimeInterval
    let animation: ChatScrollAnimation

    init(
        bottomTolerance: CGFloat = 36,
        nearBottomThreshold: CGFloat? = nil,
        autoResumeThreshold: CGFloat? = nil,
        autoFollowBreakThreshold: CGFloat = 200,
        renderBufferCount: Int = 12,
        incrementThrottleInterval: TimeInterval = 0.08,
        nearBottomConfirmationTimeout: TimeInterval = 0.5,
        animation: ChatScrollAnimation = .default
    ) {
        self.bottomTolerance = bottomTolerance
        self.nearBottomThreshold = nearBottomThreshold ?? bottomTolerance
        self.autoResumeThreshold = autoResumeThreshold ?? (nearBottomThreshold ?? bottomTolerance)
        self.autoFollowBreakThreshold = autoFollowBreakThreshold
        self.renderBufferCount = renderBufferCount
        self.incrementThrottleInterval = incrementThrottleInterval
        self.nearBottomConfirmationTimeout = nearBottomConfirmationTimeout
        self.animation = animation
    }
}

struct ChatScrollPlatformConfiguration {
    static let shared: ChatScrollConfiguration = {
#if os(iOS)
        ChatScrollConfiguration()
#elseif os(macOS)
        ChatScrollConfiguration()
#else
        ChatScrollConfiguration()
#endif
    }()
}

struct ChatScrollDecision: Equatable {
    let command: ChatScrollCommand
    let states: [ChatScrollState]

    var shouldScrollToBottom: Bool {
        switch command {
        case .noOp, .preserveVisibleContentAfterPrepend:
            return false
        case .scrollToBottom:
            return true
        }
    }
}

enum ChatScrollCommand: Equatable {
    case noOp
    case scrollToBottom(ChatScrollAnimation)
    case preserveVisibleContentAfterPrepend(anchorID: String)
}

/// 协调“用户手动回到底部”和“尾部更新触发的自动贴底”之间的执行时机。
///
/// 当用户主动点击回底按钮后，列表通常会进入一小段程序化滚动窗口；
/// 若此时流式输出或新消息继续推进，自动贴底会与这次手动滚动重叠，
/// 造成动画打架、状态重复写入或按钮显隐闪烁。
///
/// 这个闸门的策略是：
/// 1. 手动回底进行中，自动贴底请求先记为 deferred，不立即执行；
/// 2. 手动回底结束后，若期间确实积累了自动贴底请求，仅补一次最终校正。
struct ChatScrollExecutionGate: Equatable {
    private(set) var isManualJumpToBottomInFlight: Bool = false
    private(set) var hasDeferredAutoScroll: Bool = false

    mutating func beginManualJumpToBottom() {
        isManualJumpToBottomInFlight = true
        hasDeferredAutoScroll = false
    }

    /// 返回 true 表示可以立即执行自动贴底；false 表示应先延后。
    mutating func consumeAutoScrollRequest() -> Bool {
        guard isManualJumpToBottomInFlight else { return true }
        hasDeferredAutoScroll = true
        return false
    }

    /// 结束一次手动回底；返回值表示是否需要补一次延后的自动贴底。
    mutating func completeManualJumpToBottom() -> Bool {
        guard isManualJumpToBottomInFlight else { return false }
        isManualJumpToBottomInFlight = false
        let shouldRunDeferredAutoScroll = hasDeferredAutoScroll
        hasDeferredAutoScroll = false
        return shouldRunDeferredAutoScroll
    }
}

final class ChatScrollPolicy {
    private(set) var autoFollow: Bool
    private(set) var nearBottom: Bool

    let configuration: ChatScrollConfiguration

    private var lastIncrementScrollAt: Date?
    /// 最近一次确认处于底部附近的时间戳；用于跨帧竞态保护。
    private(set) var lastNearBottomConfirmedAt: Date?

    init(
        initialAutoFollow: Bool = true,
        initialNearBottom: Bool = true,
        configuration: ChatScrollConfiguration = ChatScrollPlatformConfiguration.shared
    ) {
        self.autoFollow = initialAutoFollow
        self.nearBottom = initialNearBottom
        self.configuration = configuration
        // 初始化时若在底部附近，立即确认
        if initialNearBottom {
            self.lastNearBottomConfirmedAt = Date()
        }
    }

    var isAutoScrollEnabled: Bool {
        autoFollow
    }

    var currentStates: [ChatScrollState] {
        [.autoFollow(autoFollow), .nearBottom(nearBottom)]
    }

    /// 检查近底部确认是否仍然有效（未过期）
    var isNearBottomConfirmationFresh: Bool {
        guard let confirmedAt = lastNearBottomConfirmedAt else { return false }
        return Date().timeIntervalSince(confirmedAt) < configuration.nearBottomConfirmationTimeout
    }

    @discardableResult
    func reduce(event: ChatScrollEvent, now: Date = Date()) -> ChatScrollDecision {
        let command: ChatScrollCommand

        switch event {
        case .messageAppended:
            command = handleMessageAppended(now: now)
        case .messageIncremented:
            command = handleMessageIncremented(now: now)
        case .historyPrepended(let anchorID):
            command = .preserveVisibleContentAfterPrepend(anchorID: anchorID)
        case .userScrolled(let updatedNearBottom):
            command = handleUserScrolled(updatedNearBottom: updatedNearBottom, now: now)
        case .jumpToBottomClicked:
            command = handleJumpToBottomClicked(now: now)
        case .sessionSwitched:
            command = handleSessionSwitched(now: now)
        }

        return ChatScrollDecision(command: command, states: currentStates)
    }

    @discardableResult
    func shouldScrollToBottom(for event: ChatScrollEvent, now: Date = Date()) -> Bool {
        reduce(event: event, now: now).shouldScrollToBottom
    }

    private func handleMessageAppended(now: Date) -> ChatScrollCommand {
        guard autoFollow else { return .noOp }
        // 当 autoFollow 和 nearBottom 都为 true 时，直接滚动（无需确认超时检查）。
        // 确认超时仅用于处理 nearBottom 不确定时的竞态条件。
        if nearBottom { return .scrollToBottom(.spring()) }
        guard isNearBottomConfirmationFreshAt(now) else { return .noOp }
        return .scrollToBottom(.spring())
    }

    private func handleMessageIncremented(now: Date) -> ChatScrollCommand {
        guard autoFollow else { return .noOp }
        // 当 nearBottom 为 true 时直接通过；否则需确认超时仍有效
        if !nearBottom {
            guard isNearBottomConfirmationFreshAt(now) else { return .noOp }
        }
        guard let lastIncrementScrollAt else {
            self.lastIncrementScrollAt = now
            return .scrollToBottom(.none)
        }

        let delta = now.timeIntervalSince(lastIncrementScrollAt)
        guard delta >= configuration.incrementThrottleInterval else {
            return .noOp
        }

        self.lastIncrementScrollAt = now
        return .scrollToBottom(.none)
    }

    private func handleUserScrolled(updatedNearBottom: Bool, now: Date) -> ChatScrollCommand {
        nearBottom = updatedNearBottom

        if updatedNearBottom {
            lastNearBottomConfirmedAt = now
        }

        if autoFollow, !updatedNearBottom {
            autoFollow = false
            lastNearBottomConfirmedAt = nil
            return .noOp
        }

        if !autoFollow, updatedNearBottom {
            autoFollow = true
            return .noOp
        }

        return .noOp
    }

    private func handleJumpToBottomClicked(now: Date) -> ChatScrollCommand {
        autoFollow = true
        nearBottom = true
        lastIncrementScrollAt = now
        lastNearBottomConfirmedAt = now
        return .scrollToBottom(.jumpToBottom)
    }

    private func handleSessionSwitched(now: Date) -> ChatScrollCommand {
        autoFollow = true
        nearBottom = true
        lastIncrementScrollAt = now
        lastNearBottomConfirmedAt = now
        return .scrollToBottom(.jumpToBottom)
    }

    /// 检查指定时刻近底部确认是否仍新鲜
    private func isNearBottomConfirmationFreshAt(_ now: Date) -> Bool {
        guard let confirmedAt = lastNearBottomConfirmedAt else { return false }
        return now.timeIntervalSince(confirmedAt) < configuration.nearBottomConfirmationTimeout
    }
}

// MARK: - 消息虚拟化窗口模型

/// 消息列表虚拟化窗口决策模型。
///
/// 封装可见区缓冲区计算与完整/轻量渲染决策逻辑，使其与 SwiftUI 视图解耦，
/// 可在单元测试中独立验证，适用于普通聊天、回放聊天和子代理会话等所有场景。
struct MessageVirtualizationWindow: Equatable {
    /// 缓冲区大小：可见窗口两端各预热的消息数量。
    let bufferCount: Int
    /// warm start 倍数：首次无可见信息时从尾部预热的范围（bufferCount × warmStartMultiplier）。
    let warmStartMultiplier: Int

    init(bufferCount: Int = 12, warmStartMultiplier: Int = 3) {
        self.bufferCount = bufferCount
        self.warmStartMultiplier = warmStartMultiplier
    }

    /// 根据已知可见消息索引，计算完整渲染索引范围（含两端缓冲区）。
    ///
    /// - Parameters:
    ///   - visibleIndices: 当前确认可见的消息索引集合（由 onAppear/onDisappear 跟踪）
    ///   - totalCount: 消息总数
    /// - Returns: 完整渲染范围；若 visibleIndices 为空则返回 nil（调用方应回退到 warm start）
    func computeFullRenderRange(visibleIndices: [Int], totalCount: Int) -> ClosedRange<Int>? {
        guard totalCount > 0,
              let minVisible = visibleIndices.min(),
              let maxVisible = visibleIndices.max() else {
            return nil
        }
        let lower = max(0, minVisible - bufferCount)
        let upper = min(totalCount - 1, maxVisible + bufferCount)
        return lower...upper
    }

    /// 计算 warm start 尾部预热范围：无可见索引时从尾部预热 bufferCount × warmStartMultiplier 条消息。
    ///
    /// - Parameter totalCount: 消息总数
    /// - Returns: 预热范围；消息为空时返回 nil
    func warmStartRange(totalCount: Int) -> ClosedRange<Int>? {
        guard totalCount > 0 else { return nil }
        let warmStartCount = bufferCount * warmStartMultiplier
        let lowerBound = max(0, totalCount - warmStartCount)
        return lowerBound...(totalCount - 1)
    }

    /// 判断指定索引的消息是否应完整渲染。
    ///
    /// 决策优先级：
    /// 1. 流式消息强制完整渲染，保证流式体验不中断。
    /// 2. 若有明确 fullRenderRange，使用范围判断。
    /// 3. 否则回退到 warm start 尾部预热策略。
    ///
    /// - Parameters:
    ///   - index: 消息在 displayMessages 中的索引
    ///   - isStreaming: 该消息是否处于流式输出中
    ///   - fullRenderRange: 由 computeFullRenderRange 计算得到的渲染范围（可为 nil）
    ///   - totalCount: 消息总数（用于 warm start 回退）
    func shouldFullyRender(
        index: Int,
        isStreaming: Bool,
        fullRenderRange: ClosedRange<Int>?,
        totalCount: Int
    ) -> Bool {
        if isStreaming { return true }
        guard let range = fullRenderRange else {
            return warmStartRange(totalCount: totalCount)?.contains(index) ?? false
        }
        return range.contains(index)
    }
}
