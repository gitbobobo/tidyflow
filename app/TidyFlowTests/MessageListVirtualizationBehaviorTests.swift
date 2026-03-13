import XCTest
@testable import TidyFlow

// MARK: - 消息虚拟化行为回归测试
// 验证完整/轻量渲染切换逻辑在各类典型场景下的行为正确性，
// 包括流式消息保护、滚动窗口更新、多项目多会话场景下的一致性。

final class MessageListVirtualizationBehaviorTests: XCTestCase {

    // MARK: - 辅助工具

    private func makeWindow(buffer: Int = 12) -> MessageVirtualizationWindow {
        MessageVirtualizationWindow(bufferCount: buffer, warmStartMultiplier: 3)
    }

    // MARK: - 流式消息保护：流式消息不因虚拟化而降级

    func testStreamingProtection_streamingMessageAlwaysFullRender() {
        let window = makeWindow()
        // 模拟长会话中的流式尾部消息
        for index in [0, 50, 99, 200] {
            XCTAssertTrue(
                window.shouldFullyRender(index: index, isStreaming: true, fullRenderRange: nil, totalCount: 201),
                "流式消息（index=\(index)）应始终完整渲染"
            )
        }
    }

    func testStreamingProtection_streamingInsideRangeIsFullRender() {
        let window = makeWindow()
        let range = window.computeFullRenderRange(visibleIndices: [50], totalCount: 100)
        XCTAssertTrue(
            window.shouldFullyRender(index: 50, isStreaming: true, fullRenderRange: range, totalCount: 100)
        )
    }

    func testStreamingProtection_streamingOutsideRangeIsStillFullRender() {
        let window = makeWindow()
        let range = window.computeFullRenderRange(visibleIndices: [50], totalCount: 100)
        // index=0 在 range 外，但 isStreaming=true 应强制完整渲染
        XCTAssertTrue(
            window.shouldFullyRender(index: 0, isStreaming: true, fullRenderRange: range, totalCount: 100)
        )
    }

    // MARK: - 滚动窗口切换：可见区变化后完整渲染范围的更新

    func testWindowShift_scrollingDown_rangeFollows() {
        let window = makeWindow(buffer: 5)

        let rangeAtTop = window.computeFullRenderRange(visibleIndices: [0, 1, 2], totalCount: 100)
        let rangeAtMiddle = window.computeFullRenderRange(visibleIndices: [50, 51, 52], totalCount: 100)

        XCTAssertNotEqual(rangeAtTop, rangeAtMiddle, "滚动后渲染范围应更新")
        XCTAssertEqual(rangeAtTop?.lowerBound, 0)
        XCTAssertEqual(rangeAtMiddle?.lowerBound, 45)
        XCTAssertEqual(rangeAtMiddle?.upperBound, 57)
    }

