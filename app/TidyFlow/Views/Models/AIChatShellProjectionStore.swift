import Foundation
import Observation

/// 壳投影失效签名：包含所有影响 shell projection 结果的轻量字段，
/// 视图只在签名发生变化时才调用 projectionStore.refresh。
/// 注意：tailRevision 不在此签名中；纯文本 token 增量不应触发根壳层刷新。
struct AIChatShellProjectionInvalidationSignature: Equatable {
    let tool: AIChatTool
    let currentSessionId: String?
    let historyHasMore: Bool
    let historyIsLoading: Bool
    let recentHistoryIsLoading: Bool
    let isStreaming: Bool
    let awaitingUserEcho: Bool
    let abortPendingSessionId: String?
    let hasPendingFirstContent: Bool
    let pendingQuestionCount: Int
    let pendingQuestionVersion: UInt64
    let sessionStatusIsActive: Bool?
    let sessionStatusContextPercent: Double?
    let scrollSessionToken: Int
    let canSwitchTool: Bool
}

/// 壳投影刷新所需的完整输入，从中可派生 AIChatShellProjectionInvalidationSignature。
struct AIChatShellProjectionInput {
    let tool: AIChatTool
    let currentSessionId: String?
    let messages: [AIChatMessage]
    let recentHistoryIsLoading: Bool
    let historyHasMore: Bool
    let historyIsLoading: Bool
    let canSwitchTool: Bool
    let scrollSessionToken: Int
    let sessionStatus: AISessionStatusSnapshot?
    let localIsStreaming: Bool
    let awaitingUserEcho: Bool
    let abortPendingSessionId: String?
    let hasPendingFirstContent: Bool
    let pendingQuestions: [String: AIQuestionRequestInfo]
    let tailRevision: UInt64
    let pendingQuestionVersion: UInt64

    var signature: AIChatShellProjectionInvalidationSignature {
        AIChatShellProjectionInvalidationSignature(
            tool: tool,
            currentSessionId: currentSessionId,
            historyHasMore: historyHasMore,
            historyIsLoading: historyIsLoading,
            recentHistoryIsLoading: recentHistoryIsLoading,
            isStreaming: localIsStreaming,
            awaitingUserEcho: awaitingUserEcho,
            abortPendingSessionId: abortPendingSessionId,
            hasPendingFirstContent: hasPendingFirstContent,
            pendingQuestionCount: pendingQuestions.count,
            pendingQuestionVersion: pendingQuestionVersion,
            sessionStatusIsActive: sessionStatus?.isActive,
            sessionStatusContextPercent: sessionStatus?.contextRemainingPercent,
            scrollSessionToken: scrollSessionToken,
            canSwitchTool: canSwitchTool
        )
    }
}

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

    func refresh(_ input: AIChatShellProjectionInput) {
        refresh(
            tool: input.tool,
            currentSessionId: input.currentSessionId,
            messages: input.messages,
            recentHistoryIsLoading: input.recentHistoryIsLoading,
            historyHasMore: input.historyHasMore,
            historyIsLoading: input.historyIsLoading,
            canSwitchTool: input.canSwitchTool,
            scrollSessionToken: input.scrollSessionToken,
            sessionStatus: input.sessionStatus,
            localIsStreaming: input.localIsStreaming,
            awaitingUserEcho: input.awaitingUserEcho,
            abortPendingSessionId: input.abortPendingSessionId,
            hasPendingFirstContent: input.hasPendingFirstContent,
            pendingQuestions: input.pendingQuestions
        )
    }
}
