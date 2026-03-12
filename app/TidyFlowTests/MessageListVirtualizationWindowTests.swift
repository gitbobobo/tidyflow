import XCTest
@testable import TidyFlow

// MARK: - MessageVirtualizationWindow 单元测试
// 覆盖虚拟化窗口计算、缓冲区边界、warm start、shouldFullyRender 决策路径

final class MessageListVirtualizationWindowTests: XCTestCase {

    // MARK: - 默认参数测试

    func testDefaultInit_bufferAndMultiplier() {
        let window = MessageVirtualizationWindow()
        XCTAssertEqual(window.bufferCount, 12, "默认 bufferCount 应为 12，与 ChatScrollConfiguration.renderBufferCount 一致")
        XCTAssertEqual(window.warmStartMultiplier, 3, "默认 warmStartMultiplier 应为 3")
    }

    func testCustomInit_appliesValues() {
        let window = MessageVirtualizationWindow(bufferCount: 6, warmStartMultiplier: 2)
        XCTAssertEqual(window.bufferCount, 6)
        XCTAssertEqual(window.warmStartMultiplier, 2)
    }

    // MARK: - computeFullRenderRange 测试

    func testComputeFullRenderRange_emptyVisibleIndices_returnsNil() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let result = window.computeFullRenderRange(visibleIndices: [], totalCount: 100)
        XCTAssertNil(result, "无可见索引时应返回 nil，代表需要走 warm start")
    }

    func testComputeFullRenderRange_zeroTotalCount_returnsNil() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let result = window.computeFullRenderRange(visibleIndices: [0], totalCount: 0)
        XCTAssertNil(result, "totalCount=0 时应返回 nil")
    }

    func testComputeFullRenderRange_singleVisibleMessage_extendsByBuffer() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        // 100 条消息，可见第 50 条
        let result = window.computeFullRenderRange(visibleIndices: [50], totalCount: 100)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lowerBound, 38, "下界应为 50 - 12 = 38")
        XCTAssertEqual(result?.upperBound, 62, "上界应为 50 + 12 = 62")
    }

    func testComputeFullRenderRange_topOfList_clampedAtZero() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        // 可见第 5 条，下界不应低于 0
        let result = window.computeFullRenderRange(visibleIndices: [5], totalCount: 100)
        XCTAssertEqual(result?.lowerBound, 0, "下界应被 clamp 到 0")
        XCTAssertEqual(result?.upperBound, 17)
    }

    func testComputeFullRenderRange_bottomOfList_clampedAtEnd() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        // 100 条消息，可见第 95 条，上界不应超过 99
        let result = window.computeFullRenderRange(visibleIndices: [95], totalCount: 100)
        XCTAssertEqual(result?.lowerBound, 83)
        XCTAssertEqual(result?.upperBound, 99, "上界应被 clamp 到 totalCount-1=99")
    }

    func testComputeFullRenderRange_multipleVisibleMessages_usesMinMaxWithBuffer() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        // 可见 30-40，buffer 延伸后为 18-52
        let result = window.computeFullRenderRange(visibleIndices: [30, 35, 40], totalCount: 100)
        XCTAssertEqual(result?.lowerBound, 18)
        XCTAssertEqual(result?.upperBound, 52)
    }

    func testComputeFullRenderRange_smallList_fullCoverage() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        // 只有 5 条消息，可见中间一条，整个列表都应被包含
        let result = window.computeFullRenderRange(visibleIndices: [2], totalCount: 5)
        XCTAssertEqual(result?.lowerBound, 0)
        XCTAssertEqual(result?.upperBound, 4)
    }

    // MARK: - warmStartRange 测试

    func testWarmStartRange_zeroMessages_returnsNil() {
        let window = MessageVirtualizationWindow(bufferCount: 12, warmStartMultiplier: 3)
        XCTAssertNil(window.warmStartRange(totalCount: 0))
    }

    func testWarmStartRange_fewMessages_coversAll() {
        let window = MessageVirtualizationWindow(bufferCount: 12, warmStartMultiplier: 3)
        // 消息少于 warmStartCount(36)，应覆盖全部
        let result = window.warmStartRange(totalCount: 10)
        XCTAssertEqual(result?.lowerBound, 0)
        XCTAssertEqual(result?.upperBound, 9)
    }

    func testWarmStartRange_manyMessages_coversOnlyTail() {
        let window = MessageVirtualizationWindow(bufferCount: 12, warmStartMultiplier: 3)
        // warmStartCount = 36，100 条消息从第 64 条开始
        let result = window.warmStartRange(totalCount: 100)
        XCTAssertEqual(result?.lowerBound, 64)
        XCTAssertEqual(result?.upperBound, 99)
    }

    func testWarmStartRange_exactlyWarmStartCount_coversAll() {
        let window = MessageVirtualizationWindow(bufferCount: 12, warmStartMultiplier: 3)
        // 恰好 36 条消息
        let result = window.warmStartRange(totalCount: 36)
        XCTAssertEqual(result?.lowerBound, 0)
        XCTAssertEqual(result?.upperBound, 35)
    }

    // MARK: - shouldFullyRender 测试：流式消息强制完整渲染

    func testShouldFullyRender_streamingMessage_alwaysTrue() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let result = window.shouldFullyRender(
            index: 200,
            isStreaming: true,
            fullRenderRange: nil,
            totalCount: 201
        )
        XCTAssertTrue(result, "流式消息无论索引如何都应完整渲染")
    }

    func testShouldFullyRender_streamingMessage_outsideRange_stillTrue() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let range: ClosedRange<Int> = 50...62
        let result = window.shouldFullyRender(
            index: 0,
            isStreaming: true,
            fullRenderRange: range,
            totalCount: 100
        )
        XCTAssertTrue(result, "流式消息即使在渲染范围外也应完整渲染")
    }

    // MARK: - shouldFullyRender 测试：有明确渲染范围

    func testShouldFullyRender_insideRange_returnsTrue() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let range: ClosedRange<Int> = 38...62
        XCTAssertTrue(window.shouldFullyRender(
            index: 50, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    func testShouldFullyRender_outsideRange_returnsFalse() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let range: ClosedRange<Int> = 38...62
        XCTAssertFalse(window.shouldFullyRender(
            index: 10, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    func testShouldFullyRender_atRangeBoundary_returnsTrue() {
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let range: ClosedRange<Int> = 38...62
        XCTAssertTrue(window.shouldFullyRender(
            index: 38, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
        XCTAssertTrue(window.shouldFullyRender(
            index: 62, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    // MARK: - shouldFullyRender 测试：无渲染范围（warm start 回退）

    func testShouldFullyRender_noRange_tailMessageFullyRendered() {
        let window = MessageVirtualizationWindow(bufferCount: 12, warmStartMultiplier: 3)
        // 100 条消息，warm start 覆盖 64-99，尾部消息应完整渲染
        XCTAssertTrue(window.shouldFullyRender(
            index: 99, isStreaming: false, fullRenderRange: nil, totalCount: 100
        ))
        XCTAssertTrue(window.shouldFullyRender(
            index: 64, isStreaming: false, fullRenderRange: nil, totalCount: 100
        ))
    }

    func testShouldFullyRender_noRange_headMessageLightweight() {
        let window = MessageVirtualizationWindow(bufferCount: 12, warmStartMultiplier: 3)
        // 100 条消息，warm start 覆盖 64-99，头部消息应轻量渲染
        XCTAssertFalse(window.shouldFullyRender(
            index: 0, isStreaming: false, fullRenderRange: nil, totalCount: 100
        ))
        XCTAssertFalse(window.shouldFullyRender(
            index: 63, isStreaming: false, fullRenderRange: nil, totalCount: 100
        ))
    }

    func testShouldFullyRender_noRange_emptyList_returnsFalse() {
        let window = MessageVirtualizationWindow(bufferCount: 12, warmStartMultiplier: 3)
        XCTAssertFalse(window.shouldFullyRender(
            index: 0, isStreaming: false, fullRenderRange: nil, totalCount: 0
        ))
    }

    // MARK: - 与 ChatScrollConfiguration 一致性测试

    func testBufferCount_matchesChatScrollConfigurationDefault() {
        let window = MessageVirtualizationWindow()
        let config = ChatScrollConfiguration()
        XCTAssertEqual(
            window.bufferCount,
            config.renderBufferCount,
            "MessageVirtualizationWindow.bufferCount 应与 ChatScrollConfiguration.renderBufferCount 保持一致"
        )
    }

    // MARK: - iOS 场景下的流式尾消息保护验证

    /// 验证 iOS 场景下（300 次流式 flush），流式尾消息不因 stableFullRenderRange 传递而降级。
    /// 即使 fullRenderRange 完全不包含尾部索引，isStreaming=true 也必须强制完整渲染。
    func testIOSStreamHeavy_300FlushScenario_tailAlwaysFullRender() {
        let window = MessageVirtualizationWindow()
        // 模拟 300 次 flush 后消息累计到 ~300 条，用户在底部可见最后 10 条
        let totalMessages = 300
        let visibleIndices = (290..<300).map { $0 }
        let renderRange = window.computeFullRenderRange(
            visibleIndices: visibleIndices, totalCount: totalMessages
        )

        // 流式尾消息（index=299）必须完整渲染
        XCTAssertTrue(
            window.shouldFullyRender(
                index: 299, isStreaming: true, fullRenderRange: renderRange, totalCount: totalMessages
            ),
            "iOS stream_heavy 场景：300 条消息流式尾部始终完整渲染"
        )
        // 历史消息（index=0）应轻量渲染
        XCTAssertFalse(
            window.shouldFullyRender(
                index: 0, isStreaming: false, fullRenderRange: renderRange, totalCount: totalMessages
            ),
            "iOS stream_heavy 场景：头部历史消息应轻量渲染"
        )
    }

    /// 验证 warm start 预算在 iOS 高频 flush 场景（300 条消息）下不失控。
    /// 完整渲染集大小应严格限定在 bufferCount * warmStartMultiplier 以内。
    func testWarmStartBudget_notExceededUnder300Messages() {
        let window = MessageVirtualizationWindow()
        let warmStart = window.warmStartRange(totalCount: 300)
        XCTAssertNotNil(warmStart)
        let warmStartCount = warmStart.map { $0.count } ?? 0
        let maxAllowedWarmStart = window.bufferCount * window.warmStartMultiplier
        XCTAssertLessThanOrEqual(
            warmStartCount, maxAllowedWarmStart,
            "300 条消息场景下 warm start 预算应 ≤ \(maxAllowedWarmStart)，实际 \(warmStartCount)"
        )
    }
}
