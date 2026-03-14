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

// MARK: - AIChatTranscriptViewportState 测试

/// 验证 AIChatTranscriptViewportState 可见窗口更新与 prepend 锚点语义。
final class AIChatTranscriptViewportStateTests: XCTestCase {

    func testResetClearsAllFields() {
        var state = AIChatTranscriptViewportState()
        state.visibleMessageIDs = ["m1", "m2"]
        state.stableFullRenderRange = 0...5
        state.pendingPrependAnchorID = "anchor-1"
        state.lastKnownContentHeight = 1500

        state.reset()

        XCTAssertTrue(state.visibleMessageIDs.isEmpty)
        XCTAssertNil(state.stableFullRenderRange)
        XCTAssertNil(state.pendingPrependAnchorID)
        XCTAssertEqual(state.lastKnownContentHeight, 0)
    }

    func testApplyVisibleIndicesUpdatesStableRange() {
        var state = AIChatTranscriptViewportState()
        let window = MessageVirtualizationWindow(bufferCount: 5, warmStartMultiplier: 2)

        state.applyVisibleIndices([10, 11, 12], totalCount: 30, window: window)

        XCTAssertNotNil(state.stableFullRenderRange, "有效可见索引应更新稳定渲染范围")
    }

    func testApplyEmptyVisibleIndicesDoesNotClearRange() {
        var state = AIChatTranscriptViewportState()
        state.stableFullRenderRange = 0...10

        let window = MessageVirtualizationWindow(bufferCount: 5, warmStartMultiplier: 2)
        state.applyVisibleIndices([], totalCount: 20, window: window)

        // 空可见索引时不应清除已有稳定范围（防止瞬时清空）
        XCTAssertNotNil(state.stableFullRenderRange, "空可见索引不应清除稳定渲染范围")
    }
}

// MARK: - AIChatTranscriptUpdatePlanner 测试

/// 验证 AIChatTranscriptUpdatePlanner 刷新策略计算语义。
final class AIChatTranscriptUpdatePlannerTests: XCTestCase {

    func testTailOnlyUpdateProducesTailSyncStrategy() {
        let msgs = (0..<5).map { i in makeMsg(id: "m\(i)", streaming: i == 4) }
        let strategy = AIChatTranscriptUpdatePlanner.strategy(
            previousSourceCount: 5,
            currentSourceCount: 5,
            isStreamingTail: true,
            hasPendingAnchor: false
        )
        XCTAssertEqual(strategy, .tailSync, "仅尾部流式更新应为 tailSync")
        _ = msgs
    }

    func testNewMessageProducesFullRefreshStrategy() {
        let strategy = AIChatTranscriptUpdatePlanner.strategy(
            previousSourceCount: 4,
            currentSourceCount: 5,
            isStreamingTail: false,
            hasPendingAnchor: false
        )
        XCTAssertEqual(strategy, .fullRefresh, "消息数增加应为 fullRefresh")
    }

    func testPrependAnchorTakesPriorityOverFullRefresh() {
        let strategy = AIChatTranscriptUpdatePlanner.strategy(
            previousSourceCount: 4,
            currentSourceCount: 10,
            isStreamingTail: false,
            hasPendingAnchor: true
        )
        if case .preserveAnchor = strategy {
            // 正确
        } else {
            XCTFail("有 prepend 锚点时应返回 preserveAnchor，got \(strategy)")
        }
    }

    func testUnchangedCountAndNoStreamingProducesNoneStrategy() {
        let strategy = AIChatTranscriptUpdatePlanner.strategy(
            previousSourceCount: 5,
            currentSourceCount: 5,
            isStreamingTail: false,
            hasPendingAnchor: false
        )
        XCTAssertEqual(strategy, .none, "无变化无流式应返回 none")
    }

    func testPlanPreservesViewportRangeAndPrependAnchor() {
        let messages = (0..<8).map { index in
            AIChatMessage(
                id: "m\(index)",
                messageId: "m\(index)",
                role: .assistant,
                parts: [AIChatPart(id: "p\(index)", kind: .text, text: "msg-\(index)")]
            )
        }
        var viewport = AIChatTranscriptViewportState()
        viewport.stableFullRenderRange = 2...6
        viewport.pendingPrependAnchorID = "m5"

        let plan = AIChatTranscriptUpdatePlanner.plan(
            sourceMessages: messages,
            pendingQuestions: [:],
            viewportState: viewport,
            cachedDisplayMessages: Array(messages.dropFirst(2)),
            cachedSourceCount: 6,
            isScrollInFlight: false
        )

        if case .preserveAnchor(let anchorID) = plan.refreshStrategy {
            XCTAssertEqual(anchorID, "m5")
        } else {
            XCTFail("prepend 历史时应优先生成 preserveAnchor 策略")
        }
        XCTAssertEqual(plan.fullRenderRange, 2...6, "planner 应保留 viewport 提供的稳定渲染范围")
        XCTAssertEqual(plan.pendingAnchorID, "m5")
    }

