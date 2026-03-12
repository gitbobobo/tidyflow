import XCTest
import SwiftUI
@testable import TidyFlow

final class AIChatTranscriptDeferredUpdateTests: XCTestCase {
    func testTailChangeAppliesImmediatelyWhenIdle() {
        var state = AIChatTranscriptDeferredUpdateState()

        XCTAssertTrue(state.registerTailChange())
        XCTAssertEqual(state.pendingAction, .none)
        XCTAssertFalse(state.isScrollInFlight)
    }

    func testMultipleTailChangesWhileScrollingCoalesceIntoSingleFlush() {
        var state = AIChatTranscriptDeferredUpdateState()
        state.beginScroll()

        XCTAssertFalse(state.registerTailChange())
        XCTAssertFalse(state.registerTailChange())
        XCTAssertEqual(state.pendingAction, .tailSync)

        XCTAssertEqual(state.endScroll(), .tailSync)
        XCTAssertEqual(state.pendingAction, .none)
        XCTAssertFalse(state.isScrollInFlight)
    }

    func testFullRefreshOverridesTailSyncWhileScrolling() {
        var state = AIChatTranscriptDeferredUpdateState()
        state.beginScroll()

        XCTAssertFalse(state.registerTailChange())
        XCTAssertFalse(state.registerFullRefresh())
        XCTAssertEqual(state.pendingAction, .fullRefresh)
        XCTAssertEqual(state.endScroll(), .fullRefresh)
    }

    func testResetClearsDeferredActionForSessionSwitch() {
        var state = AIChatTranscriptDeferredUpdateState()
        state.beginScroll()
        XCTAssertFalse(state.registerFullRefresh())

        state.reset()

        XCTAssertEqual(state.pendingAction, .none)
        XCTAssertFalse(state.isScrollInFlight)
        XCTAssertNil(state.endScroll())
    }

    func testAnimatingAndDeceleratingAreBothScrollingPhases() {
        XCTAssertTrue(ScrollPhase.animating.isScrolling)
        XCTAssertTrue(ScrollPhase.decelerating.isScrolling)
        XCTAssertFalse(ScrollPhase.idle.isScrolling)
    }

    func testFollowUpAfterFullRefreshPreservesPrependAnchor() {
        let anchorMessage = AIChatMessage(
            messageId: "m-anchor",
            role: .assistant,
            parts: [AIChatPart(id: "p-anchor", kind: .text, text: "较早消息")]
        )
        let tailMessage = AIChatMessage(
            messageId: "m-tail",
            role: .assistant,
            parts: [AIChatPart(id: "p-tail", kind: .text, text: "最新消息")]
        )

        let followUp = AIChatTranscriptDeferredFlushSemantics.followUpAfterFullRefresh(
            previousSourceCount: 1,
            currentSourceCount: 2,
            currentDisplayMessages: [anchorMessage, tailMessage],
            pendingPrependAnchorID: anchorMessage.id,
            lastDisplayMessageCount: 1,
            lastTailMessageID: tailMessage.id
        )

        XCTAssertEqual(followUp, .preserveVisibleContent(anchorID: anchorMessage.id))
    }

    func testFollowUpAfterFullRefreshUpdatesTailWhenNoPrependAnchor() {
        let oldMessage = AIChatMessage(
            messageId: "m-old",
            role: .assistant,
            parts: [AIChatPart(id: "p-old", kind: .text, text: "旧尾部")]
        )
        let newMessage = AIChatMessage(
            messageId: "m-new",
            role: .assistant,
            parts: [AIChatPart(id: "p-new", kind: .text, text: "新尾部")]
        )

        let followUp = AIChatTranscriptDeferredFlushSemantics.followUpAfterFullRefresh(
            previousSourceCount: 1,
            currentSourceCount: 2,
            currentDisplayMessages: [oldMessage, newMessage],
            pendingPrependAnchorID: nil,
            lastDisplayMessageCount: 1,
            lastTailMessageID: oldMessage.id
        )

        XCTAssertEqual(followUp, .updateTail)
    }

    func testFollowUpAfterFullRefreshReturnsNoneWhenDisplayDidNotChange() {
        let message = AIChatMessage(
            messageId: "m-stable",
            role: .assistant,
            parts: [AIChatPart(id: "p-stable", kind: .text, text: "稳定内容")]
        )

        let followUp = AIChatTranscriptDeferredFlushSemantics.followUpAfterFullRefresh(
            previousSourceCount: 1,
            currentSourceCount: 1,
            currentDisplayMessages: [message],
            pendingPrependAnchorID: nil,
            lastDisplayMessageCount: 1,
            lastTailMessageID: message.id
        )

        XCTAssertEqual(followUp, .none)
    }

    // MARK: - 流式消息在 deferred flush 完成后不降级为轻量渲染

    func testStreamingMessageAlwaysFullRenderAfterDeferredTailSync() {
        // tailSync 刷新完成后，流式尾消息必须保持完整渲染，
        // 不能因 flushDeferredUpdate(.tailSync) 触发的 synchronizeDisplayMessagesCacheAfterTailChange
        // 将流式消息标记为非流式（这应由 AIChatTranscriptDisplayCacheSemantics 保证）。
        let streamingMessage = AIChatMessage(
            messageId: "m-stream",
            role: .assistant,
            parts: [AIChatPart(id: "p-stream", kind: .text, text: "流式输出中")],
            isStreaming: true
        )
        let snapshot = AIChatTranscriptDisplayCacheSemantics.synchronizeAfterTailChange(
            sourceMessages: [streamingMessage],
            pendingQuestions: [:],
            cachedDisplayMessages: [streamingMessage],
            cachedSourceCount: 1
        )
        XCTAssertTrue(
            snapshot.messages.first?.isStreaming == true,
            "tailSync 刷新后流式消息不应变为非流式"
        )
    }

    // MARK: - 多会话：deferred state 在会话切换时完全重置

    func testSessionSwitch_resetClearsAllPendingState() {
        // 会话 A 滚动中触发了 fullRefresh，切换到会话 B 后 deferred state 必须清空，
        // 避免会话 A 的待处理刷新影响会话 B 的显示。
        var state = AIChatTranscriptDeferredUpdateState()
        state.beginScroll()
        XCTAssertFalse(state.registerFullRefresh())
        XCTAssertEqual(state.pendingAction, .fullRefresh)

        // 模拟会话切换调用 reset()
        state.reset()
        XCTAssertFalse(state.isScrollInFlight)
        XCTAssertEqual(state.pendingAction, .none)
        XCTAssertNil(state.endScroll(), "reset 后 endScroll 应返回 nil，无残留 pending action")
    }

    // MARK: - tailSync 与 fullRefresh 的合并优先级

    func testTailSyncThenFullRefresh_mergesToFullRefresh() {
        var state = AIChatTranscriptDeferredUpdateState()
        state.beginScroll()
        XCTAssertFalse(state.registerTailChange())
        XCTAssertFalse(state.registerFullRefresh())
        // fullRefresh 应覆盖 tailSync
        XCTAssertEqual(state.pendingAction, .fullRefresh)
    }

    func testFullRefreshThenTailSync_mergeStaysFullRefresh() {
        var state = AIChatTranscriptDeferredUpdateState()
        state.beginScroll()
        XCTAssertFalse(state.registerFullRefresh())
        XCTAssertFalse(state.registerTailChange())
        // 已有 fullRefresh 不应被 tailSync 降级
        XCTAssertEqual(state.pendingAction, .fullRefresh)
    }
}
