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
}
