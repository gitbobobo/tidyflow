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

    // MARK: - AI 聊天舞台生命周期投影

    /// 验证 newSession 输入在 active 阶段清空 activeSessionId。
    func testStageNewSessionClearsActiveSessionId() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)
        lifecycle.apply(.loadSession(sessionId: "session-1", aiTool: .codex))
        XCTAssertEqual(lifecycle.state.activeSessionId, "session-1")

        lifecycle.apply(.newSession)
        XCTAssertEqual(lifecycle.state.phase, .active, "newSession 应保持 active 阶段")
        XCTAssertNil(lifecycle.state.activeSessionId, "newSession 应清空 activeSessionId")
    }

    /// 验证 loadSession 在 active 阶段正确设置 activeSessionId。
    func testStageLoadSessionSetsActiveSessionId() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        lifecycle.apply(.ready)

        lifecycle.apply(.loadSession(sessionId: "session-abc", aiTool: .opencode))
        XCTAssertEqual(lifecycle.state.phase, .active)
        XCTAssertEqual(lifecycle.state.activeSessionId, "session-abc")
    }

    /// 验证 loadSession 允许跨工具加载（更新 aiTool）。
    func testStageLoadSessionCrossToolUpdatesAiTool() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        lifecycle.apply(.ready)

        lifecycle.apply(.loadSession(sessionId: "session-x", aiTool: .claude_code))
        XCTAssertEqual(lifecycle.state.aiTool, .claude_code, "跨工具加载应更新 aiTool")
        XCTAssertEqual(lifecycle.state.activeSessionId, "session-x")
    }

    /// 验证 acceptsSessionEvent 对 activeSessionId 匹配与 nil 的处理。
    func testStageAcceptsSessionEvent() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)

        // activeSessionId 为 nil 时接受任何 session event
        XCTAssertTrue(lifecycle.acceptsSessionEvent(sessionId: "any-session"),
                      "activeSessionId 为 nil 时应接受任意会话事件")

        lifecycle.apply(.loadSession(sessionId: "session-1", aiTool: .codex))
        XCTAssertTrue(lifecycle.acceptsSessionEvent(sessionId: "session-1"))
        XCTAssertFalse(lifecycle.acceptsSessionEvent(sessionId: "session-2"),
                       "不匹配的会话事件应被拒绝")
    }

    /// 验证重复 enter 相同上下文被忽略。
    func testStageIgnoresDuplicateEnter() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        lifecycle.apply(.ready)

        let result = lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        XCTAssertEqual(result, .ignored, "相同上下文的重复 enter 应被忽略")
        XCTAssertEqual(lifecycle.state.phase, .active, "阶段不应改变")
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