    func testPlanUsesTailSyncForLongStreamingTranscript() {
        let sourceMessages = (0..<320).map { index in
            AIChatMessage(
                id: "m\(index)",
                messageId: "m\(index)",
                role: .assistant,
                parts: [AIChatPart(id: "p\(index)", kind: .text, text: "token-\(index)")],
                isStreaming: index == 319
            )
        }
        let cachedMessages = (0..<320).map { index in
            AIChatMessage(
                id: "m\(index)",
                messageId: "m\(index)",
                role: .assistant,
                parts: [AIChatPart(id: "p\(index)", kind: .text, text: index == 319 ? "old-tail" : "token-\(index)")],
                isStreaming: index == 319
            )
        }

        let plan = AIChatTranscriptUpdatePlanner.plan(
            sourceMessages: sourceMessages,
            pendingQuestions: [:],
            viewportState: AIChatTranscriptViewportState(),
            cachedDisplayMessages: cachedMessages,
            cachedSourceCount: 320,
            isScrollInFlight: false
        )

        XCTAssertEqual(plan.refreshStrategy, .tailSync, "长会话尾部流式输出应走 tailSync")
        XCTAssertEqual(plan.displayMessages.count, 320)
        XCTAssertEqual(plan.displayMessages.last?.parts.first?.text, "token-319")
    }

    // MARK: - Helper

    private func makeMsg(id: String, streaming: Bool = false) -> AIChatMessage {
        AIChatMessage(
            id: id,
            messageId: id,
            role: .assistant,
            parts: [AIChatPart(id: "\(id)-p", kind: .text, text: "text")],
            isStreaming: streaming
        )
    }
}

// MARK: - AIChatTranscriptProjectionStore 测试

/// 验证共享转录投影 store 的增量刷新语义与缓存边界。
final class AIChatTranscriptProjectionStoreTests: XCTestCase {

    private func makeMsg(id: String, text: String = "text", streaming: Bool = false) -> AIChatMessage {
        AIChatMessage(
            id: id,
            messageId: id,
            role: .assistant,
            parts: [AIChatPart(id: "\(id)-p", kind: .text, text: text)],
            isStreaming: streaming
        )
    }

    func testEmptyProjectionAfterInit() {
        let store = AIChatTranscriptProjectionStore()
        XCTAssertTrue(store.projection.displayMessages.isEmpty)
        XCTAssertTrue(store.projection.messageIndexMap.isEmpty)
        XCTAssertNil(store.projection.fullRenderRange)
        XCTAssertEqual(store.cachedSourceCount, -1)
    }

    func testApplyPlanBuildsIndexMap() {
        let store = AIChatTranscriptProjectionStore()
        let messages = (0..<5).map { makeMsg(id: "m\($0)") }
        let plan = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: plan, sourceCount: 5)

