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

    // MARK: - 多项目多会话：窗口模型无状态，可跨场景复用

    func testStateless_sameWindowReusableAcrossSessions() {
        let window = makeWindow(buffer: 12)

        // 会话 A：100 条消息，可见 80-85
        let rangeA = window.computeFullRenderRange(visibleIndices: [80, 82, 85], totalCount: 100)

        // 会话 B：50 条消息，可见 20-25
        let rangeB = window.computeFullRenderRange(visibleIndices: [20, 22, 25], totalCount: 50)

        XCTAssertNotEqual(rangeA, rangeB, "不同会话的渲染范围不同，窗口模型应无状态")
        // 分别验证两个会话的索引决策互不干扰
        XCTAssertTrue(window.shouldFullyRender(
            index: 80, isStreaming: false, fullRenderRange: rangeA, totalCount: 100
        ))
        XCTAssertFalse(window.shouldFullyRender(
            index: 80, isStreaming: false, fullRenderRange: rangeB, totalCount: 50
        ))
    }
}
