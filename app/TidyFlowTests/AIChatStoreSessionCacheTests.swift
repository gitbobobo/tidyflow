import XCTest
@testable import TidyFlow

final class AIChatStoreSessionCacheTests: XCTestCase {
    func testReplaceMessagesFromSessionCacheMarksLatestAssistantStreaming() {
        let store = AIChatStore()
        let messages = [
            AIProtocolMessageInfo(
                id: "m-user",
                role: "user",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeTextPart(id: "p-user", text: "hi")]
            ),
            AIProtocolMessageInfo(
                id: "m-assistant",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeTextPart(id: "p-assistant", text: "hello")]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: true)

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertFalse(store.messages[0].isStreaming)
        XCTAssertTrue(store.messages[1].isStreaming)
        XCTAssertTrue(store.isStreaming)
    }

    func testApplySessionCacheOpsBuildsTextFromDeltas() {
        let store = AIChatStore()
        let basePart = makeTextPart(id: "p1", text: nil)

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m1", role: "assistant"),
                .partUpdated(messageId: "m1", part: basePart),
                .partDelta(
                    messageId: "m1",
                    partId: "p1",
                    partType: "text",
                    field: "text",
                    delta: "hel"
                ),
                .partDelta(
                    messageId: "m1",
                    partId: "p1",
                    partType: "text",
                    field: "text",
                    delta: "lo"
                ),
            ],
            isStreaming: true
        )
        store.applySessionCacheOps([], isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].role, .assistant)
        XCTAssertEqual(store.messages[0].parts.count, 1)
        XCTAssertEqual(store.messages[0].parts[0].text, "hello")
        XCTAssertFalse(store.messages[0].isStreaming)
        XCTAssertFalse(store.isStreaming)
    }

    func testSessionCacheRevisionRejectsRollback() {
        let store = AIChatStore()

        XCTAssertTrue(store.shouldApplySessionCacheRevision(1, sessionId: "s1"))
        XCTAssertTrue(store.shouldApplySessionCacheRevision(2, sessionId: "s1"))
        XCTAssertFalse(store.shouldApplySessionCacheRevision(1, sessionId: "s1"))
        XCTAssertTrue(store.shouldApplySessionCacheRevision(2, sessionId: "s1"))
    }

    func testRenderRevisionIncrementsOnPartUpdateAndDelta() {
        let store = AIChatStore()

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m1", role: "assistant"),
                .partUpdated(messageId: "m1", part: makeTextPart(id: "p1", text: "hel")),
            ],
            isStreaming: true
        )
        store.applySessionCacheOps([], isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        let revisionAfterPartUpdate = store.messages[0].renderRevision
        XCTAssertGreaterThan(revisionAfterPartUpdate, 0)

        store.applySessionCacheOps(
            [
                .partDelta(
                    messageId: "m1",
                    partId: "p1",
                    partType: "text",
                    field: "text",
                    delta: "lo"
                ),
            ],
            isStreaming: true
        )
        store.applySessionCacheOps([], isStreaming: false)

        XCTAssertEqual(store.messages[0].parts.first?.text, "hello")
        XCTAssertGreaterThan(store.messages[0].renderRevision, revisionAfterPartUpdate)
    }

    func testStreamFlushIntervalUsesAdaptiveThresholds() {
        let store = AIChatStore()

        XCTAssertEqual(store.streamFlushInterval(forBacklog: 20), 1.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(store.streamFlushInterval(forBacklog: 21), 0.05, accuracy: 0.0001)
        XCTAssertEqual(store.streamFlushInterval(forBacklog: 80), 0.05, accuracy: 0.0001)
        XCTAssertEqual(store.streamFlushInterval(forBacklog: 81), 1.0 / 12.0, accuracy: 0.0001)
    }

    func testStreamingStateConvergesWhenToolStopsRunning() {
        let store = AIChatStore()
        store.setCurrentSessionId("s1")

        let toolRunningMessage = AIProtocolMessageInfo(
            id: "m-tool",
            role: "assistant",
            createdAt: nil,
            agent: nil,
            modelProviderID: nil,
            modelID: nil,
            parts: [makeToolPart(id: "tp1", status: "running")]
        )
        store.replaceMessagesFromSessionCache([toolRunningMessage], isStreaming: false)
        XCTAssertTrue(store.isStreaming)

        store.applySessionCacheOps(
            [
                .partUpdated(messageId: "m-tool", part: makeToolPart(id: "tp1", status: "success")),
            ],
            isStreaming: false
        )
        XCTAssertFalse(store.isStreaming)
    }

    private func makeTextPart(id: String, text: String?) -> AIProtocolPartInfo {
        AIProtocolPartInfo(
            id: id,
            partType: "text",
            text: text,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: nil,
            toolName: nil,
            toolCallId: nil,
            toolKind: nil,
            toolTitle: nil,
            toolRawInput: nil,
            toolRawOutput: nil,
            toolLocations: nil,
            toolState: nil,
            toolPartMetadata: nil
        )
    }

    private func makeToolPart(id: String, status: String) -> AIProtocolPartInfo {
        AIProtocolPartInfo(
            id: id,
            partType: "tool",
            text: nil,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: nil,
            toolName: "shell",
            toolCallId: "call-\(id)",
            toolKind: nil,
            toolTitle: nil,
            toolRawInput: nil,
            toolRawOutput: nil,
            toolLocations: nil,
            toolState: ["status": status],
            toolPartMetadata: nil
        )
    }
}
