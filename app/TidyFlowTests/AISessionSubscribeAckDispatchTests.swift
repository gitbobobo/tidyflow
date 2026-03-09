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
}
