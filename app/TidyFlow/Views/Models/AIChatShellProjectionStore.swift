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
        transcriptIdentity: "main-session-opencode--0",
        composerMode: .standard,
        bottomDockClearance: AIChatComposerLayoutSemantics.messageBottomClearance,
        jumpToBottomClearance: AIChatComposerLayoutSemantics.jumpToBottomClearance,
        loadingOlderState: .hidden,
        shouldReplaceComposer: false
    )
}

struct AIChatShellProjection: Equatable {
    let presentation: AIChatPresentationProjection
    let sessionStatus: AISessionStatusSnapshot?
    let contextRemainingPercent: Double?
    let effectiveStreaming: Bool
    let canStopStreaming: Bool
    let isSendingPending: Bool
    let activePendingInteraction: AIChatPendingInteraction?
    let queuedPendingInteractionCount: Int

    static let empty = AIChatShellProjection(
        presentation: .empty,
        sessionStatus: nil,
        contextRemainingPercent: nil,
        effectiveStreaming: false,
        canStopStreaming: false,
        isSendingPending: false,
        activePendingInteraction: nil,
        queuedPendingInteractionCount: 0
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
        hasPendingFirstContent: Bool,
        pendingQuestions: [String: AIQuestionRequestInfo]
    ) -> AIChatShellProjection {
        let pendingInteractionQueue = AIChatMessageLayoutSemantics.pendingInteractionQueue(
            messages: messages,
            pendingQuestions: pendingQuestions
        )
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
        let presentationWithComposer = AIChatPresentationProjection(
            tool: presentation.tool,
            currentSessionId: presentation.currentSessionId,
            showsEmptyState: presentation.showsEmptyState,
            canSwitchTool: presentation.canSwitchTool,
            isLoadingMessages: presentation.isLoadingMessages,
            canLoadOlderMessages: presentation.canLoadOlderMessages,
            isLoadingOlderMessages: presentation.isLoadingOlderMessages,
            transcriptIdentity: presentation.transcriptIdentity,
            composerMode: pendingInteractionQueue.hasPendingInteraction ? .pendingInteraction : .standard,
            bottomDockClearance: presentation.bottomDockClearance,
            jumpToBottomClearance: presentation.jumpToBottomClearance,
            loadingOlderState: presentation.loadingOlderState,
            shouldReplaceComposer: pendingInteractionQueue.hasPendingInteraction
        )
        let sessionActive = sessionStatus?.isActive == true
        let effectiveStreaming =
            abortPendingSessionId != nil ||
            sessionActive ||
            localIsStreaming ||
            awaitingUserEcho

        return AIChatShellProjection(
            presentation: presentationWithComposer,
            sessionStatus: sessionStatus,
            contextRemainingPercent: sessionStatus?.contextRemainingPercent,
            effectiveStreaming: effectiveStreaming,
            canStopStreaming: currentSessionId != nil &&
                abortPendingSessionId == nil &&
                (sessionActive || localIsStreaming || awaitingUserEcho),
            isSendingPending: hasPendingFirstContent,
            activePendingInteraction: pendingInteractionQueue.active,
            queuedPendingInteractionCount: pendingInteractionQueue.queuedCount
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
        hasPendingFirstContent: Bool,
        pendingQuestions: [String: AIQuestionRequestInfo]
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
            hasPendingFirstContent: hasPendingFirstContent,
            pendingQuestions: pendingQuestions
        )
        _ = updateProjection(next)
    }
}
