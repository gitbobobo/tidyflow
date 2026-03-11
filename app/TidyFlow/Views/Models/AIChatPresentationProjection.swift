import Foundation
import CoreGraphics

enum AIChatComposerMode: Equatable {
    case standard
    case pendingInteraction
}

enum AIChatLoadingOlderState: Equatable {
    case hidden
    case available
    case loading
}

struct AIChatPresentationProjection: Equatable {
    let tool: AIChatTool
    let currentSessionId: String?
    let showsEmptyState: Bool
    let canSwitchTool: Bool
    let isLoadingMessages: Bool
    let canLoadOlderMessages: Bool
    let isLoadingOlderMessages: Bool
    let transcriptIdentity: String
    let composerMode: AIChatComposerMode
    let bottomDockClearance: CGFloat
    let jumpToBottomClearance: CGFloat
    let loadingOlderState: AIChatLoadingOlderState
    let shouldReplaceComposer: Bool

    var messageListIdentity: String {
        transcriptIdentity
    }
}

enum AIChatPresentationSemantics {
    static func make(
        tool: AIChatTool,
        currentSessionId: String?,
        messages: [AIChatMessage],
        recentHistoryIsLoading: Bool,
        historyHasMore: Bool,
        historyIsLoading: Bool,
        canSwitchTool: Bool,
        scrollSessionToken: Int
    ) -> AIChatPresentationProjection {
        let isLoadingMessages = currentSessionId != nil &&
            messages.isEmpty &&
            recentHistoryIsLoading
        let effectiveSessionId = currentSessionId ?? ""
        return AIChatPresentationProjection(
            tool: tool,
            currentSessionId: currentSessionId,
            showsEmptyState: messages.isEmpty,
            canSwitchTool: canSwitchTool && !isLoadingMessages,
            isLoadingMessages: isLoadingMessages,
            canLoadOlderMessages: currentSessionId != nil && historyHasMore,
            isLoadingOlderMessages: historyIsLoading,
            transcriptIdentity: "main-session-\(tool.rawValue)-\(effectiveSessionId)-\(scrollSessionToken)",
            composerMode: .standard,
            bottomDockClearance: AIChatComposerLayoutSemantics.messageBottomClearance,
            jumpToBottomClearance: AIChatComposerLayoutSemantics.jumpToBottomClearance,
            loadingOlderState: {
                if historyIsLoading {
                    return .loading
                }
                if currentSessionId != nil && historyHasMore {
                    return .available
                }
                return .hidden
            }(),
            shouldReplaceComposer: false
        )
    }
}
