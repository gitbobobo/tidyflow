import Foundation
import CoreGraphics

enum ChatScrollState: Equatable {
    case autoFollow(Bool)
    case nearBottom(Bool)
}

enum ChatScrollEvent: Equatable {
    case messageAppended
    case messageIncremented
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
        renderBufferCount: Int = 12,
        incrementThrottleInterval: TimeInterval = 0.12,
        nearBottomConfirmationTimeout: TimeInterval = 0.5,
        animation: ChatScrollAnimation = .default
    ) {
        self.bottomTolerance = bottomTolerance
        self.nearBottomThreshold = nearBottomThreshold ?? bottomTolerance
        self.autoResumeThreshold = autoResumeThreshold ?? (nearBottomThreshold ?? bottomTolerance)
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
    enum Action: Equatable {
        case none
        case scrollToBottom
        case throttledScrollToBottom
    }

    let action: Action
    let states: [ChatScrollState]

    var shouldScrollToBottom: Bool {
        switch action {
        case .none:
            return false
        case .scrollToBottom, .throttledScrollToBottom:
            return true
        }
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
        let action: ChatScrollDecision.Action

        switch event {
        case .messageAppended:
            action = handleMessageAppended(now: now)
        case .messageIncremented:
            action = handleMessageIncremented(now: now)
        case .userScrolled(let updatedNearBottom):
            action = handleUserScrolled(updatedNearBottom: updatedNearBottom, now: now)
        case .jumpToBottomClicked:
            action = handleJumpToBottomClicked(now: now)
        case .sessionSwitched:
            action = handleSessionSwitched(now: now)
        }

        return ChatScrollDecision(action: action, states: currentStates)
    }

    @discardableResult
    func shouldScrollToBottom(for event: ChatScrollEvent, now: Date = Date()) -> Bool {
        reduce(event: event, now: now).shouldScrollToBottom
    }

    private func handleMessageAppended(now: Date) -> ChatScrollDecision.Action {
        guard autoFollow else { return .none }
        // 当 autoFollow 和 nearBottom 都为 true 时，直接滚动（无需确认超时检查）。
        // 确认超时仅用于处理 nearBottom 不确定时的竞态条件。
        if nearBottom { return .scrollToBottom }
        guard isNearBottomConfirmationFreshAt(now) else { return .none }
        return .scrollToBottom
    }

    private func handleMessageIncremented(now: Date) -> ChatScrollDecision.Action {
        guard autoFollow else { return .none }
        // 当 nearBottom 为 true 时直接通过；否则需确认超时仍有效
        if !nearBottom {
            guard isNearBottomConfirmationFreshAt(now) else { return .none }
        }
        guard let lastIncrementScrollAt else {
            self.lastIncrementScrollAt = now
            return .throttledScrollToBottom
        }

        let delta = now.timeIntervalSince(lastIncrementScrollAt)
        guard delta >= configuration.incrementThrottleInterval else {
            return .none
        }

        self.lastIncrementScrollAt = now
        return .throttledScrollToBottom
    }

    private func handleUserScrolled(updatedNearBottom: Bool, now: Date) -> ChatScrollDecision.Action {
        nearBottom = updatedNearBottom

        if updatedNearBottom {
            lastNearBottomConfirmedAt = now
        }

        if autoFollow, !updatedNearBottom {
            autoFollow = false
            lastNearBottomConfirmedAt = nil
            return .none
        }

        if !autoFollow, updatedNearBottom {
            autoFollow = true
            return .none
        }

        return .none
    }

    private func handleJumpToBottomClicked(now: Date) -> ChatScrollDecision.Action {
        autoFollow = true
        nearBottom = true
        lastIncrementScrollAt = now
        lastNearBottomConfirmedAt = now
        return .scrollToBottom
    }

    private func handleSessionSwitched(now: Date) -> ChatScrollDecision.Action {
        autoFollow = true
        nearBottom = true
        lastIncrementScrollAt = now
        lastNearBottomConfirmedAt = now
        return .scrollToBottom
    }

    /// 检查指定时刻近底部确认是否仍新鲜
    private func isNearBottomConfirmationFreshAt(_ now: Date) -> Bool {
        guard let confirmedAt = lastNearBottomConfirmedAt else { return false }
        return now.timeIntervalSince(confirmedAt) < configuration.nearBottomConfirmationTimeout
    }
}
