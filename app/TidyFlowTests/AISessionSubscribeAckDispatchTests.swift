import XCTest
@testable import TidyFlow

final class AISessionSubscribeAckDispatchTests: XCTestCase {
    private final class MockAIMessageHandler: AIMessageHandler {
        var receivedAck: AISessionSubscribeAck?

        func handleAISessionSubscribeAck(_ ev: AISessionSubscribeAck) {
            receivedAck = ev
        }
    }

    func testHandleAiDomain_forwardsSubscribeAckPayloadToHandler() {
        let client = WSClient()
        let handler = MockAIMessageHandler()
        client.aiMessageHandler = handler

        let handled = client.handleAiDomain(
            "ai_session_subscribe_ack",
            json: [
                "session_id": "ses_123",
                "session_key": "codex::/tmp/demo::ses_123",
                "project_name": "myproject",
                "workspace_name": "default"
            ]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(handler.receivedAck?.sessionId, "ses_123")
        XCTAssertEqual(handler.receivedAck?.sessionKey, "codex::/tmp/demo::ses_123")
        XCTAssertEqual(handler.receivedAck?.projectName, "myproject")
        XCTAssertEqual(handler.receivedAck?.workspaceName, "default")
    }

    // MARK: - 舞台生命周期与 ack 关联

    /// 验证舞台处于 entering 阶段时 ack 触发 ready 迁移。
    func testStageTransitionsToActiveOnSubscribeAck() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        XCTAssertEqual(lifecycle.state.phase, .entering)

        // 模拟 ack 到达后标记就绪
        let result = lifecycle.apply(.ready)
        XCTAssertEqual(lifecycle.state.phase, .active)
        XCTAssertNotEqual(result, .ignored)
    }

    /// 验证舞台已 close 后，ack 对应的 ready 被忽略。
    func testStageIgnoresReadyAfterClose() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.close)
        XCTAssertEqual(lifecycle.state.phase, .idle)

        let result = lifecycle.apply(.ready)
        XCTAssertEqual(result, .ignored, "close 后的 ready 应被忽略")
        XCTAssertEqual(lifecycle.state.phase, .idle)
    }

    /// 验证 forceReset 后 ack 对应的 ready 被忽略。
    func testStageIgnoresReadyAfterForceReset() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.forceReset)
        XCTAssertEqual(lifecycle.state.phase, .idle)

        let result = lifecycle.apply(.ready)
        XCTAssertEqual(result, .ignored, "forceReset 后的 ready 应被忽略")
    }

    // MARK: - WI-002：断线重连恢复路径与 ack 交互

    /// 验证断线重连完整路径：forceReset → enter → resume → ack(resumeCompleted) → active
    func testReconnectLifecyclePath() {
        let lifecycle = AIChatStageLifecycle()
        let store = AIChatStore()

        // 初始活跃状态
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("sess-1")
        store.addSubscription("sess-1")
        XCTAssertEqual(lifecycle.state.phase, .active)

        // 断线：forceReset + 清理
        lifecycle.apply(.forceReset)
        store.clearAll()
        XCTAssertEqual(lifecycle.state.phase, .idle)
        XCTAssertTrue(store.subscribedSessionIds.isEmpty)

        // 重连：enter → resume
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        XCTAssertEqual(lifecycle.state.phase, .entering)

        lifecycle.apply(.resume(sessionId: "sess-1"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)
        XCTAssertEqual(lifecycle.state.activeSessionId, "sess-1")

        // ack 到达 → resumeCompleted
        store.addSubscription("sess-1")
        lifecycle.apply(.resumeCompleted)
        XCTAssertEqual(lifecycle.state.phase, .active)
        XCTAssertTrue(store.subscribedSessionIds.contains("sess-1"))
    }

    /// 验证 resuming 阶段的 ack 驱动 resumeCompleted（而非 ready）。
    func testStageResumingAckDrivesResumeCompleted() {
        let lifecycle = AIChatStageLifecycle()

        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)
        lifecycle.apply(.resume(sessionId: "sess-1"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)

        // 模拟 iOS handleAISessionSubscribeAck 中的分支逻辑：
        // resuming 阶段调用 resumeCompleted
        let result = lifecycle.apply(.resumeCompleted)
        XCTAssertNotEqual(result, .ignored)
        XCTAssertEqual(lifecycle.state.phase, .active, "resuming 阶段的 ack 应通过 resumeCompleted 回到 active")
    }

    /// 验证 resuming → forceReset 后迟到的 resumeCompleted 被忽略。
    func testStageIgnoresResumeCompletedAfterForceReset() {
        let lifecycle = AIChatStageLifecycle()

        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)
        lifecycle.apply(.resume(sessionId: "sess-1"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)

        lifecycle.apply(.forceReset)
        XCTAssertEqual(lifecycle.state.phase, .idle)

        let result = lifecycle.apply(.resumeCompleted)
        XCTAssertEqual(result, .ignored, "forceReset 后的 resumeCompleted 应被忽略")
        XCTAssertEqual(lifecycle.state.phase, .idle)
    }

    /// 验证切换工具后 ack 对应的上下文与新工具匹配。
    func testSwitchToolUpdatesStageContext() {
        let lifecycle = AIChatStageLifecycle()

        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)
        XCTAssertEqual(lifecycle.state.aiTool, .codex)

        lifecycle.apply(.switchTool(newTool: .claude_code))
        lifecycle.apply(.ready)
        XCTAssertEqual(lifecycle.state.aiTool, .claude_code, "切换工具后舞台上下文应更新")
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .codex),
                       "旧工具的事件应被拒绝")
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .claude_code))
    }

    /// 验证工作区切换后（forceReset + 新 enter），迟到的旧 resumeCompleted 被忽略。
    func testLateResumeCompletedAfterWorkspaceSwitchIsIgnored() {
        let lifecycle = AIChatStageLifecycle()

        // 原工作区：进入 resuming
        lifecycle.apply(.enter(project: "proj", workspace: "ws-old", aiTool: .codex))
        lifecycle.apply(.ready)
        lifecycle.apply(.resume(sessionId: "sess-old"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)

        // 工作区切换
        lifecycle.apply(.forceReset)
        lifecycle.apply(.enter(project: "proj", workspace: "ws-new", aiTool: .codex))
        lifecycle.apply(.ready)
        XCTAssertEqual(lifecycle.state.phase, .active)

        // 迟到的 resumeCompleted 来自旧工作区，应被忽略
        let result = lifecycle.apply(.resumeCompleted)
        XCTAssertEqual(result, .ignored, "工作区切换后迟到的 resumeCompleted 应被忽略")
        XCTAssertEqual(lifecycle.state.phase, .active, "phase 不应被迟到事件改变")
    }

    /// 验证断线重连流程：disconnected → reconnect → resuming → resumeCompleted → active
    func testDisconnectReconnectResumeFlowReachesActive() {
        let lifecycle = AIChatStageLifecycle()

        lifecycle.apply(.enter(project: "p", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)
        lifecycle.apply(.resume(sessionId: "sess-1"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)

        let result = lifecycle.apply(.resumeCompleted)
        XCTAssertNotEqual(result, .ignored)
        XCTAssertEqual(lifecycle.state.phase, .active, "断线重连完成后应回到 active")
    }
}
