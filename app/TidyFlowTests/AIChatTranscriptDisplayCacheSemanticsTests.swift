import XCTest
@testable import TidyFlow

final class AIChatTranscriptDisplayCacheSemanticsTests: XCTestCase {
    func testSynchronizeAfterTailChangeAppendsStreamingTailWithoutFullRecompute() {
        let streamingMessage = AIChatMessage(
            messageId: "m-stream",
            role: .assistant,
            parts: [
                AIChatPart(id: "p-stream", kind: .text, text: "正在输出")
            ],
            isStreaming: true
        )

        let snapshot = AIChatTranscriptDisplayCacheSemantics.synchronizeAfterTailChange(
            sourceMessages: [streamingMessage],
            pendingQuestions: [:],
            cachedDisplayMessages: [],
            cachedSourceCount: 1
        )

        XCTAssertEqual(snapshot.sourceCount, 1)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.messages.first?.id, streamingMessage.id)
        XCTAssertTrue(snapshot.messages.first?.isStreaming == true)
    }

    func testSynchronizeAfterTailChangeRecomputesWhenStreamingCompletes() {
        let completedMessage = AIChatMessage(
            messageId: "m-done",
            role: .assistant,
            parts: [
                AIChatPart(id: "p-done", kind: .text, text: "最终回复")
            ],
            isStreaming: false
        )

        let snapshot = AIChatTranscriptDisplayCacheSemantics.synchronizeAfterTailChange(
            sourceMessages: [completedMessage],
            pendingQuestions: [:],
            cachedDisplayMessages: [],
            cachedSourceCount: 1
        )

        XCTAssertEqual(snapshot.sourceCount, 1)
        XCTAssertEqual(snapshot.messages.count, 1, "流式完成后应强制重建缓存，避免完成态消息消失")
        XCTAssertEqual(snapshot.messages.first?.parts.first?.text, "最终回复")
        XCTAssertFalse(snapshot.messages.first?.isStreaming == true)
    }

    func testSynchronizeAfterTailChangeReplacesCachedStreamingTailInsteadOfAppendingDuplicate() {
        let localMessageID = "local-stream"
        let cachedTail = AIChatMessage(
            id: localMessageID,
            messageId: "m-stream",
            role: .assistant,
            parts: [
                AIChatPart(id: "p-stream", kind: .text, text: "第一段")
            ],
            isStreaming: true
        )
        let updatedTail = AIChatMessage(
            id: localMessageID,
            messageId: "m-stream",
            role: .assistant,
            parts: [
                AIChatPart(id: "p-stream", kind: .text, text: "第一段第二段")
            ],
            isStreaming: true
        )

        let snapshot = AIChatTranscriptDisplayCacheSemantics.synchronizeAfterTailChange(
            sourceMessages: [updatedTail],
            pendingQuestions: [:],
            cachedDisplayMessages: [cachedTail],
            cachedSourceCount: 1
        )

        XCTAssertEqual(snapshot.messages.count, 1, "同一尾消息更新时应原位替换，不应重复追加")
        XCTAssertEqual(snapshot.messages.first?.parts.first?.text, "第一段第二段")
    }
}
