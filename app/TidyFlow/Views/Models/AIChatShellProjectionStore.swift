import Foundation
import Observation

extension AIChatPresentationProjection {
    static let empty = AIChatPresentationProjection(
        tool: .opencode,
        currentSessionId: nil,
        showsEmptyState: true,
        canSwitchTool: true,
        isLoadingMessages: false,
        canLoadOlderMessages: false,
        isLoadingOlderMessages: false,
        messageListIdentity: "main-session-opencode--0"
    )
}

struct AIChatShellProjection: Equatable {
    let presentation: AIChatPresentationProjection
    let sessionStatus: AISessionStatusSnapshot?
    let contextRemainingPercent: Double?
    let effectiveStreaming: Bool
    let canStopStreaming: Bool
    let isSendingPending: Bool

    static let empty = AIChatShellProjection(
        presentation: .empty,
        sessionStatus: nil,
        contextRemainingPercent: nil,
        effectiveStreaming: false,
        canStopStreaming: false,
        isSendingPending: false
    )
}

enum AIChatShellProjectionSemantics {
    static func make(
        tool: AIChatTool,
        currentSessionId: String?,
        messages: [AIChatMessage],
        recentHistoryIsLoading: Bool,
        historyHasMore: Bool,
        historyIsLoading: Bool,
        canSwitchTool: Bool,
        scrollSessionToken: Int,
        sessionStatus: AISessionStatusSnapshot?,
        localIsStreaming: Bool,
        awaitingUserEcho: Bool,
        abortPendingSessionId: String?,
        hasPendingFirstContent: Bool
    ) -> AIChatShellProjection {
        let presentation = AIChatPresentationSemantics.make(
            tool: tool,
            currentSessionId: currentSessionId,
            messages: messages,
            recentHistoryIsLoading: recentHistoryIsLoading,
            historyHasMore: historyHasMore,
            historyIsLoading: historyIsLoading,
            canSwitchTool: canSwitchTool,
            scrollSessionToken: scrollSessionToken
        )
        let sessionActive = sessionStatus?.isActive == true
        let effectiveStreaming =
            abortPendingSessionId != nil ||
            sessionActive ||
            localIsStreaming ||
            awaitingUserEcho

        return AIChatShellProjection(
            presentation: presentation,
            sessionStatus: sessionStatus,
            contextRemainingPercent: sessionStatus?.contextRemainingPercent,
            effectiveStreaming: effectiveStreaming,
            canStopStreaming: currentSessionId != nil &&
                abortPendingSessionId == nil &&
                (sessionActive || localIsStreaming || awaitingUserEcho),
            isSendingPending: hasPendingFirstContent
        )
    }
}

@MainActor
@Observable
final class AIChatShellProjectionStore {
    private(set) var projection: AIChatShellProjection = .empty

    @discardableResult
    func updateProjection(_ next: AIChatShellProjection) -> Bool {
        guard projection != next else { return false }
        projection = next
        return true
    }

    func refresh(
        tool: AIChatTool,
        currentSessionId: String?,
        messages: [AIChatMessage],
        recentHistoryIsLoading: Bool,
        historyHasMore: Bool,
        historyIsLoading: Bool,
        canSwitchTool: Bool,
        scrollSessionToken: Int,
        sessionStatus: AISessionStatusSnapshot?,
        localIsStreaming: Bool,
        awaitingUserEcho: Bool,
        abortPendingSessionId: String?,
        hasPendingFirstContent: Bool
    ) {
        let next = AIChatShellProjectionSemantics.make(
            tool: tool,
            currentSessionId: currentSessionId,
            messages: messages,
            recentHistoryIsLoading: recentHistoryIsLoading,
            historyHasMore: historyHasMore,
            historyIsLoading: historyIsLoading,
            canSwitchTool: canSwitchTool,
            scrollSessionToken: scrollSessionToken,
            sessionStatus: sessionStatus,
            localIsStreaming: localIsStreaming,
            awaitingUserEcho: awaitingUserEcho,
            abortPendingSessionId: abortPendingSessionId,
            hasPendingFirstContent: hasPendingFirstContent
        )
        _ = updateProjection(next)
    }
}