        XCTAssertEqual(store.projection.displayMessages.count, 5)
        XCTAssertEqual(store.projection.messageIndexMap.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(store.projection.messageIndexMap["m\(i)"], i)
        }
        XCTAssertEqual(store.cachedSourceCount, 5)
    }

    func testTailSyncReusesIndexMap() {
        let store = AIChatTranscriptProjectionStore()
        let messages = (0..<5).map { makeMsg(id: "m\($0)") }

        // 先做 fullRefresh 建立初始 indexMap
        let initialPlan = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: initialPlan, sourceCount: 5)
        let initialIndexMap = store.projection.messageIndexMap

        // tailSync：消息数不变，只更新尾消息文本
        var tailMessages = messages
        tailMessages[4] = makeMsg(id: "m4", text: "updated-tail", streaming: true)
        let tailPlan = AIChatTranscriptRenderPlan(
            displayMessages: tailMessages,
            refreshStrategy: .tailSync,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: tailPlan, sourceCount: 5)

        // tailSync 应复用已有 indexMap，不重建
        XCTAssertEqual(store.projection.messageIndexMap, initialIndexMap,
                       "tailSync 应复用已有 indexMap，不重建")
        XCTAssertEqual(store.projection.displayMessages.last?.parts.first?.text, "updated-tail")
    }

    func testUpdateFullRenderRangeDoesNotRebuildMessages() {
        let store = AIChatTranscriptProjectionStore()
        let messages = (0..<10).map { makeMsg(id: "m\($0)") }
        let plan = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: plan, sourceCount: 10)

        // 更新渲染范围
        store.updateFullRenderRange(2...8)
        XCTAssertEqual(store.projection.fullRenderRange, 2...8)
        XCTAssertEqual(store.projection.displayMessages.count, 10, "updateFullRenderRange 不应改变消息列表")
        XCTAssertEqual(store.projection.messageIndexMap.count, 10, "updateFullRenderRange 不应改变索引映射")
    }

    func testUpdateFullRenderRangeSkipsWhenUnchanged() {
        let store = AIChatTranscriptProjectionStore()
        let messages = [makeMsg(id: "m0")]
        let plan = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: 0...0,
            pendingAnchorID: nil
        )
        store.apply(plan: plan, sourceCount: 1)

        // 相同范围不应触发更新
        store.updateFullRenderRange(0...0)
        XCTAssertEqual(store.projection.fullRenderRange, 0...0)
    }

    func testResetClearsAllState() {
        let store = AIChatTranscriptProjectionStore()
        let messages = (0..<5).map { makeMsg(id: "m\($0)") }
        let plan = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: 0...4,
            pendingAnchorID: nil
        )
        store.apply(plan: plan, sourceCount: 5)

        store.reset()

        XCTAssertTrue(store.projection.displayMessages.isEmpty)
        XCTAssertTrue(store.projection.messageIndexMap.isEmpty)
        XCTAssertNil(store.projection.fullRenderRange)
        XCTAssertEqual(store.cachedSourceCount, -1)
    }

    func testSessionSwitchClearsOldProjection() {
        let store = AIChatTranscriptProjectionStore()

        // 会话 A
        let messagesA = (0..<3).map { makeMsg(id: "a\($0)") }
        let planA = AIChatTranscriptRenderPlan(
            displayMessages: messagesA,
            refreshStrategy: .fullRefresh,
            fullRenderRange: 0...2,
            pendingAnchorID: nil
        )
        store.apply(plan: planA, sourceCount: 3)
        XCTAssertEqual(store.projection.messageIndexMap["a0"], 0)

        // 会话切换
        store.reset()

        // 会话 B
        let messagesB = (0..<2).map { makeMsg(id: "b\($0)") }
        let planB = AIChatTranscriptRenderPlan(
            displayMessages: messagesB,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: planB, sourceCount: 2)

        XCTAssertNil(store.projection.messageIndexMap["a0"], "会话 A 的索引不应残留")
        XCTAssertEqual(store.projection.messageIndexMap["b0"], 0)
        XCTAssertEqual(store.projection.messageIndexMap["b1"], 1)
    }

    func testPendingQuestionFullRefreshRebuildsIndexMap() {
        let store = AIChatTranscriptProjectionStore()
        let messages = (0..<5).map { makeMsg(id: "m\($0)") }

        // 初始 fullRefresh
        let plan1 = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: plan1, sourceCount: 5)

        // pendingQuestion 变更导致过滤后消息减少（模拟 fullRefresh）
        let filteredMessages = Array(messages.prefix(3))
        let plan2 = AIChatTranscriptRenderPlan(
            displayMessages: filteredMessages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: plan2, sourceCount: 5)

        XCTAssertEqual(store.projection.displayMessages.count, 3)
        XCTAssertEqual(store.projection.messageIndexMap.count, 3,
                       "pendingQuestion 变更后的 fullRefresh 应重建 indexMap")
    }

    func testHistoryPrependRebuildsIndexMap() {
        let store = AIChatTranscriptProjectionStore()

        // 初始 5 条消息
        let initial = (0..<5).map { makeMsg(id: "m\($0)") }
        let plan1 = AIChatTranscriptRenderPlan(
            displayMessages: initial,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: plan1, sourceCount: 5)
        XCTAssertEqual(store.projection.messageIndexMap["m0"], 0)

        // 历史 prepend：在头部插入 3 条
        let prepended = (0..<3).map { makeMsg(id: "h\($0)") } + initial
        let plan2 = AIChatTranscriptRenderPlan(
            displayMessages: prepended,
            refreshStrategy: .preserveAnchor(anchorID: "m0"),
            fullRenderRange: nil,
            pendingAnchorID: "m0"
        )
        store.apply(plan: plan2, sourceCount: 8)

        XCTAssertEqual(store.projection.messageIndexMap["h0"], 0)
        XCTAssertEqual(store.projection.messageIndexMap["m0"], 3,
                       "prepend 后原有消息索引应偏移")
        XCTAssertEqual(store.projection.displayMessages.count, 8)
    }
}
