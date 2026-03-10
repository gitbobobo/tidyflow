import Foundation

struct AIChatPresentationProjection: Equatable {
    let tool: AIChatTool
    let currentSessionId: String?
    let showsEmptyState: Bool
    let canSwitchTool: Bool
    let isLoadingMessages: Bool
    let canLoadOlderMessages: Bool
    let isLoadingOlderMessages: Bool
    let messageListIdentity: String
    let shouldReplaceComposer: Bool
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
            messageListIdentity: "main-session-\(tool.rawValue)-\(effectiveSessionId)-\(scrollSessionToken)",
            shouldReplaceComposer: false
        )
    }
}
