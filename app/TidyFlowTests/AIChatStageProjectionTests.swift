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

    // MARK: - AI 聊天舞台生命周期边界回归

    /// 回归：流式中断 → resuming → resumeCompleted → active
    func testStageStreamInterruptionRecovery() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        lifecycle.apply(.ready)
        lifecycle.apply(.loadSession(sessionId: "s1", aiTool: .opencode))
        XCTAssertEqual(lifecycle.state.phase, .active)

        // 流式中断
        let interruptResult = lifecycle.apply(.streamInterrupted(sessionId: "s1"))
        XCTAssertNotEqual(interruptResult, .ignored)
        XCTAssertEqual(lifecycle.state.phase, .resuming, "流式中断应迁移到 resuming")
        XCTAssertEqual(lifecycle.state.activeSessionId, "s1", "流式中断应保留会话 ID")
        // resuming 阶段仍接受匹配上下文的事件
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .opencode))

        // 恢复完成
        lifecycle.apply(.resumeCompleted)
        XCTAssertEqual(lifecycle.state.phase, .active, "恢复完成应回到 active")
    }

    /// 回归：流式中断后直接关闭（用户不等恢复）
    func testStageStreamInterruptionThenClose() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        lifecycle.apply(.ready)

        lifecycle.apply(.streamInterrupted(sessionId: "s1"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)

        lifecycle.apply(.close)
        XCTAssertEqual(lifecycle.state.phase, .idle, "流式中断后关闭应直接回到 idle")
    }

    /// 回归：工作区切换后旧上下文不再接受事件
    func testStageWorkspaceSwitchPreventsOldContextProjection() {
        let lifecycle = AIChatStageLifecycle()

        // 在 ws-1 中进入 active
        lifecycle.apply(.enter(project: "proj", workspace: "ws-1", aiTool: .opencode))
        lifecycle.apply(.ready)
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws-1", aiTool: .opencode))

        // forceReset（模拟平台工作区切换时的重置）
        lifecycle.apply(.forceReset)
        XCTAssertEqual(lifecycle.state.phase, .idle)
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws-1", aiTool: .opencode),
                        "forceReset 后旧上下文的事件应被拒绝")

        // 进入新工作区 ws-2
        lifecycle.apply(.enter(project: "proj", workspace: "ws-2", aiTool: .opencode))
        lifecycle.apply(.ready)
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws-1", aiTool: .opencode),
                        "旧工作区的事件在新上下文中应被拒绝")
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws-2", aiTool: .opencode))
    }

    /// 回归：会话恢复完成后能正常接收流式事件
    func testStageSessionRecoveryCompletionAcceptsEvents() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .claude_code))
        lifecycle.apply(.ready)

        // resume → resumeCompleted
        lifecycle.apply(.resume(sessionId: "sess-123"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .claude_code),
                      "resuming 阶段应接受匹配上下文的事件")

        lifecycle.apply(.resumeCompleted)
        XCTAssertEqual(lifecycle.state.phase, .active)
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .claude_code))
    }

    /// 回归：关闭后清理——contextKey 归空、不再接受事件
    func testStageCloseCleanup() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)
        let activeContextKey = lifecycle.state.contextKey
        XCTAssertFalse(activeContextKey.isEmpty)

        lifecycle.apply(.close)
        XCTAssertEqual(lifecycle.state.phase, .idle)
        XCTAssertEqual(lifecycle.state.project, "", "idle 状态应重置项目名")
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .codex),
                       "关闭后不应接受任何事件")
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

    // MARK: - 终端生命周期与 AI 聊天舞台对齐验证

    /// 验证终端生命周期相位名称与 AI 聊天舞台相位语义对齐
    func testTerminalLifecyclePhasesAlignWithAIChatStagePhases() {
        // 两套状态机使用相同的四相位语义：idle/entering/active/resuming
        let termPhases: [TerminalLifecyclePhase] = [.idle, .entering, .active, .resuming]
        let chatPhases: [AIChatStagePhase] = [.idle, .entering, .active, .resuming]

        XCTAssertEqual(termPhases.count, chatPhases.count,
                       "终端生命周期与 AI 聊天舞台应有相同数量的相位")

        // 验证相位名称一一对应
        for (term, chat) in zip(termPhases, chatPhases) {
            XCTAssertEqual(term.rawValue, chat.rawValue,
                           "终端 \(term.rawValue) 应与 AI 聊天 \(chat.rawValue) 对齐")
        }
    }

    /// 验证两套状态机在断连路径上的行为一致
    func testDisconnectBehaviorAlignment() {
        // 终端生命周期：active → disconnect → resuming
        let termMachine = TerminalLifecycleStateMachine()
        termMachine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        termMachine.apply(.created(termId: "t1"))
        XCTAssertEqual(termMachine.state.phase, .active)
        termMachine.apply(.disconnect)
        XCTAssertEqual(termMachine.state.phase, .resuming,
                       "终端断连后应进入 resuming，与 AI 聊天舞台行为对齐")

        // AI 聊天舞台：entering → ready(active) → forceReset(idle)
        // AI 使用 .forceReset 作为断连语义，终端使用 .disconnect
        // 两者在「工作区切换」时都使用 forceReset → idle
        let chatMachine = AIChatStageLifecycle()
        chatMachine.apply(.enter(project: "p", workspace: "ws", aiTool: .codex))
        XCTAssertEqual(chatMachine.state.phase, .entering)
        chatMachine.apply(.ready)
        XCTAssertEqual(chatMachine.state.phase, .active)
        chatMachine.apply(.forceReset)
        XCTAssertEqual(chatMachine.state.phase, .idle,
                       "AI 聊天 forceReset 后应回到 idle")
    }

    /// 验证两套状态机在强制重置路径上的行为一致
    func testForceResetBehaviorAlignment() {
        // 终端：active → forceReset → idle
        let termMachine = TerminalLifecycleStateMachine()
        termMachine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        termMachine.apply(.created(termId: "t1"))
        termMachine.apply(.forceReset)
        XCTAssertEqual(termMachine.state.phase, .idle)

        // AI 聊天：active → forceReset → idle
        let chatMachine = AIChatStageLifecycle()
        chatMachine.apply(.enter(project: "p", workspace: "ws", aiTool: .codex))
        chatMachine.apply(.ready)
        XCTAssertEqual(chatMachine.state.phase, .active)
        chatMachine.apply(.forceReset)
        XCTAssertEqual(chatMachine.state.phase, .idle)
    }
}
