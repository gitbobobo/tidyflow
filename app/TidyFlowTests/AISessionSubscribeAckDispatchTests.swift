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
}
