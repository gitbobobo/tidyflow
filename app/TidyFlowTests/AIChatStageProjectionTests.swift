import XCTest
@testable import TidyFlow

final class AIChatStageProjectionTests: XCTestCase {

    func testPendingInteractionSwitchesComposerMode() {
        let request = makeRequest(id: "req-1")
        let projection = AIChatShellProjectionSemantics.make(
            tool: .codex,
            currentSessionId: "session-1",
            messages: [makeInteractiveQuestionMessage(request: request)],
            recentHistoryIsLoading: false,
            historyHasMore: false,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: 2,
            sessionStatus: nil,
            localIsStreaming: false,
            awaitingUserEcho: false,
            abortPendingSessionId: nil,
            hasPendingFirstContent: false,
            pendingQuestions: ["call-req-1": request]
        )

        XCTAssertEqual(projection.presentation.composerMode, .pendingInteraction)
        XCTAssertTrue(projection.presentation.shouldReplaceComposer)
        XCTAssertEqual(projection.activePendingInteraction?.id, request.id)
    }

    func testLoadingOlderStateTracksHistoryFlags() {
        let available = AIChatPresentationSemantics.make(
            tool: .opencode,
            currentSessionId: "session-1",
            messages: [makePlainMessage(id: "m1")],
            recentHistoryIsLoading: false,
            historyHasMore: true,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: 1
        )
        let loading = AIChatPresentationSemantics.make(
            tool: .opencode,
            currentSessionId: "session-1",
            messages: [makePlainMessage(id: "m1")],
            recentHistoryIsLoading: false,
            historyHasMore: true,
            historyIsLoading: true,
            canSwitchTool: true,
            scrollSessionToken: 1
        )
        let hidden = AIChatPresentationSemantics.make(
            tool: .opencode,
            currentSessionId: "session-1",
            messages: [makePlainMessage(id: "m1")],
            recentHistoryIsLoading: false,
            historyHasMore: false,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: 1
        )

        XCTAssertEqual(available.loadingOlderState, .available)
        XCTAssertEqual(loading.loadingOlderState, .loading)
        XCTAssertEqual(hidden.loadingOlderState, .hidden)
    }

    func testTranscriptIdentityIncludesSessionAndScrollToken() {
        let first = AIChatPresentationSemantics.make(
            tool: .claude_code,
            currentSessionId: "session-a",
            messages: [],
            recentHistoryIsLoading: false,
            historyHasMore: false,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: 1
        )
        let second = AIChatPresentationSemantics.make(
            tool: .claude_code,
            currentSessionId: "session-a",
            messages: [],
            recentHistoryIsLoading: false,
            historyHasMore: false,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: 2
        )

        XCTAssertNotEqual(first.transcriptIdentity, second.transcriptIdentity)
        XCTAssertTrue(second.transcriptIdentity.contains("session-a"))
    }

    private func makePlainMessage(id: String) -> AIChatMessage {
        AIChatMessage(
            messageId: id,
            role: .assistant,
            parts: [
                AIChatPart(id: "part-\(id)", kind: .text, text: "hello")
            ],
            isStreaming: false
        )
    }

    private func makeRequest(id: String) -> AIQuestionRequestInfo {
        AIQuestionRequestInfo(
            id: id,
            sessionId: "session-1",
            questions: [
                AIQuestionInfo(
                    question: "开始实现？",
                    header: "计划已就绪",
                    options: [
                        AIQuestionOptionInfo(optionID: "yes", label: "是", description: "开始实现")
                    ],
                    multiple: false,
                    custom: false
                )
            ],
            toolMessageId: "tool-\(id)",
            toolCallId: "call-\(id)"
        )
    }

    private func makeInteractiveQuestionMessage(request: AIQuestionRequestInfo) -> AIChatMessage {
        let toolView = AIToolView(
            status: .pending,
            displayTitle: "question",
            statusText: "pending",
            summary: nil,
            headerCommandSummary: nil,
            durationMs: nil,
            sections: [],
            locations: [],
            question: AIToolViewQuestion(
                requestID: request.id,
                toolMessageID: request.toolMessageId,
                promptItems: request.questions,
                interactive: true,
                answers: nil
            ),
            linkedSession: nil
        )
        let part = AIChatPart(
            id: "part-\(request.id)",
            kind: .tool,
            text: nil,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: nil,
            toolName: "question",
            toolCallId: request.toolCallId,
            toolView: toolView
        )
        return AIChatMessage(
            messageId: "message-\(request.id)",
            role: .assistant,
            parts: [part],
            isStreaming: false
        )
    }
}
