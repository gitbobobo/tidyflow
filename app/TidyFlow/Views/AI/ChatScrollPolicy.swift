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
    let animation: ChatScrollAnimation

    init(
        bottomTolerance: CGFloat = 36,
        nearBottomThreshold: CGFloat? = nil,
        autoResumeThreshold: CGFloat? = nil,
        renderBufferCount: Int = 12,
        incrementThrottleInterval: TimeInterval = 0.12,
        animation: ChatScrollAnimation = .default
    ) {
        self.bottomTolerance = bottomTolerance
        self.nearBottomThreshold = nearBottomThreshold ?? bottomTolerance
        self.autoResumeThreshold = autoResumeThreshold ?? (nearBottomThreshold ?? bottomTolerance)
        self.renderBufferCount = renderBufferCount
        self.incrementThrottleInterval = incrementThrottleInterval
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

    init(
        initialAutoFollow: Bool = true,
        initialNearBottom: Bool = true,
        configuration: ChatScrollConfiguration = ChatScrollPlatformConfiguration.shared
    ) {
        self.autoFollow = initialAutoFollow
        self.nearBottom = initialNearBottom
        self.configuration = configuration
    }

    var isAutoScrollEnabled: Bool {
        autoFollow
    }

    var currentStates: [ChatScrollState] {
        [.autoFollow(autoFollow), .nearBottom(nearBottom)]
    }

    @discardableResult
    func reduce(event: ChatScrollEvent, now: Date = Date()) -> ChatScrollDecision {
        let action: ChatScrollDecision.Action

        switch event {
        case .messageAppended:
            action = handleMessageAppended()
        case .messageIncremented:
            action = handleMessageIncremented(now: now)
        case .userScrolled(let updatedNearBottom):
            action = handleUserScrolled(updatedNearBottom: updatedNearBottom)
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

    private func handleMessageAppended() -> ChatScrollDecision.Action {
        guard autoFollow else { return .none }
        return .scrollToBottom
    }

    private func handleMessageIncremented(now: Date) -> ChatScrollDecision.Action {
        guard autoFollow else { return .none }
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

    private func handleUserScrolled(updatedNearBottom: Bool) -> ChatScrollDecision.Action {
        nearBottom = updatedNearBottom

        if autoFollow, !updatedNearBottom {
            autoFollow = false
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
        return .scrollToBottom
    }

    private func handleSessionSwitched(now: Date) -> ChatScrollDecision.Action {
        autoFollow = true
        nearBottom = true
        lastIncrementScrollAt = now
        return .scrollToBottom
    }
}
