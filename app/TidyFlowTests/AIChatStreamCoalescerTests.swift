import XCTest
import CoreFoundation
@testable import TidyFlow

/// 覆盖 AIChatStreamCoalescer 聚合语义与 AIChatTailChangeSummary 的单元测试。
final class AIChatStreamCoalescerTests: XCTestCase {

    // MARK: - 空输入

    func testEmptyInputReturnsEmptyOutput() {
        let result = AIChatStreamCoalescer.coalesce([])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - partDelta 合并

    func testConsecutiveSameKeyDeltasMergeIntoOne() {
        let events: [AIChatStreamEvent] = [
            .partDelta(messageId: "m1", partId: "p1", partType: "text", field: "text", delta: "foo"),
            .partDelta(messageId: "m1", partId: "p1", partType: "text", field: "text", delta: "bar"),
            .partDelta(messageId: "m1", partId: "p1", partType: "text", field: "text", delta: "baz"),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 1)
        if case let .partDelta(_, _, _, _, delta) = result[0] {
            XCTAssertEqual(delta, "foobarbaz")
        } else {
            XCTFail("期望 partDelta")
        }
    }

    func testDifferentPartIdBreaksCoalescing() {
        let events: [AIChatStreamEvent] = [
            .partDelta(messageId: "m1", partId: "p1", partType: "text", field: "text", delta: "a"),
            .partDelta(messageId: "m1", partId: "p2", partType: "text", field: "text", delta: "b"),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 2)
    }

    func testDifferentFieldBreaksCoalescing() {
        let events: [AIChatStreamEvent] = [
            .partDelta(messageId: "m1", partId: "p1", partType: "text", field: "text", delta: "a"),
            .partDelta(messageId: "m1", partId: "p1", partType: "text", field: "reasoning", delta: "b"),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - messageUpdated 合并

    func testConsecutiveMessageUpdatedForSameIdMergesIntoLast() {
        let events: [AIChatStreamEvent] = [
            .messageUpdated(messageId: "m1", role: "user"),
            .messageUpdated(messageId: "m1", role: "assistant"),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 1)
        if case let .messageUpdated(_, role) = result[0] {
            XCTAssertEqual(role, "assistant")
        } else {
            XCTFail("期望 messageUpdated")
        }
    }

    func testMessageUpdatedForDifferentIdsPreservedInOrder() {
        let events: [AIChatStreamEvent] = [
            .messageUpdated(messageId: "m1", role: "user"),
            .messageUpdated(messageId: "m2", role: "assistant"),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - partUpdated 不合并

    func testPartUpdatedIsNeverCoalesced() {
        let part = AIProtocolPartInfo(
            id: "p1", partType: "text", text: nil, mime: nil, filename: nil,
            url: nil, synthetic: nil, ignored: nil, source: nil,
            toolName: nil, toolCallId: nil, toolKind: nil, toolView: nil
        )
        let events: [AIChatStreamEvent] = [
            .partUpdated(messageId: "m1", part: part),
            .partUpdated(messageId: "m1", part: part),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - 混合序列

    func testMixedSequencePreservesSemanticOrder() {
        let part = AIProtocolPartInfo(
            id: "p1", partType: "text", text: nil, mime: nil, filename: nil,
            url: nil, synthetic: nil, ignored: nil, source: nil,
            toolName: nil, toolCallId: nil, toolKind: nil, toolView: nil
        )
        let events: [AIChatStreamEvent] = [
            .messageUpdated(messageId: "m1", role: "user"),
            .messageUpdated(messageId: "m1", role: "assistant"),
            .partDelta(messageId: "m1", partId: "p1", partType: "text", field: "text", delta: "hello "),
            .partDelta(messageId: "m1", partId: "p1", partType: "text", field: "text", delta: "world"),
            .partUpdated(messageId: "m1", part: part),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 3)
        if case let .messageUpdated(_, role) = result[0] {
            XCTAssertEqual(role, "assistant", "messageUpdated 应取最后一次角色")
        }
        if case let .partDelta(_, _, _, _, delta) = result[1] {
            XCTAssertEqual(delta, "hello world", "连续 delta 应合并")
        }
    }

    // MARK: - 会话隔离

    func testDifferentMessageIdsDontCoalesce() {
        let eventsA: [AIChatStreamEvent] = (0..<10).map { _ in
            .partDelta(messageId: "session-A", partId: "p1", partType: "text", field: "text", delta: "A")
        }
        let eventsB: [AIChatStreamEvent] = (0..<10).map { _ in
            .partDelta(messageId: "session-B", partId: "p1", partType: "text", field: "text", delta: "B")
        }
        let result = AIChatStreamCoalescer.coalesce(eventsA + eventsB)
        XCTAssertEqual(result.count, 2, "不同 messageId 的 delta 不应合并")
    }

    // MARK: - AIChatTailChangeSummary

    func testSummaryOnEmptyAfterReturnsNoChange() {
        let summary = AIChatStreamCoalescer.summarizeTailChange(before: [], after: [])
        XCTAssertEqual(summary, .noMeaningfulChange)
    }

    func testSummaryDetectsNewMessageAppended() {
        let before = [makeMsg(id: "m1", text: "hi")]
        let after = [makeMsg(id: "m1", text: "hi"), makeMsg(id: "m2", text: "there")]
        XCTAssertEqual(AIChatStreamCoalescer.summarizeTailChange(before: before, after: after), .appendedNewMessage)
    }

    func testSummaryDetectsTailTextGrowth() {
        let before = [makeMsg(id: "m1", text: "hello")]
        let after = [makeMsg(id: "m1", text: "hello world")]
        XCTAssertEqual(AIChatStreamCoalescer.summarizeTailChange(before: before, after: after), .grewTailText)
    }

    func testSummaryDetectsNoMeaningfulChange() {
        let messages = [makeMsg(id: "m1", text: "hello")]
        XCTAssertEqual(AIChatStreamCoalescer.summarizeTailChange(before: messages, after: messages), .noMeaningfulChange)
    }

    func testSummaryHasMeaningfulChangeForAllButNoop() {
        XCTAssertTrue(AIChatTailChangeSummary.appendedNewMessage.hasMeaningfulChange)
        XCTAssertTrue(AIChatTailChangeSummary.grewTailText.hasMeaningfulChange)
        XCTAssertTrue(AIChatTailChangeSummary.changedToolPartStatus.hasMeaningfulChange)
        XCTAssertFalse(AIChatTailChangeSummary.noMeaningfulChange.hasMeaningfulChange)
    }

    // MARK: - Helper

    private func makeMsg(id: String, text: String) -> AIChatMessage {
        AIChatMessage(
            id: id,
            messageId: id,
            role: .assistant,
            parts: [AIChatPart(id: "\(id)-p", kind: .text, text: text)]
        )
    }
}
