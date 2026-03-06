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

    // MARK: - 工具卡缓存与间距回归测试

    /// 验证会话快照中多个工具 part 都被正确保留，不丢失也不产生重复。
    func testReplaceMessagesFromSessionCachePreservesMultipleToolParts() {
        let store = AIChatStore()
        let messages = [
            AIProtocolMessageInfo(
                id: "m-assistant",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [
                    makeToolPart(id: "tp1", status: "success"),
                    makeToolPart(id: "tp2", status: "success"),
                    makeTextPart(id: "p1", text: "done"),
                ]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].parts.count, 3)
        let toolParts = store.messages[0].parts.filter { $0.kind == .tool }
        XCTAssertEqual(toolParts.count, 2, "两个工具卡都应保留在缓存中")
        // 工具 part 顺序应与原始顺序一致
        XCTAssertEqual(toolParts[0].id, "tp1")
        XCTAssertEqual(toolParts[1].id, "tp2")
    }

    /// 验证增量 ops 可以在同一消息中正确平铺多个工具 part，空文本 part 不影响工具卡顺序。
    func testApplySessionCacheOpsPreservesToolPartsWithEmptyTextPart() {
        let store = AIChatStore()

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m1", role: "assistant"),
                // 空文本 part（渲染层过滤，缓存层不应丢弃）
                .partUpdated(messageId: "m1", part: makeTextPart(id: "empty-p", text: "")),
                .partUpdated(messageId: "m1", part: makeToolPart(id: "tp1", status: "success")),
                .partUpdated(messageId: "m1", part: makeToolPart(id: "tp2", status: "success")),
            ],
            isStreaming: false
        )

        XCTAssertEqual(store.messages.count, 1)
        let allParts = store.messages[0].parts
        XCTAssertEqual(allParts.count, 3, "空文本 part 也应保留在缓存中，由渲染层决定是否显示")
        let toolParts = allParts.filter { $0.kind == .tool }
        XCTAssertEqual(toolParts.count, 2, "两个相邻工具卡均应存在于缓存中")
    }

    /// 验证相邻工具卡的 session cache 快照替换后，再次替换不会产生重复 part。
    func testReplaceMessagesFromSessionCacheIsIdempotentForToolParts() {
        let store = AIChatStore()
        let messages = [
            AIProtocolMessageInfo(
                id: "m1",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [
                    makeToolPart(id: "tp1", status: "success"),
                    makeToolPart(id: "tp2", status: "success"),
                ]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: false)
        store.replaceMessagesFromSessionCache(messages, isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].parts.count, 2, "重复替换不应产生重复 part")
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