    func testWindowShift_jumpToBottom_bottomRendered() {
        let window = makeWindow(buffer: 12)
        let range = window.computeFullRenderRange(visibleIndices: [87, 88, 89, 90], totalCount: 100)

        // 跳转到底部后，尾部消息应在范围内
        XCTAssertEqual(range?.upperBound, 99)
        XCTAssertTrue(window.shouldFullyRender(
            index: 99, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    // MARK: - 轻量占位：离屏消息应使用轻量渲染

    func testLightweightPlaceholder_farAboveViewport_notFullRender() {
        let window = makeWindow(buffer: 12)
        // 用户在底部（可见 85-95），头部消息（0-72）应轻量渲染
        let range = window.computeFullRenderRange(visibleIndices: [85, 90, 95], totalCount: 100)
        for index in 0...72 {
            XCTAssertFalse(
                window.shouldFullyRender(index: index, isStreaming: false, fullRenderRange: range, totalCount: 100),
                "头部消息（index=\(index)）应轻量渲染"
            )
        }
    }

    func testLightweightPlaceholder_transitionBoundary_preciseAtBuffer() {
        let window = makeWindow(buffer: 12)
        // 可见 [50]，完整渲染范围 38...62
        let range = window.computeFullRenderRange(visibleIndices: [50], totalCount: 100)
        XCTAssertEqual(range?.lowerBound, 38)

        // 边界：index=37 轻量，index=38 完整
        XCTAssertFalse(window.shouldFullyRender(
            index: 37, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
        XCTAssertTrue(window.shouldFullyRender(
            index: 38, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    // MARK: - 会话重载后的初始状态（warm start）

    func testWarmStart_newSession_tailIsFullRender() {
        let window = makeWindow(buffer: 12)
        // 会话刚加载，visibleIDs 为空，走 warm start（尾部 36 条完整渲染）
        let range: ClosedRange<Int>? = nil // 无可见索引
        XCTAssertTrue(window.shouldFullyRender(
            index: 99, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
        XCTAssertTrue(window.shouldFullyRender(
            index: 64, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    func testWarmStart_newSession_headIsLightweight() {
        let window = makeWindow(buffer: 12)
        let range: ClosedRange<Int>? = nil
        XCTAssertFalse(window.shouldFullyRender(
            index: 0, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
        XCTAssertFalse(window.shouldFullyRender(
            index: 63, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    // MARK: - 边界：空消息列表

    func testEmptyMessageList_noRangeNoWarmStart() {
        let window = makeWindow(buffer: 12)
        let range = window.computeFullRenderRange(visibleIndices: [], totalCount: 0)
        XCTAssertNil(range)
        XCTAssertFalse(window.shouldFullyRender(
            index: 0, isStreaming: false, fullRenderRange: nil, totalCount: 0
        ))
    }

    // MARK: - 会话切换后恢复 warm start（共享语义验证）

    func testSessionSwitch_resetsToWarmStart_newSessionTailFullRender() {
        // 会话切换后 visibleMessageIDs 清空，warm start 覆盖新会话尾部。
        // 无论 macOS 还是 iOS，切换后都应从尾部 warm start 开始，不保留旧会话范围。
        let window = makeWindow(buffer: 12)
        // 旧会话：100 条消息，可见中部
        _ = window.computeFullRenderRange(visibleIndices: [45, 50, 55], totalCount: 100)

        // 新会话：80 条消息，visibleIndices 为空（warm start 路径）
        let range: ClosedRange<Int>? = nil
        XCTAssertTrue(window.shouldFullyRender(
            index: 79, isStreaming: false, fullRenderRange: range, totalCount: 80
        ), "会话切换后 warm start 路径应覆盖新会话尾部消息")
        XCTAssertTrue(window.shouldFullyRender(
            index: 44, isStreaming: false, fullRenderRange: range, totalCount: 80
        ), "80 条消息 warm start（36 条尾部）从 index=44 开始，应完整渲染")
        XCTAssertFalse(window.shouldFullyRender(
            index: 43, isStreaming: false, fullRenderRange: range, totalCount: 80
        ), "warm start 范围之外应轻量渲染")
    }

    // MARK: - 历史 prepend 后可见区 ID 跟踪的正确性

    func testHistoryPrepend_visibleIDsPreserved_rangeShiftsCorrectly() {
        // 历史 prepend 后，visibleMessageIDs 中保留的 ID 对应新列表中的新索引。
        // 窗口应能正确映射 ID → 新索引 → 新范围，不依赖固定索引缓存。
        let window = makeWindow(buffer: 5)

        // 原列表：100 条消息，可见 85...89
        let rangeBeforePrepend = window.computeFullRenderRange(
            visibleIndices: [85, 86, 87, 88, 89], totalCount: 100
        )
        XCTAssertEqual(rangeBeforePrepend?.lowerBound, 80)
        XCTAssertEqual(rangeBeforePrepend?.upperBound, 94)

        // 模拟 prepend 30 条：同一批 visible 消息在新列表中位于 115...119
        let rangeAfterPrepend = window.computeFullRenderRange(
            visibleIndices: [115, 116, 117, 118, 119], totalCount: 130
        )
        XCTAssertEqual(rangeAfterPrepend?.lowerBound, 110, "prepend 后渲染范围下界应随索引偏移更新")
        XCTAssertEqual(rangeAfterPrepend?.upperBound, 124)
    }

    // MARK: - 流式刷新后 deferred flush 不中断尾部完整渲染

    func testStreamingFlush_tailMessageFullRenderAfterDeferredFlush() {
        // 模拟 deferred flush 场景：滚动结束后刷新，流式尾部消息不因范围计算延迟而降级。
        // 这对应共享滚动路径中 flushDeferredUpdate(.tailSync) 之后的尾部渲染保护。
        let window = makeWindow(buffer: 12)

        // 流式消息在任何索引处都应完整渲染，与 fullRenderRange 无关
        let rangeAfterFlush = window.computeFullRenderRange(
            visibleIndices: [80, 85, 90], totalCount: 100
        )

        // 尾部流式消息（index=99）即使在 fullRenderRange 之外也应完整渲染
        XCTAssertTrue(window.shouldFullyRender(
            index: 99, isStreaming: true, fullRenderRange: rangeAfterFlush, totalCount: 100
        ), "deferred flush 后流式尾消息必须始终完整渲染")
    }

    // MARK: - 多工作区：窗口模型无单工作区假设

    func testMultiWorkspace_windowCalculationIsWorkspaceAgnostic() {
        // 同一 window 实例可在不同项目/工作区场景下复用，计算结果完全由输入决定。
        // 这验证了 MessageVirtualizationWindow 无单项目/单工作区假设。
        let window = makeWindow(buffer: 12)

        // 项目 A（工作区 default）：200 条消息，用户在中部
        let rangeA = window.computeFullRenderRange(
            visibleIndices: [95, 100, 105], totalCount: 200
        )
        // 项目 B（工作区 feature）：50 条消息，用户在顶部
        let rangeB = window.computeFullRenderRange(
            visibleIndices: [2, 3, 4], totalCount: 50
        )

        XCTAssertNotEqual(rangeA, rangeB, "不同场景的渲染范围不同，窗口模型应无全局状态")
        // 分别验证两场景互不干扰
        XCTAssertTrue(window.shouldFullyRender(
            index: 100, isStreaming: false, fullRenderRange: rangeA, totalCount: 200
        ))
        XCTAssertFalse(window.shouldFullyRender(
            index: 100, isStreaming: false, fullRenderRange: rangeB, totalCount: 50
        ), "50 条消息场景中 index=100 超出范围，不应完整渲染")
    }

    func testSharedMessageListViewTypeIsReusedBySubAgentAndEvolutionReplay() {
        let messages = [
            AIChatMessage(
                id: "m1",
                messageId: "m1",
                role: .assistant,
                parts: [AIChatPart(id: "p1", kind: .text, text: "hello")]
            ),
        ]
        let subAgentView = MessageListView(
            messages: messages,
            sessionToken: "sub-session",
            onQuestionReply: { _, _ in },
            onQuestionReject: { _ in },
            onQuestionReplyAsMessage: { _ in },
            onOpenLinkedSession: { _ in }
        )
        let replayView = MessageListView(
            messages: messages,
            sessionToken: "replay-session",
            onQuestionReply: { _, _ in },
            onQuestionReject: { _ in },
            onQuestionReplyAsMessage: { _ in },
            onOpenLinkedSession: nil
        )

        let subAgentBodyType = String(reflecting: type(of: subAgentView.body))
        let replayBodyType = String(reflecting: type(of: replayView.body))

        XCTAssertEqual(subAgentBodyType, replayBodyType, "子会话 viewer 与 Evolution replay 应复用同一 MessageListView 实现")
        XCTAssertTrue(subAgentBodyType.contains("AIChatTranscriptContainer"))
    }
}
